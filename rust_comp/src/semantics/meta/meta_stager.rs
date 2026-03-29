use super::meta_process_error::*;
use super::process_dependency::*;
use super::staged_ast::*;
use super::staged_forest::*;
use crate::util::id_provider::IdProvider;
use crate::frontend::meta_ast::*;
use crate::frontend::module_loader::{FileRole, LoadedFile};
use crate::semantics::types::type_env::TypeEnv;
use crate::semantics::types::types::TypeScheme;
use std::collections::{HashMap, HashSet};

pub fn process_root(
    meta_ast: &MetaAst,
    root_stmts: Vec<usize>,
    staged_forest: &mut StagedForest,
    id_provider: &mut IdProvider,
    type_env: &TypeEnv,
) -> Result<usize, MetaProcessError> {
    let mut staged_ast = StagedAst::new();
    let mut dependency_set: HashSet<ProcessDependency> = HashSet::new();
    let mut sem_root_stmts = Vec::with_capacity(root_stmts.len());
    for stmt in root_stmts {
        let id = process_stmt(
            meta_ast,
            stmt,
            &mut staged_ast,
            id_provider,
            &mut dependency_set,
            staged_forest,
            type_env,
        )?;
        sem_root_stmts.push(id);
    }
    staged_ast.sem_root_stmts = sem_root_stmts;
    let new_ast_id = staged_forest.insert_tree(staged_ast, id_provider);
    staged_forest.insert_deps(dependency_set, new_ast_id);
    staged_forest.root_id = new_ast_id;
    Ok(new_ast_id)
}

pub fn process_expr(
    meta_ast: &MetaAst,
    meta_expr_id: usize,
    staged_ast: &mut StagedAst,
    id_provider: &mut IdProvider,
    dependency_set: &mut HashSet<ProcessDependency>,
    staged_forest: &mut StagedForest,
    type_env: &TypeEnv,
) -> Result<usize, MetaProcessError> {
    let staged_expr_id = id_provider.next();
    let meta_expr = meta_ast
        .get_expr(meta_expr_id)
        .ok_or(MetaProcessError::ExprNotFound(meta_expr_id))?;
    match meta_expr {
        MetaExpr::Int(i) => {
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Int(*i));
        }
        MetaExpr::String(s) => {
            staged_ast.insert_expr(staged_expr_id, StagedExpr::String(s.clone()));
        }
        MetaExpr::Bool(b) => {
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Bool(*b));
        }

        MetaExpr::StructLiteral { type_name, fields } => {
            let mut out_fields = Vec::with_capacity(fields.len());
            for (name, field_expr_id) in fields {
                let staged_field_id = process_expr(
                    meta_ast, *field_expr_id, staged_ast, id_provider, dependency_set, staged_forest, type_env,
                )?;
                out_fields.push((name.clone(), staged_field_id));
            }
            staged_ast.insert_expr(staged_expr_id, StagedExpr::StructLiteral {
                type_name: type_name.clone(),
                fields: out_fields,
            });
        }

        MetaExpr::Variable(name) => {
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Variable(name.clone()));
        }

        MetaExpr::List(exprs) => {
            let mut ids = Vec::with_capacity(exprs.len());
            for e in exprs {
                ids.push(process_expr(meta_ast, *e, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            staged_ast.insert_expr(staged_expr_id, StagedExpr::List(ids));
        }

        MetaExpr::Add(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Add(a_id, b_id));
        }
        MetaExpr::Sub(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Sub(a_id, b_id));
        }
        MetaExpr::Mult(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Mult(a_id, b_id));
        }
        MetaExpr::Div(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Div(a_id, b_id));
        }
        MetaExpr::Equals(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Equals(a_id, b_id));
        }
        MetaExpr::NotEquals(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::NotEquals(a_id, b_id));
        }
        MetaExpr::Lt(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Lt(a_id, b_id));
        }
        MetaExpr::Gt(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Gt(a_id, b_id));
        }
        MetaExpr::Lte(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Lte(a_id, b_id));
        }
        MetaExpr::Gte(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Gte(a_id, b_id));
        }
        MetaExpr::And(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::And(a_id, b_id));
        }
        MetaExpr::Or(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Or(a_id, b_id));
        }
        MetaExpr::Not(a) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Not(a_id));
        }

        MetaExpr::Call { callee, args } => {
            let mut out_args = Vec::with_capacity(args.len());
            for meta_arg in args {
                out_args.push(process_expr(meta_ast, *meta_arg, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Call {
                callee: callee.clone(),
                args: out_args,
            });
        }

        MetaExpr::Typeof(ident) => {
            let type_str = type_env.get_type(ident)
                .map(|scheme| match scheme {
                    TypeScheme::MonoType(ty) => ty.to_string(),
                    TypeScheme::PolyType { ty, .. } => ty.to_string(),
                })
                .unwrap_or_else(|| format!("unknown({})", ident));
            staged_ast.insert_expr(staged_expr_id, StagedExpr::String(type_str));
        }

        MetaExpr::DotAccess { object, field } => {
            let obj_id = process_expr(meta_ast, *object, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::DotAccess { object: obj_id, field: field.clone() });
        }

        MetaExpr::DotCall { object, method, args } => {
            let obj_id = process_expr(meta_ast, *object, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let mut out_args = Vec::with_capacity(args.len());
            for arg in args {
                out_args.push(process_expr(meta_ast, *arg, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            staged_ast.insert_expr(staged_expr_id, StagedExpr::DotCall { object: obj_id, method: method.clone(), args: out_args });
        }

        MetaExpr::Index { object, index } => {
            let obj_id = process_expr(meta_ast, *object, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let idx_id = process_expr(meta_ast, *index, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::Index { object: obj_id, index: idx_id });
        }

        MetaExpr::EnumConstructor { enum_name, variant, payload } => {
            let staged_payload = match payload {
                ConstructorPayload::Unit => ConstructorPayload::Unit,
                ConstructorPayload::Tuple(exprs) => {
                    let mut ids = Vec::new();
                    for e in exprs {
                        ids.push(process_expr(meta_ast, *e, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
                    }
                    ConstructorPayload::Tuple(ids)
                }
                ConstructorPayload::Struct(fields) => {
                    let mut out = Vec::new();
                    for (name, e) in fields {
                        let id = process_expr(meta_ast, *e, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
                        out.push((name.clone(), id));
                    }
                    ConstructorPayload::Struct(out)
                }
            };
            staged_ast.insert_expr(staged_expr_id, StagedExpr::EnumConstructor {
                enum_name: enum_name.clone(),
                variant: variant.clone(),
                payload: staged_payload,
            });
        }

        MetaExpr::Embed(file_path) => {
            let resolved = if let Some(dir) = &staged_forest.source_dir {
                dir.join(file_path)
            } else {
                std::path::PathBuf::from(file_path)
            };
            let contents = std::fs::read_to_string(&resolved)
                .map_err(|e| MetaProcessError::EmbedFailed { path: file_path.clone(), error: e.to_string() })?;
            staged_ast.insert_expr(staged_expr_id, StagedExpr::String(contents));
        }
    };
    Ok(staged_expr_id)
}

pub fn process_stmt(
    meta_ast: &MetaAst,
    meta_stmt_id: usize,
    staged_ast: &mut StagedAst,
    id_provider: &mut IdProvider,
    dependency_set: &mut HashSet<ProcessDependency>,
    staged_forest: &mut StagedForest,
    type_env: &TypeEnv,
) -> Result<usize, MetaProcessError> {
    let staged_stmt_id = id_provider.next();
    let meta_stmt = meta_ast
        .get_stmt(meta_stmt_id)
        .ok_or(MetaProcessError::StmtNotFound(meta_stmt_id))?;
    match meta_stmt {
        MetaStmt::ExprStmt(expr) => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::ExprStmt(expr_id));
        }

        MetaStmt::VarDecl { name, expr, .. } => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::VarDecl {
                name: name.clone(),
                expr: expr_id,
            });
        }

        MetaStmt::Assign { name, expr } => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Assign {
                name: name.clone(),
                expr: expr_id,
            });
        }

        MetaStmt::IndexAssign { name, indices, expr } => {
            let mut idx_ids = Vec::new();
            for idx in indices {
                idx_ids.push(process_expr(meta_ast, *idx, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::IndexAssign {
                name: name.clone(),
                indices: idx_ids,
                expr: expr_id,
            });
        }

        MetaStmt::Print(expr) => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Print(expr_id));
        }

        MetaStmt::If { cond, body, else_branch } => {
            let cond_id = process_expr(meta_ast, *cond, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let else_id = else_branch
                .as_ref()
                .map(|s| process_stmt(meta_ast, *s, staged_ast, id_provider, dependency_set, staged_forest, type_env))
                .transpose()?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::If {
                cond: cond_id,
                body: body_id,
                else_branch: else_id,
            });
        }

        MetaStmt::WhileLoop { cond, body } => {
            let cond_id = process_expr(meta_ast, *cond, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::WhileLoop {
                cond: cond_id,
                body: body_id,
            });
        }

        MetaStmt::ForEach { var, iterable, body } => {
            let iterable_id = process_expr(meta_ast, *iterable, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::ForEach {
                var: var.clone(),
                iterable: iterable_id,
                body: body_id,
            });
        }

        MetaStmt::Block(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());
            for meta_stmt in stmts {
                children.push(process_stmt(meta_ast, *meta_stmt, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Block(children));
        }

        MetaStmt::FnDecl { name, params, body }
        | MetaStmt::MetaFnDecl { name, params, body } => {
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::FnDecl {
                name: name.clone(),
                params: params.iter().map(|p| p.name.clone()).collect(),
                body: body_id,
            });
        }

        MetaStmt::StructDecl { .. } => {}

        MetaStmt::EnumDecl { name, variants } => {
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::EnumDecl {
                name: name.clone(),
                variants: variants.clone(),
            });
        }

        MetaStmt::Match { scrutinee, arms } => {
            let scrutinee_id = process_expr(meta_ast, *scrutinee, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            let mut staged_arms = Vec::new();
            for arm in arms {
                let body_id = process_stmt(meta_ast, arm.body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
                staged_arms.push(MatchArm { pattern: arm.pattern.clone(), body: body_id });
            }
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Match {
                scrutinee: scrutinee_id,
                arms: staged_arms,
            });
        }

        MetaStmt::Return(expr) => {
            let expr_id = expr
                .map(|e| process_expr(meta_ast, e, staged_ast, id_provider, dependency_set, staged_forest, type_env))
                .transpose()?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Return(expr_id));
        }

        MetaStmt::Gen(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());
            for s in stmts {
                children.push(process_stmt(meta_ast, *s, staged_ast, id_provider, dependency_set, staged_forest, type_env)?);
            }
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Gen(children));
        }

        MetaStmt::MetaBlock(parsed_stmt) => {
            let ast_id = process_root(
                meta_ast,
                vec![*parsed_stmt],
                staged_forest,
                id_provider,
                type_env,
            )?;
            dependency_set.insert(ProcessDependency::MetaTree(ast_id));
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::MetaStmt(MetaRef { ast_ref: ast_id }));
        }

        MetaStmt::Import(decl) => {
            // Import stmts are preserved in the AST so the ID is valid at runtime.
            // Actual module namespace creation happens in setup_modules before eval.
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::Import(decl.clone()));
        }
    };
    Ok(staged_stmt_id)
}

/// Stage all files from a multi-file compilation unit into a single StagedForest.
///
/// - Entry file: all statements staged normally.
/// - AutoScope / Explicit files: only FnDecl, StructDecl, and MetaBlock statements staged;
///   their functions are merged into the root tree so they are available at runtime.
///
/// Module bindings (namespace records for explicit imports) are stored in
/// `staged_forest.module_bindings` for use during runtime setup.
pub fn stage_all_files(
    files: &[LoadedFile],
    staged_forest: &mut StagedForest,
    id_provider: &mut IdProvider,
    type_env: &TypeEnv,
) -> Result<usize, MetaProcessError> {
    let entry = files
        .iter()
        .find(|f| matches!(f.role, FileRole::Entry))
        .expect("stage_all_files: no entry file in compilation unit");

    let mut staged_ast = StagedAst::new();
    let mut dependency_set: HashSet<ProcessDependency> = HashSet::new();
    let mut sem_root_stmts: Vec<usize> = Vec::new();

    // Build a map from path stem → exports for every file (used for transitive bindings).
    let mut exports_by_stem: HashMap<String, Vec<String>> = HashMap::new();
    for file in files {
        let stem = file.path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        let exports: Vec<String> = file.ast.sem_root_stmts.iter()
            .filter_map(|&id| match file.ast.get_stmt(id) {
                Some(MetaStmt::FnDecl { name, .. }) => Some(name.clone()),
                Some(MetaStmt::MetaFnDecl { name, .. }) => Some(name.clone()),
                Some(MetaStmt::StructDecl { name, .. }) => Some(name.clone()),
                _ => None,
            })
            .collect();
        exports_by_stem.insert(stem, exports);
    }

    // Stage non-entry files first (their decls become part of the root tree).
    for file in files {
        if matches!(file.role, FileRole::Entry) {
            continue;
        }

        // Collect exported names from the MetaAst top-level decls.
        let mut export_names: Vec<String> = Vec::new();
        for &stmt_id in &file.ast.sem_root_stmts {
            match file.ast.get_stmt(stmt_id) {
                Some(MetaStmt::FnDecl { name, .. }) => export_names.push(name.clone()),
                Some(MetaStmt::MetaFnDecl { name, .. }) => export_names.push(name.clone()),
                Some(MetaStmt::StructDecl { name, .. }) => export_names.push(name.clone()),
                _ => {}
            }
        }

        // Stage exportable statements into the shared root tree.
        for &stmt_id in &file.ast.sem_root_stmts {
            if !is_exportable_stmt(&file.ast, stmt_id) {
                continue;
            }
            let staged_id = process_stmt(
                &file.ast, stmt_id,
                &mut staged_ast, id_provider,
                &mut dependency_set, staged_forest, type_env,
            )?;
            sem_root_stmts.push(staged_id);
        }

        // Record module binding for explicit imports.
        if let FileRole::Explicit(ref decl) = file.role {
            let binding = match decl {
                ImportDecl::Qualified { path } => {
                    let bind_name = path_stem(path);
                    ModuleBinding::Namespace { bind_name, exports: export_names }
                }
                ImportDecl::Aliased { alias, .. } => {
                    ModuleBinding::Namespace { bind_name: alias.clone(), exports: export_names }
                }
                ImportDecl::Selective { names, .. } => {
                    ModuleBinding::Selective { names: names.clone() }
                }
            };
            staged_forest.module_bindings.push(binding);
        }
    }

    // Scan non-entry file ASTs for imports that weren't directly recorded above
    // (e.g. circular imports where peer.cx imports the entry file).
    let bound_names: HashSet<String> = staged_forest.module_bindings.iter()
        .filter_map(|b| match b {
            ModuleBinding::Namespace { bind_name, .. } => Some(bind_name.clone()),
            _ => None,
        })
        .collect();
    let mut extra_bindings: Vec<ModuleBinding> = Vec::new();
    let mut already_bound = bound_names;
    for file in files {
        if matches!(file.role, FileRole::Entry) {
            continue;
        }
        for &stmt_id in &file.ast.sem_root_stmts {
            if let Some(MetaStmt::Import(decl)) = file.ast.get_stmt(stmt_id) {
                let bind_name = match decl {
                    ImportDecl::Qualified { path } => path_stem(path),
                    ImportDecl::Aliased { alias, .. } => alias.clone(),
                    ImportDecl::Selective { .. } => continue,
                };
                if !already_bound.contains(&bind_name) {
                    if let Some(exports) = exports_by_stem.get(&bind_name) {
                        extra_bindings.push(ModuleBinding::Namespace {
                            bind_name: bind_name.clone(),
                            exports: exports.clone(),
                        });
                        already_bound.insert(bind_name);
                    }
                }
            }
        }
    }
    staged_forest.module_bindings.extend(extra_bindings);

    // Stage entry file statements.
    for &stmt_id in &entry.ast.sem_root_stmts {
        let staged_id = process_stmt(
            &entry.ast, stmt_id,
            &mut staged_ast, id_provider,
            &mut dependency_set, staged_forest, type_env,
        )?;
        sem_root_stmts.push(staged_id);
    }

    staged_ast.sem_root_stmts = sem_root_stmts;
    let root_id = staged_forest.insert_tree(staged_ast, id_provider);
    staged_forest.insert_deps(dependency_set, root_id);
    staged_forest.root_id = root_id;

    Ok(root_id)
}

fn is_exportable_stmt(ast: &MetaAst, stmt_id: usize) -> bool {
    matches!(
        ast.get_stmt(stmt_id),
        Some(MetaStmt::FnDecl { .. })
            | Some(MetaStmt::MetaFnDecl { .. })
            | Some(MetaStmt::StructDecl { .. })
            | Some(MetaStmt::MetaBlock(_))
    )
}

/// Extract the file-stem from an import path string.
/// "util" → "util", "util.cx" → "util", "dir/util" → "util"
fn path_stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.strip_suffix(".cx").unwrap_or(name).to_string()
}
