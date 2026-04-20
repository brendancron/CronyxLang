use crate::semantics::cps::effect_marker::CpsInfo;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::util::id_provider::IdProvider;

// ── Public entry point ────────────────────────────────────────────────────────

/// Apply the selective CPS transform to `ast` in-place.
///
/// For every function in `info.cps_fns`:
///   - Adds a `__k` continuation parameter.
///   - Wraps each sequential ctl op / cps-fn call with a lambda continuation.
///   - Replaces `return x` with `__k(x)`.
///   - Appends `__k(unit)` if the body falls off the end.
///
/// Also transforms the top-level statement sequence so that calls to CPS functions
/// at the root level are wrapped with a lambda capturing the remaining statements.
///
/// Ctl calls inside loops and at the top level of non-function scopes remain on
/// the existing replay-stack path.
pub fn transform(ast: &mut RuntimeAst, info: &CpsInfo) {
    if info.cps_fns.is_empty() {
        return;
    }

    let max_id = ast.stmts.keys().chain(ast.exprs.keys()).copied().max().unwrap_or(0);
    let mut t = CpsTransform { info, ids: IdProvider::starting_from(max_id + 1) };

    // Transform all CPS FnDecl bodies.
    let fn_stmt_ids: Vec<usize> = ast.stmts.keys().copied().collect();
    for stmt_id in fn_stmt_ids {
        if let Some(RuntimeStmt::FnDecl { name, .. }) = ast.get_stmt(stmt_id) {
            if info.cps_fns.contains(name.as_str()) {
                t.transform_fn_decl(ast, stmt_id);
            }
        }
    }

    // Transform the top-level sequence for any CPS calls there.
    let root = std::mem::take(&mut ast.sem_root_stmts);
    ast.sem_root_stmts = t.transform_stmts(ast, root, false);
}

// ── Internal state ────────────────────────────────────────────────────────────

struct CpsTransform<'a> {
    info: &'a CpsInfo,
    ids: IdProvider,
}

struct CpsCall {
    callee: String,
    args: Vec<usize>,
    /// The name to bind the resumed value to; `None` for bare expression statements.
    binding: Option<String>,
}

impl<'a> CpsTransform<'a> {
    // ── FnDecl ────────────────────────────────────────────────────────────────

    fn transform_fn_decl(&mut self, ast: &mut RuntimeAst, stmt_id: usize) {
        let (name, mut params, type_params, body_id) =
            match ast.get_stmt(stmt_id).unwrap().clone() {
                RuntimeStmt::FnDecl { name, params, type_params, body } => {
                    (name, params, type_params, body)
                }
                _ => return,
            };

        params.push("__k".to_string());

        let stmts = match ast.get_stmt(body_id).unwrap().clone() {
            RuntimeStmt::Block(s) => s,
            _ => vec![body_id],
        };

        let transformed = self.transform_stmts(ast, stmts, true);
        let new_body = self.fresh_stmt(ast, RuntimeStmt::Block(transformed));

        ast.insert_stmt(
            stmt_id,
            RuntimeStmt::FnDecl { name, params, type_params, body: new_body },
        );
    }

    // ── Statement sequence ────────────────────────────────────────────────────

    /// Transform a flat statement list.
    ///
    /// `is_cps_body`: true when we are inside a CPS function — `return` gets
    /// rewritten to `__k(x)` and a trailing `__k(unit)` is appended if needed.
    fn transform_stmts(
        &mut self,
        ast: &mut RuntimeAst,
        stmts: Vec<usize>,
        is_cps_body: bool,
    ) -> Vec<usize> {
        let mut result: Vec<usize> = Vec::new();

        let mut i = 0;
        while i < stmts.len() {
            let stmt_id = stmts[i];

            // Return inside a CPS body → __k(value); terminate sequence.
            if is_cps_body {
                if let Some(k_call) = self.try_transform_return(ast, stmt_id) {
                    result.push(k_call);
                    return result;
                }
            }

            // Sequential CPS call → wrap rest as continuation lambda.
            if let Some(call) = self.extract_cps_call(ast, stmt_id) {
                let suffix = stmts[i + 1..].to_vec();
                let suffix_transformed = self.transform_stmts(ast, suffix, is_cps_body);

                let body_stmts = if suffix_transformed.is_empty() && is_cps_body {
                    // End of CPS function with no remaining statements: call __k(unit).
                    vec![self.make_k_unit_call(ast)]
                } else {
                    suffix_transformed
                };

                let cont_param = call.binding.unwrap_or_else(|| "__".to_string());
                let lambda_body = self.fresh_stmt(ast, RuntimeStmt::Block(body_stmts));
                let lambda = self.fresh_expr(
                    ast,
                    RuntimeExpr::Lambda { params: vec![cont_param], body: lambda_body },
                );

                let mut new_args = call.args;
                new_args.push(lambda);
                let call_expr =
                    self.fresh_expr(ast, RuntimeExpr::Call { callee: call.callee, args: new_args });
                let call_stmt = self.fresh_stmt(ast, RuntimeStmt::ExprStmt(call_expr));

                result.push(call_stmt);
                return result; // Everything after is inside the lambda.
            }

            result.push(stmt_id);
            i += 1;
        }

        // End of a CPS function body with no explicit return or ctl call — append __k(unit).
        if is_cps_body {
            result.push(self.make_k_unit_call(ast));
        }

        result
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// If `stmt_id` is a `Return`, rewrite it to `__k(value)` and return the new stmt ID.
    fn try_transform_return(&mut self, ast: &mut RuntimeAst, stmt_id: usize) -> Option<usize> {
        match ast.get_stmt(stmt_id)?.clone() {
            RuntimeStmt::Return(opt_expr) => {
                let val = opt_expr.unwrap_or_else(|| self.fresh_expr(ast, RuntimeExpr::Unit));
                let call = self.fresh_expr(
                    ast,
                    RuntimeExpr::Call { callee: "__k".to_string(), args: vec![val] },
                );
                Some(self.fresh_stmt(ast, RuntimeStmt::ExprStmt(call)))
            }
            _ => None,
        }
    }

    /// Emit `__k(unit)`.
    fn make_k_unit_call(&mut self, ast: &mut RuntimeAst) -> usize {
        let unit = self.fresh_expr(ast, RuntimeExpr::Unit);
        let call =
            self.fresh_expr(ast, RuntimeExpr::Call { callee: "__k".to_string(), args: vec![unit] });
        self.fresh_stmt(ast, RuntimeStmt::ExprStmt(call))
    }

    /// If `stmt_id` is a VarDecl or ExprStmt whose expression is a call to a ctl op
    /// or CPS function, return the call info. Otherwise `None`.
    fn extract_cps_call(&self, ast: &RuntimeAst, stmt_id: usize) -> Option<CpsCall> {
        match ast.get_stmt(stmt_id)? {
            RuntimeStmt::VarDecl { name, expr } => {
                if let Some(RuntimeExpr::Call { callee, args }) = ast.get_expr(*expr) {
                    if self.is_cps_callee(callee) {
                        return Some(CpsCall {
                            callee: callee.clone(),
                            args: args.clone(),
                            binding: Some(name.clone()),
                        });
                    }
                }
                None
            }
            RuntimeStmt::ExprStmt(expr) => {
                if let Some(RuntimeExpr::Call { callee, args }) = ast.get_expr(*expr) {
                    if self.is_cps_callee(callee) {
                        return Some(CpsCall {
                            callee: callee.clone(),
                            args: args.clone(),
                            binding: None,
                        });
                    }
                }
                None
            }
            _ => None,
        }
    }

    fn is_cps_callee(&self, callee: &str) -> bool {
        self.info.ctl_ops.contains(callee) || self.info.cps_fns.contains(callee)
    }

    fn fresh_expr(&mut self, ast: &mut RuntimeAst, expr: RuntimeExpr) -> usize {
        let id = self.ids.next();
        ast.insert_expr(id, expr);
        id
    }

    fn fresh_stmt(&mut self, ast: &mut RuntimeAst, stmt: RuntimeStmt) -> usize {
        let id = self.ids.next();
        ast.insert_stmt(id, stmt);
        id
    }
}
