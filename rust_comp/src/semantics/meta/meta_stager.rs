use super::meta_process_error::*;
use super::process_dependency::*;
use super::staged_ast::*;
use super::staged_forest::*;
use crate::frontend::id_provider::IdProvider;
use crate::frontend::meta_ast::*;
use crate::semantics::types::type_env::TypeEnv;
use crate::semantics::types::types::TypeScheme;
use std::collections::HashSet;

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

        MetaStmt::VarDecl { name, expr } => {
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

        MetaStmt::FnDecl { name, params, body } => {
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider, dependency_set, staged_forest, type_env)?;
            staged_ast.insert_stmt(staged_stmt_id, StagedStmt::FnDecl {
                name: name.clone(),
                params: params.clone(),
                body: body_id,
            });
        }

        MetaStmt::StructDecl { .. } => {}

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

        MetaStmt::Import(_mod_name) => {}
    };
    Ok(staged_stmt_id)
}
