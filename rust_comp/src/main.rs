mod args;
mod debug_sink;

use args::CliArgs;
use debug_sink::DebugSink;

use cronyx::error::{CompilerError, enrich_diagnostic};
use cronyx::semantics::cps::cps_transform::transform as cps_transform;
use cronyx::semantics::cps::effect_marker::mark_cps;
use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
use std::collections::HashMap;
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_annotated_view::TypeAnnotatedView;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::id_provider::IdProvider;
use std::io;
use std::path::PathBuf;

fn main() {
    let args = CliArgs::parse();
    let sink = DebugSink::from_args(&args);
    let mut entry_ctx: Option<(String, HashMap<usize, (usize, usize)>)> = None;
    if let Err(errors) = run_pipeline(&args.source_path, &sink, &mut entry_ctx) {
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
    root_path: &PathBuf,
    sink: &DebugSink,
    entry_ctx: &mut Option<(String, HashMap<usize, (usize, usize)>)>,
) -> Result<(), Vec<CompilerError>> {
    // LOAD — stop immediately on parse/IO error
    let files = load_compilation_unit(root_path)
        .map_err(|e| vec![CompilerError::Load(e)])?;

    let entry = files.iter().find(|f| matches!(f.role, FileRole::Entry)).unwrap();
    // Surface span context so main can enrich error diagnostics.
    *entry_ctx = Some((entry.source.clone(), entry.span_table.clone()));
    let meta_ast = &entry.ast;
    sink.dump_ast(meta_ast);

    // TYPE CHECK — collect all errors before stopping
    let (type_table, type_env) = type_check(meta_ast)
        .map_err(|errs| errs.into_iter().map(CompilerError::TypeCheck).collect::<Vec<_>>())?;
    sink.dump_typed_ast(TypeAnnotatedView::new(meta_ast, &type_table), &type_table);

    // METAPROCESSING — stop on first error
    let mut staged_forest = StagedForest::new();
    staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
    let mut id_provider = IdProvider::new();
    stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env)
        .map_err(|e| vec![CompilerError::Meta(e)])?;
    staged_forest.resolve_symbol_deps()
        .map_err(|e| vec![CompilerError::Meta(e)])?;
    sink.dump_staged(&staged_forest);

    let module_bindings = staged_forest.module_bindings.clone();
    let meta_env = Environment::new();

    let runtime_ast = {
        let mut stdout = io::stdout();
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            type_env: TypeEnv::new(),
            out: &mut stdout,
        };
        process(staged_forest, &mut evaluator)
            .map_err(|e| vec![CompilerError::Eval(e)])?
    };
    sink.dump_runtime_ast(&runtime_ast);
    sink.dump_runtime_code(&runtime_ast);

    // SELECTIVE CPS TRANSFORM — marks ctl-performing functions and rewrites their bodies
    // to pass continuations explicitly. Must run after meta-processing and before eval.
    let cps_info = mark_cps(&runtime_ast);
    let mut runtime_ast = runtime_ast;
    cps_transform(&mut runtime_ast, &cps_info);
    sink.dump_cps(&cps_info, &runtime_ast);

    // EVALUATION — stop on first error
    let mut setup_env = EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
        &mut io::stdout(),
        None,
        root_path.parent().map(|p| p.to_path_buf()),
    ).map_err(|e| vec![CompilerError::Eval(e)])?;

    Ok(())
}
