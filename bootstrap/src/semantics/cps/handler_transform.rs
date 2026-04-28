/// Handler-struct transform for `fn` (non-resumable) effects.
///
/// Replaces dynamic `with_fn_active` dispatch with explicit closure parameters:
///
/// Before:
///   fn greet(name) { log("Hello, " + name); }
///   fn __handle_33() { with fn log(msg) { print(msg); } greet("Brendan"); }
///
/// After:
///   fn greet(name, __h_log) { var log = __h_log; log("Hello, " + name); }
///   fn __handle_33() { var __h_log = fn(msg) { print(msg); }; greet("Brendan", __h_log); }
///
/// This makes fn-effect dispatch explicit and identical in interpreter and codegen.
use std::collections::{HashMap, HashSet};


use crate::semantics::cps::effect_marker::{CpsInfo, FnEffectInfo};
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::util::node_id::RuntimeNodeId;

pub fn transform(ast: &mut RuntimeAst, info: &FnEffectInfo) {
    if info.fn_effect_fns.is_empty() {
        return;
    }

    // Pass 1: rewrite FnDecl for functions that use fn-effect ops.
    //   - append __h_{op} params
    //   - inject `var {op} = __h_{op};` bindings at top of body
    let fn_ids: Vec<RuntimeNodeId> = ast.stmts.keys().copied().collect();
    for id in fn_ids {
        let (name, mut params, type_params, body_id) = match ast.get_stmt(id) {
            Some(RuntimeStmt::FnDecl { name, params, type_params, body }) => {
                (name.clone(), params.clone(), type_params.clone(), *body)
            }
            _ => continue,
        };

        let ops = match info.fn_effect_fns.get(&name) {
            Some(v) => v.clone(),
            None => continue,
        };

        // Add one handler param per fn-op, in sorted order.
        for op in &ops {
            params.push(handler_param_name(op));
        }

        // Inject binding stmts at top of body: `var {op} = __h_{op};`
        let body_stmts = match ast.get_stmt(body_id) {
            Some(RuntimeStmt::Block(s)) => s.clone(),
            _ => vec![body_id],
        };

        let mut injected: Vec<RuntimeNodeId> = Vec::new();
        for op in &ops {
            let param_name = handler_param_name(op);
            let var_expr_id = fresh_expr(ast, RuntimeExpr::Variable(param_name));
            let bind_id = fresh_stmt(ast, RuntimeStmt::VarDecl {
                name: op.clone(),
                expr: var_expr_id,
            });
            injected.push(bind_id);
        }
        injected.extend(body_stmts);

        let new_body = fresh_stmt(ast, RuntimeStmt::Block(injected));
        ast.insert_stmt(id, RuntimeStmt::FnDecl { name, params, type_params, body: new_body });
    }

    // Pass 2: for every function body in the AST, rewrite:
    //   - WithFn { op_name, params, body } → VarDecl { __h_{op} = Lambda { params, body } }
    //   - Call { callee, args } where callee ∈ fn_effect_fns → append handler args
    let all_fn_stmts: Vec<RuntimeNodeId> = ast.stmts.keys().copied().collect();
    for id in all_fn_stmts {
        let body_id = match ast.get_stmt(id) {
            Some(RuntimeStmt::FnDecl { body, .. }) => *body,
            _ => continue,
        };
        let body_stmts = match ast.get_stmt(body_id) {
            Some(RuntimeStmt::Block(s)) => s.clone(),
            _ => continue,
        };

        // Walk the block, rewriting WithFn and call sites.
        let mut scope: HashMap<String, String> = HashMap::new();
        let new_stmts = rewrite_stmts(ast, &body_stmts, info, &mut scope);
        let new_body = fresh_stmt(ast, RuntimeStmt::Block(new_stmts));
        // Update the FnDecl's body pointer.
        if let Some(RuntimeStmt::FnDecl { name, params, type_params, .. }) = ast.get_stmt(id).cloned() {
            ast.insert_stmt(id, RuntimeStmt::FnDecl { name, params, type_params, body: new_body });
        }
    }

    // Pass 3: rewrite the top-level statement list (sem_root_stmts).
    let root = ast.sem_root_stmts.clone();
    let mut scope: HashMap<String, String> = HashMap::new();
    let new_root = rewrite_stmts(ast, &root, info, &mut scope);
    ast.sem_root_stmts = new_root;
}

// ── Core rewriting ────────────────────────────────────────────────────────────

fn rewrite_stmts(
    ast: &mut RuntimeAst,
    stmts: &[RuntimeNodeId],
    info: &FnEffectInfo,
    scope: &mut HashMap<String, String>,
) -> Vec<RuntimeNodeId> {
    let mut out = Vec::new();
    for &id in stmts {
        match ast.get_stmt(id).cloned() {
            // WithFn → local closure binding
            Some(RuntimeStmt::WithFn { op_name, params, body, .. }) => {
                let h_name = handler_param_name(&op_name);
                let lambda_id = fresh_expr(ast, RuntimeExpr::Lambda {
                    params: params.iter().map(|p| p.name.clone()).collect(),
                    body,
                });
                // Record param type hints so the type checker can resolve handler params.
                let hints: Vec<Option<String>> = params.iter().map(|p| {
                    p.ty.as_ref().and_then(|te| match te {
                        crate::frontend::meta_ast::MetaTypeExpr::Named(n) => Some(n.clone()),
                        _ => None,
                    })
                }).collect();
                if hints.iter().any(|h| h.is_some()) {
                    ast.lambda_param_hints.insert(lambda_id, hints);
                }
                let bind = fresh_stmt(ast, RuntimeStmt::VarDecl {
                    name: h_name.clone(),
                    expr: lambda_id,
                });
                scope.insert(op_name, h_name);
                out.push(bind);
            }
            // ExprStmt — may contain a call that needs handler args
            Some(RuntimeStmt::ExprStmt(expr_id)) => {
                let new_expr = rewrite_expr(ast, expr_id, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::ExprStmt(new_expr));
                out.push(new_stmt);
            }
            // VarDecl — rewrite RHS expression
            Some(RuntimeStmt::VarDecl { name, expr }) => {
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::VarDecl { name, expr: new_expr });
                out.push(new_stmt);
            }
            // Return — rewrite expression
            Some(RuntimeStmt::Return(Some(expr))) => {
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Return(Some(new_expr)));
                out.push(new_stmt);
            }
            // If — rewrite cond and branches
            Some(RuntimeStmt::If { cond, body, else_branch }) => {
                let new_cond = rewrite_expr(ast, cond, info, scope);
                let new_body = rewrite_block(ast, body, info, scope);
                let new_else = else_branch.map(|e| rewrite_block(ast, e, info, scope));
                let new_stmt = fresh_stmt(ast, RuntimeStmt::If {
                    cond: new_cond, body: new_body, else_branch: new_else,
                });
                out.push(new_stmt);
            }
            // WhileLoop
            Some(RuntimeStmt::WhileLoop { cond, body }) => {
                let new_cond = rewrite_expr(ast, cond, info, scope);
                let new_body = rewrite_block(ast, body, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::WhileLoop { cond: new_cond, body: new_body });
                out.push(new_stmt);
            }
            // ForEach
            Some(RuntimeStmt::ForEach { var, iterable, body }) => {
                let new_iter = rewrite_expr(ast, iterable, info, scope);
                let new_body = rewrite_block(ast, body, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::ForEach { var, iterable: new_iter, body: new_body });
                out.push(new_stmt);
            }
            // Block — recurse
            Some(RuntimeStmt::Block(inner)) => {
                let new_inner = rewrite_stmts(ast, &inner, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Block(new_inner));
                out.push(new_stmt);
            }
            // Print — rewrite inner expression
            Some(RuntimeStmt::Print(expr_id)) => {
                let new_expr = rewrite_expr(ast, expr_id, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Print(new_expr));
                out.push(new_stmt);
            }
            // Assign — rewrite RHS
            Some(RuntimeStmt::Assign { name, expr }) => {
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Assign { name, expr: new_expr });
                out.push(new_stmt);
            }
            // IndexAssign — rewrite indices and RHS
            Some(RuntimeStmt::IndexAssign { name, indices, expr }) => {
                let new_indices = indices.iter().map(|&i| rewrite_expr(ast, i, info, scope)).collect();
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::IndexAssign { name, indices: new_indices, expr: new_expr });
                out.push(new_stmt);
            }
            // DotAssign — rewrite RHS
            Some(RuntimeStmt::DotAssign { object, field, expr }) => {
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::DotAssign { object, field, expr: new_expr });
                out.push(new_stmt);
            }
            // Match — rewrite scrutinee and arm bodies
            Some(RuntimeStmt::Match { scrutinee, arms }) => {
                let new_scrut = rewrite_expr(ast, scrutinee, info, scope);
                let new_arms = arms.iter().map(|arm| {
                    let new_body = rewrite_block(ast, arm.body, info, scope);
                    crate::semantics::meta::runtime_ast::RuntimeMatchArm {
                        pattern: arm.pattern.clone(),
                        body: new_body,
                    }
                }).collect();
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Match { scrutinee: new_scrut, arms: new_arms });
                out.push(new_stmt);
            }
            // Resume — rewrite optional expression
            Some(RuntimeStmt::Resume(Some(expr))) => {
                let new_expr = rewrite_expr(ast, expr, info, scope);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Resume(Some(new_expr)));
                out.push(new_stmt);
            }
            _ => out.push(id),
        }
    }
    out
}

fn rewrite_block(
    ast: &mut RuntimeAst,
    block_id: RuntimeNodeId,
    info: &FnEffectInfo,
    scope: &mut HashMap<String, String>,
) -> RuntimeNodeId {
    match ast.get_stmt(block_id).cloned() {
        Some(RuntimeStmt::Block(stmts)) => {
            let new_stmts = rewrite_stmts(ast, &stmts, info, scope);
            fresh_stmt(ast, RuntimeStmt::Block(new_stmts))
        }
        _ => {
            let rewrote = rewrite_stmts(ast, &[block_id], info, scope);
            if rewrote.len() == 1 { rewrote[0] } else {
                fresh_stmt(ast, RuntimeStmt::Block(rewrote))
            }
        }
    }
}

fn rewrite_expr(
    ast: &mut RuntimeAst,
    expr_id: RuntimeNodeId,
    info: &FnEffectInfo,
    scope: &mut HashMap<String, String>,
) -> RuntimeNodeId {
    match ast.get_expr(expr_id).cloned() {
        Some(RuntimeExpr::Call { callee, mut args }) => {
            // Rewrite args first.
            args = args.iter().map(|&a| rewrite_expr(ast, a, info, scope)).collect();

            // Append handler args for functions that need them.
            if let Some(ops) = info.fn_effect_fns.get(&callee) {
                for op in ops {
                    let h_var = scope.get(op)
                        .cloned()
                        .unwrap_or_else(|| handler_param_name(op));
                    let h_expr = fresh_expr(ast, RuntimeExpr::Variable(h_var));
                    args.push(h_expr);
                }
            }

            // Update the original expr in-place so stale zero-arg versions
            // don't remain in ast.exprs and corrupt the polymorphic-call check.
            ast.insert_expr(expr_id, RuntimeExpr::Call { callee, args });
            expr_id
        }
        Some(RuntimeExpr::Lambda { params, body }) => {
            let new_body = rewrite_block(ast, body, info, scope);
            fresh_expr(ast, RuntimeExpr::Lambda { params, body: new_body })
        }
        Some(RuntimeExpr::Add(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Add(a,b)) }
        Some(RuntimeExpr::Sub(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Sub(a,b)) }
        Some(RuntimeExpr::Mult(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Mult(a,b)) }
        Some(RuntimeExpr::Div(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Div(a,b)) }
        Some(RuntimeExpr::Equals(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Equals(a,b)) }
        Some(RuntimeExpr::NotEquals(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::NotEquals(a,b)) }
        Some(RuntimeExpr::Lt(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Lt(a,b)) }
        Some(RuntimeExpr::Gt(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Gt(a,b)) }
        Some(RuntimeExpr::Lte(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Lte(a,b)) }
        Some(RuntimeExpr::Gte(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Gte(a,b)) }
        Some(RuntimeExpr::And(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::And(a,b)) }
        Some(RuntimeExpr::Or(a, b)) => { let (a,b) = (rewrite_expr(ast,a,info,scope), rewrite_expr(ast,b,info,scope)); fresh_expr(ast, RuntimeExpr::Or(a,b)) }
        Some(RuntimeExpr::Not(a)) => { let a = rewrite_expr(ast,a,info,scope); fresh_expr(ast, RuntimeExpr::Not(a)) }
        Some(RuntimeExpr::List(elems)) => {
            let new_elems = elems.iter().map(|&e| rewrite_expr(ast, e, info, scope)).collect();
            fresh_expr(ast, RuntimeExpr::List(new_elems))
        }
        Some(RuntimeExpr::Tuple(elems)) => {
            let new_elems = elems.iter().map(|&e| rewrite_expr(ast, e, info, scope)).collect();
            fresh_expr(ast, RuntimeExpr::Tuple(new_elems))
        }
        Some(RuntimeExpr::StructLiteral { type_name, fields }) => {
            let new_fields = fields.iter()
                .map(|(k, v)| (k.clone(), rewrite_expr(ast, *v, info, scope)))
                .collect();
            fresh_expr(ast, RuntimeExpr::StructLiteral { type_name, fields: new_fields })
        }
        Some(RuntimeExpr::DotCall { object, method, args }) => {
            let new_obj = rewrite_expr(ast, object, info, scope);
            let new_args = args.iter().map(|&a| rewrite_expr(ast, a, info, scope)).collect();
            fresh_expr(ast, RuntimeExpr::DotCall { object: new_obj, method, args: new_args })
        }
        _ => expr_id, // leaf or unsupported — return unchanged
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn handler_param_name(op: &str) -> String {
    format!("__h_{op}")
}

fn fresh_expr(ast: &mut RuntimeAst, expr: RuntimeExpr) -> RuntimeNodeId {
    let id = RuntimeNodeId(ast.next_id);
    ast.next_id += 1;
    ast.exprs.insert(id, expr);
    id
}

fn fresh_stmt(ast: &mut RuntimeAst, stmt: RuntimeStmt) -> RuntimeNodeId {
    let id = RuntimeNodeId(ast.next_id);
    ast.next_id += 1;
    ast.stmts.insert(id, stmt);
    id
}

// ── Ctl handler transform ─────────────────────────────────────────────────────
//
// Converts `WithCtl { op_name, params, body }` to an explicit closure binding:
//
//   Before: with ctl throw(msg) { print(msg); }
//   After:  var throw = fn(msg, __k_ctl) { print(msg); __outer_k(unit); };
//
// Where `__outer_k` is the `__k_*` continuation param of the enclosing function.
// For resuming handlers, `resume(v)` is rewritten to a call to `__k_ctl(v)`.
// For non-resuming handlers, a call to `__outer_k(unit)` is appended.

/// Convert `WithCtl` nodes to explicit lambda bindings throughout the AST.
/// Must run after `cps_transform` (which adds `__k_*` params and rewrites ctl calls).
pub fn transform_ctl(ast: &mut RuntimeAst, cps_info: &CpsInfo) {
    if cps_info.ctl_ops.is_empty() {
        return;
    }

    let fn_ids: Vec<RuntimeNodeId> = ast.stmts.keys().copied().collect();
    for id in fn_ids {
        let (name, params, type_params, body_id) = match ast.get_stmt(id) {
            Some(RuntimeStmt::FnDecl { name, params, type_params, body }) => {
                (name.clone(), params.clone(), type_params.clone(), *body)
            }
            _ => continue,
        };

        // Find the outer continuation param (`__k_*`) of this function.
        let outer_k = params.iter().find(|p| p.starts_with("__k")).cloned();

        let body_stmts = match ast.get_stmt(body_id) {
            Some(RuntimeStmt::Block(s)) => s.clone(),
            _ => continue,
        };

        let new_stmts = rewrite_ctl_stmts(ast, &body_stmts, &cps_info.ctl_ops, outer_k.as_deref());
        let new_body = fresh_stmt(ast, RuntimeStmt::Block(new_stmts));
        ast.insert_stmt(id, RuntimeStmt::FnDecl { name, params, type_params, body: new_body });
    }

    // Also rewrite the root statement list.
    let root = ast.sem_root_stmts.clone();
    let new_root = rewrite_ctl_stmts(ast, &root, &cps_info.ctl_ops, None);
    ast.sem_root_stmts = new_root;
}

fn rewrite_ctl_stmts(
    ast: &mut RuntimeAst,
    stmts: &[RuntimeNodeId],
    ctl_ops: &HashSet<String>,
    outer_k: Option<&str>,
) -> Vec<RuntimeNodeId> {
    let mut out = Vec::new();
    for &id in stmts {
        match ast.get_stmt(id).cloned() {
            Some(RuntimeStmt::WithCtl { op_name, params, ret_ty, body, .. }) => {
                // Keep WithCtl in place for dynamic dispatch (interpreter ctl_handlers stack /
                // codegen with_ctl_active map), but annotate outer_k so codegen can store
                // the handle continuation at install time and call it after non-resuming bodies.
                let annotated = RuntimeStmt::WithCtl {
                    op_name, params, ret_ty, body,
                    outer_k: outer_k.map(String::from),
                };
                let new_id = fresh_stmt(ast, annotated);
                out.push(new_id);
            }
            // Recurse into blocks so nested WithCtl is handled.
            Some(RuntimeStmt::Block(inner)) => {
                let new_inner = rewrite_ctl_stmts(ast, &inner, ctl_ops, outer_k);
                let new_stmt = fresh_stmt(ast, RuntimeStmt::Block(new_inner));
                out.push(new_stmt);
            }
            _ => out.push(id),
        }
    }
    out
}

