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

/// Result of the fn-effect marking pass.
/// Tracks which `fn` (non-resumable) effect operations each function uses, so the
/// handler-transform pass can add explicit handler parameters and rewrite call sites.
#[derive(Debug, Default)]
pub struct FnEffectInfo {
    /// All `fn` op names declared across all effects in the program.
    pub fn_ops: HashSet<String>,
    /// function name → sorted list of fn-op names it uses (directly or transitively).
    /// Sorted for deterministic parameter ordering.
    pub fn_effect_fns: HashMap<String, Vec<String>>,
}

/// Walk `ast` and return a `FnEffectInfo` describing which functions use `fn` effect ops.
pub fn mark_fn_effects(ast: &RuntimeAst) -> FnEffectInfo {
    let mut info = FnEffectInfo::default();

    // Phase 1 — collect fn op names from effect declarations.
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::EffectDecl { ops, .. } = stmt {
            for op in ops {
                if matches!(op.kind, EffectOpKind::Fn) {
                    info.fn_ops.insert(op.name.clone());
                }
            }
        }
    }

    if info.fn_ops.is_empty() {
        return info;
    }

    // Phase 2 — find functions with direct fn-op calls in their body.
    let mut fn_bodies: HashMap<String, RuntimeNodeId> = HashMap::new();
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, body, .. } = stmt {
            fn_bodies.insert(name.clone(), *body);
            let used: HashSet<String> = collect_fn_op_calls(ast, *body, &info.fn_ops);
            if !used.is_empty() {
                let mut ops: Vec<String> = used.into_iter().collect();
                ops.sort();
                info.fn_effect_fns.insert(name.clone(), ops);
            }
        }
    }

    // Pre-compute which fn-ops each function PROVIDES via WithFn in its body.
    // A function that provides op X does not need to receive __h_X as a parameter.
    let mut provided: HashMap<String, HashSet<String>> = HashMap::new();
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, body, .. } = stmt {
            let p = collect_provided_fn_ops(ast, *body);
            if !p.is_empty() {
                provided.insert(name.clone(), p);
            }
        }
    }

    // Phase 3 — transitive closure: callers of fn-effect functions also need handler params.
    let mut callers: HashMap<String, Vec<String>> = HashMap::new();
    for (name, &body_id) in &fn_bodies {
        for callee in collect_callees(ast, body_id) {
            callers.entry(callee).or_default().push(name.clone());
        }
    }

    let mut queue: VecDeque<String> = info.fn_effect_fns.keys().cloned().collect();
    while let Some(fn_name) = queue.pop_front() {
        let ops = info.fn_effect_fns[&fn_name].clone();
        if let Some(caller_list) = callers.get(&fn_name) {
            for caller in caller_list.clone() {
                let caller_provides = provided.get(&caller);
                // Only propagate ops the caller doesn't already provide via WithFn.
                let new_ops: Vec<String> = ops.iter()
                    .filter(|op| !caller_provides.map_or(false, |p| p.contains(*op)))
                    .cloned()
                    .collect();
                if new_ops.is_empty() { continue; }
                let entry = info.fn_effect_fns.entry(caller.clone()).or_default();
                let before = entry.len();
                for op in &new_ops {
                    if !entry.contains(op) {
                        entry.push(op.clone());
                    }
                }
                if entry.len() > before {
                    entry.sort();
                    queue.push_back(caller);
                }
            }
        }
    }

    info
}

/// Collect all fn-op names that a function body installs via `WithFn`.
fn collect_provided_fn_ops(ast: &RuntimeAst, body_id: RuntimeNodeId) -> HashSet<String> {
    let mut out = HashSet::new();
    collect_provided_fn_ops_stmt(ast, body_id, &mut out);
    out
}

fn collect_provided_fn_ops_stmt(ast: &RuntimeAst, stmt_id: RuntimeNodeId, out: &mut HashSet<String>) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::WithFn { op_name, .. }) => { out.insert(op_name.clone()); }
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts { collect_provided_fn_ops_stmt(ast, id, out); }
        }
        _ => {}
    }
}

fn collect_fn_op_calls(ast: &RuntimeAst, body_id: RuntimeNodeId, fn_ops: &HashSet<String>) -> HashSet<String> {
    let mut out = HashSet::new();
    collect_fn_op_calls_stmt(ast, body_id, fn_ops, &mut out);
    out
}

fn collect_fn_op_calls_stmt(ast: &RuntimeAst, stmt_id: RuntimeNodeId, fn_ops: &HashSet<String>, out: &mut HashSet<String>) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts { collect_fn_op_calls_stmt(ast, id, fn_ops, out); }
        }
        Some(RuntimeStmt::VarDecl { expr, .. }) | Some(RuntimeStmt::ExprStmt(expr)) => {
            collect_fn_op_calls_expr(ast, *expr, fn_ops, out);
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            collect_fn_op_calls_expr(ast, *cond, fn_ops, out);
            collect_fn_op_calls_stmt(ast, *body, fn_ops, out);
            if let Some(e) = else_branch { collect_fn_op_calls_stmt(ast, *e, fn_ops, out); }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            collect_fn_op_calls_expr(ast, *cond, fn_ops, out);
            collect_fn_op_calls_stmt(ast, *body, fn_ops, out);
        }
        Some(RuntimeStmt::ForEach { body, .. }) => collect_fn_op_calls_stmt(ast, *body, fn_ops, out),
        Some(RuntimeStmt::Return(Some(expr))) => collect_fn_op_calls_expr(ast, *expr, fn_ops, out),
        Some(RuntimeStmt::Print(expr)) => collect_fn_op_calls_expr(ast, *expr, fn_ops, out),
        Some(RuntimeStmt::Assign { expr, .. }) => collect_fn_op_calls_expr(ast, *expr, fn_ops, out),
        _ => {}
    }
}

fn collect_fn_op_calls_expr(ast: &RuntimeAst, expr_id: RuntimeNodeId, fn_ops: &HashSet<String>, out: &mut HashSet<String>) {
    let children: Vec<RuntimeNodeId> = match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            if fn_ops.contains(callee.as_str()) {
                out.insert(callee.clone());
            }
            args.clone()
        }
        Some(RuntimeExpr::Add(a, b) | RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b)
            | RuntimeExpr::Div(a, b) | RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b)
            | RuntimeExpr::Lt(a, b) | RuntimeExpr::Gt(a, b) | RuntimeExpr::Lte(a, b)
            | RuntimeExpr::Gte(a, b) | RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b)) => {
            vec![*a, *b]
        }
        Some(RuntimeExpr::Not(a)) => vec![*a],
        Some(RuntimeExpr::List(elems) | RuntimeExpr::Tuple(elems)) => elems.clone(),
        Some(RuntimeExpr::Lambda { body, .. }) => {
            collect_fn_op_calls_stmt(ast, *body, fn_ops, out);
            return;
        }
        Some(RuntimeExpr::DotCall { object, args, .. }) => {
            let mut v = vec![*object];
            v.extend(args.iter().copied());
            v
        }
        Some(RuntimeExpr::StructLiteral { fields, .. }) => fields.iter().map(|(_, id)| *id).collect(),
        _ => return,
    };
    for c in children { collect_fn_op_calls_expr(ast, c, fn_ops, out); }
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
        Some(RuntimeStmt::Print(expr)) => collect_callees_expr(ast, *expr, out),
        Some(RuntimeStmt::Assign { expr, .. }) => collect_callees_expr(ast, *expr, out),
        _ => {}
    }
}

fn collect_callees_expr(ast: &RuntimeAst, expr_id: RuntimeNodeId, out: &mut HashSet<String>) {
    let children: Vec<RuntimeNodeId> = match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            out.insert(callee.clone());
            args.clone()
        }
        Some(RuntimeExpr::Add(a, b) | RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b)
            | RuntimeExpr::Div(a, b) | RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b)
            | RuntimeExpr::Lt(a, b) | RuntimeExpr::Gt(a, b) | RuntimeExpr::Lte(a, b)
            | RuntimeExpr::Gte(a, b) | RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b)) => {
            vec![*a, *b]
        }
        Some(RuntimeExpr::Not(a)) => vec![*a],
        Some(RuntimeExpr::List(elems) | RuntimeExpr::Tuple(elems)) => elems.clone(),
        Some(RuntimeExpr::Lambda { body, .. }) => {
            collect_callees_stmt(ast, *body, out);
            return;
        }
        Some(RuntimeExpr::DotCall { object, args, .. }) => {
            let mut v = vec![*object];
            v.extend(args.iter().copied());
            v
        }
        Some(RuntimeExpr::StructLiteral { fields, .. }) => fields.iter().map(|(_, id)| *id).collect(),
        _ => return,
    };
    for c in children { collect_callees_expr(ast, c, out); }
}
