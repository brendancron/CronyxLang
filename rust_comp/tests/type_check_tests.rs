use cronyx::frontend::id_provider::IdProvider;
use cronyx::frontend::lexer::tokenize;
use cronyx::frontend::meta_ast::*;
use cronyx::frontend::parser::{parse, ParseCtx};
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::semantics::types::type_error::TypeError;
use cronyx::semantics::types::typed_ast::TypeTable;
use cronyx::semantics::types::types::*;

// --- Helpers ---

/// Parse source into a MetaAst using the real lexer + parser.
fn parse_source(source: &str) -> MetaAst {
    let tokens = tokenize(source).unwrap();
    let mut ctx = ParseCtx::new();
    parse(&tokens, &mut ctx).unwrap();
    ctx.ast
}

/// Build a MetaAst containing a single `var _ = <expr>` statement.
/// Returns the ast and the ID of the inserted expression.
fn ast_with_expr(expr: MetaExpr) -> (MetaAst, usize) {
    let mut ast = MetaAst::new();
    let mut ids = IdProvider::new();
    let expr_id = ast.insert_expr(&mut ids, expr);
    let stmt_id = ast.insert_stmt(&mut ids, MetaStmt::VarDecl {
        name: "_".into(),
        expr: expr_id,
    });
    ast.sem_root_stmts.push(stmt_id);
    (ast, expr_id)
}

#[cfg(test)]
mod type_check_tests {
    use super::*;

    // --- Literal typing ---

    #[test]
    fn int_literal_infers_int() {
        let (ast, expr_id) = ast_with_expr(MetaExpr::Int(42));
        let (table, _) = type_check(&ast).unwrap();
        assert_eq!(table.get_expr_type(expr_id), Some(&int_type()));
    }

    #[test]
    fn bool_literal_infers_bool() {
        let (ast, expr_id) = ast_with_expr(MetaExpr::Bool(true));
        let (table, _) = type_check(&ast).unwrap();
        assert_eq!(table.get_expr_type(expr_id), Some(&bool_type()));
    }

    #[test]
    fn string_literal_infers_string() {
        let (ast, expr_id) = ast_with_expr(MetaExpr::String("hi".into()));
        let (table, _) = type_check(&ast).unwrap();
        assert_eq!(table.get_expr_type(expr_id), Some(&string_type()));
    }

    // --- Variables ---

    #[test]
    fn unbound_variable_errors() {
        let ast = parse_source("var x = y;");
        assert!(type_check(&ast).is_err());
    }

    #[test]
    fn var_decl_binds_type_in_env() {
        let ast = parse_source("var x = 3;");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(env.lookup("x"), Some(int_type()));
    }

    #[test]
    fn variable_reference_infers_bound_type() {
        // x is bound to int, y = x should also be int
        let ast = parse_source("var x = 3; var y = x;");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(env.lookup("y"), Some(int_type()));
    }

    // --- Block scoping ---

    #[test]
    fn block_scope_does_not_leak() {
        let ast = parse_source("{ var x = 1; }");
        let (_, mut env) = type_check(&ast).unwrap();
        assert!(env.get_type("x").is_none());
    }

    // --- If statements ---

    #[test]
    fn if_condition_must_be_bool() {
        let ast = parse_source("if (1) {}");
        assert!(type_check(&ast).is_err());
    }

    #[test]
    fn if_bool_condition_ok() {
        let ast = parse_source("if (true) {}");
        assert!(type_check(&ast).is_ok());
    }

    #[test]
    fn if_without_else_ok() {
        let ast = parse_source("if (true) { var x = 1; }");
        assert!(type_check(&ast).is_ok());
    }

    #[test]
    fn if_branch_scope_does_not_leak() {
        // The if body is a Block, so its bindings are properly scoped
        let ast = parse_source("if (true) { var x = 1; }");
        let (_, mut env) = type_check(&ast).unwrap();
        assert!(env.get_type("x").is_none());
    }

    // --- Function declarations ---

    #[test]
    fn fn_decl_no_return_binds_unit() {
        let ast = parse_source("fn foo() {}");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(
            env.lookup("foo"),
            Some(Type::Func {
                params: vec![],
                ret: Box::new(unit_type()),
            })
        );
    }

    #[test]
    fn fn_decl_with_return_binds_correct_type() {
        let ast = parse_source("fn foo() { return 3; }");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(
            env.lookup("foo"),
            Some(Type::Func {
                params: vec![],
                ret: Box::new(int_type()),
            })
        );
    }

    #[test]
    fn fn_return_branches_match() {
        let ast = parse_source("
            fn foo() {
                if (true) { return 1; }
                else { return 5; }
            }
        ");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(
            env.lookup("foo"),
            Some(Type::Func {
                params: vec![],
                ret: Box::new(int_type()),
            })
        );
    }

    #[test]
    fn fn_return_branches_mismatch_errors() {
        let ast = parse_source("
            fn foo() {
                if (true) { return 1; }
                else { return true; }
            }
        ");
        assert!(type_check(&ast).is_err());
    }

    // --- Calls ---

    #[test]
    fn call_simple_function_ok() {
        let ast = parse_source("
            fn id(x) { return x; }
            id(3);
        ");
        assert!(type_check(&ast).is_ok());
    }

    #[test]
    fn call_returns_correct_type() {
        let ast = parse_source("
            fn five() { return 5; }
            var x = five();
        ");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(env.lookup("x"), Some(int_type()));
    }

    #[test]
    fn call_with_multiple_params() {
        let ast = parse_source("
            fn ret_first(a, b) { return a; }
            var x = ret_first(1, \"hi\");
        ");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(env.lookup("x"), Some(int_type()));
    }

    #[test]
    fn call_argument_type_mismatch_errors() {
        // foo expects bool (used in if), called with int
        let ast = parse_source("
            fn cond(x) {
                if (x) { return 3; }
                else { return 7; }
            }
            cond(3);
        ");
        assert!(type_check(&ast).is_err());
    }

    #[test]
    fn call_polymorphic_identity_twice() {
        let ast = parse_source("
            fn id(x) { return x; }
            var a = id(1);
            var b = id(true);
        ");
        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(env.lookup("a"), Some(int_type()));
        assert_eq!(env.lookup("b"), Some(bool_type()));
    }

    // --- Record types ---

    #[test]
    fn record_literal_infers_record_type() {
        // Build the MetaAst manually since the parser doesn't support bare
        // object literal syntax yet ({ key: value })
        let mut ast = MetaAst::new();
        let mut ids = IdProvider::new();

        let name_val = ast.insert_expr(&mut ids, MetaExpr::String("Alice".into()));
        let age_val  = ast.insert_expr(&mut ids, MetaExpr::Int(30));
        let record   = ast.insert_expr(&mut ids, MetaExpr::StructLiteral {
            type_name: String::new(),
            fields: vec![
                ("name".into(), name_val),
                ("age".into(),  age_val),
            ],
        });
        let stmt = ast.insert_stmt(&mut ids, MetaStmt::VarDecl {
            name: "p".into(),
            expr: record,
        });
        ast.sem_root_stmts.push(stmt);

        let (_, mut env) = type_check(&ast).unwrap();
        assert_eq!(
            env.lookup("p"),
            Some(record_type([
                ("age".to_string(),  int_type()),
                ("name".to_string(), string_type()),
            ]))
        );
    }
}
