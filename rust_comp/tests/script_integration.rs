use std::fs::read_to_string;
use std::io::Cursor;
use std::path::PathBuf;

use cronyx::frontend::module_loader::{load_compilation_unit, FileRole};
use cronyx::runtime::environment::*;
use cronyx::runtime::interpreter::*;
use cronyx::semantics::cps::cps_transform::transform_interpreter as cps_transform;
use cronyx::semantics::cps::effect_marker::mark_cps;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::*;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::id_provider::IdProvider;

pub fn run_test(root_path: &PathBuf, out_path: &PathBuf) {
    eprintln!("input : {}", root_path.display());
    eprintln!("expect: {}", out_path.display());
    let expected_out = read_to_string(out_path).unwrap();

    // Load the compilation unit (entry file + explicit imports).
    let files = load_compilation_unit(root_path).expect("failed to load compilation unit");

    // Type-check the entry file.
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

    let module_bindings = staged_forest.module_bindings.clone();
    let mut eval_buf = Cursor::new(Vec::<u8>::new());
    let meta_env = Environment::new();

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

    // Hoist all functions and create module namespace values before eval.
    let mut setup_env = EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
        &mut eval_buf,
        None,
        root_path.parent().map(|p| p.to_path_buf()),
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
    mod core {
        use super::*;

        cx_test!(print_hello, "tests/core/print", "hello");
        cx_test!(math_math, "tests/core/math", "math");
        cx_test!(string_concat, "tests/core/strings", "concat");
        cx_test!(variables_variables, "tests/core/variables", "variables");
        cx_test!(variables_reassign, "tests/core/variables", "reassign");
        cx_test!(control_if, "tests/core/control", "if");
        cx_test!(control_else, "tests/core/control", "else");
        cx_test!(control_if_else_chain, "tests/core/control", "if_else_chain");
        cx_test!(func_greeting, "tests/core/functions", "greeting");
        cx_test!(func_return, "tests/core/functions", "return");
        cx_test!(func_fib, "tests/core/functions", "fib");
        cx_test!(func_closure, "tests/core/functions", "closure");
        cx_test!(list_list, "tests/core/lists", "list");
        cx_test!(struct_struct, "tests/core/structs", "struct");
        cx_test!(modules_import, "tests/core/modules", "main");
        cx_test!(modules_qualified, "tests/core/modules/qualified", "main");
        cx_test!(modules_alias, "tests/core/modules/alias", "main");
        cx_test!(modules_selective, "tests/core/modules/selective", "main");
        cx_test!(
            modules_multi_export,
            "tests/core/modules/multi_export",
            "main"
        );
        cx_test!(modules_circular, "tests/core/modules/circular", "main");
        cx_test!(modules_same_dir, "tests/core/modules/same_dir", "main");
        cx_test!(modules_wildcard, "tests/core/modules/wildcard", "main");
        cx_test!(embed_embed, "tests/core/embed", "embed");
        cx_test!(resolution_symbol, "tests/core/resolution", "symbol_res");
        cx_test!(type_annot_var, "tests/core/type_annotations", "var_annot");
        cx_test!(type_annot_fn, "tests/core/type_annotations", "fn_annot");
        cx_test!(
            type_annot_mixed,
            "tests/core/type_annotations",
            "mixed_annot"
        );
        cx_test!(enum_unit_variants, "tests/core/enums", "unit_variants");
        cx_test!(enum_tuple_variants, "tests/core/enums", "tuple_variants");
        cx_test!(enum_struct_variants, "tests/core/enums", "struct_variants");
        cx_test!(enum_wildcard, "tests/core/enums", "wildcard");

        // Required features for 0.1.0
        cx_test!(ops_comparison, "tests/core/operators", "comparison");
        cx_test!(ops_logical, "tests/core/operators", "logical");
        cx_test!(control_while, "tests/core/control", "while");
        cx_test!(list_index_access, "tests/core/lists", "index_access");
        cx_test!(list_index_assign, "tests/core/lists", "index_assign");
        cx_test!(list_methods, "tests/core/lists", "list_methods");
        cx_test!(string_methods, "tests/core/strings", "string_methods");
        cx_test!(string_slice,   "tests/core/strings", "string_slice");   // Phase 2d
        cx_test!(builtins_readfile, "tests/core/builtins", "readfile");
        cx_test!(builtins_conversions, "tests/core/builtins", "conversions");
        cx_test!(builtins_free, "tests/core/builtins", "free");

        // Required features for 0.1.1
        cx_test!(control_for_c, "tests/core/control", "for_c");
        cx_test!(tuples_basic, "tests/core/tuples", "tuple_basic");
        cx_test!(ops_precedence, "tests/core/operators", "precedence");
        cx_test!(
            ops_logical_symbols,
            "tests/core/operators",
            "logical_symbols"
        );
        cx_test!(
            ops_compound_assign,
            "tests/core/operators",
            "compound_assign"
        );
        cx_test!(ops_unary_minus, "tests/core/operators", "unary_minus");
        cx_test!(ops_not_index, "tests/core/operators", "not_index");

        // Slices
        cx_test!(slice_negative_index, "tests/core/slices", "negative_index");
        cx_test!(slice_range, "tests/core/slices", "slice_range");

        // typeof / type reflection
        cx_test!(types_typeof_primitives, "tests/types", "typeof_primitives");
        cx_test!(types_typeof_slice, "tests/types", "typeof_slice");
        cx_test!(types_typeof_tuple, "tests/types", "typeof_tuple");
        cx_test!(types_typeof_record, "tests/types", "typeof_record");
        cx_test!(types_typeof_fn, "tests/types", "typeof_fn");
        cx_test!(types_typeof_enum, "tests/types", "typeof_enum");

        // Effect typing — TDD: these fail until effect inference is implemented.
        // Expected output uses postfix effect row notation: (int) -> unit <yield>
        cx_test!(types_typeof_effect_ctl, "tests/types", "typeof_effect_ctl");
        cx_test!(
            types_typeof_effect_multi,
            "tests/types",
            "typeof_effect_multi"
        );
        cx_test!(
            types_typeof_effect_transitive,
            "tests/types",
            "typeof_effect_transitive"
        );
        cx_test!(
            types_typeof_effect_fn_vs_ctl,
            "tests/types",
            "typeof_effect_fn_vs_ctl"
        );

        // Required features for 0.1.4
        cx_test!(traits_basic_impl, "tests/core/traits/basic_impl", "main");
        cx_test!(
            traits_multiple_impls,
            "tests/core/traits/multiple_impls",
            "main"
        );
        cx_test!(traits_trait_bound, "tests/core/traits/trait_bound", "main");
        cx_test!(
            generics_generic_fn,
            "tests/core/generics/generic_fn",
            "main"
        );
        cx_test!(
            generics_generic_struct,
            "tests/core/generics/generic_struct",
            "main"
        );
        cx_test!(
            generics_monomorphize,
            "tests/core/generics/monomorphize",
            "main"
        );

        // Defer
        cx_test!(defer_basic, "tests/core/defer", "defer_basic");
        cx_test!(defer_lifo, "tests/core/defer", "defer_lifo");
        cx_test!(defer_return, "tests/core/defer", "defer_return");
    }

    /// Algebraic effects tests — organized by implementation phase.
    /// Tests are expected to fail until the corresponding phase is implemented.
    /// As each phase lands, more tests will pass.
    #[cfg(test)]
    mod effects {
        use super::*;

        // Phase 1: Parsing — effect declarations parse without crashing
        #[test]
        fn effect_decl_parse() {
            run_test(
                &test_dir("tests/effects/effect_decl_parse/effect_decl_parse.cx"),
                &test_dir("tests/effects/effect_decl_parse/effect_decl_parse.txt"),
            );
        }

        // Phase 2: fn effects
        #[test]
        fn effect_log() {
            run_test(
                &test_dir("tests/effects/log/log.cx"),
                &test_dir("tests/effects/log/log.txt"),
            );
        }

        #[test]
        fn effect_fn_shadow() {
            run_test(
                &test_dir("tests/effects/fn_shadow/fn_shadow.cx"),
                &test_dir("tests/effects/fn_shadow/fn_shadow.txt"),
            );
        }

        #[test]
        fn effect_fn_scoped() {
            run_test(
                &test_dir("tests/effects/fn_scoped/fn_scoped.cx"),
                &test_dir("tests/effects/fn_scoped/fn_scoped.txt"),
            );
        }

        // Phase 3: ctl effects — single resume
        #[test]
        fn effect_yield() {
            run_test(
                &test_dir("tests/effects/yield/yield.cx"),
                &test_dir("tests/effects/yield/yield.txt"),
            );
        }

        #[test]
        fn effect_yield_nested_fn() {
            run_test(
                &test_dir("tests/effects/yield_nested_fn/yield_nested_fn.cx"),
                &test_dir("tests/effects/yield_nested_fn/yield_nested_fn.txt"),
            );
        }

        #[test]
        fn effect_yield_in_while() {
            run_test(
                &test_dir("tests/effects/yield_in_while/yield_in_while.cx"),
                &test_dir("tests/effects/yield_in_while/yield_in_while.txt"),
            );
        }

        #[test]
        fn effect_ctl_no_resume() {
            run_test(
                &test_dir("tests/effects/ctl_no_resume/ctl_no_resume.cx"),
                &test_dir("tests/effects/ctl_no_resume/ctl_no_resume.txt"),
            );
        }

        #[test]
        fn effect_resume_with_value() {
            run_test(
                &test_dir("tests/effects/resume_with_value/resume_with_value.cx"),
                &test_dir("tests/effects/resume_with_value/resume_with_value.txt"),
            );
        }

        #[test]
        fn effect_across_functions() {
            run_test(
                &test_dir("tests/effects/effect_across_functions/effect_across_functions.cx"),
                &test_dir("tests/effects/effect_across_functions/effect_across_functions.txt"),
            );
        }

        #[test]
        fn effect_handler_override() {
            run_test(
                &test_dir("tests/effects/handler_override/handler_override.cx"),
                &test_dir("tests/effects/handler_override/handler_override.txt"),
            );
        }

        // Phase 3: fn + ctl effects combined — single resume
        #[test]
        fn effect_nested_effects() {
            run_test(
                &test_dir("tests/effects/nested_effects/nested_effects.cx"),
                &test_dir("tests/effects/nested_effects/nested_effects.txt"),
            );
        }

        // Phase 4: ctl effects — multi resume
        #[test]
        fn effect_flip() {
            run_test(
                &test_dir("tests/effects/flip/flip.cx"),
                &test_dir("tests/effects/flip/flip.txt"),
            );
        }

        #[test]
        fn effect_multi_resume_accumulate() {
            run_test(
                &test_dir("tests/effects/multi_resume_accumulate/multi_resume_accumulate.cx"),
                &test_dir("tests/effects/multi_resume_accumulate/multi_resume_accumulate.txt"),
            );
        }

        // Phase 5: built-in choose + assert (non-determinism + pruning)
        #[test]
        fn effect_assert() {
            run_test(
                &test_dir("tests/effects/assert/assert.cx"),
                &test_dir("tests/effects/assert/assert.txt"),
            );
        }

        #[test]
        fn effect_assert_fn() {
            run_test(
                &test_dir("tests/effects/assert/assert_fn.cx"),
                &test_dir("tests/effects/assert/assert_fn.txt"),
            );
        }
    }

    /// Operator overloading tests — TDD, fail until impl lands.
    /// Syntax: `impl Add for Vec2 { fn add(a: Vec2, b: Vec2): Vec2 { ... } }`
    #[cfg(test)]
    mod operators {
        use super::*;

        #[test]
        fn op_vec2_add() {
            run_test(
                &test_dir("tests/operators/vec2_add.cx"),
                &test_dir("tests/operators/vec2_add.txt"),
            );
        }

        #[test]
        fn op_operator_chain() {
            run_test(
                &test_dir("tests/operators/operator_chain.cx"),
                &test_dir("tests/operators/operator_chain.txt"),
            );
        }

        #[test]
        fn op_operator_eq() {
            run_test(
                &test_dir("tests/operators/operator_eq.cx"),
                &test_dir("tests/operators/operator_eq.txt"),
            );
        }

        #[test]
        fn op_operator_in_fn() {
            run_test(
                &test_dir("tests/operators/operator_in_fn.cx"),
                &test_dir("tests/operators/operator_in_fn.txt"),
            );
        }

        #[test]
        fn op_operator_mul() {
            run_test(
                &test_dir("tests/operators/operator_mul.cx"),
                &test_dir("tests/operators/operator_mul.txt"),
            );
        }
    }

    #[cfg(test)]
    mod meta {
        use super::*;

        cx_test!(execution_basic, "tests/meta/execution", "basic");
        cx_test!(execution_nested, "tests/meta/execution", "nested");
        cx_test!(codegen_basic, "tests/meta/codegen", "basic");
        cx_test!(codegen_nested, "tests/meta/codegen", "nested");
        cx_test!(codegen_env, "tests/meta/codegen", "env");
        cx_test!(codegen_gen_meta, "tests/meta/codegen", "gen_meta");
        cx_test!(codegen_greeting, "tests/meta/codegen", "greeting");
        cx_test!(codegen_sub1, "tests/meta/codegen", "sub1");
        cx_test!(codegen_gen_symbol, "tests/meta/codegen", "gen_symbol");
        cx_test!(meta_fn, "tests/meta/functions", "meta_fn");
        cx_test!(meta_fib, "tests/meta/functions", "fib");
        cx_test!(reflection_typeof, "tests/meta/reflection", "typeof");
    }
}
