(* Fixtures live in <repo>/tests: a .cx with a .txt of its expected stdout, or
   with a .err holding one `[line:col] message` per diagnostic. Listed
   explicitly, so the lists record what this bootstrap supports. *)

open Bootstrap

let cases =
  [ "tests/core/print/hello"
  ; "tests/core/math/math"
  ; "tests/core/variables/variables"
  ; "tests/core/variables/reassign"
  ; "tests/core/control/if"
  ; "tests/core/control/else"
  ; "tests/core/control/if_else_chain"
  ; "tests/core/control/while"
  ; "tests/core/control/for_in"
  ; "tests/core/modules/main"
  ; "tests/core/modules/alias/main"
  ; "tests/core/modules/multi_export/main"
  ; "tests/core/modules/qualified/main"
  ; "tests/core/modules/same_dir/main"
  ; "tests/core/modules/selective/main"
  ; "tests/core/modules/wildcard/main"
  ; "tests/core/modules/circular/main"
  ; "tests/core/modules/types/main"
  ; "tests/stdlib/math/math"
  ; "tests/stdlib/error/error"
  ; "tests/core/control/for_c"
  ; "tests/core/operators/comparison"
  ; "tests/core/operators/compound_assign"
  ; "tests/core/operators/compound_target"
  ; "tests/core/operators/unary_minus"
  ; "tests/core/type_annotations/var_annot"
  ; "tests/core/type_annotations/fn_annot"
  ; "tests/core/type_annotations/mixed_annot"
  ; "tests/core/strings/concat"
  ; "tests/core/functions/fib"
  ; "tests/core/functions/greeting"
  ; "tests/core/functions/return"
  ; "tests/core/functions/closure"
  ; "tests/core/functions/evaluation_order"
  ; "tests/types/inference/annotations"
  ; "tests/types/inference/numeric_defaulting"
  ; "tests/types/inference/polymorphism"
  ; "tests/types/inference/float_math"
  ; "tests/types/inference/higher_order"
  ; "tests/types/inference/polymorphic_recursion"
  ; "tests/reflection/typeof_exprs"
  ; "tests/reflection/typeof_primitives"
  ; "tests/reflection/typeof_fn"
  ; "tests/reflection/typeof_generic"
  ; "tests/reflection/typeof_pack"
  ; "tests/effects/rows/inferred_rows"
  ; "tests/effects/rows/builtin_in_effectful_fn"
  ; "tests/effects/rows/inferred_polymorphic"
  ; "tests/effects/rows/row_variable"
  ; "tests/effects/rows/map_over_effects"
  ; "tests/effects/rows/row_extension"
  ; "tests/effects/log/log"
  ; "tests/effects/ask/ask"
  ; "tests/effects/multi_handle/multi_handle"
  ; "tests/effects/multi_handle/differing_arms"
  ; "tests/effects/exception/exception"
  ; "tests/effects/delim/delim"
  ; "tests/effects/flip/flip"
  ; "tests/effects/recover/recover"
  ; "tests/effects/handler/handler"
  ; "tests/effects/stream/stream"
  ; "tests/effects/run_value/value"
  ; "tests/effects/run_value/return_clause"
  ; "tests/effects/run_value/unit_body"
  ; "tests/effects/run_value/arm_answers"
  ; "tests/effects/run_value/two_in_one_expr"
  ; "tests/effects/deferred/deferred"
  ; "tests/effects/async/async"
  ; "tests/effects/fn_values/in_list"
  ; "tests/effects/fn_values/in_tuple"
  ; "tests/effects/fn_values/named_as_value"
  ; "tests/effects/fn_values/suspending_closure"
  ; "tests/effects/fn_values/closure_in_arm"
  ; "tests/effects/fn_values/through_index"
  ; "tests/effects/fn_values/spawn"
  ; "tests/effects/fn_values/multishot_closure"
  ; "tests/effects/fn_values/nested_spawn"
  ; "tests/effects/abort_after_resumption"
  ; "tests/effects/abort_under_conversion"
  ; "tests/core/arrays/basics"
  ; "tests/core/arrays/identity"
  ; "tests/core/arrays/methods"
  ; "tests/core/lists/index_access"
  ; "tests/core/lists/index_assign"
  ; "tests/core/lists/list"
  ; "tests/core/lists/list_methods"
  ; "tests/core/collections/user_container"
  ; "tests/core/collections/set"
  ; "tests/core/collections/map"
  ; "tests/core/collections/narrowing"
  ; "tests/core/strings/string_methods"
  ; "tests/core/strings/escapes"
  ; "tests/core/syntax/trailing_comma"
  ; "tests/core/strings/string_index"
  ; "tests/core/chars/basics"
  ; "tests/core/chars/unicode"
  ; "tests/core/operators/not_index"
  ; "tests/core/operators/structural_equality"
  ; "tests/core/operators/bounded_param"
  ; "tests/core/operators/partial_ord"
  ; "tests/core/tuples/tuple_basic"
  ; "tests/reflection/typeof_tuple"
  ; "tests/core/tuples/typed"
  ; "tests/core/tuples/destructure"
  ; "tests/core/for_tuple/for_tuple"
  ; "tests/core/records/structural"
  ; "tests/reflection/typeof_record"
  ; "tests/reflection/shape_product"
  ; "tests/reflection/shape_sum"
  ; "tests/reflection/shape_scalar"
  ; "tests/core/math/modulus"
  ; "tests/stdlib/list/list"
  ; "tests/stdlib/list/effectful"
  ; "tests/core/lambdas/basics"
  ; "tests/core/lambdas/trailing"
  ; "tests/core/lambdas/trailing_no_parens"
  ; "tests/core/lambdas/trailing_method"
  ; "tests/core/lambdas/method_brace_not_match"
  ; "tests/core/lambdas/trailing_arity"
  ; "tests/core/lambdas/trailing_arity_method"
  ; "tests/core/lambdas/trailing_named"
  ; "tests/core/ufcs/basics"
  ; "tests/core/ufcs/impl_wins"
  ; "tests/core/ufcs/with_lambda"
  ; "tests/core/ufcs/imported/main"
  ; "tests/stdlib/fallible/fallible"
  ; "tests/stdlib/toml/toml/toml"
  ; "tests/core/strings/string_slice"
  ; "tests/core/slices/overload"
  ; "tests/core/embed/embed"
  ; "tests/core/defer/defer_return"
  ; "tests/core/defer/defer_scope"
  ; "tests/core/defer/defer_effect"
  ; "tests/core/resolution/symbol_res"
  ; "tests/core/resolution/hoisting"
  ; "tests/core/builtins/print_value"
  ; "tests/core/builtins/readfile"
  ; "tests/core/builtins/writefile"
  ; "tests/core/builtins/readfile_meta"
  ; "tests/core/variadic/basics"
  ; "tests/core/variadic/generic"
  ; "tests/core/variadic/packs/basics"
  ; "tests/core/variadic/packs/empty"
  ; "tests/core/variadic/packs/through_fn"
  ; "tests/core/variadic/packs/written"
  ; "tests/core/variadic/packs/erased"
  ; "tests/core/variadic/packs/tuple"
  ; "tests/core/variadic/packs/tuple_empty"
  ; "tests/core/variadic/packs/collect"
  ; "tests/core/variadic/packs/collect_generic"
  ; "tests/core/variadic/packs/spread"
  ; "tests/core/variadic/packs/spread_roundtrip"
  ; "tests/core/variadic/packs/spread_method"
  ; "tests/core/variadic/packs/spread_impl_method"
  ; "tests/core/variadic/packs/impl_pack"
  ; "tests/core/variadic/packs/spelling"
  ; "tests/core/variadic/packs/impl_trait_args"
  ; "tests/core/variadic/packs/action"
  ; "tests/reflection/typeof_effect_transitive"
  ; "tests/reflection/typeof_effect_multi"
  ; "tests/reflection/typeof_effect_fn_vs_ctl"
  ; "tests/reflection/typeof_effect_ctl"
  ; "tests/core/defer/defer_lifo"
  ; "tests/core/defer/defer_basic"
  ; "tests/core/slices/slice_range"
  ; "tests/reflection/typeof_slice"
  ; "tests/reflection/typeof_enum"
  ; "tests/core/structs/struct_dot_assign"
  ; "tests/core/structs/field_call"
  ; "tests/core/enums/wildcard"
  ; "tests/core/enums/unit_variants"
  ; "tests/stdlib/automata/dfa/dfa"
  ; "tests/stdlib/automata/nfa/nfa"
  ; "tests/stdlib/regex/regex/regex"
  ; "tests/effects/generic/shared_param"
  ; "tests/effects/generic/generic"
  ; "tests/effects/generic/nested"
  ; "tests/core/operators/precedence"
  ; "tests/core/operators/logical_symbols"
  ; "tests/core/operators/logical"
  ; "tests/effects/final/abort"
  ; "tests/effects/final/in_loop"
  ; "tests/effects/logic/simple_guard"
  ; "tests/effects/logic/multi_guard"
  ; "tests/effects/multishot_sequel"
  ; "tests/core/functions/trailing_foreach"
  ; "tests/core/functions/trailing_after_args"
  ; "tests/core/functions/trailing_it"
  ; "tests/core/builtins/ord"
  ; "tests/core/builtins/conversions"
  ; "tests/core/builtins/chr"
  ; "tests/core/builtins/int_float"
  ; "tests/effects/nested_return"
  ; "tests/effects/match/return_in_match"
  ; "tests/effects/match/resume_in_match"
  ; "tests/effects/match/suspend_in_scrutinee"
  ; "tests/effects/suspend_in_condition"
  ; "tests/effects/suspend_in_while_condition"
  ; "tests/effects/suspend_in_record"
  ; "tests/effects/suspend_in_variant"
  ; "tests/effects/suspend_in_field_assign"
  ; "tests/effects/suspend_in_logical"
  ; "tests/effects/suspend_in_logical_while"
  ; "tests/effects/suspend_in_logical_nested"
  ; "tests/effects/return_in_inner_run"
  ; "tests/effects/return_in_inner_ctl_run"
  ; "tests/effects/return_past_outer_ctl_run"
  ; "tests/effects/two_runs_one_expr"
  ; "tests/effects/return_past_arm_defer"
  ; "tests/effects/return_out_of_run"
  ; "tests/effects/inner_run_suspends_outward"
  ; "tests/effects/nested_aborts"
  ; "tests/stdlib/iterable/iterable"
  ; "tests/stdlib/hashmap/hashmap"
  ; "tests/stdlib/hashset/hashset"
  ; "tests/core/strings/string_starts_ends"
  ; "tests/core/strings/string_ordering"
  ; "tests/core/strings/case"
  ; "tests/core/strings/parse"
  ; "tests/core/strings/split_str"
  ; "tests/stdlib/string/string"
  ; "tests/stdlib/stringbuilder/stringbuilder"
  ; "tests/stdlib/tostring/tostring"
  ; "tests/reflection/typeof_type_name"
  ; "tests/core/modules/module_statements/main"
  ; "tests/meta/01_basic/basic"
  ; "tests/meta/01_basic/nested"
  ; "tests/meta/02_gen/basic"
  ; "tests/meta/02_gen/env"
  ; "tests/meta/02_gen/gen_meta"
  ; "tests/meta/02_gen/gen_symbol"
  ; "tests/meta/02_gen/greeting"
  ; "tests/meta/02_gen/nested"
  ; "tests/meta/02_gen/promote"
  ; "tests/meta/02_gen/reify_enum_payload"
  ; "tests/meta/02_gen/reify_enum_struct_variant"
  ; "tests/meta/02_gen/reify_enum_unit"
  ; "tests/meta/02_gen/reify_generic_struct"
  ; "tests/meta/02_gen/reify_list"
  ; "tests/meta/02_gen/reify_nested"
  ; "tests/meta/02_gen/reify_record"
  ; "tests/meta/02_gen/reify_record_anonymous"
  ; "tests/meta/02_gen/reify_struct"
  ; "tests/meta/02_gen/reify_tuple_destructure"
  ; "tests/meta/02_gen/reify_tuple_field"
  ; "tests/meta/02_gen/shadowed_local"
  ; "tests/meta/02_gen/sub1"
  ; "tests/meta/03_derive/basic"
  ; "tests/meta/03_derive/deriver_below"
  ; "tests/meta/03_derive/gen_in_helper"
  ; "tests/meta/04_functions/dyn_fib"
  ; "tests/meta/04_functions/static_fib"
  ; "tests/meta/05_order/01_basic"
  ; "tests/meta/05_order/02_nested"
  ; "tests/meta/05_order/03_never"
  ; "tests/meta/05_order/04_recursion"
  ; "tests/meta/05_order/05_mutual_recursion"
  ; "tests/meta/05_order/06_body_order"
  ; "tests/meta/05_order/07_type_mono"
  ; "tests/meta/05_order/08_static_invoke"
  ; "tests/meta/05_order/09_dyn_invoke"
  ; "tests/meta/05_order/10_box"
  ; "tests/meta/05_order/11_buf"
  ; "tests/meta/05_order/12_methods"
  ; "tests/meta/05_order/13_gen_call"
  ; "tests/meta/05_order/14_gen_body"
  ; "tests/meta/05_order/15_gen_local"
  ; "tests/meta/05_order/16_gen_after"
  ; "tests/meta/05_order/19_gen_static_arg"
  ; "tests/meta/05_order/20_template_mutual"
  ; "tests/meta/05_order/21_demand_order"
  ; "tests/meta/05_order/22_demand_order_reverse"
  ; "tests/meta/05_order/23_meta_in_loop"
  ; "tests/meta/05_order/24_call_in_loop"
  ; "tests/meta/05_order/25_meta_in_lambda"
  ; "tests/meta/05_order/26_unreached_type"
  ; "tests/meta/05_order/27_meta_reaches_fn"
  ; "tests/meta/06_modules/circular/main"
  ; "tests/meta/06_modules/derive_across/main"
  ; "tests/meta/06_modules/derive_across_selective/main"
  ; "tests/meta/06_modules/first_reference/main"
  ; "tests/meta/06_modules/gen_export/main"
  ; "tests/meta/06_modules/import_order/main"
  ; "tests/meta/06_modules/imported_once/main"
  ; "tests/meta/06_modules/template_across/main"
  ; "tests/meta/06_modules/template_two_importers/main"
  ; "tests/meta/06_modules/unreached_fn/main"
  ; "tests/meta/06_modules/unused_import/main"
  ; "tests/meta/07_precheck/alias_generated"
  ; "tests/meta/07_precheck/depends_on_meta"
  ; "tests/meta/07_precheck/generated_later"
  ; "tests/meta/05_order/28_const_args"
  ; "tests/meta/code/fold"
  ; "tests/meta/code/derive_eq"
  ; "tests/meta/code/helper"
  ; "tests/meta/derive/two_traits"
  ; "tests/meta/attributes/fields"
  ; "tests/meta/attributes/variants"
  ; "tests/meta/attributes/arguments"
  ; "tests/meta/attributes/without_derive"
  ; "tests/meta/attributes/declarations"
  ; "tests/core/records/nominal"
  ; "tests/core/enums/tuple_variants"
  ; "tests/core/enums/struct_variants"
  ; "tests/types/gadt/query"
  ; "tests/types/gadt/main"
  ; "tests/types/gadt/accumulator"
  ; "tests/types/gadt/pair"
  ; "tests/operators/vec2_add"
  ; "tests/operators/operator_mul"
  ; "tests/operators/operator_eq"
  ; "tests/operators/operator_chain"
  ; "tests/operators/operator_in_fn"
  ; "tests/operators/compound_assign"
  ; "tests/operators/traits/vec2_add"
  ; "tests/operators/traits/asymmetric"
  ; "tests/operators/traits/equality"
  ; "tests/operators/traits/indexing"
  ; "tests/operators/traits/generic_bound"
  ; "tests/operators/traits/derive_eq"
  ; "tests/operators/traits/tuple_eq"
  ; "tests/core/traits/basic_impl/main"
  ; "tests/core/traits/multiple_impls/main"
  ; "tests/core/traits/inherent/main"
  ; "tests/core/traits/generic_impl_two_methods/main"
  ; "tests/core/traits/generic_impl_operator/main"
  ; "tests/core/traits/try_from/main"
  ; "tests/core/traits/associated"
  ; "tests/core/traits/associated_builtin"
  ; "tests/core/traits/associated_type"
  ; "tests/core/traits/supertrait"
  ; "tests/core/traits/builtin_receiver/main"
  ; "tests/effects/methods/methods"
  ; "tests/core/static_params/type_params/main"
  ; "tests/core/static_params/type_reuse/main"
  ; "tests/core/static_params/parameterized_types/main"
  ; "tests/core/static_params/parameterized_sums/main"
  ; "tests/core/static_params/value_params/main"
  ; "tests/core/static_params/mixed_params/main"
  ; "tests/core/traits/trait_bound/main"
  ; "tests/core/static_params/inferred_constraints/main"
  ; "tests/core/static_params/element_generic/main"
  ; "tests/meta/params/func"
  ; "tests/effects/nested_control/run_in_if"
  ; "tests/effects/nested_control/run_in_while"
  ; "tests/effects/nested_control/run_in_match"
  ; "tests/effects/nested_control/op_only_in_match"
  ; "tests/effects/nested_decls/handler_in_block"
  ; "tests/effects/nested_decls/variadic_in_block"
  ; "tests/core/defer/defer_in_match_arm"
  ; "tests/core/resolution/hoisting_in_match_arm"
  ; "tests/core/types/local_type_per_function"
  ; "tests/core/types/unit_literal"
  ; "tests/core/types/empty_type"
  ; "tests/core/types/empty_type_impl"
  ; "tests/core/traits/dyn/binding"
  ; "tests/core/traits/dyn/param"
  ; "tests/core/traits/dyn/collection"
  ; "tests/core/traits/dyn/returned"
  ; "tests/core/traits/dyn/effect"
  ; "tests/core/traits/dyn/effect_resumes"
  ; "tests/core/traits/dyn/method_arg"
  ; "tests/core/traits/dyn/list_param"
  ; "tests/core/traits/dyn/field"
  ; "tests/core/traits/dyn/supertrait"
  ; "tests/core/modules/local_binders/main"
  ; "tests/core/static_params/shadowed_value_param"
  ; "tests/core/static_params/nested/template_in_function"
  ; "tests/core/static_params/nested/template_in_method"
  ; "tests/core/defer/defer_in_converted_fn"
  ; "tests/core/defer/defer_multishot"
  ; "tests/core/defer/defer_multishot_abort"
  ; "tests/core/defer/defer_performs_effect"
  ]

(* Programs that must be rejected, and the diagnostics they must produce. *)
let error_cases =
  [ "tests/core/variadic/errors/not_last"
  ; "tests/core/variadic/packs/errors/wrong_arity"
  ; "tests/core/variadic/packs/errors/wrong_type"
  ; "tests/core/variadic/packs/errors/not_last"
  ; "tests/core/variadic/packs/errors/mixed_pool"
  ; "tests/core/variadic/packs/errors/empty_arguments"
  ; "tests/core/variadic/packs/errors/bare_pack"
  ; "tests/core/variadic/packs/errors/spread_array"
  ; "tests/core/variadic/packs/errors/spread_arity"
  ; "tests/core/variadic/packs/errors/spread_not_last"
  ; "tests/core/variadic/packs/errors/tuple_not_pack"
  ; "tests/core/variadic/packs/errors/spread_not_pack"
  ; "tests/core/variadic/packs/errors/impl_missing_dots"
  ; "tests/core/variadic/packs/errors/impl_stray_dots"
  ; "tests/core/lambdas/errors/unnamed_pair"
  ; "tests/core/lambdas/errors/naked_arrow"
  ; "tests/core/type_annotations/errors/arrow_return"
  ; "tests/core/types/errors/empty_type_field"
    (* Inference never produces a trait object; only a written type asks for one. *)
  ; "tests/core/traits/errors/inferred_trait_object"
  ; "tests/core/traits/errors/not_an_implementer"
  ; "tests/core/traits/errors/object_needs_receiver"
  ; "tests/core/enums/errors/new_variant"
  ; "tests/core/lambdas/errors/trailing_comma"
  ; "tests/core/embed/errors/missing"
  ; "tests/effects/generic/errors/one_type"
  ; "tests/effects/final/errors/resumes"
  ; "tests/effects/errors/arm_settles_op_param"
  ; "tests/core/ufcs/errors/arity"
  ; "tests/meta/02_gen/errors/reify_fn"
  ; "tests/meta/02_gen/errors/reify_object"
  ; "tests/meta/03_derive/errors/gen_at_runtime"
  ; "tests/meta/03_derive/errors/use_before_derive"
  ; "tests/meta/04_functions/errors/meta_fn"
  ; "tests/meta/05_order/17_gen_before"
  ; "tests/meta/05_order/18_gen_before_top"
  ; "tests/meta/05_order/errors/distinct_instances"
  ; "tests/meta/05_order/errors/double_demotion"
  ; "tests/meta/05_order/errors/dynamic_in_meta"
  ; "tests/meta/05_order/errors/static_arg_in_meta"
  ; "tests/meta/05_order/errors/meta_type_without_args"
  ; "tests/meta/05_order/errors/value_type_without_args"
  ; "tests/meta/07_precheck/errors/instance_mismatch"
  ; "tests/meta/07_precheck/errors/unreached_value_param"
  ; "tests/core/functions/errors/duplicate_fn"
  ; "tests/core/types/errors/duplicate_type"
  ; "tests/meta/02_gen/errors/duplicate_generated"
  ; "tests/core/traits/errors/self_method_on_type"
  ; "tests/meta/derive/errors/no_deriver"
  ; "tests/meta/derive/errors/two_derivers"
  ; "tests/meta/attributes/errors/not_a_literal"
  ; "tests/meta/attributes/errors/not_a_declaration"
  ; "tests/reflection/errors/no_such_name"
  ; "tests/meta/code/errors/outside_meta"
  ; "tests/meta/code/errors/not_a_name"
  ; "tests/reflection/errors/not_a_value"
  ; "tests/types/errors/mixed_numeric"
  ; "tests/types/inference/errors/unspecializable_recursion"
  ; "tests/types/errors/non_bool_condition"
  ; "tests/types/errors/undefined_variable"
  ; "tests/types/errors/arity"
  ; "tests/types/errors/return_mismatch"
  ; "tests/types/errors/assign_mismatch"
  ; "tests/types/errors/unknown_type"
  ; "tests/types/errors/declared_without_value"
  ; "tests/types/errors/string_comparison"
  ; "tests/effects/errors/unhandled"
  ; "tests/effects/errors/non_exhaustive"
  ; "tests/effects/errors/no_such_operation"
  ; "tests/effects/errors/unknown_effect"
  ; "tests/effects/errors/purity_violated"
  ; "tests/effects/errors/unknown_handler"
  ; "tests/effects/errors/leaked_effect"
  ; "tests/effects/errors/pure_parameter"
  ; "tests/core/arrays/errors/mixed_elements"
  ; "tests/core/arrays/errors/not_indexable"
  ; "tests/core/arrays/errors/element_mismatch"
  ; "tests/core/collections/errors/duplicate_container"
  ; "tests/core/modules/errors/imported_type_error/main"
  ; "tests/core/chars/errors/not_a_string"
  ; "tests/core/chars/errors/char_is_not_a_byte"
  ; "tests/core/strings/errors/immutable"
  ; "tests/core/strings/errors/immutable_compound"
  ; "tests/core/strings/errors/split_separator"
  ; "tests/core/tuples/errors/no_such_field"
  ; "tests/core/tuples/errors/unknown_arity"
  ; "tests/core/records/errors/no_such_field"
  ; "tests/core/records/errors/field_mismatch"
  ; "tests/core/records/errors/missing_field"
  ; "tests/core/records/errors/nominal_mismatch"
  ; "tests/core/enums/errors/not_exhaustive"
  ; "tests/core/enums/errors/no_such_variant"
  ; "tests/core/enums/errors/payload_mismatch"
  ; "tests/core/enums/errors/not_a_sum"
  ; "tests/operators/errors/duplicate"
  ; "tests/operators/errors/undeclared"
  ; "tests/core/traits/errors/incomplete"
  ; "tests/core/traits/errors/unknown_trait"
  ; "tests/core/traits/errors/duplicate"
  ; "tests/core/traits/errors/missing_supertrait"
  ; "tests/core/traits/errors/no_self"
  ; "tests/core/traits/errors/no_such_method"
  ; "tests/core/traits/errors/arity"
  ; "tests/core/traits/errors/unknown_method"
  ; "tests/core/traits/errors/ambiguous_receiver"
  ; "tests/core/traits/errors/generic_impl_no_operator"
  ; "tests/core/traits/errors/impl_signature_mismatch"
  ; "tests/core/traits/errors/impl_method_arity"
  ; "tests/core/traits/errors/impl_trait_arg_arity"
  ; "tests/core/traits/errors/impl_missing_trait_args"
  ; "tests/core/syntax/errors/derive_trailing_comma"
  ; "tests/core/static_params/errors/type_arity"
  ; "tests/core/static_params/errors/static_arity"
  ; "tests/core/static_params/errors/not_static"
  ; "tests/core/static_params/errors/static_call"
  ; "tests/core/static_params/errors/embedded_bytes"
  ; "tests/types/gadt/errors/ill_typed_tree"
  ; "tests/types/gadt/errors/impossible_arm"
  ; "tests/types/gadt/errors/leaked_constraint"
  ; "tests/effects/errors/duplicate_operation"
  ; "tests/types/errors/local_type_escapes"
  ; "tests/types/inference/errors/unspecializable_names_the_caller"
  ; "tests/core/modules/errors/outside_package/main"
  ; "tests/effects/errors/handler_widens"
  ; "tests/core/traits/errors/impl_row_narrower"
  ; "tests/core/traits/errors/impl_row_wider"
  ; "tests/core/traits/errors/object_not_a_bound"
  ]

(* Accepted, then failing while running. Separate from [error_cases], which
   never reach the interpreter. *)
let runtime_cases =
  [ "tests/core/builtins/readfile_missing"
  ; "tests/core/collections/index_out_of_range"
  ; "tests/core/slices/negative_index"
  ; "tests/core/builtins/chr_invalid"
  ]

(* The fixtures live outside the dune project root, so find them at runtime. *)
let repo_root () =
  let marker = Filename.concat "tests" (Filename.concat "core" "print") in
  let rec up dir =
    if Sys.file_exists (Filename.concat dir marker)
    then Some dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent)
  in
  match Sys.getenv_opt "CRONYX_REPO_ROOT" with
  | Some dir -> Some dir
  | None -> up (Sys.getcwd ())

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let normalize s =
  String.trim (String.concat "\n" (String.split_on_char '\r' s |> List.filter (( <> ) "")))

let described path (e : Diagnostic.error) =
  Printf.sprintf
    "%s error %s %s"
    (String.lowercase_ascii (Diagnostic.stage_name e.Diagnostic.stage))
    (Ast.locate ~entry:path e.Diagnostic.span)
    e.Diagnostic.message

let interpret path =
  let buf = Buffer.create 256 in
  let out = Buffer.add_string buf in
  match Pipeline.compile ~roots:(Driver.roots_for path) ~out path with
  | Error [] -> Error "the program does not compile"
  | Error (e :: _) -> Error (described path e)
  | Ok converted ->
    (match Pipeline.run (Builtins.env ~out) converted with
     | Ok () -> Ok (Buffer.contents buf)
     | Error e -> Error (described path e))

(* Why a fixture does not run yet. *)
type blocker =
  | Waiting of string (* work that is planned and named *)
  (* Native compilation, out of scope for this bootstrap. *)
  | Parked
  | Unplanned (* no design for it anywhere yet *)

(* The suite asserts each still fails, so one that starts working is reported
   rather than sitting unnoticed. *)
let expected_failing : (string * blocker) list =
    (* Parked — native compilation, deliberately out of scope *)
  [ "tests/compile/m0/m0", Parked
  ; "tests/compile/m1/fib", Parked
  ; "tests/compile/m2/struct", Parked
  ; "tests/compile/m3/fact", Parked
  ; "tests/compile/m4/countdown", Parked
  ; "tests/compile/m5/sum", Parked
  ; "tests/compile/m6/apply", Parked
  ; "tests/compile/m7/safe_div", Parked
  ; "tests/compile/m8/gadt", Parked
  ]

(* Ought to be rejected and are not, paired with the `.err` they should
   produce. The suite announces the moment one starts being caught. *)
let known_unsound : string list =
  (* The row is compared as written, so an impl that performs an effect neither
     it nor the trait declares is still accepted. *)
  [ "tests/core/traits/errors/impl_row_inferred" ]

(* Every diagnostic the checker found, not only the first. *)
let rejections path =
  match Pipeline.compile ~roots:(Driver.roots_for path) ~out:(fun _ -> ()) path with
  | Ok _ -> Error "expected an error, but the program checked"
  | Error errors ->
    Ok
      (String.concat
         "\n"
         (List.map
            (fun (e : Diagnostic.error) ->
              Printf.sprintf
                "%s %s"
                (Ast.locate ~entry:path e.Diagnostic.span)
                e.Diagnostic.message)
            errors))

(* Passing here is the failure, as with [expected_failing]: being rejected is
   what this fixture is waiting for. *)
let run_known_unsound root name =
  let path ext = Filename.concat root (name ^ ext) in
  match rejections (path ".cx") with
  | Error _ ->
    Printf.printf "ok   %s (still unsound)\n" name;
    true
  | Ok actual ->
    Printf.printf
      "PASSES %s\n  now rejected; move it into `error_cases`\n  --- got ---\n%s\n"
      name
      (normalize actual);
    false

let run_error_case root name =
  let path ext = Filename.concat root (name ^ ext) in
  let expected = read_file (path ".err") in
  match rejections (path ".cx") with
  | Error message ->
    Printf.printf "FAIL %s\n  %s\n" name message;
    false
  | Ok actual ->
    if String.equal (normalize actual) (normalize expected)
    then (
      Printf.printf "ok   %s\n" name;
      true)
    else (
      Printf.printf
        "FAIL %s\n  --- expected ---\n%s\n  --- actual ---\n%s\n"
        name
        (normalize expected)
        (normalize actual);
      false)

let run_runtime_case root name =
  let path ext = Filename.concat root (name ^ ext) in
  let expected = read_file (path ".rt") in
  match interpret (path ".cx") with
  | Ok _ ->
    Printf.printf "FAIL %s\n  expected a runtime error, but the program ran\n" name;
    false
  | Error actual ->
    (* Just the message: a diagnostic raised inside the prelude has a line
       number that is not the user's. *)
    let from mark =
      match String.index_opt actual mark with
      | Some at -> String.sub actual at (String.length actual - at)
      | None -> actual
    in
    let actual =
      if String.length (String.trim expected) > 0 && (String.trim expected).[0] = '['
      then from '['
      else (
        match String.index_opt actual ']' with
        | Some at -> String.trim (String.sub actual (at + 1) (String.length actual - at - 1))
        | None -> actual)
    in
    if String.equal (normalize actual) (normalize expected)
    then (
      Printf.printf "ok   %s\n" name;
      true)
    else (
      Printf.printf
        "FAIL %s\n  --- expected ---\n%s\n  --- actual ---\n%s\n"
        name
        (normalize expected)
        (normalize actual);
      false)

(* Printing a parsed program gives back a program that parses the same way.
   Catches a printer that drops or reshapes something. *)
let run_round_trip root name =
  let path = Filename.concat root (name ^ ".cx") in
  let parse where text =
    match Scanner.scan_tokens (Source_map.File.create ~path ~text) with
    | Error _ -> Error (Printf.sprintf "%s does not scan" where)
    | Ok tokens ->
      (match Parser.parse tokens with
       | Error (e :: _) ->
         Error
           (Printf.sprintf
              "%s does not parse %s %s"
              where
              (Ast.locate ~entry:path e.Parser.span)
              e.Parser.message)
       | Error [] -> Error (Printf.sprintf "%s does not parse" where)
       | Ok program -> Ok program)
  in
  match parse "source" (read_file path) with
  | Error message ->
    Printf.printf "FAIL %s (round trip)\n  %s\n" name message;
    false
  | Ok once ->
    let printed = Bootstrap.Source.program once in
    (match parse "its own output" printed with
     | Error message ->
       Printf.printf "FAIL %s (round trip)\n  %s\n" name message;
       false
     | Ok twice ->
       let again = Bootstrap.Source.program twice in
       if String.equal printed again
       then (
         Printf.printf "ok   %s (round trip)\n" name;
         true)
       else (
         Printf.printf "FAIL %s (round trip)\n  printing it twice differs\n" name;
         false))

let run_case root name =
  let path ext = Filename.concat root (name ^ ext) in
  let expected = read_file (path ".txt") in
  match interpret (path ".cx") with
  | Error message ->
    Printf.printf "FAIL %s\n  %s\n" name message;
    false
  | Ok actual ->
    if String.equal (normalize actual) (normalize expected)
    then (
      Printf.printf "ok   %s\n" name;
      true)
    else (
      Printf.printf
        "FAIL %s\n  --- expected ---\n%s\n  --- actual ---\n%s\n"
        name
        (normalize expected)
        (normalize actual);
      false)

(* Passing is the failure. An `.err` one has arrived when it is rejected with
   the diagnostic it names, not merely rejected. *)
let run_expected_failing root (name, blocker) =
  let path ext = Filename.concat root (name ^ ext) in
  let matches ext produce =
    Sys.file_exists (path ext)
    &&
    match produce (path ".cx") with
    | Ok actual -> String.equal (normalize actual) (normalize (read_file (path ext)))
    | Error _ -> false
  in
  if matches ".txt" interpret || matches ".err" rejections
  then (
    Printf.printf
      "PASSES %s\n  now works; move it into `%s` (was waiting on %s)\n"
      name
      (if Sys.file_exists (path ".err") then "error_cases" else "cases")
      (match blocker with
       | Waiting work -> work
       | Parked -> "the LLVM path, which is out of scope"
       | Unplanned -> "a design");
    false)
  else true

(* A fixture no list names is never run and never reported — the exact failure
   [expected_failing] exists to prevent. *)
let unclaimed root =
  let claimed = Hashtbl.create 512 in
  List.iter (fun name -> Hashtbl.replace claimed name ()) cases;
  List.iter (fun name -> Hashtbl.replace claimed name ()) error_cases;
  List.iter (fun name -> Hashtbl.replace claimed name ()) runtime_cases;
  List.iter (fun (name, _) -> Hashtbl.replace claimed name ()) expected_failing;
  List.iter (fun name -> Hashtbl.replace claimed name ()) known_unsound;
  let missing = ref [] in
  let rec walk dir =
    Array.iter
      (fun entry ->
        let path = Filename.concat dir entry in
        if Sys.is_directory path
        then walk path
        else if Filename.check_suffix entry ".cx"
        then (
          let stem = Filename.remove_extension path in
          let expected = List.exists (fun ext -> Sys.file_exists (stem ^ ext)) [ ".txt"; ".err"; ".rt" ] in
          let name =
            let cut = String.length root + 1 in
            let name = String.sub stem cut (String.length stem - cut) in
            (* The lists above spell a fixture with `/`, and `Filename.concat`
               spells it with `\\` on Windows -- so every fixture would match no
               list and the whole suite would report as claimed by nothing. *)
            String.map (fun c -> if Char.equal c '\\' then '/' else c) name
          in
          if expected && not (Hashtbl.mem claimed name) then missing := name :: !missing))
      (Sys.readdir dir)
  in
  walk (Filename.concat root "tests");
  List.sort String.compare !missing

let run_partition root =
  match unclaimed root with
  | [] ->
    Printf.printf "ok   every fixture is claimed by a list\n";
    true
  | missing ->
    Printf.printf
      "FAIL fixtures no list names, so nothing runs them:\n%s\n"
      (String.concat "\n" (List.map (fun name -> "  " ^ name) missing));
    false

(* The fixture suite compares `[line:col] message`, so nothing there would
   notice a frame that renders without its source line or without its closing
   rule -- the two ways the Rust compiler's diagnostics used to come out
   broken. *)
let rendered stage ~entry ~path ~text ~lo ~hi message =
  let span =
    match text with
    | None -> Source_map.Span.nowhere
    | Some text -> Source_map.Span.of_range (Source_map.File.create ~path ~text) ~lo ~hi
  in
  Render.error ~entry (Diagnostic.at stage span message)

let renderings =
  [ ( "a span inside a line"
    , rendered
        Diagnostic.Type
        ~entry:"alpha.cx"
        ~path:"alpha.cx"
        ~text:(Some "fn main() {\n  var x: int = \"hi\";\n}\n")
        ~lo:27
        ~hi:31
        "expected int, found string"
    , "× Type error: expected int, found string\n\
      \  ┌─ alpha.cx:2:16\n\
      \  │\n\
       2 │   var x: int = \"hi\";\n\
      \  │                ~~~~\n\
      \  └─\n" )
    (* The gutter widens with the line number, so the rules stay under it. *)
  ; ( "a two-digit line number"
    , rendered
        Diagnostic.Verify
        ~entry:"beta.cx"
        ~path:"beta.cx"
        ~text:(Some (String.concat "" (List.init 11 (fun _ -> "//\n")) ^ "var zz = 1;\n"))
        ~lo:37
        ~hi:39
        "not in scope"
    , "× Verify error: not in scope\n\
      \   ┌─ beta.cx:12:5\n\
      \   │\n\
       12 │ var zz = 1;\n\
      \   │     ~~\n\
      \   └─\n" )
    (* A tab is eight columns and the emoji is two, in the line and in the
       underline alike. *)
  ; ( "a line with a tab and a wide character"
    , rendered
        Diagnostic.Verify
        ~entry:"wide.cx"
        ~path:"wide.cx"
        ~text:(Some "\tvar wide = \"\xf0\x9f\x8e\x89\"; var bad = 1;\n")
        ~lo:24
        ~hi:27
        "not in scope"
    , "\xc3\x97 Verify error: not in scope\n\
      \  \xe2\x94\x8c\xe2\x94\x80 wide.cx:1:25\n\
      \  \xe2\x94\x82\n\
       1 \xe2\x94\x82         var wide = \"\xf0\x9f\x8e\x89\"; var bad = 1;\n\
      \  \xe2\x94\x82                              ~~~\n\
      \  \xe2\x94\x94\xe2\x94\x80\n" )
    (* No location is a case the frame answers for, not one it skips. *)
  ; ( "a span with no source behind it"
    , rendered
        Diagnostic.Type
        ~entry:"gamma.cx"
        ~path:""
        ~text:None
        ~lo:0
        ~hi:0
        "Unhandled effect(s): Log."
    , "× Type error: Unhandled effect(s): Log.\n\
      \  ┌─ (no source location)\n\
      \  └─\n" )
  ]

let run_rendering () =
  List.for_all
    (fun (what, actual, expected) ->
      if String.equal actual expected
      then (
        Printf.printf "ok   renders %s\n" what;
        true)
      else (
        Printf.printf
          "FAIL renders %s\n  --- expected ---\n%s  --- actual ---\n%s"
          what
          expected
          actual;
        false))
    renderings

let () =
  match repo_root () with
  | None ->
    prerr_endline "could not locate the repo root (set CRONYX_REPO_ROOT)";
    exit 1
  | Some root ->
    let results =
      List.map (run_case root) cases
      @ List.map (run_error_case root) error_cases
      @ List.map (run_runtime_case root) runtime_cases
      @ List.map (run_round_trip root) cases
      @ List.map (run_expected_failing root) expected_failing
      @ List.map (run_known_unsound root) known_unsound
      @ [ run_partition root; run_rendering () ]
    in
    let failed = List.length (List.filter not results) in
    Printf.printf "\n%d/%d passed\n" (List.length results - failed) (List.length results);
    if failed > 0 then exit 1
