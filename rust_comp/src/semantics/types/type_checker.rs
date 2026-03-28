use crate::frontend::meta_ast::{ConstructorPayload, Pattern, VariantBindings, *};
use super::typed_ast::TypeTable;
use super::type_env::TypeEnv;
use super::type_error::TypeError;
use super::type_subst::{unify, ApplySubst, TypeSubst};
use super::type_utils::generalize;
use super::types::*;

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
}

impl TypeCheckCtx {
    fn new() -> Self {
        TypeCheckCtx {
            return_type: None,
            saw_return: false,
        }
    }
}

pub fn type_check(ast: &MetaAst) -> Result<(TypeTable, TypeEnv), TypeError> {
    let mut table = TypeTable::new();
    let mut env = TypeEnv::new();
    let mut subst = TypeSubst::new();
    let mut ctx = TypeCheckCtx::new();

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

        MetaExpr::Equals(a, b) => {
            let ta = infer_expr(ast, a, env, subst, table)?;
            let tb = infer_expr(ast, b, env, subst, table)?;
            unify(&ta, &tb, subst)?;
            bool_type()
        }

        MetaExpr::List(items) => {
            let elem_tv = Type::Var(env.fresh());
            for item_id in items {
                let t = infer_expr(ast, item_id, env, subst, table)?;
                unify(&t, &elem_tv, subst)?;
            }
            elem_tv.apply(subst)
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

        MetaStmt::FnDecl { name, params, body } => {
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

            let final_fn_type = fn_type.apply(subst);
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

        // These don't produce a meaningful type for the table
        MetaStmt::StructDecl { .. }
        | MetaStmt::Import(_)
        | MetaStmt::MetaBlock(_)
        | MetaStmt::Gen(_) => unit_type(),
    };

    let ty = ty.apply(subst);
    table.stmt_types.insert(stmt_id, ty.clone());
    Ok(ty)
}
