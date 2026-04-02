mod args;
mod debug_sink;

use args::CliArgs;
use debug_sink::DebugSink;

use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
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
    run_pipeline(&args.source_path, &sink);
}

fn run_pipeline(root_path: &PathBuf, sink: &DebugSink) {
    // LOAD
    let files = load_compilation_unit(root_path)
        .expect("failed to load compilation unit");

    let entry = files.iter().find(|f| matches!(f.role, FileRole::Entry)).unwrap();
    let meta_ast = &entry.ast;
    sink.dump_ast(meta_ast);

    // TYPE CHECK (pass 1)
    let (type_table, type_env) = type_check(meta_ast).unwrap();
    sink.dump_typed_ast(TypeAnnotatedView::new(meta_ast, &type_table), &type_table);

    // METAPROCESSING
    let mut staged_forest = StagedForest::new();
    staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
    let mut id_provider = IdProvider::new();
    stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env).unwrap();
    staged_forest.resolve_symbol_deps().unwrap();
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
        process(staged_forest, &mut evaluator).unwrap()
    };
    sink.dump_runtime_ast(&runtime_ast);
    sink.dump_runtime_code(&runtime_ast);

    // EVALUATION
    let mut setup_env = EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
        &mut io::stdout(),
        None,
        root_path.parent().map(|p| p.to_path_buf()),
    )
    .unwrap();
}
