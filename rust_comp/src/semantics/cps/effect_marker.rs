use std::collections::{HashMap, HashSet};

use crate::frontend::meta_ast::EffectOpKind;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};

/// Result of the effect-marking pass.
#[derive(Debug, Default)]
pub struct CpsInfo {
    /// Names of all `ctl` operations declared in the program.
    pub ctl_ops: HashSet<String>,
    /// Names of all functions that must be CPS-transformed (call ctl ops directly or
    /// transitively). Only functions with sequential top-level ctl calls are included;
    /// ctl calls inside loops are left to the existing replay-stack mechanism.
    pub cps_fns: HashSet<String>,
}

/// Walk `ast` and populate a `CpsInfo` describing which ops are `ctl` and which
/// functions must be CPS-transformed.
pub fn mark_cps(ast: &RuntimeAst) -> CpsInfo {
    let mut info = CpsInfo::default();

    // Phase 1 — collect ctl op names from effect declarations.
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::EffectDecl { ops, .. } = stmt {
            for op in ops {
                if matches!(op.kind, EffectOpKind::Ctl) {
                    info.ctl_ops.insert(op.name.clone());
                }
            }
        }
    }

    // Phase 2 — find functions that make direct sequential ctl calls in their body
    // (top-level block only; ctl calls inside loops are excluded).
    let mut fn_bodies: HashMap<String, usize> = HashMap::new();
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, body, .. } = stmt {
            fn_bodies.insert(name.clone(), *body);
            if body_has_sequential_ctl_call(ast, *body, &info.ctl_ops) {
                info.cps_fns.insert(name.clone());
            }
        }
    }

    // Phase 3 — transitive closure: if a function calls a cps_fn it is also cps.
    loop {
        let mut added = false;
        for (name, &body_id) in &fn_bodies {
            if info.cps_fns.contains(name) {
                continue;
            }
            if body_calls_any_of(ast, body_id, &info.cps_fns) {
                info.cps_fns.insert(name.clone());
                added = true;
            }
        }
        if !added {
            break;
        }
    }

    info
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Returns true if `body_id` (a Block or single stmt) contains a ctl op call at
/// the top level of the block — i.e. not nested inside a loop body.
fn body_has_sequential_ctl_call(ast: &RuntimeAst, body_id: usize, ctl_ops: &HashSet<String>) -> bool {
    match ast.get_stmt(body_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            stmts.iter().any(|&id| stmt_is_direct_ctl_call(ast, id, ctl_ops))
        }
        Some(_) => stmt_is_direct_ctl_call(ast, body_id, ctl_ops),
        None => false,
    }
}

/// Returns true if `stmt_id` is, or recursively contains, a ctl op call.
/// Recurses into WhileLoop bodies so that functions like `range` that only
/// call ctl ops from inside a loop are still marked as CPS functions.
fn stmt_is_direct_ctl_call(ast: &RuntimeAst, stmt_id: usize, ctl_ops: &HashSet<String>) -> bool {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::VarDecl { expr, .. }) | Some(RuntimeStmt::ExprStmt(expr)) => {
            expr_calls_ctl_op(ast, *expr, ctl_ops)
        }
        Some(RuntimeStmt::Block(stmts)) => {
            stmts.iter().any(|&id| stmt_is_direct_ctl_call(ast, id, ctl_ops))
        }
        Some(RuntimeStmt::WhileLoop { body, .. }) => {
            stmt_is_direct_ctl_call(ast, *body, ctl_ops)
        }
        _ => false,
    }
}

fn expr_calls_ctl_op(ast: &RuntimeAst, expr_id: usize, ctl_ops: &HashSet<String>) -> bool {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, .. }) => ctl_ops.contains(callee.as_str()),
        _ => false,
    }
}

/// Returns true if `stmt_id` (recursively) calls any function in `fns`.
fn body_calls_any_of(ast: &RuntimeAst, body_id: usize, fns: &HashSet<String>) -> bool {
    stmt_calls_any_of(ast, body_id, fns)
}

fn stmt_calls_any_of(ast: &RuntimeAst, stmt_id: usize, fns: &HashSet<String>) -> bool {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::VarDecl { expr, .. }) | Some(RuntimeStmt::ExprStmt(expr)) => {
            expr_calls_any_of(ast, *expr, fns)
        }
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            stmts.iter().any(|&id| stmt_calls_any_of(ast, id, fns))
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            expr_calls_any_of(ast, *cond, fns)
                || stmt_calls_any_of(ast, *body, fns)
                || else_branch.map_or(false, |e| stmt_calls_any_of(ast, e, fns))
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            expr_calls_any_of(ast, *cond, fns) || stmt_calls_any_of(ast, *body, fns)
        }
        Some(RuntimeStmt::ForEach { body, .. }) => stmt_calls_any_of(ast, *body, fns),
        Some(RuntimeStmt::Return(Some(expr))) => expr_calls_any_of(ast, *expr, fns),
        _ => false,
    }
}

fn expr_calls_any_of(ast: &RuntimeAst, expr_id: usize, fns: &HashSet<String>) -> bool {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            if fns.contains(callee.as_str()) {
                return true;
            }
            let args = args.clone();
            args.iter().any(|&a| expr_calls_any_of(ast, a, fns))
        }
        _ => false,
    }
}
