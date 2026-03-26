use std::fs::read_to_string;
use std::io::{self, Cursor};
use std::path::PathBuf;

use cronyx::frontend::id_provider::IdProvider;
use cronyx::frontend::lexer::*;
use cronyx::frontend::parser::*;
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::*;
use cronyx::semantics::meta::meta_stager::process_root;
use cronyx::semantics::meta::staged_forest::StagedForest;

pub fn run_test(root_path: &PathBuf, out_path: &PathBuf) {
    eprintln!("input : {}", root_path.display());
    eprintln!("expect: {}", out_path.display());
    let in_buf = read_to_string(root_path).unwrap();
    let expected_out = read_to_string(out_path).unwrap();

    let tokens = tokenize(&in_buf).unwrap();
    let mut parse_ctx = ParseCtx::new();
    let _ = parse(&tokens, &mut parse_ctx).unwrap();
    let meta_ast = &(parse_ctx.ast);

    let mut staged_forest = StagedForest::new();
    let mut id_provider = IdProvider::new();
    let root_id = process_root(meta_ast, meta_ast.sem_root_stmts.clone(), &mut staged_forest, &mut id_provider).unwrap();
    staged_forest.root_id = root_id;

    let mut evaluator = InterpreterMetaEvaluator {
        env: Environment::new(),
        out: &mut io::stdout(),
    };
    let runtime_ast = process(staged_forest, &mut evaluator).unwrap();

    let mut eval_buf = Cursor::new(Vec::<u8>::new());

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        Environment::new(),
        &mut eval_buf,
        None,
    )
    .unwrap();

    let actual = String::from_utf8(eval_buf.into_inner()).unwrap();

    if normalize(&actual) != normalize(&expected_out) {
        panic!(
            "\n--- expected ---\n{}\n--- actual ---\n{}\n",
            expected_out, actual
        );
    }
}

fn normalize(s: &str) -> String {
    s.trim().replace("\r\n", "\n")
}

fn repo_root() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn test_dir(rel: &str) -> std::path::PathBuf {
    repo_root().join(rel)
}

macro_rules! cx_test {
    ($test:ident, $dir:literal, $file:literal) => {
        #[test]
        fn $test() {
            run_test(
                &test_dir(concat!($dir, "/", $file, ".cx")),
                &test_dir(concat!($dir, "/", $file, ".txt")),
            );
        }
    };
}

#[cfg(test)]
mod script_integration {
    use super::*;

    #[cfg(test)]
    mod vanilla {
        use super::*;

        // Testing Print Utility
        cx_test!(print_hello, "tests/01_vanilla/01_print", "hello");

        // Math and binary operators
        cx_test!(math_math, "tests/01_vanilla/02_math", "math");

        // String functions
        cx_test!(string_concat, "tests/01_vanilla/03_string", "concat");

        // Variables and Environment
        cx_test!(
            environment_variables,
            "tests/01_vanilla/04_environment",
            "01_variables"
        );
        cx_test!(
            environment_reassign,
            "tests/01_vanilla/04_environment",
            "02_reassign"
        );

        // Control Flow
        cx_test!(control_if, "tests/01_vanilla/05_control", "01_if");
        cx_test!(control_else, "tests/01_vanilla/05_control", "02_else");
        cx_test!(
            control_if_else_chain,
            "tests/01_vanilla/05_control",
            "03_if_else_chain"
        );

        // Functions
        cx_test!(func_greeting, "tests/01_vanilla/06_func", "01_greeting");
        cx_test!(func_return, "tests/01_vanilla/06_func", "02_return");
        cx_test!(func_fib, "tests/01_vanilla/06_func", "03_fib");
        cx_test!(func_closure, "tests/01_vanilla/06_func", "04_closure");

        // Lists
        cx_test!(list_list, "tests/01_vanilla/07_list", "01_list");

        // Struct
        cx_test!(struct_struct, "tests/01_vanilla/08_struct", "01_struct");

        // Imports
        cx_test!(imports_import, "tests/01_vanilla/09_imports", "main");

        // Embed
        cx_test!(embed_embed, "tests/01_vanilla/10_embed", "embed");
    }

    #[cfg(test)]
    mod meta {
        use super::*;

        // comptime
        cx_test!(comptime_basic, "tests/02_meta/comptime", "basic");
        cx_test!(comptime_nested, "tests/02_meta/comptime", "nested");

        // gen
        cx_test!(gen_basic, "tests/02_meta/gen", "basic");
        cx_test!(gen_nested, "tests/02_meta/gen", "nested");
        cx_test!(gen_env, "tests/02_meta/gen", "gen_env");
        cx_test!(gen_meta, "tests/02_meta/gen", "gen_meta");

        // fn (meta functions)
        cx_test!(meta_fn, "tests/02_meta/fn", "meta_fn");
        cx_test!(meta_fib, "tests/02_meta/fn", "fib");

        // reflection
        cx_test!(
            reflection_type_name,
            "tests/02_meta/reflection",
            "type_name"
        );

        // substitution
        cx_test!(
            substitution_greeting,
            "tests/02_meta/substitution",
            "greeting"
        );
        cx_test!(substitution_sub1, "tests/02_meta/substitution", "sub1");
    }
}
