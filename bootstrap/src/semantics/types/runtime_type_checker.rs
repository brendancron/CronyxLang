use crate::frontend::meta_ast::{ForVar, ImportDecl, MetaTypeExpr, Pattern, VariantBindings, VariantPayload};
use crate::semantics::meta::runtime_ast::*;
use crate::util::node_id::RuntimeNodeId;
use super::type_env::TypeEnv;
use super::type_error::{TypeError, TypeErrorKind};
use super::type_subst::{unify, ApplySubst, TypeSubst};
use super::type_utils::generalize;
use super::types::*;
use std::collections::HashMap;

fn path_stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.strip_suffix(".cx").unwrap_or(name).to_string()
}

fn hint_to_type(name: &str) -> Type {
    match name {
        "int" | "i64" => Type::Primitive(PrimitiveType::Int),
        "string" | "str" => Type::Primitive(PrimitiveType::String),
        "bool" => Type::Primitive(PrimitiveType::Bool),
        "unit" => Type::Primitive(PrimitiveType::Unit),
        _ => Type::Enum(name.to_string()),
    }
}

fn meta_type_expr_to_type(te: &MetaTypeExpr, local_map: &HashMap<String, Type>, env: &mut TypeEnv) -> Type {
    match te {
        MetaTypeExpr::Named(n) => {
            if let Some(ty) = local_map.get(n.as_str()) {
                return ty.clone();
            }
            match n.as_str() {
                "int" => Type::Primitive(crate::semantics::types::types::PrimitiveType::Int),
                "string" => Type::Primitive(crate::semantics::types::types::PrimitiveType::String),
                "bool" => Type::Primitive(crate::semantics::types::types::PrimitiveType::Bool),
                "unit" => Type::Primitive(crate::semantics::types::types::PrimitiveType::Unit),
                _ => Type::Enum(n.clone()),
            }
        }
        MetaTypeExpr::App(name, args) => {
            Type::App(name.clone(), args.iter().map(|a| meta_type_expr_to_type(a, local_map, env)).collect())
        }
        MetaTypeExpr::Tuple(elems) => {
            Type::Tuple(elems.iter().map(|e| meta_type_expr_to_type(e, local_map, env)).collect())
        }
        MetaTypeExpr::Slice(inner) => {
            Type::Slice(Box::new(meta_type_expr_to_type(inner, local_map, env)))
        }
    }
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
/// Run Phase-2 type checking on a `RuntimeAst`.
///
/// Returns the resolved type map on success.  Non-fatal warnings (e.g.
/// polymorphic calls that are correct at runtime but unsound for codegen) are
/// appended to `warnings` rather than returned as errors so callers can choose
/// how strictly to treat them.
pub fn type_check_runtime(
    ast: &RuntimeAst,
    env: &mut TypeEnv,
    warnings: &mut Vec<TypeError>,
) -> Result<HashMap<RuntimeNodeId, Type>, TypeError> {
    let mut subst = TypeSubst::new();
    let mut ctx = CheckCtx::new();
    let mut type_map: HashMap<RuntimeNodeId, Type> = HashMap::new();

    // Pre-bind built-in runtime functions
    let alpha = env.fresh();
    let beta = env.fresh();
    env.bind_mono("readfile",  Type::Func { params: vec![string_type()], ret: Box::new(string_type()), effects: EffectRow::empty() });
    env.bind_mono("writefile", Type::Func { params: vec![string_type(), string_type()], ret: Box::new(unit_type()), effects: EffectRow::empty() });
    env.bind("to_string", TypeScheme::PolyType {
        vars: vec![alpha],
        ty: Type::Func { params: vec![Type::Var(alpha)], ret: Box::new(string_type()), effects: EffectRow::empty() },
    });
    env.bind_mono("to_int",    Type::Func { params: vec![string_type()], ret: Box::new(int_type()), effects: EffectRow::empty()    });
    env.bind_mono("ord",       Type::Func { params: vec![string_type()], ret: Box::new(int_type()), effects: EffectRow::empty()    });
    env.bind("free", TypeScheme::PolyType {
        vars: vec![beta],
        ty: Type::Func { params: vec![Type::Var(beta)], ret: Box::new(unit_type()), effects: EffectRow::empty() },
    });

    // Pre-register all enum declarations so FnDecl bodies (which may appear
    // before the EnumDecl in sem_root_stmts after monomorphization) can find
    // variant types during pattern match arm binding.
    for &stmt_id in &ast.sem_root_stmts {
        if let Some(RuntimeStmt::EnumDecl { name, variants, .. }) = ast.get_stmt(stmt_id) {
            env.register_enum(name, variants.clone());
        }
    }
    hoist_fn_types(ast, &ast.sem_root_stmts, env, &mut subst);
    for &stmt_id in &ast.sem_root_stmts.clone() {
        infer_stmt(ast, stmt_id, env, &mut subst, &mut ctx, &mut type_map)?;
    }

    // Apply the final substitution so callers see concrete types, not raw type vars.
    let mut resolved: HashMap<RuntimeNodeId, Type> = type_map.into_iter()
        .map(|(id, ty)| (id, ty.apply(&subst)))
        .collect();

    // Populate FnDecl entries: store a fully-concrete call-site signature under
    // each FnDecl's stmt_id so codegen can read resolved param kinds without
    // scanning the AST itself.
    //
    // For genuinely polymorphic functions called with multiple distinct concrete
    // types, we warn and keep the first concrete call site.  Proper
    // monomorphization would produce separate FnDecl nodes eliminating this
    // ambiguity, but that is not yet implemented.
    //
    // Both arg types AND return type come from the call expression so that
    // monomorphized generic functions (whose FnDecl return type is still a
    // type variable) get the correct concrete return type.
    let mut fn_call_types: HashMap<String, (Vec<Type>, Type)> = HashMap::new();
    for (&expr_id, expr) in &ast.exprs {
        if let RuntimeExpr::Call { callee, args } = expr {
            let arg_types: Vec<Type> = args.iter()
                .map(|&id| resolved.get(&id).cloned().unwrap_or_else(|| Type::Var(env.fresh())))
                .collect();
            if !arg_types.iter().all(|t| !matches!(t, Type::Var(_))) {
                continue; // skip call sites with unresolved args
            }
            let ret_type = resolved.get(&expr_id).cloned().unwrap_or_else(|| Type::Var(env.fresh()));
            let new_concrete = arg_types.iter().all(|t| !t.contains_var());
            // Skip stdlib functions — they may be polymorphic by design.
            if ast.stdlib_fn_names.contains(callee.as_str()) {
                continue;
            }
            if let Some((existing_args, existing_ret)) = fn_call_types.get(callee.as_str()).cloned() {
                let existing_len = existing_args.len();
                if existing_len != arg_types.len() {
                    // Different arity — genuinely polymorphic.
                    warnings.push(TypeError::polymorphic_call(callee.clone()));
                } else if existing_args != arg_types {
                    let existing_concrete = existing_args.iter().all(|t| !t.contains_var());
                    if !existing_concrete && new_concrete {
                        // New call site has more specific types — replace.
                        fn_call_types.insert(callee.clone(), (arg_types, ret_type));
                    } else if existing_concrete && !new_concrete {
                        // Existing is more specific — keep it, no warning.
                    } else if existing_concrete {
                        // Both fully concrete but different — genuinely polymorphic.
                        warnings.push(TypeError::polymorphic_call(callee.clone()));
                    }
                    // If neither is fully concrete, keep existing (best effort).
                }
                let _ = (existing_ret, existing_len); // suppress unused warnings
            } else {
                fn_call_types.insert(callee.clone(), (arg_types, ret_type));
            }
        }
    }
    // Apply fn_call_types to all FnDecls — including those nested in Block stmts (impl methods).
    fn apply_call_types(
        ast: &RuntimeAst,
        ids: &[RuntimeNodeId],
        fn_call_types: &mut HashMap<String, (Vec<Type>, Type)>,
        resolved: &mut HashMap<RuntimeNodeId, Type>,
    ) {
        for &stmt_id in ids {
            match ast.get_stmt(stmt_id) {
                Some(RuntimeStmt::FnDecl { name, .. }) => {
                    if let Some((arg_types, call_ret)) = fn_call_types.remove(name) {
                        let existing_param_count = resolved.get(&stmt_id)
                            .and_then(|t| if let Type::Func { params, .. } = t { Some(params.len()) } else { None })
                            .unwrap_or(0);
                        if arg_types.len() < existing_param_count {
                            continue;
                        }
                        let inferred_ret = resolved.get(&stmt_id)
                            .and_then(|t| if let Type::Func { ret, .. } = t { Some(*ret.clone()) } else { None });
                        let ret = match inferred_ret {
                            Some(r) if !matches!(r, Type::Var(_)) => r,
                            _ => call_ret,
                        };
                        resolved.insert(stmt_id, Type::Func {
                            params: arg_types,
                            ret: Box::new(ret),
                            effects: EffectRow::empty(),
                        });
                    }
                }
                Some(RuntimeStmt::Block(children)) => {
                    let children = children.clone();
                    apply_call_types(ast, &children, fn_call_types, resolved);
                }
                _ => {}
            }
        }
    }
    apply_call_types(ast, &ast.sem_root_stmts.clone(), &mut fn_call_types, &mut resolved);

    Ok(resolved)
}

/// Pre-register all FnDecl and EffectDecl operation types in a stmt list so
/// forward calls type-check (including effect ops called inside __handle_N bodies).
fn hoist_fn_types(
    ast: &RuntimeAst,
    stmts: &[RuntimeNodeId],
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
) {
    for &stmt_id in stmts {
        match ast.get_stmt(stmt_id) {
            Some(RuntimeStmt::FnDecl { name, params, .. }) => {
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
            Some(RuntimeStmt::EffectDecl { ops, .. }) => {
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
            _ => {}
        }
    }
}

fn infer_expr(
    ast: &RuntimeAst,
    expr_id: RuntimeNodeId,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    type_map: &mut HashMap<RuntimeNodeId, Type>,
) -> Result<Type, TypeError> {
    let expr = ast.get_expr(expr_id).ok_or_else(|| TypeError::unsupported())?.clone();
    let ty = match expr {
        RuntimeExpr::Int(_) => int_type(),
        RuntimeExpr::Bool(_) => bool_type(),
        RuntimeExpr::String(_) => string_type(),

        RuntimeExpr::Variable(ref name) => {
            env.lookup(name).ok_or_else(|| TypeError::unbound_var(name.clone()))?
        }

        RuntimeExpr::Add(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            let tv = Type::Var(env.fresh());
            unify(&ta, &tv, subst)?;
            unify(&tb, &tv, subst)?;
            tv.apply(subst)
        }

        RuntimeExpr::Sub(a, b) | RuntimeExpr::Mult(a, b) | RuntimeExpr::Div(a, b) | RuntimeExpr::Mod(a, b) => {
            let ta = infer_expr(ast, a, env, subst, type_map)?;
            let tb = infer_expr(ast, b, env, subst, type_map)?;
            match (ta.apply(subst), tb.apply(subst)) {
                (Type::Struct { .. }, _) | (_, Type::Struct { .. }) => {
                    // Struct operand → operator dispatch (e.g. `impl Mul for Vec2`).
                    // The dispatch function is resolved by the interpreter/codegen at
                    // call time; leave the result as a fresh type var.
                    Type::Var(env.fresh())
                }
                _ => {
                    // Standard arithmetic: both operands must be int.
                    unify(&ta, &int_type(), subst)?;
                    unify(&tb, &int_type(), subst)?;
                    int_type()
                }
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
            obj_ty.apply(subst)
        }

        RuntimeExpr::Call { ref callee, ref args } => {
            let callee_ty = env
                .lookup(callee)
                .ok_or_else(|| TypeError::unbound_var(callee.clone()))?;
            let mut arg_types = Vec::new();
            for &arg_id in args {
                arg_types.push(infer_expr(ast, arg_id, env, subst, type_map)?);
            }
            let ret_tv = Type::Var(env.fresh());
            let expected_fn = Type::Func {
                params: arg_types.clone(),
                ret: Box::new(ret_tv.clone()),
                effects: EffectRow::empty(),
            };
            // If unification fails with >1 args, check whether the failure is a
            // CPS-injected continuation (last arg is a Lambda or a __k_* Variable)
            // or a genuine arity error. The CPS transform appends either an inline
            // Lambda continuation or the enclosing function's __k_N parameter when
            // the ctl call is in tail position (`return ctl_op(args, __k_N)`).
            // When unification fails with exactly 1 arg, fall through silently —
            // polymorphic recursive calls (e.g. in GADTs) currently rely on this
            // leniency until full polymorphic type-checking is implemented.
            if unify(&callee_ty, &expected_fn, subst).is_err() && arg_types.len() > 1 {
                let last_is_lambda = args.last()
                    .and_then(|&id| ast.get_expr(id))
                    .map(|e| matches!(e, RuntimeExpr::Lambda { .. })
                        || matches!(e, RuntimeExpr::Variable(n) if n.starts_with("__k")))
                    .unwrap_or(false);
                if last_is_lambda {
                    let trimmed = Type::Func {
                        params: arg_types[..arg_types.len() - 1].to_vec(),
                        ret: Box::new(ret_tv.clone()),
                        effects: EffectRow::empty(),
                    };
                    unify(&callee_ty, &trimmed, subst)?;
                } else {
                    return Err(TypeError::type_mismatch(callee_ty, expected_fn));
                }
            }
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

        RuntimeExpr::DotAccess { object, field } => {
            let obj_ty = infer_expr(ast, object, env, subst, type_map)?;
            match obj_ty.apply(subst) {
                Type::Struct { fields, .. } => {
                    // Object type is known — return the field's concrete type.
                    fields.get(field.as_str()).cloned().unwrap_or_else(|| Type::Var(env.fresh()))
                }
                _ => {
                    // Object type is still a variable (e.g. a function param whose
                    // concrete type is only known at call sites).  Return a fresh
                    // variable; the caller does not need this type for codegen.
                    Type::Var(env.fresh())
                }
            }
        }

        RuntimeExpr::DotCall { object, ref args, .. } => {
            // If the object is a module-qualified access (e.g. `peer.run()`), the object
            // variable may not be in scope as a regular variable. Treat lookup failures
            // here as a module reference and continue with a fresh TypeVar.
            let _ = infer_expr(ast, object, env, subst, type_map);
            for &arg_id in args {
                infer_expr(ast, arg_id, env, subst, type_map)?;
            }
            Type::Var(env.fresh())
        }

        RuntimeExpr::Index { object, index } => {
            let obj_ty = infer_expr(ast, object, env, subst, type_map)?;
            infer_expr(ast, index, env, subst, type_map)?;
            // Derive element type from the slice type.
            // For Var objects (generic params), unify with Slice(elem_var) so the element
            // type is tracked — this lets functions like `first<T>(list) { return list[0] }`
            // infer return type as T when T=String at the call site.
            match obj_ty.apply(subst) {
                Type::Slice(elem) => *elem,
                Type::Var(_) => {
                    let elem_tv = Type::Var(env.fresh());
                    let slice_ty = Type::Slice(Box::new(elem_tv.clone()));
                    let _ = unify(&obj_ty.apply(subst), &slice_ty, subst);
                    elem_tv.apply(subst)
                }
                _ => Type::Var(env.fresh()),
            }
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
                Type::Var(_) => {
                    // Object type is unknown (e.g. a generic param `pair`).
                    // Unify it with a Tuple containing at least index+1 fresh vars so
                    // that other accesses on the same variable share element type vars.
                    // This produces the correct scheme for functions like `swap(pair) { return (pair.1, pair.0) }`.
                    let elem_tvs: Vec<Type> = (0..=index).map(|_| Type::Var(env.fresh())).collect();
                    let tuple_ty = Type::Tuple(elem_tvs.clone());
                    let _ = unify(&obj_ty.apply(subst), &tuple_ty, subst);
                    elem_tvs[index].apply(subst)
                }
                _ => Type::Var(env.fresh()),
            }
        }

        RuntimeExpr::Unit => unit_type(),

        RuntimeExpr::Lambda { params, body } => {
            env.push_scope();
            let hints = ast.lambda_param_hints.get(&expr_id);
            let param_types: Vec<Type> = params.iter().enumerate().map(|(i, _)| {
                hints.and_then(|h| h.get(i)).and_then(|h| h.as_deref())
                    .map(|name| hint_to_type(name))
                    .unwrap_or_else(|| Type::Var(env.fresh()))
            }).collect();
            for (name, ty) in params.iter().zip(&param_types) {
                env.bind_mono(name, ty.clone());
            }
            // Infer body to constrain param types via usage (e.g. `x * 2` → x is int)
            let mut lambda_ctx = CheckCtx::new();
            let _ = infer_stmt(ast, body, env, subst, &mut lambda_ctx, type_map);
            env.pop_scope();
            let resolved_params: Vec<Type> = param_types.iter().map(|t| t.apply(subst)).collect();
            let ret_tv = env.fresh();
            Type::Func {
                params: resolved_params,
                ret: Box::new(Type::Var(ret_tv)),
                effects: EffectRow::empty(),
            }
        }

        RuntimeExpr::EnumConstructor { ref enum_name, ref variant, ref payload } => {
            match payload {
                RuntimeConstructorPayload::Tuple(ids) => {
                    for &id in ids {
                        infer_expr(ast, id, env, subst, type_map)?;
                    }
                }
                RuntimeConstructorPayload::Struct(fields) => {
                    for (_, id) in fields {
                        infer_expr(ast, *id, env, subst, type_map)?;
                    }
                }
                RuntimeConstructorPayload::Unit => {}
            }
            if let Some(variants) = env.lookup_enum(enum_name).cloned() {
                if let Some(v) = variants.iter().find(|v| v.name == *variant) {
                    if let Some(ret_te) = &v.return_type {
                        let local_map: HashMap<String, Type> = v.local_type_params.iter()
                            .map(|ltp| (ltp.clone(), Type::Var(env.fresh())))
                            .collect();
                        return Ok(meta_type_expr_to_type(ret_te, &local_map, env));
                    }
                }
            }
            Type::Enum(enum_name.clone())
        }

        RuntimeExpr::ResumeExpr(opt_id) => {
            if let Some(id) = opt_id {
                infer_expr(ast, id, env, subst, type_map)?;
            }
            Type::Var(env.fresh())
        }
    };
    type_map.insert(expr_id, ty.clone());
    Ok(ty)
}

fn infer_stmt(
    ast: &RuntimeAst,
    stmt_id: RuntimeNodeId,
    env: &mut TypeEnv,
    subst: &mut TypeSubst,
    ctx: &mut CheckCtx,
    type_map: &mut HashMap<RuntimeNodeId, Type>,
) -> Result<(), TypeError> {
    let stmt = ast.get_stmt(stmt_id).ok_or_else(|| TypeError::unsupported())?.clone();
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
                return Err(TypeError::unbound_var(name.clone()));
            }
        }

        RuntimeStmt::IndexAssign { indices, expr, .. } => {
            for idx in indices {
                infer_expr(ast, idx, env, subst, type_map)?;
            }
            infer_expr(ast, expr, env, subst, type_map)?;
        }

        RuntimeStmt::DotAssign { expr, .. } => {
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
            let resolved_fn_type = fn_type.apply(subst);
            type_map.insert(stmt_id, resolved_fn_type.clone());
            let scheme = generalize(env, resolved_fn_type);
            env.bind(&name, scheme);
        }

        RuntimeStmt::Return(opt_expr) => {
            let ty = match opt_expr {
                None => unit_type(),
                Some(expr_id) => infer_expr(ast, expr_id, env, subst, type_map)?,
            };
            if let Some(ret_ty) = ctx.return_type.as_ref() {
                if let Err(e) = unify(&ty, ret_ty, subst) {
                    if !matches!(e.kind, TypeErrorKind::Unsupported) {
                        return Err(e);
                    }
                }
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
            type_map.insert(stmt_id, elem_ty.clone());
            env.push_scope();
            match var {
                ForVar::Name(name) => env.bind_mono(name.as_str(), elem_ty),
                ForVar::Tuple(names) => {
                    let components = match &elem_ty {
                        Type::Tuple(tys) => tys.clone(),
                        _ => names.iter().map(|_| Type::Var(env.fresh())).collect(),
                    };
                    for (name, ty) in names.iter().zip(components) {
                        env.bind_mono(name.as_str(), ty);
                    }
                }
            }
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

        RuntimeStmt::EnumDecl { name, variants, .. } => {
            env.register_enum(&name, variants.clone());
        }

        RuntimeStmt::Match { scrutinee, arms } => {
            let scrutinee_ty = infer_expr(ast, scrutinee, env, subst, type_map)?;
            for arm in arms {
                let mut arm_subst = subst.clone();
                env.push_scope();
                match &arm.pattern {
                    Pattern::Wildcard => {}
                    Pattern::Enum { enum_name, variant, bindings } => {
                        let found_variant = env.lookup_enum(enum_name).cloned()
                            .and_then(|variants| variants.iter().find(|v| v.name == *variant).cloned());
                        if let Some(v) = found_variant {
                            let local_map: HashMap<String, Type> = v.local_type_params.iter()
                                .map(|ltp| (ltp.clone(), Type::Var(env.fresh())))
                                .collect();

                            if let Some(ret_te) = &v.return_type {
                                let ret_ty = meta_type_expr_to_type(ret_te, &local_map, env);
                                let _ = unify(&scrutinee_ty.apply(&arm_subst), &ret_ty, &mut arm_subst);
                            }

                            match (&v.payload, bindings) {
                                (_, VariantBindings::Unit) => {}
                                (VariantPayload::Tuple(type_exprs), VariantBindings::Tuple(names)) => {
                                    for (te, name) in type_exprs.iter().zip(names.iter()) {
                                        let ty = meta_type_expr_to_type(te, &local_map, env);
                                        env.bind_mono(name, ty);
                                    }
                                    for name in names.iter().skip(type_exprs.len()) {
                                        let tv = env.fresh();
                                        env.bind_mono(name, Type::Var(tv));
                                    }
                                }
                                (_, VariantBindings::Tuple(names)) => {
                                    for name in names {
                                        let tv = env.fresh();
                                        env.bind_mono(name, Type::Var(tv));
                                    }
                                }
                                (_, VariantBindings::Struct(names)) => {
                                    for name in names {
                                        let tv = env.fresh();
                                        env.bind_mono(name, Type::Var(tv));
                                    }
                                }
                            }
                        } else {
                            // Enum not yet registered (e.g. meta-eval incremental type check)
                            // or variant not found — bind all pattern vars with fresh type vars.
                            match bindings {
                                VariantBindings::Unit => {}
                                VariantBindings::Tuple(names) | VariantBindings::Struct(names) => {
                                    for name in names {
                                        let tv = env.fresh();
                                        env.bind_mono(name, Type::Var(tv));
                                    }
                                }
                            }
                        }
                    }
                }
                infer_stmt(ast, arm.body, env, &mut arm_subst, ctx, type_map)?;
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

        // Register the ctl op as callable + type-check handler body with __k in scope.
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
            // __k is the continuation closure — bind so Resume can type-check the body.
            let k_param_tv = Type::Var(env.fresh());
            let k_ret_tv = Type::Var(env.fresh());
            env.bind_mono("__k", Type::Func {
                params: vec![k_param_tv],
                ret: Box::new(k_ret_tv),
                effects: EffectRow::empty(),
            });
            infer_stmt(ast, body, env, subst, ctx, type_map)?;
            env.pop_scope();
        }

        RuntimeStmt::Resume(opt_expr) => {
            if let Some(expr_id) = opt_expr {
                infer_expr(ast, expr_id, env, subst, type_map)?;
            }
        }
    }
    Ok(())
}
