use cronyx::frontend::lexer::*;
use cronyx::frontend::parser::*;
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::*;
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
        writeln!(meta_ast_graph_file, "{:?}", meta_ast);

        let mut meta_ast_file = to_file(out_dir, "meta_ast.txt");
        meta_ast.format_tree(&mut meta_ast_file);

        // SEMANTIC ANALYSIS

        // METAPROCESSING

        let staged = process_root(&meta_ast, meta_ast.sem_root_stmts.clone()).unwrap();
        let mut stdout = io::stdout();

        let mut evaluator = InterpreterMetaEvaluator {
            env: Environment::new(),
            out: &mut stdout,
        };
        let runtime_ast = process(staged, &mut evaluator).unwrap();

        let mut runtime_ast_file = to_file(out_dir, "runtime_ast.txt");
        runtime_ast.format_tree(&mut runtime_ast_file);

        let mut runtime_ast_graph_file = to_file(out_dir, "runtime_ast_graph.txt");
        writeln!(runtime_ast_graph_file, "{:?}", runtime_ast);
        // EVALUATION

        eval(
            &runtime_ast,
            &runtime_ast.sem_root_stmts,
            Environment::new(),
            &mut io::stdout(),
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
