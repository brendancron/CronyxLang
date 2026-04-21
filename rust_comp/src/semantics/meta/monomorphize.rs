use std::collections::{HashMap, HashSet};
use crate::frontend::meta_ast::{ConstructorPayload, MatchArm};
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::types::types::{PrimitiveType, Type, TypeVar};

/// Produce a stable identifier-safe string from a type for name mangling.
fn mangle_type(ty: &Type) -> String {
    match ty {
        Type::Primitive(PrimitiveType::Int) => "int".to_string(),
        Type::Primitive(PrimitiveType::String) => "str".to_string(),
        Type::Primitive(PrimitiveType::Bool) => "bool".to_string(),
        Type::Primitive(PrimitiveType::Unit) => "unit".to_string(),
        Type::Var(TypeVar { id }) => format!("t{id}"),
        Type::Func { .. } => "fn".to_string(),
        Type::Record(fields) => {
            let keys = fields.keys().cloned().collect::<Vec<_>>().join("_");
            format!("rec_{keys}")
        }
        Type::Tuple(items) => {
            let inner = items.iter().map(mangle_type).collect::<Vec<_>>().join("_");
            format!("tuple_{inner}")
        }
        Type::Slice(elem) => format!("slice_{}", mangle_type(elem)),
        Type::Enum(name) => name.clone(),
    }
}

// ── ID-remapping clone helpers ──────────────────────────────────────────────

fn clone_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    next_id: &mut usize,
    new_stmts: &mut HashMap<usize, RuntimeStmt>,
    new_exprs: &mut HashMap<usize, RuntimeExpr>,
    stmt_map: &mut HashMap<usize, usize>,
    expr_map: &mut HashMap<usize, usize>,
) -> usize {
    if let Some(&mapped) = expr_map.get(&expr_id) {
        return mapped;
    }
    let new_id = *next_id;
    *next_id += 1;
    expr_map.insert(expr_id, new_id);

    let expr = ast.get_expr(expr_id).expect("invalid expr id during monomorphize clone").clone();

    macro_rules! ce {
        ($id:expr) => { clone_expr(ast, $id, next_id, new_stmts, new_exprs, stmt_map, expr_map) }
    }

    let new_expr = match expr {
        RuntimeExpr::Int(_) | RuntimeExpr::String(_) | RuntimeExpr::Bool(_) | RuntimeExpr::Variable(_) => expr,
        RuntimeExpr::Add(a, b) => RuntimeExpr::Add(ce!(a), ce!(b)),
        RuntimeExpr::Sub(a, b) => RuntimeExpr::Sub(ce!(a), ce!(b)),
        RuntimeExpr::Mult(a, b) => RuntimeExpr::Mult(ce!(a), ce!(b)),
        RuntimeExpr::Div(a, b) => RuntimeExpr::Div(ce!(a), ce!(b)),
        RuntimeExpr::Equals(a, b) => RuntimeExpr::Equals(ce!(a), ce!(b)),
        RuntimeExpr::NotEquals(a, b) => RuntimeExpr::NotEquals(ce!(a), ce!(b)),
        RuntimeExpr::Lt(a, b) => RuntimeExpr::Lt(ce!(a), ce!(b)),
        RuntimeExpr::Gt(a, b) => RuntimeExpr::Gt(ce!(a), ce!(b)),
        RuntimeExpr::Lte(a, b) => RuntimeExpr::Lte(ce!(a), ce!(b)),
        RuntimeExpr::Gte(a, b) => RuntimeExpr::Gte(ce!(a), ce!(b)),
        RuntimeExpr::And(a, b) => RuntimeExpr::And(ce!(a), ce!(b)),
        RuntimeExpr::Or(a, b) => RuntimeExpr::Or(ce!(a), ce!(b)),
        RuntimeExpr::Not(a) => RuntimeExpr::Not(ce!(a)),
        RuntimeExpr::List(items) => RuntimeExpr::List(items.iter().map(|&i| ce!(i)).collect()),
        RuntimeExpr::Tuple(items) => RuntimeExpr::Tuple(items.iter().map(|&i| ce!(i)).collect()),
        RuntimeExpr::TupleIndex { object, index } => RuntimeExpr::TupleIndex { object: ce!(object), index },
        RuntimeExpr::Index { object, index } => RuntimeExpr::Index { object: ce!(object), index: ce!(index) },
        RuntimeExpr::DotAccess { object, field } => RuntimeExpr::DotAccess { object: ce!(object), field },
        RuntimeExpr::DotCall { object, method, args } => RuntimeExpr::DotCall {
            object: ce!(object),
            method,
            args: args.iter().map(|&a| ce!(a)).collect(),
        },
        RuntimeExpr::Call { callee, args } => RuntimeExpr::Call {
            callee,
            args: args.iter().map(|&a| ce!(a)).collect(),
        },
        RuntimeExpr::StructLiteral { type_name, fields } => RuntimeExpr::StructLiteral {
            type_name,
            fields: fields.iter().map(|(n, id)| (n.clone(), ce!(*id))).collect(),
        },
        RuntimeExpr::EnumConstructor { enum_name, variant, payload } => RuntimeExpr::EnumConstructor {
            enum_name,
            variant,
            payload: match payload {
                ConstructorPayload::Unit => ConstructorPayload::Unit,
                ConstructorPayload::Tuple(ids) => ConstructorPayload::Tuple(ids.iter().map(|i| ce!(*i)).collect()),
                ConstructorPayload::Struct(fields) => ConstructorPayload::Struct(
                    fields.iter().map(|(n, id)| (n.clone(), ce!(*id))).collect(),
                ),
            },
        },
        RuntimeExpr::SliceRange { object, start, end } => RuntimeExpr::SliceRange {
            object: ce!(object),
            start: start.map(|s| ce!(s)),
            end: end.map(|e| ce!(e)),
        },
        RuntimeExpr::Lambda { params, body } => RuntimeExpr::Lambda {
            params,
            body: clone_stmt(ast, body, next_id, new_stmts, new_exprs, stmt_map, expr_map),
        },
        RuntimeExpr::Unit => RuntimeExpr::Unit,
    };

    new_exprs.insert(new_id, new_expr);
    new_id
}

fn clone_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    next_id: &mut usize,
    new_stmts: &mut HashMap<usize, RuntimeStmt>,
    new_exprs: &mut HashMap<usize, RuntimeExpr>,
    stmt_map: &mut HashMap<usize, usize>,
    expr_map: &mut HashMap<usize, usize>,
) -> usize {
    if let Some(&mapped) = stmt_map.get(&stmt_id) {
        return mapped;
    }
    let new_id = *next_id;
    *next_id += 1;
    stmt_map.insert(stmt_id, new_id);

    let stmt = ast.get_stmt(stmt_id).expect("invalid stmt id during monomorphize clone").clone();

    macro_rules! cs {
        ($id:expr) => { clone_stmt(ast, $id, next_id, new_stmts, new_exprs, stmt_map, expr_map) }
    }
    macro_rules! ce {
        ($id:expr) => { clone_expr(ast, $id, next_id, new_stmts, new_exprs, stmt_map, expr_map) }
    }

    let new_stmt = match stmt {
        RuntimeStmt::Block(children) => RuntimeStmt::Block(children.iter().map(|&c| cs!(c)).collect()),
        RuntimeStmt::Return(opt_e) => RuntimeStmt::Return(opt_e.map(|e| ce!(e))),
        RuntimeStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(ce!(e)),
        RuntimeStmt::Print(e) => RuntimeStmt::Print(ce!(e)),
        RuntimeStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl { name, expr: ce!(expr) },
        RuntimeStmt::Assign { name, expr } => RuntimeStmt::Assign { name, expr: ce!(expr) },
        RuntimeStmt::IndexAssign { name, indices, expr } => RuntimeStmt::IndexAssign {
            name,
            indices: indices.iter().map(|&i| ce!(i)).collect(),
            expr: ce!(expr),
        },
        RuntimeStmt::FnDecl { name, params, type_params, body } => RuntimeStmt::FnDecl {
            name,
            params,
            type_params,
            body: cs!(body),
        },
        RuntimeStmt::If { cond, body, else_branch } => RuntimeStmt::If {
            cond: ce!(cond),
            body: cs!(body),
            else_branch: else_branch.map(|e| cs!(e)),
        },
        RuntimeStmt::WhileLoop { cond, body } => RuntimeStmt::WhileLoop {
            cond: ce!(cond),
            body: cs!(body),
        },
        RuntimeStmt::ForEach { var, iterable, body } => RuntimeStmt::ForEach {
            var,
            iterable: ce!(iterable),
            body: cs!(body),
        },
        RuntimeStmt::Match { scrutinee, arms } => RuntimeStmt::Match {
            scrutinee: ce!(scrutinee),
            arms: arms.iter().map(|arm| MatchArm {
                pattern: arm.pattern.clone(),
                body: cs!(arm.body),
            }).collect(),
        },
        RuntimeStmt::Defer(inner) => RuntimeStmt::Defer(cs!(inner)),
        other => other,
    };

    new_stmts.insert(new_id, new_stmt);
    new_id
}

// ── Main monomorphization pass ───────────────────────────────────────────────

pub fn monomorphize(ast: &mut RuntimeAst, type_map: &HashMap<usize, Type>) {
    // Collect all generic functions (non-empty type_params).
    let generic_fns: HashMap<String, usize> = ast.stmts.iter()
        .filter_map(|(&id, stmt)| {
            if let RuntimeStmt::FnDecl { name, type_params, .. } = stmt {
                if !type_params.is_empty() {
                    return Some((name.clone(), id));
                }
            }
            None
        })
        .collect();

    if generic_fns.is_empty() {
        return;
    }

    // Allocate fresh IDs above the current max.
    let mut next_id = ast.stmts.keys().chain(ast.exprs.keys()).max().copied().unwrap_or(0) + 1;

    // Walk every expression in the AST to find call sites that target generic functions.
    // Collect: mangled_name → (original_fn_name, original_stmt_id)
    let mut instantiations: HashMap<String, (String, usize)> = HashMap::new();
    // Per call-site rewrite: expr_id → mangled_name
    let mut call_rewrites: HashMap<usize, String> = HashMap::new();

    for (&expr_id, expr) in &ast.exprs {
        if let RuntimeExpr::Call { callee, args } = expr {
            if let Some(&orig_stmt_id) = generic_fns.get(callee.as_str()) {
                let arg_types: Vec<Type> = args.iter()
                    .map(|&arg_id| type_map.get(&arg_id).cloned()
                         .unwrap_or(Type::Var(TypeVar { id: usize::MAX })))
                    .collect();
                let suffix = arg_types.iter().map(mangle_type).collect::<Vec<_>>().join("__");
                let mangled = format!("{callee}__{suffix}");
                instantiations.entry(mangled.clone())
                    .or_insert_with(|| (callee.clone(), orig_stmt_id));
                call_rewrites.insert(expr_id, mangled);
            }
        }
    }

    if instantiations.is_empty() {
        return;
    }

    // For each unique instantiation, clone the generic function body under the mangled name.
    let mut new_fn_stmt_ids: Vec<usize> = Vec::new();
    for (mangled_name, (_, orig_stmt_id)) in &instantiations {
        if let Some(RuntimeStmt::FnDecl { params, body, .. }) = ast.stmts.get(orig_stmt_id).cloned() {
            let mut stmt_map: HashMap<usize, usize> = HashMap::new();
            let mut expr_map: HashMap<usize, usize> = HashMap::new();
            let mut new_stmts: HashMap<usize, RuntimeStmt> = HashMap::new();
            let mut new_exprs: HashMap<usize, RuntimeExpr> = HashMap::new();

            let new_body = clone_stmt(
                ast, body, &mut next_id,
                &mut new_stmts, &mut new_exprs,
                &mut stmt_map, &mut expr_map,
            );

            let fn_id = next_id;
            next_id += 1;
            new_stmts.insert(fn_id, RuntimeStmt::FnDecl {
                name: mangled_name.clone(),
                params,
                type_params: vec![],
                body: new_body,
            });

            ast.stmts.extend(new_stmts);
            ast.exprs.extend(new_exprs);
            new_fn_stmt_ids.push(fn_id);
        }
    }

    // Rewrite every call site to use the mangled name.
    for (expr_id, mangled_name) in &call_rewrites {
        if let Some(RuntimeExpr::Call { args, .. }) = ast.exprs.get(expr_id).cloned() {
            ast.exprs.insert(*expr_id, RuntimeExpr::Call {
                callee: mangled_name.clone(),
                args,
            });
        }
    }

    // Remove the original generic FnDecl stmts — both from the map and from sem_root_stmts.
    let generic_ids: HashSet<usize> = generic_fns.values().copied().collect();
    ast.sem_root_stmts.retain(|id| !generic_ids.contains(id));
    for id in &generic_ids {
        ast.stmts.remove(id);
    }

    // Prepend the new specialised FnDecls to sem_root_stmts so the formatter shows them first.
    let mut new_roots = new_fn_stmt_ids;
    new_roots.append(&mut ast.sem_root_stmts);
    ast.sem_root_stmts = new_roots;
}
