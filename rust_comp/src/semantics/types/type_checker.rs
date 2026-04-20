use crate::frontend::meta_ast::{ConstructorPayload, EffectOpKind, Pattern, VariantBindings, *};
use super::typed_ast::TypeTable;
use super::type_env::TypeEnv;
use super::type_error::TypeError;
use super::type_subst::{unify, ApplySubst, TypeSubst};
use super::type_utils::generalize;
use super::types::*;
use std::collections::BTreeSet;

fn resolve_annotation(s: &str) -> Option<Type> {
    match s {
        "int" => Some(int_type()),
        "bool" => Some(bool_type()),
        "string" => Some(string_type()),
        "unit" => Some(unit_type()),
        _ => None,
    }
}

struct TypeCheckCtx {
    return_type: Option<Type>,
    saw_return: bool,
    /// Names of ops declared as `ctl` — used during effect inference.
    ctl_ops: BTreeSet<String>,
}

impl TypeCheckCtx {
    fn new() -> Self {
        TypeCheckCtx {
            return_type: None,
            saw_return: false,
            ctl_ops: BTreeSet::new(),
        }
    }
}

/// Walk a statement body and collect every ctl effect it performs, either
/// directly (callee ∈ ctl_ops) or transitively (callee's resolved type has
/// a non-empty effect row). Does NOT recurse into nested FnDecl bodies —
/// their effects are their own, already reflected in their bound type.
fn collect_body_effects(
    ast: &MetaAst,
    stmt_id: usize,
    ctl_ops: &BTreeSet<String>,
    env: &TypeEnv,
    out: &mut BTreeSet<String>,
) {
    let Some(stmt) = ast.get_stmt(stmt_id) else { return };
    match stmt.clone() {
        MetaStmt::ExprStmt(e) => collect_expr_effects(ast, e, ctl_ops, env, out),
        MetaStmt::VarDecl { expr, .. } => collect_expr_effects(ast, expr, ctl_ops, env, out),
        MetaStmt::Assign { expr, .. } => collect_expr_effects(ast, expr, ctl_ops, env, out),
        MetaStmt::IndexAssign { indices, expr, .. } => {
            for i in indices { collect_expr_effects(ast, i, ctl_ops, env, out); }
            collect_expr_effects(ast, expr, ctl_ops, env, out);
        }
        MetaStmt::Return(Some(e)) => collect_expr_effects(ast, e, ctl_ops, env, out),
        MetaStmt::Print(e) => collect_expr_effects(ast, e, ctl_ops, env, out),
        MetaStmt::Block(stmts) => {
            for s in stmts { collect_body_effects(ast, s, ctl_ops, env, out); }
        }
        MetaStmt::If { cond, body, else_branch } => {
            collect_expr_effects(ast, cond, ctl_ops, env, out);
            collect_body_effects(ast, body, ctl_ops, env, out);
            if let Some(e) = else_branch { collect_body_effects(ast, e, ctl_ops, env, out); }
        }
        MetaStmt::WhileLoop { cond, body } => {
            collect_expr_effects(ast, cond, ctl_ops, env, out);
            collect_body_effects(ast, body, ctl_ops, env, out);
        }
        MetaStmt::ForEach { iterable, body, .. } => {
            collect_expr_effects(ast, iterable, ctl_ops, env, out);
            collect_body_effects(ast, body, ctl_ops, env, out);
        }
        MetaStmt::Match { scrutinee, arms } => {
            collect_expr_effects(ast, scrutinee, ctl_ops, env, out);
            for arm in arms { collect_body_effects(ast, arm.body, ctl_ops, env, out); }
        }
        // Nested fn / handler declarations — do not recurse into their bodies.
        MetaStmt::FnDecl { .. }
        | MetaStmt::WithFn { .. }
        | MetaStmt::WithCtl { .. } => {}
        _ => {}
    }
}

fn collect_expr_effects(
    ast: &MetaAst,
    expr_id: usize,
    ctl_ops: &BTreeSet<String>,
    env: &TypeEnv,
    out: &mut BTreeSet<String>,
) {
    let Some(expr) = ast.get_expr(expr_id) else { return };
    match expr.clone() {
        MetaExpr::Call { callee, args } => {
            // Direct ctl op call.
            if ctl_ops.contains(&callee) {
                out.insert(callee.clone());
            }
            // Transitive: pick up effects from the callee's bound type.
            if let Some(scheme) = env.get_type(&callee) {
                let ty = match scheme {
                    TypeScheme::MonoType(t) => t,
                    TypeScheme::PolyType { ty, .. } => ty,
                };
                if let Type::Func { effects, .. } = ty {
                    out.extend(effects.effects.iter().cloned());
                }
            }
            for a in args { collect_expr_effects(ast, a, ctl_ops, env, out); }
        }
        MetaExpr::Add(a, b)
        | MetaExpr::Sub(a, b)
        | MetaExpr::Mult(a, b)
        | MetaExpr::Div(a, b)
        | MetaExpr::Equals(a, b)
        | MetaExpr::NotEquals(a, b)
        | MetaExpr::Lt(a, b)
        | MetaExpr::Gt(a, b)
        | MetaExpr::Lte(a, b)
        | MetaExpr::Gte(a, b)
        | MetaExpr::And(a, b)
        | MetaExpr::Or(a, b) => {
            collect_expr_effects(ast, a, ctl_ops, env, out);
            collect_expr_effects(ast, b, ctl_ops, env, out);
        }
        MetaExpr::Not(a) => collect_expr_effects(ast, a, ctl_ops, env, out),
        MetaExpr::List(items) | MetaExpr::Tuple(items) => {
            for i in items { collect_expr_effects(ast, i, ctl_ops, env, out); }
        }
        MetaExpr::SliceRange { object, start, end } => {
            collect_expr_effects(ast, object, ctl_ops, env, out);
            if let Some(s) = start { collect_expr_effects(ast, s, ctl_ops, env, out); }
            if let Some(e) = end { collect_expr_effects(ast, e, ctl_ops, env, out); }
        }
        MetaExpr::Index { object, index } => {
            collect_expr_effects(ast, object, ctl_ops, env, out);
            collect_expr_effects(ast, index, ctl_ops, env, out);
        }
        MetaExpr::TupleIndex { object, .. } => collect_expr_effects(ast, object, ctl_ops, env, out),
        MetaExpr::DotAccess { object, .. } => collect_expr_effects(ast, object, ctl_ops, env, out),
        MetaExpr::DotCall { object, args, .. } => {
            collect_expr_effects(ast, object, ctl_ops, env, out);
            for a in args { collect_expr_effects(ast, a, ctl_ops, env, out); }
        }
        MetaExpr::StructLiteral { fields, .. } => {
            for (_, e) in fields { collect_expr_effects(ast, e, ctl_ops, env, out); }
        }
        MetaExpr::EnumConstructor { payload, .. } => {
            match payload {
                ConstructorPayload::Tuple(ids) => {
                    for i in ids { collect_expr_effects(ast, i, ctl_ops, env, out); }
                }
                ConstructorPayload::Struct(fields) => {
                    for (_, i) in fields { collect_expr_effects(ast, i, ctl_ops, env, out); }
                }
                ConstructorPayload::Unit => {}
            }
        }
        _ => {}
    }
}

pub fn type_check(ast: &MetaAst) -> Result<(TypeTable, TypeEnv), TypeError> {
    let mut table = TypeTable::new();
    let mut env = TypeEnv::new();
    let mut subst = TypeSubst::new();
    let mut ctx = TypeCheckCtx::new();

    // Pre-bind built-in runtime functions
    let alpha = env.fresh();
    env.bind_mono("readfile",  Type::Func { params: vec![string_type()], ret: Box::new(string_type()), effects: EffectRow::empty() });
    env.bind("to_string", TypeScheme::PolyType {
        vars: vec![alpha],
        ty: Type::Func { params: vec![Type::Var(alpha)], ret: Box::new(string_type()), effects: EffectRow::empty() },
    });
    env.bind_mono("to_int",    Type::Func { params: vec![string_type()], ret: Box::new(int_type()), effects: EffectRow::empty()    });

    for stmt_id in &ast.sem_root_stmts.clone() {
        infer_stmt(ast, *stmt_id, &mut env, &mut subst, &mut ctx, &mut table)?;
    }

    Ok((table, env))
}

fn infer_expr(
    ast: &MetaAst,
    expr_id: usize,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    table: &mut TypeTable,
) -> Result<Type, TypeError> {
    let expr = ast.get_expr(expr_id).ok_or(TypeError::Unsupported)?.clone();

    let ty = match expr {
        MetaExpr::Int(_) => int_type(),
        MetaExpr::Bool(_) => bool_type(),
        MetaExpr::String(_) => string_type(),

        MetaExpr::Variable(name) => {
            env.lookup(&name).unwrap_or_else(|| Type::Var(env.fresh()))
        }

        // Add is polymorphic: String+String→String, Int+Int→Int.
        MetaExpr::Add(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            let tv = Type::Var(env.fresh());
            unify(&ta, &tv, subst)?;
            unify(&tb, &tv, subst)?;
            tv.apply(subst)
        }

        MetaExpr::Sub(a, b) | MetaExpr::Mult(a, b) | MetaExpr::Div(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            unify(&ta, &int_type(), subst)?;
            unify(&tb, &int_type(), subst)?;
            int_type()
        }

        MetaExpr::Equals(a, b) | MetaExpr::NotEquals(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            unify(&ta, &tb, subst)?;
            bool_type()
        }

        MetaExpr::Lt(a, b) | MetaExpr::Gt(a, b) | MetaExpr::Lte(a, b) | MetaExpr::Gte(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            unify(&ta, &int_type(), subst)?;
            unify(&tb, &int_type(), subst)?;
            bool_type()
        }

        MetaExpr::And(a, b) | MetaExpr::Or(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            unify(&ta, &bool_type(), subst)?;
            unify(&tb, &bool_type(), subst)?;
            bool_type()
        }

        MetaExpr::Not(a) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            unify(&ta, &bool_type(), subst)?;
            bool_type()
        }

        MetaExpr::List(items) => {
            let elem_tv = Type::Var(env.fresh());
            for item_id in items {
                let t = infer_expr(ast, item_id, env, subst, table)?;
                unify(&t, &elem_tv, subst)?;
            }
            Type::Slice(Box::new(elem_tv.apply(subst)))
        }

        MetaExpr::SliceRange { object, start, end } => {
            let obj_ty = infer_expr(ast, object, env, subst, table)?;
            if let Some(start_id) = start {
                let t = infer_expr(ast, start_id, env, subst, table)?;
                unify(&t, &int_type(), subst)?;
            }
            if let Some(end_id) = end {
                let t = infer_expr(ast, end_id, env, subst, table)?;
                unify(&t, &int_type(), subst)?;
            }
            // Result is the same slice type as the object
            obj_ty.apply(subst)
        }

        MetaExpr::Call { callee, args } => {
            let callee_ty = env.lookup(&callee).unwrap_or_else(|| Type::Var(env.fresh()));

            let mut arg_types = Vec::new();
            for arg_id in args {
                arg_types.push(infer_expr(ast, arg_id, env, subst, table)?);
            }

            let ret_tv = Type::Var(env.fresh());
            let expected_fn = Type::Func {
                params: arg_types,
                ret: Box::new(ret_tv.clone()),
                effects: EffectRow::empty(),
            };

            unify(&callee_ty, &expected_fn, subst)?;
            ret_tv.apply(subst)
        }

        MetaExpr::StructLiteral { fields, .. } => {
            let mut field_types = std::collections::BTreeMap::new();
            for (field_name, expr_id) in fields {
                let t = infer_expr(ast, expr_id, env, subst, table)?;
                field_types.insert(field_name, t);
            }
            Type::Record(field_types)
        }

        MetaExpr::EnumConstructor { enum_name, payload, .. } => {
            match payload {
                ConstructorPayload::Tuple(ids) => {
                    for id in ids {
                        infer_expr(ast, id, env, subst, table)?;
                    }
                }
                ConstructorPayload::Struct(fields) => {
                    for (_, id) in fields {
                        infer_expr(ast, id, env, subst, table)?;
                    }
                }
                ConstructorPayload::Unit => {}
            }
            Type::Enum(enum_name.clone())
        }

        // Resolved at compile time by the metaprocessor — type is string
        MetaExpr::Typeof(_) | MetaExpr::Embed(_) => string_type(),

        MetaExpr::DotAccess { object, .. } => {
            infer_expr(ast, object, env, subst, table)?;
            Type::Var(env.fresh())
        }

        MetaExpr::DotCall { object, args, .. } => {
            infer_expr(ast, object, env, subst, table)?;
            for arg_id in args {
                infer_expr(ast, arg_id, env, subst, table)?;
            }
            Type::Var(env.fresh())
        }

        MetaExpr::Index { object, index } => {
            infer_expr(ast, object, env, subst, table)?;
            infer_expr(ast, index, env, subst, table)?;
            Type::Var(env.fresh())
        }

        MetaExpr::Tuple(items) => {
            let mut elem_types = Vec::new();
            for item_id in items {
                elem_types.push(infer_expr(ast, item_id, env, subst, table)?);
            }
            Type::Tuple(elem_types)
        }

        MetaExpr::TupleIndex { object, index } => {
            let obj_ty = infer_expr(ast, object, env, subst, table)?;
            match obj_ty.apply(subst) {
                Type::Tuple(elems) => elems.get(index).cloned().unwrap_or_else(|| Type::Var(env.fresh())),
                _ => Type::Var(env.fresh()),
            }
        }
    };

    let ty = ty.apply(subst);
    table.expr_types.insert(expr_id, ty.clone());
    Ok(ty)
}

fn infer_stmt(
    ast: &MetaAst,
    stmt_id: usize,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    ctx: &mut TypeCheckCtx,
    table: &mut TypeTable,
) -> Result<Type, TypeError> {
    let stmt = ast.get_stmt(stmt_id).ok_or(TypeError::Unsupported)?.clone();

    let ty = match stmt {
        MetaStmt::ExprStmt(expr_id) => {
            infer_expr(ast, expr_id, env, subst, table)?;
            unit_type()
        }

        MetaStmt::VarDecl { name, type_annotation, expr } => {
            let expr_ty = infer_expr(ast, expr, env, subst, table)?;
            if let Some(declared_ty) = type_annotation.as_deref().and_then(resolve_annotation) {
                unify(&expr_ty, &declared_ty, subst)?;
            }
            let scheme = generalize(env, expr_ty.apply(subst));
            env.bind(&name, scheme);
            unit_type()
        }

        MetaStmt::Assign { name, expr } => {
            let expr_ty = infer_expr(ast, expr, env, subst, table)?;
            if let Some(existing_ty) = env.lookup(name.as_str()) {
                unify(&expr_ty, &existing_ty, subst)?;
            }
            unit_type()
        }

        MetaStmt::IndexAssign { indices, expr, .. } => {
            for idx in indices {
                infer_expr(ast, idx, env, subst, table)?;
            }
            infer_expr(ast, expr, env, subst, table)?;
            unit_type()
        }

        MetaStmt::FnDecl { name, params, body, .. } => {
            let mut param_types = Vec::new();
            for p in &params {
                let ty = p.ty.as_deref()
                    .and_then(resolve_annotation)
                    .unwrap_or_else(|| Type::Var(env.fresh()));
                param_types.push(ty);
            }
            let ret_tv = Type::Var(env.fresh());

            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv.clone()),
                effects: EffectRow::empty(),
            };

            env.push_scope();
            env.bind_mono(&name, fn_type.clone());

            for (param, ty) in params.iter().zip(param_types.iter()) {
                env.bind_mono(&param.name, ty.clone());
            }

            let saved_ret = ctx.return_type.take();
            let saved_saw = ctx.saw_return;
            ctx.return_type = Some(ret_tv.clone());
            ctx.saw_return = false;

            infer_stmt(ast, body, env, subst, ctx, table)?;

            if !ctx.saw_return {
                unify(&ret_tv, &unit_type(), subst)?;
            }

            ctx.return_type = saved_ret;
            ctx.saw_return = saved_saw;

            env.pop_scope();

            // Collect the effect row: direct ctl op calls + transitive effects
            // from called functions whose types are now resolved in the env.
            let mut raw_effects = BTreeSet::new();
            collect_body_effects(ast, body, &ctx.ctl_ops, env, &mut raw_effects);
            let effect_row = EffectRow { effects: raw_effects };

            let base = fn_type.apply(subst);
            let final_fn_type = match base {
                Type::Func { params, ret, .. } => Type::Func { params, ret, effects: effect_row },
                other => other,
            };
            let scheme = generalize(env, final_fn_type.clone());
            env.bind(&name, scheme);

            final_fn_type
        }

        MetaStmt::Return(opt_expr) => {
            let expr_ty = match opt_expr {
                None => unit_type(),
                Some(expr_id) => infer_expr(ast, expr_id, env, subst, table)?,
            };

            let ret_ty = ctx.return_type.as_ref().ok_or(TypeError::InvalidReturn)?.clone();
            ctx.saw_return = true;
            unify(&expr_ty, &ret_ty, subst)?;
            unit_type()
        }

        MetaStmt::Block(stmts) => {
            env.push_scope();
            for s in stmts {
                infer_stmt(ast, s, env, subst, ctx, table)?;
            }
            env.pop_scope();
            unit_type()
        }

        MetaStmt::If { cond, body, else_branch } => {
            let cond_ty = infer_expr(ast, cond, env, subst, table)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx, table)?;
            if let Some(else_id) = else_branch {
                infer_stmt(ast, else_id, env, subst, ctx, table)?;
            }
            unit_type()
        }

        MetaStmt::WhileLoop { cond, body } => {
            let cond_ty = infer_expr(ast, cond, env, subst, table)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx, table)?;
            unit_type()
        }

        MetaStmt::ForEach { var, iterable, body } => {
            let iter_ty = infer_expr(ast, iterable, env, subst, table)?;
            let elem_tv = Type::Var(env.fresh());
            // iterable must be a list of elem_tv
            unify(&iter_ty, &elem_tv, subst)?;
            env.push_scope();
            env.bind_mono(&var, elem_tv.apply(subst));
            infer_stmt(ast, body, env, subst, ctx, table)?;
            env.pop_scope();
            unit_type()
        }

        MetaStmt::Print(expr_id) => {
            infer_expr(ast, expr_id, env, subst, table)?;
            unit_type()
        }

        MetaStmt::MetaFnDecl { name, params, body } => {
            let mut param_types = Vec::new();
            for p in params.iter() {
                let ty = p.ty.as_deref()
                    .and_then(resolve_annotation)
                    .unwrap_or_else(|| Type::Var(env.fresh()));
                param_types.push(ty);
            }
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv.clone()),
                effects: EffectRow::empty(),
            };
            env.push_scope();
            env.bind_mono(name.as_str(), fn_type.clone());
            for (param, ty) in params.iter().zip(param_types.iter()) {
                env.bind_mono(param.name.as_str(), ty.clone());
            }
            let saved_ret = ctx.return_type.take();
            let saved_saw = ctx.saw_return;
            ctx.return_type = Some(ret_tv.clone());
            ctx.saw_return = false;
            infer_stmt(ast, body, env, subst, ctx, table)?;
            if !ctx.saw_return {
                unify(&ret_tv, &unit_type(), subst)?;
            }
            ctx.return_type = saved_ret;
            ctx.saw_return = saved_saw;
            env.pop_scope();
            let final_fn_type = fn_type.apply(subst);
            let scheme = generalize(env, final_fn_type.clone());
            env.bind(name.as_str(), scheme);
            final_fn_type
        }

        MetaStmt::EnumDecl { name, variants } => {
            env.register_enum(&name, variants.clone());
            unit_type()
        }

        MetaStmt::Match { scrutinee, arms } => {
            let _scrutinee_ty = infer_expr(ast, scrutinee, env, subst, table)?;
            for arm in arms {
                env.push_scope();
                match &arm.pattern {
                    Pattern::Wildcard => {}
                    Pattern::Enum { enum_name, variant, bindings } => {
                        if let Some(variants) = env.lookup_enum(enum_name).cloned() {
                            if let Some(v) = variants.iter().find(|v| v.name == *variant) {
                                match (&v.payload, bindings) {
                                    (_, VariantBindings::Unit) => {}
                                    (_, VariantBindings::Tuple(names)) => {
                                        for name in names {
                                            let tv = Type::Var(env.fresh());
                                            env.bind_mono(name, tv);
                                        }
                                    }
                                    (_, VariantBindings::Struct(names)) => {
                                        for name in names {
                                            let tv = Type::Var(env.fresh());
                                            env.bind_mono(name, tv);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                infer_stmt(ast, arm.body, env, subst, ctx, table)?;
                env.pop_scope();
            }
            unit_type()
        }

        MetaStmt::EffectDecl { ops, .. } => {
            for op in &ops {
                // Track ctl ops for effect inference.
                if matches!(op.kind, EffectOpKind::Ctl) {
                    ctx.ctl_ops.insert(op.name.clone());
                }
                // Register the op as callable so call sites type-check.
                let param_types: Vec<Type> = op.params.iter()
                    .map(|p| p.ty.as_deref().and_then(resolve_annotation).unwrap_or_else(|| Type::Var(env.fresh())))
                    .collect();
                let ret_ty = op.ret_ty.as_deref()
                    .and_then(resolve_annotation)
                    .unwrap_or_else(|| Type::Var(env.fresh()));
                env.bind_mono(&op.name, Type::Func {
                    params: param_types,
                    ret: Box::new(ret_ty),
                    effects: EffectRow::empty(),
                });
            }
            unit_type()
        }

        // These don't produce a meaningful type for the table
        MetaStmt::StructDecl { .. }
        | MetaStmt::Import(_)
        | MetaStmt::MetaBlock(_)
        | MetaStmt::Gen(_)
        | MetaStmt::TraitDecl { .. }
        | MetaStmt::ImplDecl { .. }
        | MetaStmt::WithFn { .. }
        | MetaStmt::WithCtl { .. }
        | MetaStmt::Resume(_) => unit_type(),
    };

    let ty = ty.apply(subst);
    table.stmt_types.insert(stmt_id, ty.clone());
    Ok(ty)
}
