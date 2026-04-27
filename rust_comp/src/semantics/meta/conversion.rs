use super::runtime_ast::*;
use super::staged_ast::*;
use crate::semantics::meta::gen_collector::GeneratedOutput;
use crate::util::node_id::{RuntimeNodeId, StagedNodeId};
use std::collections::{HashMap, HashSet};

#[inline(always)]
fn rid(id: StagedNodeId) -> RuntimeNodeId { RuntimeNodeId(id.0) }

/// Collect names referenced as variables or call callees in the given stmts,
/// minus names that are locally bound within those stmts.
/// Used for lambda-lifting `__handle_N` so that free variables from the
/// enclosing function scope are passed as explicit parameters.
fn collect_free_vars(ast: &RuntimeAst, stmts: &[RuntimeNodeId]) -> Vec<String> {
    let mut referenced: HashSet<String> = HashSet::new();
    let mut locally_bound: HashSet<String> = HashSet::new();
    for &s in stmts {
        scan_stmt(ast, s, &mut referenced, &mut locally_bound);
    }
    let mut free: Vec<String> = referenced.difference(&locally_bound).cloned().collect();
    free.sort(); // deterministic order for stable codegen
    free
}

fn scan_stmt(ast: &RuntimeAst, stmt_id: RuntimeNodeId, refs: &mut HashSet<String>, bound: &mut HashSet<String>) {
    let stmt = match ast.get_stmt(stmt_id) { Some(s) => s.clone(), None => return };
    match stmt {
        RuntimeStmt::Block(children) => {
            for &c in &children { scan_stmt(ast, c, refs, bound); }
        }
        RuntimeStmt::VarDecl { name, expr } => {
            scan_expr(ast, expr, refs, bound);
            bound.insert(name);
        }
        RuntimeStmt::Assign { name: _, expr } => scan_expr(ast, expr, refs, bound),
        RuntimeStmt::IndexAssign { expr, indices, .. } => {
            scan_expr(ast, expr, refs, bound);
            for &i in &indices { scan_expr(ast, i, refs, bound); }
        }
        RuntimeStmt::ExprStmt(e) => scan_expr(ast, e, refs, bound),
        RuntimeStmt::Return(Some(e)) => scan_expr(ast, e, refs, bound),
        RuntimeStmt::Return(None) => {}
        RuntimeStmt::Print(e) => scan_expr(ast, e, refs, bound),
        RuntimeStmt::If { cond, body, else_branch } => {
            scan_expr(ast, cond, refs, bound);
            scan_stmt(ast, body, refs, bound);
            if let Some(eb) = else_branch { scan_stmt(ast, eb, refs, bound); }
        }
        RuntimeStmt::WhileLoop { cond, body } => {
            scan_expr(ast, cond, refs, bound);
            scan_stmt(ast, body, refs, bound);
        }
        RuntimeStmt::ForEach { var, iterable, body } => {
            scan_expr(ast, iterable, refs, bound);
            bound.insert(var);
            scan_stmt(ast, body, refs, bound);
        }
        RuntimeStmt::FnDecl { name, params, body, .. } => {
            bound.insert(name);
            let mut inner_refs: HashSet<String> = HashSet::new();
            let mut inner_bound: HashSet<String> = bound.clone();
            for p in &params { inner_bound.insert(p.clone()); }
            scan_stmt(ast, body, &mut inner_refs, &mut inner_bound);
            for r in inner_refs.difference(&inner_bound) { refs.insert(r.clone()); }
        }
        RuntimeStmt::WithCtl { op_name, params, body, .. } | RuntimeStmt::WithFn { op_name, params, body, .. } => {
            bound.insert(op_name.clone());
            let mut inner_refs: HashSet<String> = HashSet::new();
            let mut inner_bound: HashSet<String> = bound.clone();
            for p in &params { inner_bound.insert(p.name.clone()); }
            scan_stmt(ast, body, &mut inner_refs, &mut inner_bound);
            for r in inner_refs.difference(&inner_bound) { refs.insert(r.clone()); }
        }
        RuntimeStmt::Resume(Some(e)) => scan_expr(ast, e, refs, bound),
        RuntimeStmt::Resume(None) => {}
        _ => {}
    }
}

fn scan_expr(ast: &RuntimeAst, expr_id: RuntimeNodeId, refs: &mut HashSet<String>, bound: &mut HashSet<String>) {
    let expr = match ast.get_expr(expr_id) { Some(e) => e.clone(), None => return };
    match expr {
        RuntimeExpr::Variable(name) => { refs.insert(name); }
        RuntimeExpr::Call { callee, args } => {
            refs.insert(callee.clone());
            for &a in &args { scan_expr(ast, a, refs, bound); }
        }
        RuntimeExpr::Lambda { params, body } => {
            let mut inner_refs: HashSet<String> = HashSet::new();
            let mut inner_bound: HashSet<String> = bound.clone();
            for p in &params { inner_bound.insert(p.clone()); }
            scan_stmt(ast, body, &mut inner_refs, &mut inner_bound);
            for r in inner_refs.difference(&inner_bound) { refs.insert(r.clone()); }
        }
        RuntimeExpr::Add(a, b) | RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b)
        | RuntimeExpr::Div(a, b) | RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b)
        | RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b)
        | RuntimeExpr::Lt(a, b) | RuntimeExpr::Lte(a, b)
        | RuntimeExpr::Gt(a, b) | RuntimeExpr::Gte(a, b) => {
            scan_expr(ast, a, refs, bound);
            scan_expr(ast, b, refs, bound);
        }
        RuntimeExpr::Not(e) => scan_expr(ast, e, refs, bound),
        RuntimeExpr::List(items) | RuntimeExpr::Tuple(items) => {
            for &i in &items { scan_expr(ast, i, refs, bound); }
        }
        RuntimeExpr::Index { object, index } => {
            scan_expr(ast, object, refs, bound);
            scan_expr(ast, index, refs, bound);
        }
        RuntimeExpr::DotAccess { object, .. } => scan_expr(ast, object, refs, bound),
        RuntimeExpr::DotCall { object, args, .. } => {
            scan_expr(ast, object, refs, bound);
            for &a in &args { scan_expr(ast, a, refs, bound); }
        }
        RuntimeExpr::StructLiteral { fields, .. } => {
            for (_, e) in &fields { scan_expr(ast, *e, refs, bound); }
        }
        RuntimeExpr::EnumConstructor { payload, .. } => {
            match payload {
                RuntimeConstructorPayload::Tuple(items) => { for &i in &items { scan_expr(ast, i, refs, bound); } }
                RuntimeConstructorPayload::Struct(fields) => { for (_, e) in &fields { scan_expr(ast, *e, refs, bound); } }
                RuntimeConstructorPayload::Unit => {}
            }
        }
        RuntimeExpr::ResumeExpr(Some(e)) => scan_expr(ast, e, refs, bound),
        RuntimeExpr::TupleIndex { object, .. } => scan_expr(ast, object, refs, bound),
        RuntimeExpr::SliceRange { object, start, end } => {
            scan_expr(ast, object, refs, bound);
            if let Some(s) = start { scan_expr(ast, s, refs, bound); }
            if let Some(e) = end { scan_expr(ast, e, refs, bound); }
        }
        _ => {}
    }
}

#[derive(Debug)]
pub enum AstConversionError {
    UnresolvedMeta(RuntimeNodeId),
}

pub fn convert_to_runtime(
    staged: &StagedAst,
    meta_generated: &HashMap<usize, GeneratedOutput>,
) -> Result<RuntimeAst, AstConversionError> {
    let mut runtime = RuntimeAst::new();

    // Build handler name → ops lookup for RunWith desugar.
    let handler_defs: std::collections::HashMap<String, Vec<RuntimeNodeId>> = staged.stmts.values()
        .filter_map(|stmt| {
            if let StagedStmt::HandlerDef { name, ops, .. } = stmt {
                Some((name.clone(), ops.iter().map(|&id| rid(id)).collect()))
            } else {
                None
            }
        })
        .collect();

    let max_staged = staged.stmts.keys().chain(staged.exprs.keys()).map(|id| id.0).max().unwrap_or(0);
    let max_meta = meta_generated.values()
        .flat_map(|o| o.supporting_stmts.keys().map(|id| id.0).chain(o.exprs.keys().map(|id| id.0)))
        .max().unwrap_or(0);
    let mut next_id = max_staged.max(max_meta) + 1;

    let mut expansion_map: HashMap<StagedNodeId, Vec<usize>> = HashMap::new();

    for (id, stmt) in &staged.stmts {
        if let StagedStmt::MetaStmt(meta_ref) = stmt {
            let tree_id = meta_ref.ast_ref;
            let output = meta_generated
                .get(&tree_id)
                .ok_or(AstConversionError::UnresolvedMeta(rid(*id)))?;

            for (stmt_id, stmt) in &output.supporting_stmts {
                runtime.insert_stmt(*stmt_id, stmt.clone());
            }
            for (expr_id, expr) in &output.exprs {
                runtime.insert_expr(*expr_id, expr.clone());
            }

            let mut new_ids = Vec::with_capacity(output.stmts.len());
            for gen_stmt in &output.stmts {
                let new_id = next_id;
                next_id += 1;
                runtime.insert_stmt(RuntimeNodeId(new_id), gen_stmt.clone());
                new_ids.push(new_id);
            }
            expansion_map.insert(*id, new_ids);
        }
    }

    // Two-pass expr conversion: RunHandle/RunWith exprs need collect_free_vars which requires
    // all stmts to be in runtime first. First pass: non-handle exprs. Second pass
    // (after stmt conversion): RunHandle/RunWith exprs with correct free-var analysis.
    let mut deferred_handles: Vec<(RuntimeNodeId, RuntimeNodeId, Vec<RuntimeNodeId>)> = Vec::new();

    for (id, expr) in &staged.exprs {
        match expr {
            StagedExpr::RunHandle { body, effects } => {
                let all_ops: Vec<RuntimeNodeId> = effects.iter()
                    .flat_map(|(_, stmts)| stmts.iter().map(|&s| rid(s)))
                    .collect();
                deferred_handles.push((rid(*id), rid(*body), all_ops));
                continue;
            }
            StagedExpr::RunWith { body, handler_name } => {
                let ops = handler_defs.get(handler_name).cloned().unwrap_or_default();
                deferred_handles.push((rid(*id), rid(*body), ops));
                continue;
            }
            _ => {}
        }
        let runtime_expr = convert_expr(expr, *id)?;
        runtime.insert_expr(rid(*id), runtime_expr);
    }

    // Convert stmts before second pass so collect_free_vars can walk handler/body stmts.
    for (id, stmt) in &staged.stmts {
        let runtime_stmt = match stmt.clone() {
            StagedStmt::MetaStmt(_) => continue,
            StagedStmt::HandlerDef { .. } => continue,
            StagedStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(rid(e)),
            StagedStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl { name, expr: rid(expr) },
            StagedStmt::Assign { name, expr } => RuntimeStmt::Assign { name, expr: rid(expr) },
            StagedStmt::IndexAssign { name, indices, expr } => RuntimeStmt::IndexAssign {
                name,
                indices: indices.into_iter().map(rid).collect(),
                expr: rid(expr),
            },
            StagedStmt::FnDecl { name, params, type_params, body } => {
                RuntimeStmt::FnDecl { name, params, type_params, body: rid(body) }
            }
            StagedStmt::Print(e) => RuntimeStmt::Print(rid(e)),
            StagedStmt::Return(e) => RuntimeStmt::Return(e.map(rid)),
            StagedStmt::Import(s) => RuntimeStmt::Import(s),
            StagedStmt::Gen(g) => RuntimeStmt::Gen(expand_ids_runtime(&g, &expansion_map)),
            StagedStmt::Block(children) => {
                RuntimeStmt::Block(expand_ids_runtime(&children, &expansion_map))
            }
            StagedStmt::If { cond, body, else_branch } => RuntimeStmt::If {
                cond: rid(cond),
                body: rid(body),
                else_branch: else_branch.map(rid),
            },
            StagedStmt::WhileLoop { cond, body } => RuntimeStmt::WhileLoop {
                cond: rid(cond),
                body: rid(body),
            },
            StagedStmt::ForEach { var, iterable, body } => RuntimeStmt::ForEach {
                var,
                iterable: rid(iterable),
                body: rid(body),
            },
            StagedStmt::StructDecl { name, fields } => {
                let runtime_fields = fields
                    .into_iter()
                    .map(|f| RuntimeFieldDecl { field_name: f.field_name, type_name: f.type_name })
                    .collect();
                RuntimeStmt::StructDecl { name, fields: runtime_fields }
            }
            StagedStmt::EnumDecl { name, type_params, variants } => {
                RuntimeStmt::EnumDecl { name, type_params, variants }
            }
            StagedStmt::Match { scrutinee, arms } => RuntimeStmt::Match {
                scrutinee: rid(scrutinee),
                arms: arms.into_iter().map(|a: StagedMatchArm| RuntimeMatchArm {
                    pattern: a.pattern,
                    body: rid(a.body),
                }).collect(),
            },
            StagedStmt::EffectDecl { name, ops } => RuntimeStmt::EffectDecl { name, ops },
            StagedStmt::WithFn { op_name, params, ret_ty, body } => {
                RuntimeStmt::WithFn { op_name, params, ret_ty, body: rid(body) }
            }
            StagedStmt::WithCtl { op_name, params, ret_ty, body } => {
                RuntimeStmt::WithCtl { op_name, params, ret_ty, body: rid(body) }
            }
            StagedStmt::Resume(opt_expr) => RuntimeStmt::Resume(opt_expr.map(rid)),
        };
        runtime.insert_stmt(rid(*id), runtime_stmt);
    }

    // Build a set of globally-visible names that should NOT be lambda-lifted.
    let mut globals: HashSet<String> = HashSet::new();
    for stmt in runtime.stmts.values() {
        match stmt {
            RuntimeStmt::FnDecl { name, .. } => { globals.insert(name.clone()); }
            RuntimeStmt::EffectDecl { ops, .. } => {
                for op in ops { globals.insert(op.name.clone()); }
            }
            _ => {}
        }
    }
    for builtin in &["readfile", "to_string", "to_int", "free", "print"] {
        globals.insert(builtin.to_string());
    }

    // Second pass: process deferred RunHandle/RunWith exprs.
    for (id, body, handler_stmts) in deferred_handles {
        let fn_name = format!("__handle_{}", next_id);
        next_id += 1;

        let body_inner: Vec<RuntimeNodeId> = match runtime.get_stmt(body) {
            Some(RuntimeStmt::Block(stmts)) => stmts.clone(),
            _ => vec![body],
        };
        let full_stmts: Vec<RuntimeNodeId> = handler_stmts.iter().chain(body_inner.iter()).copied().collect();

        let free_vars: Vec<String> = collect_free_vars(&runtime, &full_stmts)
            .into_iter()
            .filter(|n| !globals.contains(n.as_str()))
            .collect();

        let body_block_id = RuntimeNodeId(next_id);
        next_id += 1;
        runtime.insert_stmt(body_block_id, RuntimeStmt::Block(full_stmts));

        let fndecl_id = RuntimeNodeId(next_id);
        next_id += 1;
        runtime.insert_stmt(fndecl_id, RuntimeStmt::FnDecl {
            name: fn_name.clone(),
            params: free_vars.clone(),
            type_params: vec![],
            body: body_block_id,
        });
        runtime.sem_root_stmts.push(fndecl_id);

        let arg_exprs: Vec<RuntimeNodeId> = free_vars.iter().map(|name| {
            let expr_id = RuntimeNodeId(next_id);
            next_id += 1;
            runtime.insert_expr(expr_id, RuntimeExpr::Variable(name.clone()));
            expr_id
        }).collect();

        runtime.insert_expr(id, RuntimeExpr::Call { callee: fn_name, args: arg_exprs });
    }

    let mut new_root = std::mem::take(&mut runtime.sem_root_stmts);
    let expanded = expand_ids_runtime(&staged.sem_root_stmts, &expansion_map);
    new_root.extend(expanded.into_iter().filter(|id| runtime.get_stmt(*id).is_some()));
    runtime.sem_root_stmts = new_root;

    Ok(runtime)
}

fn convert_expr(expr: &StagedExpr, id: StagedNodeId) -> Result<RuntimeExpr, AstConversionError> {
    let r = match expr.clone() {
        StagedExpr::Int(v) => RuntimeExpr::Int(v),
        StagedExpr::String(s) => RuntimeExpr::String(s),
        StagedExpr::Bool(b) => RuntimeExpr::Bool(b),
        StagedExpr::Variable(v) => RuntimeExpr::Variable(v),
        StagedExpr::List(l) => RuntimeExpr::List(l.into_iter().map(rid).collect()),
        StagedExpr::Add(a, b) => RuntimeExpr::Add(rid(a), rid(b)),
        StagedExpr::Sub(a, b) => RuntimeExpr::Sub(rid(a), rid(b)),
        StagedExpr::Mult(a, b) => RuntimeExpr::Mult(rid(a), rid(b)),
        StagedExpr::Div(a, b) => RuntimeExpr::Div(rid(a), rid(b)),
        StagedExpr::Equals(a, b) => RuntimeExpr::Equals(rid(a), rid(b)),
        StagedExpr::NotEquals(a, b) => RuntimeExpr::NotEquals(rid(a), rid(b)),
        StagedExpr::Lt(a, b) => RuntimeExpr::Lt(rid(a), rid(b)),
        StagedExpr::Gt(a, b) => RuntimeExpr::Gt(rid(a), rid(b)),
        StagedExpr::Lte(a, b) => RuntimeExpr::Lte(rid(a), rid(b)),
        StagedExpr::Gte(a, b) => RuntimeExpr::Gte(rid(a), rid(b)),
        StagedExpr::And(a, b) => RuntimeExpr::And(rid(a), rid(b)),
        StagedExpr::Or(a, b) => RuntimeExpr::Or(rid(a), rid(b)),
        StagedExpr::Not(a) => RuntimeExpr::Not(rid(a)),
        StagedExpr::StructLiteral { type_name, fields } => RuntimeExpr::StructLiteral {
            type_name,
            fields: fields.into_iter().map(|(k, v)| (k, rid(v))).collect(),
        },
        StagedExpr::Call { callee, args } => RuntimeExpr::Call {
            callee,
            args: args.into_iter().map(rid).collect(),
        },
        StagedExpr::DotAccess { object, field } => RuntimeExpr::DotAccess { object: rid(object), field },
        StagedExpr::DotCall { object, method, args } => RuntimeExpr::DotCall {
            object: rid(object),
            method,
            args: args.into_iter().map(rid).collect(),
        },
        StagedExpr::Index { object, index } => RuntimeExpr::Index { object: rid(object), index: rid(index) },
        StagedExpr::EnumConstructor { enum_name, variant, payload } => {
            let rt_payload = match payload {
                StagedConstructorPayload::Unit => RuntimeConstructorPayload::Unit,
                StagedConstructorPayload::Tuple(items) => RuntimeConstructorPayload::Tuple(items.into_iter().map(rid).collect()),
                StagedConstructorPayload::Struct(fields) => RuntimeConstructorPayload::Struct(fields.into_iter().map(|(k, v)| (k, rid(v))).collect()),
            };
            RuntimeExpr::EnumConstructor { enum_name, variant, payload: rt_payload }
        }
        StagedExpr::Tuple(items) => RuntimeExpr::Tuple(items.into_iter().map(rid).collect()),
        StagedExpr::TupleIndex { object, index } => RuntimeExpr::TupleIndex { object: rid(object), index },
        StagedExpr::SliceRange { object, start, end } => RuntimeExpr::SliceRange {
            object: rid(object),
            start: start.map(rid),
            end: end.map(rid),
        },
        StagedExpr::Lambda { params, body } => RuntimeExpr::Lambda { params, body: rid(body) },
        StagedExpr::ResumeExpr(opt_id) => RuntimeExpr::ResumeExpr(opt_id.map(rid)),
        StagedExpr::RunHandle { .. } => unreachable!("RunHandle exprs deferred to second pass"),
        StagedExpr::RunWith { .. } => unreachable!("RunWith exprs deferred to second pass"),
        StagedExpr::MetaExpr(_) => return Err(AstConversionError::UnresolvedMeta(rid(id))),
    };
    Ok(r)
}

fn expand_ids_runtime(ids: &[StagedNodeId], expansion_map: &HashMap<StagedNodeId, Vec<usize>>) -> Vec<RuntimeNodeId> {
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        match expansion_map.get(id) {
            Some(new_ids) => out.extend(new_ids.iter().map(|&i| RuntimeNodeId(i))),
            None => out.push(rid(*id)),
        }
    }
    out
}
