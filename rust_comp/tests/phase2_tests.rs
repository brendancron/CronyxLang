/// Phase 2 LLVM-readiness tests — TDD.
/// All tests here should FAIL until the corresponding feature is implemented.
///
/// Phases:
///   2a — verify_no_type_vars: assert no Type::Var survives Phase 2 type checking
///   2b — EnumRegistry: tag integers + resolved payload types for codegen
///   2c — Type::Struct: named struct type preserving the struct name in the TypeTable
///   2e — ForEach variable type: loop variable type recorded in the TypeTable
///
/// Phase 2d (string slice range) is tested as a script integration test.
use std::collections::HashMap;

use cronyx::frontend::meta_ast::{EnumVariant, VariantPayload};
use cronyx::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use cronyx::semantics::types::enum_registry::{EnumRegistry, ResolvedPayload};
use cronyx::semantics::types::runtime_type_checker::type_check_runtime;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::semantics::types::type_var_verify::verify_no_type_vars;
use cronyx::semantics::types::types::*;

// ---------------------------------------------------------------------------
// Phase 2a — TypeVar verification
// ---------------------------------------------------------------------------

#[cfg(test)]
mod phase2a {
    use super::*;

    #[test]
    fn passes_on_fully_concrete_map() {
        let mut map = HashMap::new();
        map.insert(0, int_type());
        map.insert(1, string_type());
        map.insert(2, bool_type());
        map.insert(3, unit_type());
        map.insert(4, Type::Slice(Box::new(int_type())));
        map.insert(5, Type::Tuple(vec![int_type(), bool_type()]));
        assert!(verify_no_type_vars(&map).is_ok());
    }

    #[test]
    fn fails_on_bare_type_var() {
        let mut map = HashMap::new();
        map.insert(0, int_type());
        map.insert(1, type_var(42));
        let err = verify_no_type_vars(&map).unwrap_err();
        assert!(err.contains(&1), "expected id 1 in error list, got {:?}", err);
    }

    #[test]
    fn fails_on_type_var_inside_slice() {
        let mut map = HashMap::new();
        map.insert(0, Type::Slice(Box::new(type_var(7))));
        let err = verify_no_type_vars(&map).unwrap_err();
        assert!(err.contains(&0));
    }

    #[test]
    fn fails_on_type_var_inside_tuple() {
        let mut map = HashMap::new();
        map.insert(0, Type::Tuple(vec![int_type(), type_var(3)]));
        let err = verify_no_type_vars(&map).unwrap_err();
        assert!(err.contains(&0));
    }

    #[test]
    fn fails_on_type_var_in_fn_return() {
        let mut map = HashMap::new();
        map.insert(0, Type::Func {
            params: vec![int_type()],
            ret: Box::new(type_var(99)),
            effects: EffectRow::empty(),
        });
        let err = verify_no_type_vars(&map).unwrap_err();
        assert!(err.contains(&0));
    }

    #[test]
    fn reports_all_offending_ids() {
        let mut map = HashMap::new();
        map.insert(0, type_var(1));
        map.insert(1, int_type());
        map.insert(2, type_var(2));
        let err = verify_no_type_vars(&map).unwrap_err();
        assert!(err.contains(&0));
        assert!(err.contains(&2));
        assert!(!err.contains(&1));
    }

    #[test]
    fn empty_map_passes() {
        assert!(verify_no_type_vars(&HashMap::new()).is_ok());
    }
}

// ---------------------------------------------------------------------------
// Phase 2b — EnumRegistry
// ---------------------------------------------------------------------------

#[cfg(test)]
mod phase2b {
    use super::*;

    fn ast_with_enum(name: &str, variants: Vec<EnumVariant>) -> RuntimeAst {
        let mut ast = RuntimeAst::new();
        ast.insert_stmt(0, RuntimeStmt::EnumDecl {
            name: name.into(),
            variants,
        });
        ast.sem_root_stmts = vec![0];
        ast
    }

    #[test]
    fn unit_variants_get_sequential_tags() {
        let ast = ast_with_enum("Direction", vec![
            EnumVariant { name: "North".into(), payload: VariantPayload::Unit },
            EnumVariant { name: "South".into(), payload: VariantPayload::Unit },
            EnumVariant { name: "East".into(),  payload: VariantPayload::Unit },
            EnumVariant { name: "West".into(),  payload: VariantPayload::Unit },
        ]);
        let registry = EnumRegistry::build(&ast);
        let variants = registry.get("Direction").expect("Direction not in registry");
        assert_eq!(variants.len(), 4);
        assert_eq!(variants[0].name, "North"); assert_eq!(variants[0].tag, 0);
        assert_eq!(variants[1].name, "South"); assert_eq!(variants[1].tag, 1);
        assert_eq!(variants[2].name, "East");  assert_eq!(variants[2].tag, 2);
        assert_eq!(variants[3].name, "West");  assert_eq!(variants[3].tag, 3);
    }

    #[test]
    fn unit_variant_payload_is_unit() {
        let ast = ast_with_enum("Color", vec![
            EnumVariant { name: "Red".into(), payload: VariantPayload::Unit },
        ]);
        let registry = EnumRegistry::build(&ast);
        let variants = registry.get("Color").unwrap();
        assert!(matches!(variants[0].payload, ResolvedPayload::Unit));
    }

    #[test]
    fn tuple_payload_primitive_types_resolved() {
        let ast = ast_with_enum("Shape", vec![
            EnumVariant {
                name: "Circle".into(),
                payload: VariantPayload::Tuple(vec!["int".into()]),
            },
            EnumVariant {
                name: "Rect".into(),
                payload: VariantPayload::Tuple(vec!["int".into(), "int".into()]),
            },
        ]);
        let registry = EnumRegistry::build(&ast);
        let variants = registry.get("Shape").unwrap();

        assert_eq!(variants[0].tag, 0);
        match &variants[0].payload {
            ResolvedPayload::Tuple(types) => assert_eq!(types, &[int_type()]),
            _ => panic!("expected tuple payload for Circle"),
        }

        assert_eq!(variants[1].tag, 1);
        match &variants[1].payload {
            ResolvedPayload::Tuple(types) => assert_eq!(types, &[int_type(), int_type()]),
            _ => panic!("expected tuple payload for Rect"),
        }
    }

    #[test]
    fn unknown_type_in_payload_becomes_enum_type() {
        // A variant whose payload references a user-defined type name
        let ast = ast_with_enum("Tree", vec![
            EnumVariant {
                name: "Leaf".into(),
                payload: VariantPayload::Tuple(vec!["int".into()]),
            },
            EnumVariant {
                name: "Node".into(),
                payload: VariantPayload::Tuple(vec!["Tree".into(), "Tree".into()]),
            },
        ]);
        let registry = EnumRegistry::build(&ast);
        let variants = registry.get("Tree").unwrap();
        match &variants[1].payload {
            ResolvedPayload::Tuple(types) => {
                // "Tree" is not a primitive, so it resolves to Type::Enum("Tree")
                assert_eq!(types[0], Type::Enum("Tree".into()));
            }
            _ => panic!("expected tuple payload"),
        }
    }

    #[test]
    fn multiple_enums_in_one_ast() {
        let mut ast = RuntimeAst::new();
        ast.insert_stmt(0, RuntimeStmt::EnumDecl {
            name: "A".into(),
            variants: vec![EnumVariant { name: "X".into(), payload: VariantPayload::Unit }],
        });
        ast.insert_stmt(1, RuntimeStmt::EnumDecl {
            name: "B".into(),
            variants: vec![EnumVariant { name: "Y".into(), payload: VariantPayload::Unit }],
        });
        ast.sem_root_stmts = vec![0, 1];
        let registry = EnumRegistry::build(&ast);
        assert!(registry.get("A").is_some());
        assert!(registry.get("B").is_some());
    }

    #[test]
    fn missing_enum_returns_none() {
        let registry = EnumRegistry::build(&RuntimeAst::new());
        assert!(registry.get("Nonexistent").is_none());
    }
}

// ---------------------------------------------------------------------------
// Phase 2c — Named struct types (Type::Struct)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod phase2c {
    use super::*;

    fn ast_with_struct_literal(struct_name: &str, fields: Vec<(&str, RuntimeExpr)>) -> (RuntimeAst, usize) {
        let mut ast = RuntimeAst::new();
        let mut next_id = 0usize;
        let mut alloc = || { let id = next_id; next_id += 1; id };

        let mut field_ids = vec![];
        for (name, expr) in &fields {
            let eid = alloc();
            ast.insert_expr(eid, expr.clone());
            field_ids.push((name.to_string(), eid));
        }

        let lit_id = alloc();
        ast.insert_expr(lit_id, RuntimeExpr::StructLiteral {
            type_name: struct_name.into(),
            fields: field_ids,
        });

        let decl_id = alloc();
        ast.insert_stmt(decl_id, RuntimeStmt::VarDecl { name: "p".into(), expr: lit_id });
        ast.sem_root_stmts = vec![decl_id];

        (ast, lit_id)
    }

    #[test]
    fn struct_literal_typed_as_named_struct_not_record() {
        let (ast, lit_id) = ast_with_struct_literal("Point", vec![
            ("x", RuntimeExpr::Int(1)),
            ("y", RuntimeExpr::Int(2)),
        ]);
        let mut env = TypeEnv::new();
        let type_map = type_check_runtime(&ast, &mut env).unwrap();
        let ty = type_map.get(&lit_id).expect("no type for struct literal");
        // Must be Type::Struct, not Type::Record or Type::Var
        match ty {
            Type::Struct { name, fields } => {
                assert_eq!(name, "Point");
                assert_eq!(fields.get("x"), Some(&int_type()));
                assert_eq!(fields.get("y"), Some(&int_type()));
            }
            other => panic!("expected Type::Struct, got {:?}", other),
        }
    }

    #[test]
    fn variable_bound_to_struct_has_named_type() {
        let (ast, _) = ast_with_struct_literal("Vec2", vec![
            ("x", RuntimeExpr::Int(0)),
            ("y", RuntimeExpr::Int(0)),
        ]);
        let mut env = TypeEnv::new();
        type_check_runtime(&ast, &mut env).unwrap();
        // The variable "p" should have type Type::Struct { name: "Vec2", ... }
        let ty = env.lookup("p").expect("p not in env");
        match ty {
            Type::Struct { name, .. } => assert_eq!(name, "Vec2"),
            other => panic!("expected Type::Struct, got {:?}", other),
        }
    }

    #[test]
    fn struct_types_with_same_name_unify() {
        use cronyx::semantics::types::type_subst::{unify, TypeSubst};
        use std::collections::BTreeMap;
        let mut fields = BTreeMap::new();
        fields.insert("x".into(), int_type());
        let a = Type::Struct { name: "Point".into(), fields: fields.clone() };
        let b = Type::Struct { name: "Point".into(), fields };
        let mut subst = TypeSubst::new();
        assert!(unify(&a, &b, &mut subst).is_ok());
    }

    #[test]
    fn struct_types_with_different_names_do_not_unify() {
        use cronyx::semantics::types::type_subst::{unify, TypeSubst};
        use std::collections::BTreeMap;
        let mut fields = BTreeMap::new();
        fields.insert("x".into(), int_type());
        let a = Type::Struct { name: "Point".into(), fields: fields.clone() };
        let b = Type::Struct { name: "Vec2".into(),  fields };
        let mut subst = TypeSubst::new();
        assert!(unify(&a, &b, &mut subst).is_err());
    }
}

// ---------------------------------------------------------------------------
// Phase 2e — ForEach variable type in TypeMap
// ---------------------------------------------------------------------------

#[cfg(test)]
mod phase2e {
    use super::*;

    #[test]
    fn foreach_element_type_recorded_under_stmt_id() {
        let mut ast = RuntimeAst::new();
        // [1, 2, 3]
        ast.insert_expr(0, RuntimeExpr::Int(1));
        ast.insert_expr(1, RuntimeExpr::Int(2));
        ast.insert_expr(2, RuntimeExpr::Int(3));
        ast.insert_expr(3, RuntimeExpr::List(vec![0, 1, 2]));
        // var nums = [...]
        ast.insert_stmt(4, RuntimeStmt::VarDecl { name: "nums".into(), expr: 3 });
        // for (x in nums) { }
        ast.insert_stmt(5, RuntimeStmt::Block(vec![]));
        let foreach_id = 6;
        ast.insert_stmt(foreach_id, RuntimeStmt::ForEach {
            var: "x".into(),
            iterable: 3,
            body: 5,
        });
        ast.sem_root_stmts = vec![4, foreach_id];

        let mut env = TypeEnv::new();
        let type_map = type_check_runtime(&ast, &mut env).unwrap();

        // ForEach stmt_id should map to the element type (int)
        assert_eq!(
            type_map.get(&foreach_id),
            Some(&int_type()),
            "loop variable type should be int"
        );
    }

    #[test]
    fn foreach_element_type_is_string_for_string_slice() {
        let mut ast = RuntimeAst::new();
        // ["a", "b", "c"]
        ast.insert_expr(0, RuntimeExpr::String("a".into()));
        ast.insert_expr(1, RuntimeExpr::String("b".into()));
        ast.insert_expr(2, RuntimeExpr::String("c".into()));
        ast.insert_expr(3, RuntimeExpr::List(vec![0, 1, 2]));
        ast.insert_stmt(4, RuntimeStmt::VarDecl { name: "strs".into(), expr: 3 });
        ast.insert_stmt(5, RuntimeStmt::Block(vec![]));
        let foreach_id = 6;
        ast.insert_stmt(foreach_id, RuntimeStmt::ForEach {
            var: "s".into(),
            iterable: 3,
            body: 5,
        });
        ast.sem_root_stmts = vec![4, foreach_id];

        let mut env = TypeEnv::new();
        let type_map = type_check_runtime(&ast, &mut env).unwrap();

        assert_eq!(type_map.get(&foreach_id), Some(&string_type()));
    }
}
