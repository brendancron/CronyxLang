use std::fs::read_to_string;
use std::path::PathBuf;
use std::process::Command;

use cronyx::codegen::compile as codegen_compile;
use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
use cronyx::runtime::environment::Environment;
use cronyx::semantics::cps::cps_transform::transform as cps_transform;
use cronyx::semantics::cps::effect_marker::mark_cps;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::runtime_type_checker::type_check_runtime;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::id_provider::IdProvider;
use std::io::Cursor;

/// Compile a `.cx` source file to a native binary, then:
///   1. Compare the emitted LLVM IR against `<expected_path>.ll` (if it exists).
///   2. Run the binary and compare stdout against `<expected_path>.txt`.
///
/// The `target triple` line is stripped from both IR files before comparison
/// so tests are portable across machines.
pub fn run_compile_test(root_path: &PathBuf, out_path: &PathBuf, expected_path: &PathBuf) {
    eprintln!("input : {}", root_path.display());
    eprintln!("binary: {}", out_path.display());
    eprintln!("expect: {}", expected_path.display());

    let expected = read_to_string(expected_path).unwrap();

    // ── Pipeline (mirrors main.rs run_pipeline) ───────────────────────────────
    let files = load_compilation_unit(root_path).expect("failed to load compilation unit");

    let entry_ast = files
        .iter()
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

    let meta_env = Environment::new();
    let mut eval_buf = Cursor::new(Vec::<u8>::new());

    let runtime_ast = {
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            type_env: TypeEnv::new(),
            out: &mut eval_buf,
        };
        process(staged_forest, &mut evaluator).unwrap()
    };

    let cps_info = mark_cps(&runtime_ast);
    let mut runtime_ast = runtime_ast;
    cps_transform(&mut runtime_ast, &cps_info);

    let type_map = {
        let mut rt_env = TypeEnv::new();
        type_check_runtime(&runtime_ast, &mut rt_env).unwrap()
    };

    // ── Compile ───────────────────────────────────────────────────────────────
    codegen_compile(&runtime_ast, &type_map, out_path)
        .expect("codegen failed");

    // ── IR regression check ───────────────────────────────────────────────────
    let ll_path = out_path.with_extension("ll");
    let expected_ll_path = expected_path.with_extension("ll");
    if expected_ll_path.exists() {
        let expected_ir = read_to_string(&expected_ll_path).unwrap();
        let actual_ir   = read_to_string(&ll_path).unwrap();
        if normalize_ir(&actual_ir) != normalize_ir(&expected_ir) {
            panic!(
                "\n--- expected IR ---\n{}\n--- actual IR ---\n{}\n",
                normalize_ir(&expected_ir),
                normalize_ir(&actual_ir),
            );
        }
    }

    // ── Run binary and capture stdout ─────────────────────────────────────────
    let output = Command::new(out_path)
        .output()
        .expect("failed to run compiled binary");

    let actual = String::from_utf8(output.stdout).unwrap();

    if normalize(&actual) != normalize(&expected) {
        panic!(
            "\n--- expected ---\n{}\n--- actual ---\n{}\n",
            expected, actual
        );
    }
}

fn normalize(s: &str) -> String {
    s.trim().replace("\r\n", "\n")
}

/// Strip machine-specific lines before comparing IR.
/// `target triple` varies by machine; everything else should be deterministic.
fn normalize_ir(s: &str) -> String {
    s.lines()
        .filter(|l| !l.starts_with("target triple"))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn test_dir(rel: &str) -> PathBuf {
    repo_root().join(rel)
}

fn tmp_binary(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cronyx_test_{name}"))
}

macro_rules! cx_compile_test {
    ($test:ident, $dir:literal, $file:literal) => {
        #[test]
        fn $test() {
            run_compile_test(
                &test_dir(concat!($dir, "/", $file, ".cx")),
                &tmp_binary(concat!($file)),
                &test_dir(concat!($dir, "/", $file, ".txt")),
            );
        }
    };
}

#[cfg(test)]
mod compile {
    use super::*;

    cx_compile_test!(m0_arithmetic, "tests/compile/m0", "m0");
    cx_compile_test!(m1_fibonacci,  "tests/compile/m1", "fib");
    cx_compile_test!(m2_struct,     "tests/compile/m2", "struct");
    cx_compile_test!(m3_factorial,  "tests/compile/m3", "fact");
}
