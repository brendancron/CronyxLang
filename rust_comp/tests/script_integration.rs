use std::fs::read_to_string;
use std::io::{Cursor};
use std::path::PathBuf;

use cronyx::frontend::id_provider::IdProvider;
use cronyx::frontend::module_loader::{load_compilation_unit, load_compilation_unit_with_autoscope, FileRole};
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::*;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;

pub fn run_test(root_path: &PathBuf, out_path: &PathBuf) {
    eprintln!("input : {}", root_path.display());
    eprintln!("expect: {}", out_path.display());
    let expected_out = read_to_string(out_path).unwrap();

    // Load the compilation unit (entry file + explicit imports).
    let files = load_compilation_unit(root_path)
        .expect("failed to load compilation unit");

    // Type-check the entry file.
    let entry_ast = files.iter()
        .find(|f| matches!(f.role, FileRole::Entry))
        .map(|f| &f.ast)
        .unwrap();
    let type_env = type_check(entry_ast)
        .map(|(_, env)| env)
        .unwrap_or_else(|_| TypeEnv::new());

    let mut staged_forest = StagedForest::new();
    staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
    let mut id_provider = IdProvider::new();

    stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env).unwrap();
    staged_forest.resolve_symbol_deps().unwrap();

    let module_bindings = staged_forest.module_bindings.clone();
    let mut eval_buf = Cursor::new(Vec::<u8>::new());
    let meta_env = Environment::new();

    let runtime_ast = {
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            out: &mut eval_buf,
        };
        process(staged_forest, &mut evaluator).unwrap()
    };

    // Hoist all functions and create module namespace values before eval.
    let mut setup_env = EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
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

fn run_test_autoscope(root_path: &PathBuf, out_path: &PathBuf) {
    eprintln!("input : {}", root_path.display());
    eprintln!("expect: {}", out_path.display());
    let expected_out = read_to_string(out_path).unwrap();

    let files = load_compilation_unit_with_autoscope(root_path)
        .expect("failed to load compilation unit");

    let entry_ast = files.iter()
        .find(|f| matches!(f.role, FileRole::Entry))
        .map(|f| &f.ast)
        .unwrap();
    let type_env = type_check(entry_ast)
        .map(|(_, env)| env)
        .unwrap_or_else(|_| TypeEnv::new());

    let mut staged_forest = StagedForest::new();
    staged_forest.source_dir = root_path.parent().map(|p| p.to_path_buf());
    let mut id_provider = IdProvider::new();

    stage_all_files(&files, &mut staged_forest, &mut id_provider, &type_env).unwrap();
    staged_forest.resolve_symbol_deps().unwrap();

    let module_bindings = staged_forest.module_bindings.clone();
    let mut eval_buf = Cursor::new(Vec::<u8>::new());
    let meta_env = Environment::new();

    let runtime_ast = {
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            out: &mut eval_buf,
        };
        process(staged_forest, &mut evaluator).unwrap()
    };

    let mut setup_env = EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
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

macro_rules! cx_test_autoscope {
    ($test:ident, $dir:literal, $file:literal) => {
        #[test]
        fn $test() {
            run_test_autoscope(
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
    mod core {
        use super::*;

        cx_test!(print_hello,          "tests/core/print",     "hello");
        cx_test!(math_math,            "tests/core/math",      "math");
        cx_test!(string_concat,        "tests/core/strings",   "concat");
        cx_test!(variables_variables,  "tests/core/variables", "variables");
        cx_test!(variables_reassign,   "tests/core/variables", "reassign");
        cx_test!(control_if,           "tests/core/control",   "if");
        cx_test!(control_else,         "tests/core/control",   "else");
        cx_test!(control_if_else_chain,"tests/core/control",   "if_else_chain");
        cx_test!(func_greeting,        "tests/core/functions", "greeting");
        cx_test!(func_return,          "tests/core/functions", "return");
        cx_test!(func_fib,             "tests/core/functions", "fib");
        cx_test!(func_closure,         "tests/core/functions", "closure");
        cx_test!(list_list,            "tests/core/lists",     "list");
        cx_test!(struct_struct,        "tests/core/structs",   "struct");
        cx_test!(modules_import,       "tests/core/modules",              "main");
        cx_test!(modules_qualified,    "tests/core/modules/qualified",    "main");
        cx_test!(modules_alias,        "tests/core/modules/alias",        "main");
        cx_test!(modules_selective,    "tests/core/modules/selective",    "main");
        cx_test!(modules_multi_export, "tests/core/modules/multi_export", "main");
        cx_test!(modules_circular,     "tests/core/modules/circular",     "main");
        cx_test_autoscope!(modules_same_dir, "tests/core/modules/same_dir", "main");
        cx_test!(embed_embed,          "tests/core/embed",     "embed");
        cx_test!(resolution_symbol,    "tests/core/resolution","symbol_res");
    }

    #[cfg(test)]
    mod meta {
        use super::*;

        cx_test!(execution_basic,      "tests/meta/execution", "basic");
        cx_test!(execution_nested,     "tests/meta/execution", "nested");
        cx_test!(codegen_basic,        "tests/meta/codegen",   "basic");
        cx_test!(codegen_nested,       "tests/meta/codegen",   "nested");
        cx_test!(codegen_env,          "tests/meta/codegen",   "env");
        cx_test!(codegen_gen_meta,     "tests/meta/codegen",   "gen_meta");
        cx_test!(codegen_greeting,     "tests/meta/codegen",   "greeting");
        cx_test!(codegen_sub1,         "tests/meta/codegen",   "sub1");
        cx_test!(codegen_gen_symbol,   "tests/meta/codegen",   "gen_symbol");
        cx_test!(meta_fn,              "tests/meta/functions", "meta_fn");
        cx_test!(meta_fib,             "tests/meta/functions", "fib");
        cx_test!(reflection_typeof,    "tests/meta/reflection","typeof");
    }
}
