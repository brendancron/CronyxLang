use super::staged_ast::*;
use std::collections::HashSet;

/// Names declared at the top level of a tree — what this tree exports to others.
pub fn collect_provides(ast: &StagedAst) -> HashSet<String> {
    let mut provides = HashSet::new();
    for stmt_id in &ast.sem_root_stmts {
        collect_top_level_decl(ast, *stmt_id, &mut provides);
    }
    provides
}

/// Names used in this tree that are not declared anywhere within it.
/// Skips Gen blocks — variables inside gen are runtime references, not meta-time deps.
pub fn collect_external_uses(ast: &StagedAst) -> HashSet<String> {
    let mut declares = HashSet::new();
    let mut uses = HashSet::new();

    // Walk from the root stmts so we preserve structural context (e.g., in_gen).
    for &stmt_id in &ast.sem_root_stmts {
        collect_stmt_symbols(ast, stmt_id, &mut declares, &mut uses, false);
    }

    uses.difference(&declares).cloned().collect()
}

fn collect_top_level_decl(ast: &StagedAst, stmt_id: usize, out: &mut HashSet<String>) {
    let Some(stmt) = ast.get_stmt(stmt_id) else { return };
    match stmt {
        StagedStmt::VarDecl { name, .. } => { out.insert(name.clone()); }
        StagedStmt::FnDecl { name, .. } => { out.insert(name.clone()); }
        StagedStmt::StructDecl { name, .. } => { out.insert(name.clone()); }
        // Gen blocks export the declarations they contain
        StagedStmt::Gen(stmts) => {
            for &child_id in stmts {
                collect_top_level_decl(ast, child_id, out);
            }
        }
        StagedStmt::Block(stmts) => {
            for &child_id in stmts {
                collect_top_level_decl(ast, child_id, out);
            }
        }
        _ => {}
    }
}

/// `in_gen`: if true, collect declares but skip uses (gen body is runtime code, not meta deps).
fn collect_stmt_symbols(
    ast: &StagedAst,
    stmt_id: usize,
    declares: &mut HashSet<String>,
    uses: &mut HashSet<String>,
    in_gen: bool,
) {
    let Some(stmt) = ast.get_stmt(stmt_id) else { return };
    match stmt {
        StagedStmt::VarDecl { name, expr } => {
            declares.insert(name.clone());
            collect_expr_symbols(ast, *expr, declares, uses, in_gen);
        }
        StagedStmt::Assign { expr, .. } => {
            collect_expr_symbols(ast, *expr, declares, uses, in_gen);
        }
        StagedStmt::IndexAssign { indices, expr, .. } => {
            for &idx in indices {
                collect_expr_symbols(ast, idx, declares, uses, in_gen);
            }
            collect_expr_symbols(ast, *expr, declares, uses, in_gen);
        }
        StagedStmt::FnDecl { name, params, body, .. } => {
            declares.insert(name.clone());
            for p in params { declares.insert(p.clone()); }
            collect_stmt_symbols(ast, *body, declares, uses, in_gen);
        }
        StagedStmt::StructDecl { name, .. } => { declares.insert(name.clone()); }
        StagedStmt::ForEach { var, iterable, body } => {
            declares.insert(var.clone());
            collect_expr_symbols(ast, *iterable, declares, uses, in_gen);
            collect_stmt_symbols(ast, *body, declares, uses, in_gen);
        }
        StagedStmt::WhileLoop { cond, body } => {
            collect_expr_symbols(ast, *cond, declares, uses, in_gen);
            collect_stmt_symbols(ast, *body, declares, uses, in_gen);
        }
        StagedStmt::If { cond, body, else_branch } => {
            collect_expr_symbols(ast, *cond, declares, uses, in_gen);
            collect_stmt_symbols(ast, *body, declares, uses, in_gen);
            if let Some(e) = else_branch {
                collect_stmt_symbols(ast, *e, declares, uses, in_gen);
            }
        }
        StagedStmt::Block(stmts) => {
            for &child in stmts {
                collect_stmt_symbols(ast, child, declares, uses, in_gen);
            }
        }
        StagedStmt::Gen(stmts) => {
            // Recurse with in_gen=true: collect declares (for shadowing), skip uses
            for &child in stmts {
                collect_stmt_symbols(ast, child, declares, uses, true);
            }
        }
        StagedStmt::Return(expr) => {
            if let Some(e) = expr {
                collect_expr_symbols(ast, *e, declares, uses, in_gen);
            }
        }
        StagedStmt::ExprStmt(expr) | StagedStmt::Print(expr) => {
            collect_expr_symbols(ast, *expr, declares, uses, in_gen);
        }
        StagedStmt::MetaStmt(_) | StagedStmt::Import(_) => {}
        StagedStmt::EnumDecl { name, .. } => { declares.insert(name.clone()); }
        StagedStmt::EffectDecl { .. } | StagedStmt::Resume(_) => {}
        StagedStmt::WithFn { body, .. } | StagedStmt::WithCtl { body, .. } => {
            collect_stmt_symbols(ast, *body, declares, uses, in_gen);
        }
        StagedStmt::Match { scrutinee, arms } => {
            collect_expr_symbols(ast, *scrutinee, declares, uses, in_gen);
            for arm in arms {
                collect_stmt_symbols(ast, arm.body, declares, uses, in_gen);
            }
        }
    }
}

fn collect_expr_symbols(
    ast: &StagedAst,
    expr_id: usize,
    declares: &mut HashSet<String>,
    uses: &mut HashSet<String>,
    in_gen: bool,
) {
    let Some(expr) = ast.get_expr(expr_id) else { return };
    match expr {
        StagedExpr::Variable(name) => {
            if !in_gen { uses.insert(name.clone()); }
        }
        StagedExpr::Call { callee, args } => {
            if !in_gen { uses.insert(callee.clone()); }
            for &arg in args {
                collect_expr_symbols(ast, arg, declares, uses, in_gen);
            }
        }
        StagedExpr::Add(a, b) | StagedExpr::Sub(a, b)
        | StagedExpr::Mult(a, b) | StagedExpr::Div(a, b)
        | StagedExpr::Equals(a, b) | StagedExpr::NotEquals(a, b)
        | StagedExpr::Lt(a, b) | StagedExpr::Gt(a, b)
        | StagedExpr::Lte(a, b) | StagedExpr::Gte(a, b)
        | StagedExpr::And(a, b) | StagedExpr::Or(a, b) => {
            collect_expr_symbols(ast, *a, declares, uses, in_gen);
            collect_expr_symbols(ast, *b, declares, uses, in_gen);
        }
        StagedExpr::Not(a) => {
            collect_expr_symbols(ast, *a, declares, uses, in_gen);
        }
        StagedExpr::List(items) => {
            for &item in items {
                collect_expr_symbols(ast, item, declares, uses, in_gen);
            }
        }
        StagedExpr::StructLiteral { fields, .. } => {
            for (_, field_expr) in fields {
                collect_expr_symbols(ast, *field_expr, declares, uses, in_gen);
            }
        }
        StagedExpr::DotAccess { object, .. } => {
            collect_expr_symbols(ast, *object, declares, uses, in_gen);
        }
        StagedExpr::DotCall { object, args, .. } => {
            collect_expr_symbols(ast, *object, declares, uses, in_gen);
            for &arg in args {
                collect_expr_symbols(ast, arg, declares, uses, in_gen);
            }
        }
        StagedExpr::Index { object, index } => {
            collect_expr_symbols(ast, *object, declares, uses, in_gen);
            collect_expr_symbols(ast, *index, declares, uses, in_gen);
        }
        StagedExpr::Tuple(items) => {
            for &item in items {
                collect_expr_symbols(ast, item, declares, uses, in_gen);
            }
        }
        StagedExpr::TupleIndex { object, .. } => {
            collect_expr_symbols(ast, *object, declares, uses, in_gen);
        }
        StagedExpr::SliceRange { object, start, end } => {
            collect_expr_symbols(ast, *object, declares, uses, in_gen);
            if let Some(s) = start { collect_expr_symbols(ast, *s, declares, uses, in_gen); }
            if let Some(e) = end { collect_expr_symbols(ast, *e, declares, uses, in_gen); }
        }
        StagedExpr::Lambda { .. } => {}
        StagedExpr::Int(_) | StagedExpr::String(_) | StagedExpr::Bool(_)
        | StagedExpr::MetaExpr(_) => {}
        StagedExpr::EnumConstructor { payload, .. } => {
            use crate::frontend::meta_ast::ConstructorPayload;
            match payload {
                ConstructorPayload::Tuple(ids) => {
                    for &id in ids { collect_expr_symbols(ast, id, declares, uses, in_gen); }
                }
                ConstructorPayload::Struct(fields) => {
                    for (_, id) in fields { collect_expr_symbols(ast, *id, declares, uses, in_gen); }
                }
                ConstructorPayload::Unit => {}
            }
        }
    }
}
