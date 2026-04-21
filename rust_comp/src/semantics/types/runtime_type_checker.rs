use crate::frontend::meta_ast::{ConstructorPayload, ImportDecl, Pattern, VariantBindings};
use crate::semantics::meta::runtime_ast::*;
use super::type_env::TypeEnv;
use super::type_error::TypeError;
use super::type_subst::{unify, ApplySubst, TypeSubst};
use super::type_utils::generalize;
use super::types::*;
use std::collections::HashMap;

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
pub fn type_check_runtime(ast: &RuntimeAst, env: &mut TypeEnv) -> Result<HashMap<usize, Type>, TypeError> {
    let mut subst = TypeSubst::new();
    let mut ctx = CheckCtx::new();
    let mut type_map: HashMap<usize, Type> = HashMap::new();

    // Pre-bind built-in runtime functions
    let alpha = env.fresh();
    let beta = env.fresh();
    env.bind_mono("readfile",  Type::Func { params: vec![string_type()], ret: Box::new(string_type()), effects: EffectRow::empty() });
    env.bind("to_string", TypeScheme::PolyType {
        vars: vec![alpha],
        ty: Type::Func { params: vec![Type::Var(alpha)], ret: Box::new(string_type()), effects: EffectRow::empty() },
    });
    env.bind_mono("to_int",    Type::Func { params: vec![string_type()], ret: Box::new(int_type()), effects: EffectRow::empty()    });
    env.bind("free", TypeScheme::PolyType {
        vars: vec![beta],
        ty: Type::Func { params: vec![Type::Var(beta)], ret: Box::new(unit_type()), effects: EffectRow::empty() },
    });

    hoist_fn_types(ast, &ast.sem_root_stmts, env, &mut subst);
    for &stmt_id in &ast.sem_root_stmts.clone() {
        infer_stmt(ast, stmt_id, env, &mut subst, &mut ctx, &mut type_map)?;
    }

    // Apply the final substitution so callers see concrete types, not raw type vars.
    let resolved = type_map.into_iter()
        .map(|(id, ty)| (id, ty.apply(&subst)))
        .collect();
    Ok(resolved)
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
                effects: EffectRow::empty(),
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
    type_map: &mut HashMap<usize, Type>,
) -> Result<Type, TypeError> {
    let expr = ast.get_expr(expr_id).ok_or(TypeError::unsupported())?.clone();
    let ty = match expr {
        RuntimeExpr::Int(_) => int_type(),
        RuntimeExpr::Bool(_) => bool_type(),
        RuntimeExpr::String(_) => string_type(),

        RuntimeExpr::Variable(ref name) => {
            env.lookup(name).ok_or_else(|| TypeError::unbound_var(name.clone()).at(expr_id))?
        }

        RuntimeExpr::Add(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            let tv = Type::Var(env.fresh());
            unify(&ta, &tv, subst)?;
            unify(&tb, &tv, subst)?;
            tv.apply(subst)
        }

        RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b) | RuntimeExpr::Div(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            // If both operands are int, return int. Otherwise the operator is
            // dispatched to a user-defined impl at runtime — leave the result
            // as a fresh type variable so codegen can refine it.
            match (ta.apply(subst), tb.apply(subst)) {
                (Type::Primitive(PrimitiveType::Int), Type::Primitive(PrimitiveType::Int)) => int_type(),
                _ => Type::Var(env.fresh()),
            }
        }

        RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            unify(&ta, &tb, subst)?;
            bool_type()
        }

        RuntimeExpr::Lt(a, b) | RuntimeExpr::Gt(a, b) | RuntimeExpr::Lte(a, b) | RuntimeExpr::Gte(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            unify(&ta, &int_type(), subst)?;
            unify(&tb, &int_type(), subst)?;
            bool_type()
        }

        RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            unify(&ta, &bool_type(), subst)?;
            unify(&tb, &bool_type(), subst)?;
            bool_type()
        }

        RuntimeExpr::Not(a) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            unify(&ta, &bool_type(), subst)?;
            bool_type()
        }

        RuntimeExpr::List(items) => {
            let elem_tv = Type::Var(env.fresh());
            for item_id in items {
                let t = infer_expr(ast, item_id, env, subst, type_map)?;
                unify(&t, &elem_tv, subst)?;
            }
            Type::Slice(Box::new(elem_tv.apply(subst)))
        }

        RuntimeExpr::SliceRange { object, start, end } => {
            let obj_ty = infer_expr(ast, object, env, subst, type_map)?;
            if let Some(start_id) = start {
                let t = infer_expr(ast, start_id, env, subst, type_map)?;
                unify(&t, &int_type(), subst)?;
            }
            if let Some(end_id) = end {
                let t = infer_expr(ast, end_id, env, subst, type_map)?;
                unify(&t, &int_type(), subst)?;
            }
            // SliceRange on a string yields a string; on a slice yields the same slice type.
            match obj_ty.apply(subst) {
                t @ Type::Primitive(crate::semantics::types::types::PrimitiveType::String) => t,
                t => t,
            }
        }

        RuntimeExpr::Call { ref callee, ref args } => {
            let callee_ty = env
                .lookup(callee)
                .ok_or_else(|| TypeError::unbound_var(callee.clone()).at(expr_id))?;
            let mut arg_types = Vec::new();
            for &arg_id in args {
                arg_types.push(infer_expr(ast, arg_id, env, subst, type_map)?);
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

        RuntimeExpr::StructLiteral { ref type_name, ref fields } => {
            let mut field_types = std::collections::BTreeMap::new();
            for (name, field_expr_id) in fields {
                let ty = infer_expr(ast, *field_expr_id, env, subst, type_map)?;
                field_types.insert(name.clone(), ty);
            }
            Type::Struct { name: type_name.clone(), fields: field_types }
        }

        // Module dot-access — we don't track module member types yet.
        RuntimeExpr::DotAccess { object, .. } => {
            infer_expr(ast, object, env, subst, type_map)?;
            Type::Var(env.fresh())
        }

        RuntimeExpr::DotCall { object, ref args, .. } => {
            infer_expr(ast, object, env, subst, type_map)?;
            for &arg_id in args {
                infer_expr(ast, arg_id, env, subst, type_map)?;
            }
            Type::Var(env.fresh())
        }

        RuntimeExpr::Index { object, index } => {
            infer_expr(ast, object, env, subst, type_map)?;
            infer_expr(ast, index, env, subst, type_map)?;
            Type::Var(env.fresh())
        }

        RuntimeExpr::Tuple(ref items) => {
            let mut elem_types = Vec::new();
            for &item_id in items {
                elem_types.push(infer_expr(ast, item_id, env, subst, type_map)?);
            }
            Type::Tuple(elem_types)
        }

        RuntimeExpr::TupleIndex { object, index } => {
            let obj_ty = infer_expr(ast, object, env, subst, type_map)?;
            match obj_ty.apply(subst) {
                Type::Tuple(elems) => elems.get(index).cloned().unwrap_or_else(|| Type::Var(env.fresh())),
                _ => Type::Var(env.fresh()),
            }
        }

        RuntimeExpr::Unit => unit_type(),

        RuntimeExpr::Lambda { ref params, .. } => {
            // Lambdas are injected by the CPS pass after type checking; return a fresh fn type.
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            Type::Func {
                params: param_types,
                ret: Box::new(ret_tv),
                effects: EffectRow::empty(),
            }
        }

        RuntimeExpr::EnumConstructor { ref enum_name, ref payload, .. } => {
            match payload {
                ConstructorPayload::Tuple(ids) => {
                    for &id in ids {
                        infer_expr(ast, id, env, subst, type_map)?;
                    }
                }
                ConstructorPayload::Struct(fields) => {
                    for (_, id) in fields {
                        infer_expr(ast, *id, env, subst, type_map)?;
                    }
                }
                ConstructorPayload::Unit => {}
            }
            Type::Enum(enum_name.clone())
        }
    };
    type_map.insert(expr_id, ty.clone());
    Ok(ty)
}

fn infer_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    ctx: &mut CheckCtx,
    type_map: &mut HashMap<usize, Type>,
) -> Result<(), TypeError> {
    let stmt = ast.get_stmt(stmt_id).ok_or(TypeError::unsupported())?.clone();
    match stmt {
        RuntimeStmt::ExprStmt(expr_id) => {
            infer_expr(ast, expr_id, env, subst, type_map)?;
        }

        RuntimeStmt::Print(expr_id) => {
            infer_expr(ast, expr_id, env, subst, type_map)?;
        }

        RuntimeStmt::VarDecl { name, expr } => {
            let ty = infer_expr(ast, expr, env, subst, type_map)?;
            let scheme = generalize(env, ty);
            env.bind(&name, scheme);
        }

        RuntimeStmt::Assign { name, expr } => {
            let ty = infer_expr(ast, expr, env, subst, type_map)?;
            if let Some(existing) = env.lookup(&name) {
                unify(&ty, &existing, subst)?;
            } else {
                return Err(TypeError::unbound_var(name.clone()).at(stmt_id));
            }
        }

        RuntimeStmt::IndexAssign { indices, expr, .. } => {
            for idx in indices {
                infer_expr(ast, idx, env, subst, type_map)?;
            }
            infer_expr(ast, expr, env, subst, type_map)?;
        }

        RuntimeStmt::FnDecl { name, params, body, .. } => {
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv.clone()),
                effects: EffectRow::empty(),
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
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
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
                Some(expr_id) => infer_expr(ast, expr_id, env, subst, type_map)?,
            };
            if let Some(ret_ty) = ctx.return_type.as_ref() {
                unify(&ty, ret_ty, subst)?;
            } else {
                return Err(TypeError::invalid_return());
            }
            ctx.saw_return = true;
        }

        RuntimeStmt::Block(stmts) => {
            env.push_scope();
            hoist_fn_types(ast, &stmts, env, subst);
            for child_id in &stmts {
                infer_stmt(ast, *child_id, env, subst, ctx, type_map)?;
            }
            env.pop_scope();
        }

        RuntimeStmt::If { cond, body, else_branch } => {
            let cond_ty = infer_expr(ast, cond, env, subst, type_map)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
            if let Some(else_id) = else_branch {
                infer_stmt(ast, else_id, env, subst, ctx, type_map)?;
            }
        }

        RuntimeStmt::WhileLoop { cond, body } => {
            let cond_ty = infer_expr(ast, cond, env, subst, type_map)?;
            unify(&cond_ty, &bool_type(), subst)?;
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
        }

        RuntimeStmt::ForEach { var, iterable, body } => {
            let iter_ty = infer_expr(ast, iterable, env, subst, type_map)?;
            let elem_ty = match iter_ty.apply(subst) {
                Type::Slice(elem) => *elem,
                _ => Type::Var(env.fresh()),
            };
            // Record element type under the ForEach stmt_id so codegen knows
            // the alloca type for the loop variable without re-scanning the AST.
            type_map.insert(stmt_id, elem_ty.clone());
            env.push_scope();
            env.bind_mono(&var, elem_ty);
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
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
            infer_expr(ast, scrutinee, env, subst, type_map)?;
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
                infer_stmt(ast, arm.body, env, subst, ctx, type_map)?;
                env.pop_scope();
            }
        }

        RuntimeStmt::WithFn { op_name, params, body, .. } => {
            // Register the handler as a callable function so subsequent calls
            // to the same name (e.g. `log("hello")`) type-check correctly.
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv),
                effects: EffectRow::empty(),
            };
            let scheme = generalize(env, fn_type);
            env.bind(&op_name, scheme);
            // Check the handler body with params in scope.
            env.push_scope();
            for (param, ty) in params.iter().zip(&param_types) {
                env.bind_mono(&param.name, ty.clone());
            }
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
            env.pop_scope();
        }

        // Register each declared operation so call sites type-check.
        RuntimeStmt::EffectDecl { ops, .. } => {
            for op in ops {
                let param_types: Vec<Type> = op.params.iter().map(|_| Type::Var(env.fresh())).collect();
                let ret_tv = Type::Var(env.fresh());
                let fn_type = Type::Func {
                    params: param_types,
                    ret: Box::new(ret_tv),
                    effects: EffectRow::empty(),
                };
                env.bind(&op.name, generalize(env, fn_type));
            }
        }

        // Register the ctl op as callable + type-check handler body.
        RuntimeStmt::WithCtl { op_name, params, body, .. } => {
            let param_types: Vec<Type> = params.iter().map(|_| Type::Var(env.fresh())).collect();
            let ret_tv = Type::Var(env.fresh());
            let fn_type = Type::Func {
                params: param_types.clone(),
                ret: Box::new(ret_tv),
                effects: EffectRow::empty(),
            };
            env.bind(&op_name, generalize(env, fn_type));
            env.push_scope();
            for (param, ty) in params.iter().zip(&param_types) {
                env.bind_mono(&param.name, ty.clone());
            }
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
            env.pop_scope();
        }

        RuntimeStmt::Resume(_) => {}
    }
    Ok(())
}
