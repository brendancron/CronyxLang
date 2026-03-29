use cronyx::util::id_provider::IdProvider;
use cronyx::frontend::module_loader::{load_compilation_unit_with_autoscope, FileRole};
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_annotated_view::TypeAnnotatedView;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::formatters::tree_formatter::*;
use std::fmt::Debug;
use std::fs::{create_dir_all, File};
use std::io::{self, Write};
use std::path::PathBuf;

fn main() {
    fn run_pipeline(root_path: &PathBuf, out_dir: &PathBuf) {
        create_dir_all(&out_dir).unwrap();

        // LOAD all files in the compilation unit (entry + explicit imports)
        let files = load_compilation_unit_with_autoscope(root_path)
            .expect("failed to load compilation unit");

        let entry = files.iter().find(|f| matches!(f.role, FileRole::Entry)).unwrap();
        let meta_ast = &entry.ast;

        let mut meta_ast_graph_file = to_file(out_dir, "meta_ast_graph.txt");
        writeln!(meta_ast_graph_file, "{:?}", meta_ast).unwrap();

        let mut meta_ast_file = to_file(out_dir, "meta_ast.txt");
        meta_ast.format_tree(&mut meta_ast_file);

        // SEMANTIC ANALYSIS — TYPE CHECK PASS 1

        let (type_table, type_env) = type_check(meta_ast).unwrap();

        let mut type_table_file = to_file(out_dir, "type_table.txt");
        for (id, ty) in &type_table.expr_types {
            writeln!(type_table_file, "expr {id}: {ty:?}").unwrap();
        }
        for (id, ty) in &type_table.stmt_types {
            writeln!(type_table_file, "stmt {id}: {ty:?}").unwrap();
        }

        let mut meta_ast_typed_file = to_file(out_dir, "meta_ast_typed.txt");
        TypeAnnotatedView::new(meta_ast, &type_table).format_tree(&mut meta_ast_typed_file);

        // METAPROCESSING

        let mut staged_forest = StagedForest::new();
        staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
        let mut id_provider = IdProvider::new();
        stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env).unwrap();
        staged_forest.resolve_symbol_deps().unwrap();

        let mut staged_forest_graph_file = to_file(out_dir, "staged_forest_graph.txt");
        writeln!(staged_forest_graph_file, "{:?}", staged_forest).unwrap();

        let mut staged_forest_file = to_file(out_dir, "staged_forest.txt");
        staged_forest.format_tree(&mut staged_forest_file);

        let module_bindings = staged_forest.module_bindings.clone();
        let mut stdout = io::stdout();
        let meta_env = Environment::new();

        let runtime_ast = {
            let mut evaluator = InterpreterMetaEvaluator {
                env: meta_env.clone(),
                type_env: TypeEnv::new(),
                out: &mut stdout,
            };
            process(staged_forest, &mut evaluator).unwrap()
        };

        let mut runtime_ast_file = to_file(out_dir, "runtime_ast.txt");
        runtime_ast.format_tree(&mut runtime_ast_file);

        let mut runtime_ast_graph_file = to_file(out_dir, "runtime_ast_graph.txt");
        writeln!(runtime_ast_graph_file, "{:?}", runtime_ast).unwrap();

        // EVALUATION — setup module namespaces then run
        let mut setup_env = EnvHandler::from(meta_env.clone());
        setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

        eval(
            &runtime_ast,
            &runtime_ast.sem_root_stmts,
            meta_env,
            &mut io::stdout(),
            None,
        )
        .unwrap();
    }

    let input = std::env::args().nth(1);
    let root_path = PathBuf::from(input.expect("source file path required"));
    let out_path = PathBuf::from("../out");
    run_pipeline(&root_path, &out_path);
}

pub fn to_file(out_dir: &PathBuf, file_name: &str) -> File {
    File::create(out_dir.join(file_name)).unwrap()
}

pub fn dump<T: Debug, W: Write>(items: &[T], out: &mut W) {
    for item in items {
        writeln!(out, "{item:?}")
            .map_err(|e| e.to_string())
            .unwrap();
    }
}
