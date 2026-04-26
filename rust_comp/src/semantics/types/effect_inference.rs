//! Effect inference — Chunk 1 (monomorphic, no row variables).
//!
//! Two passes:
//!
//! **Pass A1 — `infer_meta`**: Runs on the MetaAst before staging. Collects ctl ops,
//! infers per-function effect rows via fixed-point iteration, and updates `TypeEnv`
//! so that `typeof(fn)` resolves to the correct type string during staging.
//!
//! **Pass A2 + B — `infer_and_check`**: Runs on the RuntimeAst after meta-processing.
//! Re-infers effect rows (now authoritative post-monomorphization) and then checks that
//! every top-level call site has all required effects handled.

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::error::CompilerError;
use crate::frontend::meta_ast::{EffectOpKind, MetaAst, MetaExpr, MetaStmt};
use crate::semantics::cps::effect_marker::CpsInfo;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::semantics::types::type_env::TypeEnv;
use crate::semantics::types::types::{EffectRow, Type, TypeScheme};

// ── Public types ─────────────────────────────────────────────────────────────

/// Per-function inferred effect rows (post-staging).
#[derive(Debug, Default, Clone)]
pub struct EffectInfo {
    /// Maps function name → sorted set of ctl op names it performs (directly or transitively).
    pub fn_rows: HashMap<String, BTreeSet<String>>,
    /// Maps function name → set of ctl ops it handles internally via `with ctl`.
    /// Used to allow HOF arguments whose effects are handled by the callee.
    pub fn_handles: HashMap<String, BTreeSet<String>>,
}

impl EffectInfo {
    pub fn row_of(&self, fn_name: &str) -> Option<&BTreeSet<String>> {
        self.fn_rows.get(fn_name)
    }
    pub fn handles_of(&self, fn_name: &str) -> Option<&BTreeSet<String>> {
        self.fn_handles.get(fn_name)
    }
}

// ── Pass A1: MetaAst inference ────────────────────────────────────────────────

/// Infer effect rows from the MetaAst and update `type_env` in place.
///
/// Must be called **after** `type_check` and **before** `stage_all_files` so that
/// `typeof(fn)` expressions in the MetaAst resolve to types that include effect rows.
pub fn infer_meta(meta_ast: &MetaAst, type_env: &mut TypeEnv) {
    let ctl_ops = collect_ctl_ops_meta(meta_ast);
    if ctl_ops.is_empty() {
        return;
    }

    // Collect function bodies from MetaAst sem_root_stmts.
    let mut fn_bodies: HashMap<String, usize> = HashMap::new();
    for &stmt_id in &meta_ast.sem_root_stmts {
        if let Some(MetaStmt::FnDecl { name, body, .. }) = meta_ast.get_stmt(stmt_id) {
            fn_bodies.insert(name.clone(), *body);
        }
    }

    let fn_rows = infer_fn_rows_meta(meta_ast, &fn_bodies, &ctl_ops);

    // Update type_env: for each function with a non-empty effect row, patch its Func type.
    for (fn_name, ops) in &fn_rows {
        if ops.is_empty() {
            continue;
        }
        let new_effects = EffectRow { effects: ops.clone() };
        // Look up current type scheme and patch the effects field.
        let updated = match type_env.get_type(fn_name) {
            Some(TypeScheme::MonoType(Type::Func { params, ret, .. })) => {
                Some(TypeScheme::MonoType(Type::Func { params, ret, effects: new_effects }))
            }
            Some(TypeScheme::PolyType { vars, ty: Type::Func { params, ret, .. } }) => {
                Some(TypeScheme::PolyType {
                    vars,
                    ty: Type::Func { params, ret, effects: new_effects },
                })
            }
            _ => None,
        };
        if let Some(scheme) = updated {
            type_env.bind(fn_name, scheme);
        }
    }
}

fn collect_ctl_ops_meta(meta_ast: &MetaAst) -> HashSet<String> {
    let mut ops = HashSet::new();
    for &stmt_id in &meta_ast.sem_root_stmts {
        if let Some(MetaStmt::EffectDecl { ops: effect_ops, .. }) = meta_ast.get_stmt(stmt_id) {
            for op in effect_ops {
                if matches!(op.kind, EffectOpKind::Ctl) {
                    ops.insert(op.name.clone());
                }
            }
        }
    }
    ops
}

fn infer_fn_rows_meta(
    meta_ast: &MetaAst,
    fn_bodies: &HashMap<String, usize>,
    ctl_ops: &HashSet<String>,
) -> HashMap<String, BTreeSet<String>> {
    let mut fn_rows: HashMap<String, BTreeSet<String>> = HashMap::new();

    // Pass A1a: direct ctl calls per function.
    for (name, &body_id) in fn_bodies {
        let mut row = BTreeSet::new();
        collect_ctl_calls_meta_stmt(meta_ast, body_id, ctl_ops, &mut row);
        if !row.is_empty() {
            fn_rows.insert(name.clone(), row);
        }
    }

    // Pass A1b: transitive closure — propagate effects through function calls.
    loop {
        let mut changed = false;
        let snapshot = fn_rows.clone();
        for (name, &body_id) in fn_bodies {
            let mut additional = BTreeSet::new();
            collect_transitive_meta_stmt(meta_ast, body_id, &snapshot, &mut additional);
            let row = fn_rows.entry(name.clone()).or_default();
            let prev = row.len();
            row.extend(additional);
            if row.len() > prev {
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }

    fn_rows
}

fn collect_ctl_calls_meta_stmt(
    ast: &MetaAst,
    stmt_id: usize,
    ctl_ops: &HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_stmt(stmt_id) {
        Some(MetaStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts {
                collect_ctl_calls_meta_stmt(ast, id, ctl_ops, out);
            }
        }
        Some(MetaStmt::ExprStmt(e)) => {
            collect_ctl_calls_meta_expr(ast, *e, ctl_ops, out);
        }
        Some(MetaStmt::VarDecl { expr, .. }) => {
            collect_ctl_calls_meta_expr(ast, *expr, ctl_ops, out);
        }
        Some(MetaStmt::If { cond, body, else_branch }) => {
            collect_ctl_calls_meta_expr(ast, *cond, ctl_ops, out);
            collect_ctl_calls_meta_stmt(ast, *body, ctl_ops, out);
            if let Some(e) = else_branch {
                collect_ctl_calls_meta_stmt(ast, *e, ctl_ops, out);
            }
        }
        Some(MetaStmt::WhileLoop { cond, body }) => {
            collect_ctl_calls_meta_expr(ast, *cond, ctl_ops, out);
            collect_ctl_calls_meta_stmt(ast, *body, ctl_ops, out);
        }
        Some(MetaStmt::ForEach { body, .. }) => {
            collect_ctl_calls_meta_stmt(ast, *body, ctl_ops, out);
        }
        Some(MetaStmt::Return(Some(e))) => {
            collect_ctl_calls_meta_expr(ast, *e, ctl_ops, out);
        }
        _ => {}
    }
}

fn collect_ctl_calls_meta_expr(
    ast: &MetaAst,
    expr_id: usize,
    ctl_ops: &HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_expr(expr_id) {
        Some(MetaExpr::Call { callee, args }) => {
            if ctl_ops.contains(callee.as_str()) {
                out.insert(callee.clone());
            }
            let args = args.clone();
            for &a in &args {
                collect_ctl_calls_meta_expr(ast, a, ctl_ops, out);
            }
        }
        _ => {}
    }
}

fn collect_transitive_meta_stmt(
    ast: &MetaAst,
    stmt_id: usize,
    fn_rows: &HashMap<String, BTreeSet<String>>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_stmt(stmt_id) {
        Some(MetaStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts {
                collect_transitive_meta_stmt(ast, id, fn_rows, out);
            }
        }
        Some(MetaStmt::ExprStmt(e)) => {
            collect_transitive_meta_expr(ast, *e, fn_rows, out);
        }
        Some(MetaStmt::VarDecl { expr, .. }) => {
            collect_transitive_meta_expr(ast, *expr, fn_rows, out);
        }
        Some(MetaStmt::If { cond, body, else_branch }) => {
            collect_transitive_meta_expr(ast, *cond, fn_rows, out);
            collect_transitive_meta_stmt(ast, *body, fn_rows, out);
            if let Some(e) = else_branch {
                collect_transitive_meta_stmt(ast, *e, fn_rows, out);
            }
        }
        Some(MetaStmt::WhileLoop { cond, body }) => {
            collect_transitive_meta_expr(ast, *cond, fn_rows, out);
            collect_transitive_meta_stmt(ast, *body, fn_rows, out);
        }
        Some(MetaStmt::ForEach { body, .. }) => {
            collect_transitive_meta_stmt(ast, *body, fn_rows, out);
        }
        Some(MetaStmt::Return(Some(e))) => {
            collect_transitive_meta_expr(ast, *e, fn_rows, out);
        }
        _ => {}
    }
}

fn collect_transitive_meta_expr(
    ast: &MetaAst,
    expr_id: usize,
    fn_rows: &HashMap<String, BTreeSet<String>>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_expr(expr_id) {
        Some(MetaExpr::Call { callee, args }) => {
            if let Some(row) = fn_rows.get(callee.as_str()) {
                out.extend(row.iter().cloned());
            }
            let args = args.clone();
            for &a in &args {
                collect_transitive_meta_expr(ast, a, fn_rows, out);
            }
        }
        _ => {}
    }
}

// ── Pass A2 + B: RuntimeAst inference + call-site checking ───────────────────

/// Infer effect rows from the RuntimeAst and check that every top-level call
/// site has all required effects handled by an enclosing `with ctl` handler.
///
/// Returns `EffectInfo` on success, or `CompilerError::EffectNotHandled` on the
/// first unhandled effect found.
pub fn infer_and_check(
    ast: &RuntimeAst,
    cps_info: &CpsInfo,
) -> Result<EffectInfo, CompilerError> {
    let info = infer_runtime(ast, cps_info);
    check_top_level(ast, &info, cps_info)?;
    Ok(info)
}

fn infer_runtime(ast: &RuntimeAst, cps_info: &CpsInfo) -> EffectInfo {
    let mut info = EffectInfo::default();
    let ctl_ops = &cps_info.ctl_ops;

    // Collect function bodies.
    let mut fn_bodies: HashMap<String, usize> = HashMap::new();
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, body, .. } = stmt {
            fn_bodies.insert(name.clone(), *body);
        }
    }

    // Pass A2a: direct ctl calls — immutable baseline.
    let mut direct_rows: HashMap<String, BTreeSet<String>> = HashMap::new();
    for (name, &body_id) in &fn_bodies {
        let mut row = BTreeSet::new();
        collect_ctl_calls_runtime_stmt(ast, body_id, ctl_ops, &mut row);
        if !row.is_empty() {
            direct_rows.insert(name.clone(), row);
        }
    }

    // Collect what each function handles internally — immutable.
    for (name, &body_id) in &fn_bodies {
        let mut handled = BTreeSet::new();
        collect_handled_ops_runtime_stmt(ast, body_id, &mut handled);
        if !handled.is_empty() {
            info.fn_handles.insert(name.clone(), handled);
        }
    }

    // Convergence loop: new_row(f) = (direct(f) ∪ transitive_from_snapshot) - handled(f)
    //
    // Rebuilding from scratch each iteration ensures that subtract and propagate
    // interact correctly: a handler in __handle_N removes an op both from its own
    // direct calls AND from any transitive contributions it picks up from callees.
    // A simple A2a→A2c→A2b order fails because A2b can re-introduce ops that A2c
    // already removed (when a callee passes effects up through the handler).
    loop {
        let snapshot = info.fn_rows.clone();
        let mut new_rows: HashMap<String, BTreeSet<String>> = HashMap::new();
        for (name, &body_id) in &fn_bodies {
            let mut row = direct_rows.get(name).cloned().unwrap_or_default();
            let mut transitive = BTreeSet::new();
            collect_transitive_runtime_stmt(ast, body_id, &snapshot, &mut transitive);
            row.extend(transitive);
            if let Some(handled) = info.fn_handles.get(name) {
                for op in handled {
                    row.remove(op);
                }
            }
            if !row.is_empty() {
                new_rows.insert(name.clone(), row);
            }
        }
        if new_rows == info.fn_rows {
            break;
        }
        info.fn_rows = new_rows;
    }

    info
}

fn collect_handled_ops_runtime_stmt(ast: &RuntimeAst, stmt_id: usize, out: &mut BTreeSet<String>) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::WithCtl { op_name, .. }) | Some(RuntimeStmt::WithFn { op_name, .. }) => {
            out.insert(op_name.clone());
        }
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts {
                collect_handled_ops_runtime_stmt(ast, id, out);
            }
        }
        _ => {}
    }
}

fn collect_ctl_calls_runtime_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    ctl_ops: &HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts {
                collect_ctl_calls_runtime_stmt(ast, id, ctl_ops, out);
            }
        }
        Some(RuntimeStmt::ExprStmt(e)) => {
            collect_ctl_calls_runtime_expr(ast, *e, ctl_ops, out);
        }
        Some(RuntimeStmt::VarDecl { expr, .. }) => {
            collect_ctl_calls_runtime_expr(ast, *expr, ctl_ops, out);
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            collect_ctl_calls_runtime_expr(ast, *cond, ctl_ops, out);
            collect_ctl_calls_runtime_stmt(ast, *body, ctl_ops, out);
            if let Some(e) = else_branch {
                collect_ctl_calls_runtime_stmt(ast, *e, ctl_ops, out);
            }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            collect_ctl_calls_runtime_expr(ast, *cond, ctl_ops, out);
            collect_ctl_calls_runtime_stmt(ast, *body, ctl_ops, out);
        }
        Some(RuntimeStmt::ForEach { body, .. }) => {
            collect_ctl_calls_runtime_stmt(ast, *body, ctl_ops, out);
        }
        Some(RuntimeStmt::Return(Some(e))) => {
            collect_ctl_calls_runtime_expr(ast, *e, ctl_ops, out);
        }
        _ => {}
    }
}

fn collect_ctl_calls_runtime_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    ctl_ops: &HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            if ctl_ops.contains(callee.as_str()) {
                out.insert(callee.clone());
            }
            let args = args.clone();
            for &a in &args {
                collect_ctl_calls_runtime_expr(ast, a, ctl_ops, out);
            }
        }
        _ => {}
    }
}

fn collect_transitive_runtime_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    fn_rows: &HashMap<String, BTreeSet<String>>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for &id in &stmts {
                collect_transitive_runtime_stmt(ast, id, fn_rows, out);
            }
        }
        Some(RuntimeStmt::ExprStmt(e)) => {
            collect_transitive_runtime_expr(ast, *e, fn_rows, out);
        }
        Some(RuntimeStmt::VarDecl { expr, .. }) => {
            collect_transitive_runtime_expr(ast, *expr, fn_rows, out);
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            collect_transitive_runtime_expr(ast, *cond, fn_rows, out);
            collect_transitive_runtime_stmt(ast, *body, fn_rows, out);
            if let Some(e) = else_branch {
                collect_transitive_runtime_stmt(ast, *e, fn_rows, out);
            }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            collect_transitive_runtime_expr(ast, *cond, fn_rows, out);
            collect_transitive_runtime_stmt(ast, *body, fn_rows, out);
        }
        Some(RuntimeStmt::ForEach { body, .. }) => {
            collect_transitive_runtime_stmt(ast, *body, fn_rows, out);
        }
        Some(RuntimeStmt::Return(Some(e))) => {
            collect_transitive_runtime_expr(ast, *e, fn_rows, out);
        }
        _ => {}
    }
}

fn collect_transitive_runtime_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    fn_rows: &HashMap<String, BTreeSet<String>>,
    out: &mut BTreeSet<String>,
) {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            if let Some(row) = fn_rows.get(callee.as_str()) {
                out.extend(row.iter().cloned());
            }
            let args = args.clone();
            for &a in &args {
                collect_transitive_runtime_expr(ast, a, fn_rows, out);
            }
        }
        _ => {}
    }
}

// ── Phase B: call-site checking ───────────────────────────────────────────────

fn check_top_level(
    ast: &RuntimeAst,
    info: &EffectInfo,
    cps_info: &CpsInfo,
) -> Result<(), CompilerError> {
    let active = BTreeSet::new();
    check_stmts(ast, &ast.sem_root_stmts.clone(), &active, info, cps_info)
}

fn check_stmts(
    ast: &RuntimeAst,
    stmts: &[usize],
    handler_stack: &BTreeSet<String>,
    info: &EffectInfo,
    cps_info: &CpsInfo,
) -> Result<(), CompilerError> {
    let mut active = handler_stack.clone();
    for &stmt_id in stmts {
        check_stmt(ast, stmt_id, &mut active, info, cps_info)?;
    }
    Ok(())
}

fn check_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    active: &mut BTreeSet<String>,
    info: &EffectInfo,
    cps_info: &CpsInfo,
) -> Result<(), CompilerError> {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::WithCtl { op_name, .. }) => {
            active.insert(op_name.clone());
        }
        Some(RuntimeStmt::ExprStmt(e)) => {
            check_expr(ast, *e, active, info, cps_info)?;
        }
        Some(RuntimeStmt::VarDecl { expr, .. }) => {
            check_expr(ast, *expr, active, info, cps_info)?;
        }
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            let cond = *cond;
            let body = *body;
            let else_branch = *else_branch;
            check_expr(ast, cond, active, info, cps_info)?;
            check_stmts_block(ast, body, active, info, cps_info)?;
            if let Some(e) = else_branch {
                check_stmts_block(ast, e, active, info, cps_info)?;
            }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            let cond = *cond;
            let body = *body;
            check_expr(ast, cond, active, info, cps_info)?;
            check_stmts_block(ast, body, active, info, cps_info)?;
        }
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            check_stmts(ast, &stmts, active, info, cps_info)?;
        }
        // FnDecl: skip body — effects propagate through effect rows, checked at call sites.
        Some(RuntimeStmt::FnDecl { .. }) => {}
        // WithFn, EffectDecl, Resume, etc.: no call-site check needed.
        _ => {}
    }
    Ok(())
}

/// Check a single block (identified by its stmt_id, which should be a Block).
/// Creates a fresh copy of the active set so handler additions don't leak out.
fn check_stmts_block(
    ast: &RuntimeAst,
    block_id: usize,
    active: &BTreeSet<String>,
    info: &EffectInfo,
    cps_info: &CpsInfo,
) -> Result<(), CompilerError> {
    match ast.get_stmt(block_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            check_stmts(ast, &stmts, active, info, cps_info)
        }
        _ => check_stmts(ast, &[block_id], active, info, cps_info),
    }
}

fn check_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    active: &BTreeSet<String>,
    info: &EffectInfo,
    cps_info: &CpsInfo,
) -> Result<(), CompilerError> {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Call { callee, args }) => {
            let callee = callee.clone();
            let args = args.clone();

            // Direct ctl op call.
            if cps_info.ctl_ops.contains(callee.as_str()) && !active.contains(callee.as_str()) {
                return Err(CompilerError::EffectNotHandled { op: callee });
            }

            // Call to a function with a known effect row.
            if let Some(row) = info.fn_rows.get(callee.as_str()) {
                for op in row {
                    if !active.contains(op.as_str()) {
                        return Err(CompilerError::EffectNotHandled { op: op.clone() });
                    }
                }
            }

            // Chunk 2 — HOF argument checking.
            // If an argument is a named function with effects, those effects must be
            // handled either at this call site OR internally by the callee (the callee
            // installs its own `with ctl` handlers that cover those effects).
            let callee_handles: BTreeSet<String> = info.fn_handles
                .get(callee.as_str())
                .cloned()
                .unwrap_or_default();
            for &a in &args {
                if let Some(RuntimeExpr::Variable(name)) = ast.get_expr(a) {
                    if let Some(row) = info.fn_rows.get(name.as_str()) {
                        for op in row {
                            if !active.contains(op.as_str()) && !callee_handles.contains(op.as_str()) {
                                return Err(CompilerError::EffectNotHandled { op: op.clone() });
                            }
                        }
                    }
                }
            }

            // Recurse into arguments for nested calls.
            for &a in &args {
                check_expr(ast, a, active, info, cps_info)?;
            }
        }
        _ => {}
    }
    Ok(())
}
