use crate::frontend::meta_ast::{ConstructorPayload, ImportDecl, Pattern, VariantBindings};
use crate::semantics::meta::runtime_ast::*;
use super::type_env::TypeEnv;
use super::type_error::TypeError;
use super::type_subst::{unify, ApplySubst, TypeSubst};
use super::type_utils::generalize;
use super::types::*;

fn path_stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.strip_suffix(".cx").unwrap_or(name).to_string()
}

struct CheckCtx {
    return_type: Option<Type>,
    saw_return: bool,
}

impl CheckCtx {
    fn new() -> Self {
        CheckCtx { return_type: None, saw_return: false }
    }
}

/// Phase-2 type checker: runs on RuntimeAst after meta processing.
///
/// Unlike the Phase-1 MetaAst type checker, this is strict: referencing an
/// unbound variable is a hard error. `env` is threaded in and mutated so that
/// names introduced in earlier mini-trees remain visible when checking later
/// ones (mirrors how the meta interpreter shares its environment).
pub fn type_check_runtime(ast: &RuntimeAst, env: &mut TypeEnv) -> Result<(), TypeError> {
    let mut subst = TypeSubst::new();
    let mut ctx = CheckCtx::new();

    // Pre-bind built-in runtime functions
    let alpha = env.fresh();
    env.bind_mono("readfile",  Type::Func { params: vec![string_type()], ret: Box::new(string_type()) });
    env.bind("to_string", TypeScheme::PolyType {
        vars: vec![alpha],
        ty: Type::Func { params: vec![Type::Var(alpha)], ret: Box::new(string_type()) },
    });
    env.bind_mono("to_int",    Type::Func { params: vec![string_type()], ret: Box::new(int_type())    });

    hoist_fn_types(ast, &ast.sem_root_stmts, env, &mut subst);
    for &stmt_id in &ast.sem_root_stmts.clone() {
        infer_stmt(ast, stmt_id, env, &mut subst, &mut ctx)?;
    }
    Ok(())
}

/// Pre-register all FnDecl types in a stmt list so forward calls type-check.
fn hoist_fn_types(
    ast: &RuntimeAst,
    stmts: &[usize],
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
) {
    for &stmt_id in stmts {
        if let Some(RuntimeStmt::FnDecl { name, params, .. }) = ast.get_stmt(stmt_id) {
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types,
                ret: Box::new(ret_tv),
            };
            let scheme = generalize(env, fn_type.apply(subst));
            env.bind(name, scheme);
        }
    }
}

fn infer_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
) -> Result<Type, TypeError> {
    let expr = ast.get_expr(expr_id).ok_or(TypeError::Unsupported)?.clone();
    match expr {
        RuntimeExpr::Int(_) => Ok(int_type()),
        RuntimeExpr::Bool(_) => Ok(bool_type()),
        RuntimeExpr::String(_) => Ok(string_type()),

        RuntimeExpr::Variable(name) => {
            env.lookup(&name).ok_or_else(|| TypeError::UnboundVar(name.clone()))
        }

        RuntimeExpr::Add(a, b) => {
            let ta = infer_expr(ast, a, env, subst)?;
            let tb = infer_expr(ast, b, env, subst)?;
            let tv = Type::Var(env.fresh());
            unify(&ta, &tv, subst)?;
            unify(&tb, &tv, subst)?;
            Ok(tv.apply(subst))
        }

        RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b) | RuntimeExpr::Div(a, b) => {
            let ta = infer_expr(ast, a, env, subst)?;
            let tb = infer_expr(ast, b, env, subst)?;
            unify(&ta, &int_type(), subst)?;
            unify(&tb, &int_type(), subst)?;
            Ok(int_type())
        }

        RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b) => {
            let ta = infer_expr(ast, a, env, subst)?;
            let tb = infer_expr(ast, b, env, subst)?;
            unify(&ta, &tb, subst)?;
            Ok(bool_type())
        }

        RuntimeExpr::Lt(a, b) | RuntimeExpr::Gt(a, b) | RuntimeExpr::Lte(a, b) | RuntimeExpr::Gte(a, b) => {
            let ta = infer_expr(ast, a, env, subst)?;
            let tb = infer_expr(ast, b, env, subst)?;
            unify(&ta, &int_type(), subst)?;
            unify(&tb, &int_type(), subst)?;
            Ok(bool_type())
        }

        RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b) => {
            let ta = infer_expr(ast, a, env, subst)?;
            let tb = infer_expr(ast, b, env, subst)?;
            unify(&ta, &bool_type(), subst)?;
            unify(&tb, &bool_type(), subst)?;
            Ok(bool_type())
        }

        RuntimeExpr::Not(a) => {
            let ta = infer_expr(ast, a, env, subst)?;
            unify(&ta, &bool_type(), subst)?;
            Ok(bool_type())
        }

        RuntimeExpr::List(items) => {
            let elem_tv = Type::Var(env.fresh());
            for item_id in items {
                let t = infer_expr(ast, item_id, env, subst)?;
                unify(&t, &elem_tv, subst)?;
            }
            Ok(elem_tv.apply(subst))
        }

        RuntimeExpr::Call { callee, args } => {
            let callee_ty = env
                .lookup(&callee)
                .ok_or_else(|| TypeError::UnboundVar(callee.clone()))?;
            let mut arg_types = Vec::new();
            for arg_id in args {
                arg_types.push(infer_expr(ast, arg_id, env, subst)?);
            }
            let ret_tv = Type::Var(env.fresh());
            let expected_fn = Type::Func {
                params: arg_types,
                ret: Box::new(ret_tv.clone()),
            };
            unify(&callee_ty, &expected_fn, subst)?;
            Ok(ret_tv.apply(subst))
        }

        RuntimeExpr::StructLiteral { fields, .. } => {
            for (_, expr_id) in fields {
                infer_expr(ast, expr_id, env, subst)?;
            }
            Ok(Type::Var(env.fresh()))
        }

        // Module dot-access — we don't track module member types yet.
        RuntimeExpr::DotAccess { object, .. } => {
            infer_expr(ast, object, env, subst)?;
            Ok(Type::Var(env.fresh()))
        }

        RuntimeExpr::DotCall { object, args, .. } => {
            infer_expr(ast, object, env, subst)?;
            for arg_id in args {
                infer_expr(ast, arg_id, env, subst)?;
            }
            Ok(Type::Var(env.fresh()))
        }

        RuntimeExpr::Index { object, index } => {
            infer_expr(ast, object, env, subst)?;
            infer_expr(ast, index, env, subst)?;
            Ok(Type::Var(env.fresh()))
        }

        RuntimeExpr::Tuple(items) => {
            for item_id in items {
                infer_expr(ast, item_id, env, subst)?;
            }
            Ok(Type::Var(env.fresh()))
        }

        RuntimeExpr::TupleIndex { object, .. } => {
            infer_expr(ast, object, env, subst)?;
            Ok(Type::Var(env.fresh()))
        }

        RuntimeExpr::EnumConstructor { enum_name, payload, .. } => {
            match payload {
                ConstructorPayload::Tuple(ids) => {
                    for id in ids {
                        infer_expr(ast, id, env, subst)?;
                    }
                }
                ConstructorPayload::Struct(fields) => {
                    for (_, id) in fields {
                        infer_expr(ast, id, env, subst)?;
                    }
                }
                ConstructorPayload::Unit => {}
            }
            Ok(Type::Enum(enum_name.clone()))
        }
    }
}

fn infer_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    ctx: &mut CheckCtx,
) -> Result<(), TypeError> {
    let stmt = ast.get_stmt(stmt_id).ok_or(TypeError::Unsupported)?.clone();
    match stmt {
        RuntimeStmt::ExprStmt(expr_id) => {
            infer_expr(ast, expr_id, env, subst)?;
        }

        RuntimeStmt::Print(expr_id) => {
            infer_expr(ast, expr_id, env, subst)?;
        }

        RuntimeStmt::VarDecl { name, expr } => {
            let ty = infer_expr(ast, expr, env, subst)?;
            let scheme = generalize(env, ty);
            env.bind(&name, scheme);
        }

        RuntimeStmt::Assign { name, expr } => {
            let ty = infer_expr(ast, expr, env, subst)?;
            if let Some(existing) = env.lookup(&name) {
                unify(&ty, &existing, subst)?;
            } else {
                return Err(TypeError::UnboundVar(name.clone()));
            }
        }

        RuntimeStmt::IndexAssign { indices, expr, .. } => {
            for idx in indices {
                infer_expr(ast, idx, env, subst)?;
            }
            infer_expr(ast, expr, env, subst)?;
        }

        RuntimeStmt::FnDecl { name, params, body } => {
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv.clone()),
            };
            env.push_scope();
            env.bind_mono(&name, fn_type.clone());
            for (param, ty) in params.iter().zip(&param_types) {
                env.bind_mono(param, ty.clone());
            }
            let saved_ret = ctx.return_type.take();
            let saved_saw = ctx.saw_return;
            ctx.return_type = Some(ret_tv.clone());
            ctx.saw_return = false;
            infer_stmt(ast, body, env, subst, ctx)?;
            if !ctx.saw_return {
                unify(&ret_tv, &unit_type(), subst)?;
            }
            ctx.return_type = saved_ret;
            ctx.saw_return = saved_saw;
            env.pop_scope();
            let scheme = generalize(env, fn_type.apply(subst));
            env.bind(&name, scheme);
        }

        RuntimeStmt::Return(opt_expr) => {
            let ty = match opt_expr {
                None => unit_type(),
                Some(expr_id) => infer_expr(ast, expr_id, env, subst)?,
            };
            if let Some(ret_ty) = ctx.return_type.as_ref() {
                unify(&ty, ret_ty, subst)?;
            } else {
                return Err(TypeError::InvalidReturn);
            }
            ctx.saw_return = true;
        }

        RuntimeStmt::Block(stmts) => {
            env.push_scope();
            hoist_fn_types(ast, &stmts, env, subst);
            for child_id in &stmts {
                infer_stmt(ast, *child_id, env, subst, ctx)?;
            }
            env.pop_scope();
        }

        RuntimeStmt::If { cond, body, else_branch } => {
            let cond_ty = infer_expr(ast, cond, env, subst)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx)?;
            if let Some(else_id) = else_branch {
                infer_stmt(ast, else_id, env, subst, ctx)?;
            }
        }

        RuntimeStmt::WhileLoop { cond, body } => {
            let cond_ty = infer_expr(ast, cond, env, subst)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx)?;
        }

        RuntimeStmt::ForEach { var, iterable, body } => {
            infer_expr(ast, iterable, env, subst)?;
            env.push_scope();
            let var_ty = Type::Var(env.fresh());
            env.bind_mono(&var, var_ty);
            infer_stmt(ast, body, env, subst, ctx)?;
            env.pop_scope();
        }

        RuntimeStmt::Gen(_) => {
            // Gen blocks are template code emitted at the call site; variable
            // references inside may be runtime references not yet in scope.
            // The generated output is type-checked when inlined into the root AST.
        }

        RuntimeStmt::Import(decl) => {
            // Register the bound name so downstream code can reference the namespace.
            match &decl {
                ImportDecl::Qualified { path } => {
                    let name = path_stem(path);
                    let ty = Type::Var(env.fresh());
                    env.bind_mono(&name, ty);
                }
                ImportDecl::Aliased { alias, .. } => {
                    let ty = Type::Var(env.fresh());
                    env.bind_mono(alias, ty);
                }
                ImportDecl::Selective { names, .. } => {
                    for name in names {
                        let ty = Type::Var(env.fresh());
                        env.bind_mono(name, ty);
                    }
                }
                ImportDecl::Wildcard { .. } => {
                    unreachable!("wildcard imports must be expanded by module_loader before type checking")
                }
            }
        }

        // StructDecl doesn't have checkable expressions.
        RuntimeStmt::StructDecl { .. } => {}

        RuntimeStmt::EnumDecl { name, variants } => {
            env.register_enum(&name, variants.clone());
        }

        RuntimeStmt::Match { scrutinee, arms } => {
            infer_expr(ast, scrutinee, env, subst)?;
            for arm in arms {
                env.push_scope();
                match &arm.pattern {
                    Pattern::Wildcard => {}
                    Pattern::Enum { enum_name, variant, bindings } => {
                        if let Some(variants) = env.lookup_enum(enum_name).cloned() {
                            if let Some(_v) = variants.iter().find(|v| v.name == *variant) {
                                match bindings {
                                    VariantBindings::Unit => {}
                                    VariantBindings::Tuple(names) => {
                                        for name in names {
                                            let tv = Type::Var(env.fresh());
                                            env.bind_mono(name, tv);
                                        }
                                    }
                                    VariantBindings::Struct(names) => {
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
                infer_stmt(ast, arm.body, env, subst, ctx)?;
                env.pop_scope();
            }
        }
    }
    Ok(())
}
