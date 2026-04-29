use std::fs::read_to_string;
use std::path::PathBuf;
use std::process::Command;

use cronyx::codegen::compile as codegen_compile;
use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
use cronyx::runtime::environment::Environment;
use cronyx::semantics::cps::cps_transform::transform as cps_transform;
use cronyx::semantics::cps::effect_marker::{mark_cps, mark_fn_effects};
use cronyx::semantics::cps::handler_transform::{transform as handler_transform, transform_ctl};
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
            meta_captures: Vec::new(),
        };
        process(staged_forest, &mut evaluator).unwrap()
    };

    let cps_info = mark_cps(&runtime_ast);
    let runtime_ast = cps_transform(runtime_ast, &cps_info);
    let fn_effect_info = mark_fn_effects(&runtime_ast);
    let mut runtime_ast = runtime_ast;
    handler_transform(&mut runtime_ast, &fn_effect_info);
    transform_ctl(&mut runtime_ast, &cps_info);

    let type_map = {
        let mut rt_env = TypeEnv::new();
        type_check_runtime(&runtime_ast, &mut rt_env, &mut Vec::new()).unwrap()
    };

    // ── Compile ───────────────────────────────────────────────────────────────
    codegen_compile(&runtime_ast, &type_map, &cps_info, out_path)
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
        .current_dir(root_path.parent().unwrap())
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
                &tmp_binary(stringify!($test)),
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
    cx_compile_test!(m4_countdown,  "tests/compile/m4", "countdown");
    cx_compile_test!(m5_sum,        "tests/compile/m5", "sum");
    cx_compile_test!(m6_apply,      "tests/compile/m6", "apply");
    cx_compile_test!(m7_safe_div,   "tests/compile/m7", "safe_div");
    cx_compile_test!(m8_gadt,       "tests/compile/m8", "gadt");
}

#[cfg(test)]
mod core {
    use super::*;

    cx_compile_test!(print_hello,            "tests/core/print",        "hello");
    cx_compile_test!(math_math,              "tests/core/math",         "math");
    cx_compile_test!(string_concat,          "tests/core/strings",      "concat");
    cx_compile_test!(string_methods,         "tests/core/strings",      "string_methods");
    cx_compile_test!(string_slice,           "tests/core/strings",      "string_slice");
    cx_compile_test!(string_index,           "tests/core/strings",      "string_index");
    cx_compile_test!(string_starts_ends,     "tests/core/strings",      "string_starts_ends");
    cx_compile_test!(variables_variables,    "tests/core/variables",    "variables");
    cx_compile_test!(variables_reassign,     "tests/core/variables",    "reassign");
    cx_compile_test!(control_if,             "tests/core/control",      "if");
    cx_compile_test!(control_else,           "tests/core/control",      "else");
    cx_compile_test!(control_if_else_chain,  "tests/core/control",      "if_else_chain");
    cx_compile_test!(control_while,          "tests/core/control",      "while");
    cx_compile_test!(control_for_c,          "tests/core/control",      "for_c");
    cx_compile_test!(func_greeting,          "tests/core/functions",    "greeting");
    cx_compile_test!(func_return,            "tests/core/functions",    "return");
    cx_compile_test!(func_fib,               "tests/core/functions",    "fib");
    cx_compile_test!(func_closure,           "tests/core/functions",    "closure");
    cx_compile_test!(func_trailing_it,              "tests/core/functions", "trailing_it");
    cx_compile_test!(func_trailing_explicit_param,  "tests/core/functions", "trailing_explicit_param");
    cx_compile_test!(func_trailing_after_args,      "tests/core/functions", "trailing_after_args");
    cx_compile_test!(func_trailing_multi_param,     "tests/core/functions", "trailing_multi_param");
    cx_compile_test!(func_trailing_foreach,         "tests/core/functions", "trailing_foreach");
    cx_compile_test!(list_list,              "tests/core/lists",        "list");
    cx_compile_test!(list_index_access,      "tests/core/lists",        "index_access");
    cx_compile_test!(list_index_assign,      "tests/core/lists",        "index_assign");
    cx_compile_test!(list_methods,           "tests/core/lists",        "list_methods");
    cx_compile_test!(struct_struct,          "tests/core/structs",      "struct");
    cx_compile_test!(struct_struct2,         "tests/core/structs",      "struct2");
    cx_compile_test!(struct_dot_assign,      "tests/core/structs",      "struct_dot_assign");
    cx_compile_test!(modules_import,         "tests/core/modules",      "main");
    cx_compile_test!(modules_qualified,      "tests/core/modules/qualified",   "main");
    cx_compile_test!(modules_alias,          "tests/core/modules/alias",       "main");
    cx_compile_test!(modules_selective,      "tests/core/modules/selective",   "main");
    cx_compile_test!(modules_multi_export,   "tests/core/modules/multi_export","main");
    cx_compile_test!(modules_circular,       "tests/core/modules/circular",    "main");
    cx_compile_test!(modules_same_dir,       "tests/core/modules/same_dir",    "main");
    cx_compile_test!(modules_wildcard,       "tests/core/modules/wildcard",    "main");
    cx_compile_test!(embed_embed,            "tests/core/embed",        "embed");
    cx_compile_test!(resolution_symbol,      "tests/core/resolution",   "symbol_res");
    cx_compile_test!(type_annot_var,         "tests/core/type_annotations", "var_annot");
    cx_compile_test!(type_annot_fn,          "tests/core/type_annotations", "fn_annot");
    cx_compile_test!(type_annot_mixed,       "tests/core/type_annotations", "mixed_annot");
    cx_compile_test!(enum_unit_variants,     "tests/core/enums",        "unit_variants");
    cx_compile_test!(enum_tuple_variants,    "tests/core/enums",        "tuple_variants");
    cx_compile_test!(enum_struct_variants,   "tests/core/enums",        "struct_variants");
    cx_compile_test!(enum_wildcard,          "tests/core/enums",        "wildcard");
    cx_compile_test!(ops_comparison,         "tests/core/operators",    "comparison");
    cx_compile_test!(ops_logical,            "tests/core/operators",    "logical");
    cx_compile_test!(ops_logical_symbols,    "tests/core/operators",    "logical_symbols");
    cx_compile_test!(ops_compound_assign,    "tests/core/operators",    "compound_assign");
    cx_compile_test!(ops_precedence,         "tests/core/operators",    "precedence");
    cx_compile_test!(ops_unary_minus,        "tests/core/operators",    "unary_minus");
    cx_compile_test!(ops_not_index,          "tests/core/operators",    "not_index");
    cx_compile_test!(slice_negative_index,   "tests/core/slices",       "negative_index");
    cx_compile_test!(slice_range,            "tests/core/slices",       "slice_range");
    cx_compile_test!(tuples_basic,           "tests/core/tuples",       "tuple_basic");
    cx_compile_test!(builtins_readfile,      "tests/core/builtins",     "readfile");
    cx_compile_test!(builtins_writefile,     "tests/core/builtins",     "writefile");
    cx_compile_test!(builtins_conversions,   "tests/core/builtins",     "conversions");
    cx_compile_test!(builtins_free,          "tests/core/builtins",     "free");
    cx_compile_test!(builtins_ord,           "tests/core/builtins",     "ord");
    cx_compile_test!(generics_generic_fn,    "tests/core/generics/generic_fn",      "main");
    cx_compile_test!(generics_generic_struct,"tests/core/generics/generic_struct",   "main");
    cx_compile_test!(generics_monomorphize,  "tests/core/generics/monomorphize",     "main");
    cx_compile_test!(traits_basic_impl,      "tests/core/traits/basic_impl",         "main");
    cx_compile_test!(traits_multiple_impls,  "tests/core/traits/multiple_impls",     "main");
    cx_compile_test!(traits_trait_bound,     "tests/core/traits/trait_bound",        "main");
    cx_compile_test!(defer_basic,            "tests/core/defer",        "defer_basic");
    cx_compile_test!(defer_lifo,             "tests/core/defer",        "defer_lifo");
    cx_compile_test!(defer_return,           "tests/core/defer",        "defer_return");
    cx_compile_test!(types_typeof_primitives,   "tests/types", "typeof_primitives");
    cx_compile_test!(types_typeof_slice,        "tests/types", "typeof_slice");
    cx_compile_test!(types_typeof_tuple,        "tests/types", "typeof_tuple");
    cx_compile_test!(types_typeof_record,       "tests/types", "typeof_record");
    cx_compile_test!(types_typeof_fn,           "tests/types", "typeof_fn");
    cx_compile_test!(types_typeof_enum,         "tests/types", "typeof_enum");
    cx_compile_test!(types_typeof_effect_ctl,         "tests/types", "typeof_effect_ctl");
    cx_compile_test!(types_typeof_effect_multi,       "tests/types", "typeof_effect_multi");
    cx_compile_test!(types_typeof_effect_transitive,  "tests/types", "typeof_effect_transitive");
    cx_compile_test!(types_typeof_effect_fn_vs_ctl,   "tests/types", "typeof_effect_fn_vs_ctl");
    cx_compile_test!(types_gadt,             "tests/types/gadt",        "main");
}

#[cfg(test)]
mod effects {
    use super::*;

    cx_compile_test!(effect_log,          "tests/effects/log",          "log");
    cx_compile_test!(effect_ask,          "tests/effects/ask",          "ask");
    cx_compile_test!(effect_exception,    "tests/effects/exception",    "exception");
    cx_compile_test!(effect_recover,      "tests/effects/recover",      "recover");
    cx_compile_test!(effect_flip,         "tests/effects/flip",         "flip");
    cx_compile_test!(effect_simple_guard, "tests/effects/logic",        "simple_guard");
    cx_compile_test!(effect_multi_guard,  "tests/effects/logic",        "multi_guard");
    cx_compile_test!(effect_handler,      "tests/effects/handler",      "handler");
    cx_compile_test!(effect_stream,       "tests/effects/stream",       "stream");
    cx_compile_test!(effect_async,        "tests/effects/async",        "async");
    cx_compile_test!(effect_multi_handle, "tests/effects/multi_handle", "multi_handle");
    cx_compile_test!(effect_delim,        "tests/effects/delim",        "delim");
}

#[cfg(test)]
mod operators {
    use super::*;

    cx_compile_test!(op_vec2_add,      "tests/operators", "vec2_add");
    cx_compile_test!(op_operator_chain,"tests/operators", "operator_chain");
    cx_compile_test!(op_operator_eq,   "tests/operators", "operator_eq");
    cx_compile_test!(op_operator_in_fn,"tests/operators", "operator_in_fn");
    cx_compile_test!(op_operator_mul,  "tests/operators", "operator_mul");
}

#[cfg(test)]
mod meta {
    use super::*;

    cx_compile_test!(execution_basic,   "tests/meta/execution", "basic");
    cx_compile_test!(execution_nested,  "tests/meta/execution", "nested");
    cx_compile_test!(codegen_basic,     "tests/meta/codegen",   "basic");
    cx_compile_test!(codegen_nested,    "tests/meta/codegen",   "nested");
    cx_compile_test!(codegen_env,       "tests/meta/codegen",   "env");
    cx_compile_test!(codegen_gen_meta,  "tests/meta/codegen",   "gen_meta");
    cx_compile_test!(codegen_greeting,  "tests/meta/codegen",   "greeting");
    cx_compile_test!(codegen_sub1,      "tests/meta/codegen",   "sub1");
    cx_compile_test!(codegen_gen_symbol,"tests/meta/codegen",   "gen_symbol");
    cx_compile_test!(meta_fn,           "tests/meta/functions", "meta_fn");
    cx_compile_test!(meta_fib,          "tests/meta/functions", "fib");
    cx_compile_test!(reflection_typeof, "tests/meta/reflection","typeof");
}
