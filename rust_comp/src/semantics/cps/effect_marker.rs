use std::collections::{HashMap, HashSet, VecDeque};

use crate::frontend::meta_ast::EffectOpKind;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::util::node_id::RuntimeNodeId;

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

    // Phase 2 — find functions that make direct sequential ctl calls in their body.
    let mut fn_bodies: HashMap<String, RuntimeNodeId> = HashMap::new();
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, body, .. } = stmt {
            fn_bodies.insert(name.clone(), *body);
            if body_has_sequential_ctl_call(ast, *body, &info.ctl_ops) {
                info.cps_fns.insert(name.clone());
            }
        }
    }

    // Phase 3 — transitive closure via BFS on a reverse call graph.
    // Build callers: fn_name → functions that call it.
    // Then seed a worklist from the initial cps_fns and propagate outward.
    // Each function is enqueued at most once → O(n + E) vs the previous O(n²).
    let mut callers: HashMap<String, Vec<String>> = HashMap::new();
    for (name, &body_id) in &fn_bodies {
        for callee in collect_callees(ast, body_id) {
            callers.entry(callee).or_default().push(name.clone());
        }
    }

    let mut queue: VecDeque<String> = info.cps_fns.iter().cloned().collect();
    while let Some(cps_fn) = queue.pop_front() {
        if let Some(caller_list) = callers.get(&cps_fn) {
            for caller in caller_list {
                if info.cps_fns.insert(caller.clone()) {
                    queue.push_back(caller.clone());
                }
            }
        }
    }

    info
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn body_has_sequential_ctl_call(ast: &RuntimeAst, body_id: RuntimeNodeId, ctl_ops: &HashSet<String>) -> bool {
    match ast.get_stmt(body_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            stmts.iter().any(|&id| stmt_is_direct_ctl_call(ast, id, ctl_ops))
        }
        Some(_) => stmt_is_direct_ctl_call(ast, body_id, ctl_ops),
        None => false,
    }
}

fn stmt_is_direct_ctl_call(ast: &RuntimeAst, stmt_id: RuntimeNodeId, ctl_ops: &HashSet<String>) -> bool {
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
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            expr_calls_ctl_op(ast, *cond, ctl_ops)
                || stmt_is_direct_ctl_call(ast, *body, ctl_ops)
                || else_branch.map_or(false, |e| stmt_is_direct_ctl_call(ast, e, ctl_ops))
        }
        Some(RuntimeStmt::Return(Some(expr))) => {
            expr_calls_ctl_op(ast, *expr, ctl_ops)
        }
        _ => false,
    }
}

fn expr_calls_ctl_op(ast: &RuntimeAst, expr_id: RuntimeNodeId, ctl_ops: &HashSet<String>) -> bool {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, .. }) => ctl_ops.contains(callee.as_str()),
        _ => false,
    }
}

fn collect_callees(ast: &RuntimeAst, body_id: RuntimeNodeId) -> HashSet<String> {
    let mut out = HashSet::new();
    collect_callees_stmt(ast, body_id, &mut out);
    out
}

fn collect_callees_stmt(ast: &RuntimeAst, stmt_id: RuntimeNodeId, out: &mut HashSet<String>) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::VarDecl { expr, .. }) | Some(RuntimeStmt::ExprStmt(expr)) => {
            collect_callees_expr(ast, *expr, out);
        }
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts { collect_callees_stmt(ast, id, out); }
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            collect_callees_expr(ast, *cond, out);
            collect_callees_stmt(ast, *body, out);
            if let Some(e) = else_branch { collect_callees_stmt(ast, *e, out); }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            collect_callees_expr(ast, *cond, out);
            collect_callees_stmt(ast, *body, out);
        }
        Some(RuntimeStmt::ForEach { body, .. }) => collect_callees_stmt(ast, *body, out),
        Some(RuntimeStmt::Return(Some(expr))) => collect_callees_expr(ast, *expr, out),
        _ => {}
    }
}

fn collect_callees_expr(ast: &RuntimeAst, expr_id: RuntimeNodeId, out: &mut HashSet<String>) {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            out.insert(callee.clone());
            let args = args.clone();
            for &a in &args { collect_callees_expr(ast, a, out); }
        }
        _ => {}
    }
}
