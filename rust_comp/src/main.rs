use cronyx::frontend::lexer::*;
use cronyx::frontend::parser::*;
use cronyx::frontend::id_provider::IdProvider;
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::*;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_annotated_view::TypeAnnotatedView;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::util::formatters::tree_formatter::*;
use std::fmt::Debug;
use std::fs::{create_dir_all, read_to_string, File};
use std::io::{self, Write};
use std::path::PathBuf;

fn main() {
    fn run_pipeline(root_path: &PathBuf, out_dir: &PathBuf) {
        let buf = read_to_string(root_path).unwrap();
        create_dir_all(&out_dir).unwrap();

        // TOKENIZE

        let tokens = tokenize(&buf).unwrap();
        let mut tok_file = to_file(out_dir, "tokens.txt");
        dump(&tokens, &mut tok_file);

        // PARSE
        let mut parse_ctx = ParseCtx::new();
        let _ = parse(&tokens, &mut parse_ctx).unwrap();
        let meta_ast = &(parse_ctx.ast);

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
        process_root(
            &meta_ast,
            meta_ast.sem_root_stmts.clone(),
            &mut staged_forest,
            &mut id_provider,
            &type_env,
        ).unwrap();

        let mut staged_forest_graph_file = to_file(out_dir, "staged_forest_graph.txt");
        writeln!(staged_forest_graph_file, "{:?}", staged_forest).unwrap();

        let mut staged_forest_file = to_file(out_dir, "staged_forest.txt");
        staged_forest.format_tree(&mut staged_forest_file);

        let mut stdout = io::stdout();
        let meta_env = Environment::new();

        let runtime_ast = {
            let mut evaluator = InterpreterMetaEvaluator {
                env: meta_env.clone(),
                out: &mut stdout,
            };
            process(staged_forest, &mut evaluator).unwrap()
        };

        let mut runtime_ast_file = to_file(out_dir, "runtime_ast.txt");
        runtime_ast.format_tree(&mut runtime_ast_file);

        let mut runtime_ast_graph_file = to_file(out_dir, "runtime_ast_graph.txt");
        writeln!(runtime_ast_graph_file, "{:?}", runtime_ast).unwrap();
        // EVALUATION

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
