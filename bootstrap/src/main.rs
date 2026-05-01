mod args;
mod debug_sink;

use args::CliArgs;
use debug_sink::DebugSink;

use cronyx::codegen::compile as codegen_compile;
use cronyx::error::{CompilerError, Diagnostic, enrich_diagnostic};
use cronyx::semantics::cps::cps_transform::transform as cps_transform;
use cronyx::semantics::cps::effect_marker::{mark_cps, mark_fn_effects};
use cronyx::semantics::cps::handler_transform::{transform as handler_transform, transform_ctl};
use cronyx::semantics::types::effect_inference;
use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
use std::collections::HashMap;
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::{process, ProcessError};
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::runtime_type_checker::type_check_runtime;
use cronyx::semantics::types::type_annotated_view::TypeAnnotatedView;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::id_provider::IdProvider;
use std::io;
use std::path::PathBuf;

fn main() {
    let args = CliArgs::parse().unwrap_or_else(|msg| {
        Diagnostic::new(msg).emit();
        std::process::exit(1);
    });
    let sink = DebugSink::from_args(&args);
    let mut entry_ctx: Option<(String, HashMap<usize, (usize, usize)>)> = None;
    if let Err(errors) = run_pipeline(&args, &sink, &mut entry_ctx) {
        for e in &errors {
            let mut diag = e.to_diagnostic();
            if diag.file.is_none() {
                diag.file = Some(args.source_path.clone());
            }
            if let Some((ref source, ref spans)) = entry_ctx {
                diag = enrich_diagnostic(diag, e, source, spans);
            }
            diag.emit();
        }
        if errors.len() > 1 {
            CompilerError::summary(errors.len()).emit();
        }
        std::process::exit(1);
    }
}

fn run_pipeline(
    args: &CliArgs,
    sink: &DebugSink,
    entry_ctx: &mut Option<(String, HashMap<usize, (usize, usize)>)>,
) -> Result<(), Vec<CompilerError>> {
    let root_path = &args.source_path;
    let stdlib_root = std::env::var("CRONYX_STDLIB")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            let candidates = [
                std::path::PathBuf::from("stdlib"),
                std::path::PathBuf::from("../stdlib"),
            ];
            candidates.into_iter()
                .find(|p| p.join("lang").is_dir())
                .unwrap_or_else(|| std::path::PathBuf::from("stdlib"))
        });
    // LOAD — stop immediately on parse/IO error
    let files = load_compilation_unit(root_path, &stdlib_root)
        .map_err(|e| vec![CompilerError::Load(e)])?;

    let entry = files.iter().find(|f| matches!(f.role, FileRole::Entry))
        .ok_or_else(|| vec![CompilerError::Codegen("internal error: no entry file found after loading".to_string())])?;
    // Surface span context so main can enrich error diagnostics.
    *entry_ctx = Some((entry.source.clone(), entry.span_table.clone()));
    let meta_ast = &entry.ast;
    sink.dump_ast(meta_ast);

    // TYPE CHECK — collect all errors before stopping
    let (type_table, mut type_env) = type_check(meta_ast)
        .map_err(|errs| errs.into_iter().map(CompilerError::TypeCheck).collect::<Vec<_>>())?;
    sink.dump_typed_ast(TypeAnnotatedView::new(meta_ast, &type_table), &type_table);

    // EFFECT INFERENCE (Pass A1) — update type_env with effect rows before staging so
    // typeof() expressions resolve to types that include effect annotations.
    effect_inference::infer_meta(meta_ast, &mut type_env);

    // METAPROCESSING — stop on first error
    let mut staged_forest = StagedForest::new();
    staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
    let mut id_provider = IdProvider::new();
    stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env)
        .map_err(|errs| errs.into_iter().map(CompilerError::Meta).collect::<Vec<_>>())?;
    staged_forest.resolve_symbol_deps()
        .map_err(|e| vec![CompilerError::Meta(e)])?;
    sink.dump_staged(&staged_forest);

    let meta_env = Environment::new();

    let runtime_ast = {
        let mut stdout = io::stdout();
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            type_env: TypeEnv::new(),
            out: &mut stdout,
            meta_captures: Vec::new(),
        };
        process(staged_forest, &mut evaluator)
            .map_err(|e| vec![match e {
                ProcessError::Eval(eval_err) => CompilerError::Eval(eval_err),
                ProcessError::Meta(meta_err) => CompilerError::Meta(meta_err),
            }])?
    };
    sink.dump_runtime_ast(&runtime_ast);
    sink.dump_runtime_code(&runtime_ast);

    // SELECTIVE CPS TRANSFORM — marks ctl-performing functions and rewrites their bodies
    // to pass continuations explicitly. Must run after meta-processing and before eval.
    let cps_info = mark_cps(&runtime_ast);

    // EFFECT INFERENCE (Pass A2 + B) — infer per-function effect rows and check that
    // every top-level call site has all required effects handled.
    effect_inference::infer_and_check(&runtime_ast, &cps_info)
        .map_err(|e| vec![e])?;
    let runtime_ast = cps_transform(runtime_ast, &cps_info);
    let fn_effect_info = mark_fn_effects(&runtime_ast);
    let mut runtime_ast = runtime_ast;
    handler_transform(&mut runtime_ast, &fn_effect_info);
    transform_ctl(&mut runtime_ast, &cps_info);
    sink.dump_cps(&cps_info, &runtime_ast);

    // RUNTIME TYPE CHECK — needed by codegen; also validates the post-CPS AST.
    let type_map = {
        let mut rt_env = TypeEnv::new();
        let mut rt_warnings: Vec<_> = Vec::new();
        let map = type_check_runtime(&runtime_ast, &mut rt_env, &mut rt_warnings)
            .map_err(|e| vec![CompilerError::TypeCheck(e)])?;
        // Polymorphic-call warnings are non-fatal for the interpreter (runtime
        // dispatch handles them correctly) but block codegen (which would emit
        // wrong types). Surface them as errors only on the compile path.
        if !args.interpret && !rt_warnings.is_empty() {
            return Err(rt_warnings.into_iter().map(CompilerError::TypeCheck).collect());
        }
        map
    };

    // INTERPRET — tree-walking interpreter when --interpret is set.
    if args.interpret {
        let mut setup_env = EnvHandler::from(meta_env.clone());
        setup_modules(&runtime_ast, &mut setup_env);

        eval(
            &runtime_ast,
            &runtime_ast.sem_root_stmts,
            meta_env,
            &mut io::stdout(),
            None,
            root_path.parent().map(|p| p.to_path_buf()),
        ).map_err(|e| vec![CompilerError::Eval(e)])?;

        return Ok(());
    }

    // COMPILE — emit native binary via LLVM (default).
    let out_path = args.out_path.clone().unwrap_or_else(|| PathBuf::from("a.out"));
    codegen_compile(&runtime_ast, &type_map, &cps_info, &out_path)
        .map_err(|e| vec![CompilerError::Codegen(e.to_string())])?;

    Ok(())
}
