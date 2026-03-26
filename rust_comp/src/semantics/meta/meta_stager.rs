use super::meta_process_error::*;
use super::process_dependency::*;
use super::staged_ast::*;
use super::staged_forest::*;
use crate::frontend::id_provider::IdProvider;
use crate::frontend::meta_ast::*;
use std::collections::HashSet;

pub fn process_root(
    meta_ast: &MetaAst,
    root_stmts: Vec<usize>,
    staged_forest: &mut StagedForest,
    staged_forest_id_provider: &mut IdProvider,
) -> Result<usize, MetaProcessError> {
    let mut staged_ast = StagedAst::new();
    let mut dependency_set: HashSet<ProcessDependency> = HashSet::new();
    let mut ast_id_provider = IdProvider::new();
    let mut sem_root_stmts = Vec::with_capacity(root_stmts.len());
    for stmt in root_stmts {
        let id = process_stmt(
            meta_ast,
            stmt,
            &mut staged_ast,
            &mut ast_id_provider,
            &mut dependency_set,
            staged_forest,
            staged_forest_id_provider,
        )?;
        sem_root_stmts.push(id);
    }
    staged_ast.sem_root_stmts = sem_root_stmts;
    let new_ast_id = staged_forest.insert_tree(staged_ast, staged_forest_id_provider);
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
    staged_forest_id_provider: &mut IdProvider,
) -> Result<usize, MetaProcessError> {
    let staged_expr_id = id_provider.next();
    let meta_expr = meta_ast
        .get_expr(meta_expr_id)
        .ok_or(MetaProcessError::ExprNotFound(meta_expr_id))?;
    match meta_expr {
        MetaExpr::Int(i) => {
            let expr = StagedExpr::Int(*i);
            staged_ast.insert_expr(staged_expr_id, expr);
        }
        MetaExpr::String(s) => {
            let expr = StagedExpr::String(s.clone());
            staged_ast.insert_expr(staged_expr_id, expr);
        }
        MetaExpr::Bool(b) => {
            let expr = StagedExpr::Bool(*b);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::StructLiteral { type_name, fields } => {
            //let mut out_fields = Vec::with_capacity(fields.len());

            //for (name, meta_expr_id) in fields {
            //let expr_id = id_provider.next();
            //let field_expr_id = work_queue.queue_expr(id_provider, *meta_expr_id);
            //out_fields.push((name.clone(), field_expr_id));
            //}

            //let expr = StagedExpr::StructLiteral {
            //type_name: type_name.clone(),
            //fields: out_fields,
            //};

            //runtime_ast.insert_expr(staged_expr_id, expr);
        }

        //MetaExpr::Variable(name) => match ctx.env.borrow().get(name) {
        //    Some(x) => value_to_literal(x, ctx),
        //    None => Ok(StagedExpr::Variable(name.clone())),
        //},
        //TODO replace the value to lit inlining
        MetaExpr::Variable(name) => {
            let expr = StagedExpr::Variable(name.clone());
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::List(exprs) => {
            let mut ids = Vec::with_capacity(exprs.len());
            for e in exprs {
                let id = process_expr(
                    meta_ast,
                    *e,
                    staged_ast,
                    id_provider,
                    dependency_set,
                    staged_forest,
                    staged_forest_id_provider,
                )?;
                ids.push(id);
            }

            let expr = StagedExpr::List(ids.clone());
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Add(a, b) => {
            let a_id = process_expr(
                meta_ast,
                *a,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let b_id = process_expr(
                meta_ast,
                *b,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let expr = StagedExpr::Add(a_id, b_id);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Sub(a, b) => {
            let a_id = process_expr(
                meta_ast,
                *a,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let b_id = process_expr(
                meta_ast,
                *b,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let expr = StagedExpr::Sub(a_id, b_id);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Mult(a, b) => {
            let a_id = process_expr(
                meta_ast,
                *a,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let b_id = process_expr(
                meta_ast,
                *b,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let expr = StagedExpr::Mult(a_id, b_id);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Div(a, b) => {
            let a_id = process_expr(
                meta_ast,
                *a,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let b_id = process_expr(
                meta_ast,
                *b,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let expr = StagedExpr::Div(a_id, b_id);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Equals(a, b) => {
            let a_id = process_expr(
                meta_ast,
                *a,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let b_id = process_expr(
                meta_ast,
                *b,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let expr = StagedExpr::Equals(a_id, b_id);
            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Call { callee, args } => {
            let mut out_args = Vec::with_capacity(args.len());

            for meta_arg in args {
                let arg_id = process_expr(
                    meta_ast,
                    *meta_arg,
                    staged_ast,
                    id_provider,
                    dependency_set,
                    staged_forest,
                    staged_forest_id_provider,
                )?;
                out_args.push(arg_id);
            }

            let expr = StagedExpr::Call {
                callee: callee.clone(),
                args: out_args.clone(),
            };

            staged_ast.insert_expr(staged_expr_id, expr);
        }

        MetaExpr::Typeof(ident) => {
            let type_expr = StagedExpr::String(ident.clone());
            staged_ast.insert_expr(staged_expr_id, type_expr);
        }

        MetaExpr::Embed(file_path) => {
            let expr = StagedExpr::String(file_path.clone());
            staged_ast.insert_expr(staged_expr_id, expr);
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
    staged_forest_id_provider: &mut IdProvider,
) -> Result<usize, MetaProcessError> {
    let staged_stmt_id = id_provider.next();
    let meta_stmt = meta_ast
        .get_stmt(meta_stmt_id)
        .ok_or(MetaProcessError::StmtNotFound(meta_stmt_id))?;
    match meta_stmt {
        MetaStmt::ExprStmt(expr) => {
            let expr_id = process_expr(
                meta_ast,
                *expr,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let stmt = StagedStmt::ExprStmt(expr_id);
            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::VarDecl { name, expr } => {
            let expr_id = process_expr(
                meta_ast,
                *expr,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let stmt = StagedStmt::VarDecl {
                name: name.clone(),
                expr: expr_id,
            };
            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::Print(expr) => {
            let expr_id = process_expr(
                meta_ast,
                *expr,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let stmt = StagedStmt::Print(expr_id);
            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::If {
            cond,
            body,
            else_branch,
        } => {
            let cond_id = process_expr(
                meta_ast,
                *cond,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let body_id = process_stmt(
                meta_ast,
                *body,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;

            let else_id = else_branch
                .as_ref()
                .map(|s| {
                    process_stmt(
                        meta_ast,
                        *s,
                        staged_ast,
                        id_provider,
                        dependency_set,
                        staged_forest,
                        staged_forest_id_provider,
                    )
                })
                .transpose()?;

            let stmt = StagedStmt::If {
                cond: cond_id,
                body: body_id,
                else_branch: else_id,
            };

            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::ForEach {
            var,
            iterable,
            body,
        } => {
            let iterable_id = process_expr(
                meta_ast,
                *iterable,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let body_id = process_stmt(
                meta_ast,
                *body,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;
            let stmt = StagedStmt::ForEach {
                var: var.clone(),
                iterable: iterable_id,
                body: body_id,
            };

            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::Block(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());

            for meta_stmt in stmts {
                let stmt_id = process_stmt(
                    meta_ast,
                    *meta_stmt,
                    staged_ast,
                    id_provider,
                    dependency_set,
                    staged_forest,
                    staged_forest_id_provider,
                )?;
                children.push(stmt_id);
            }

            let stmt = StagedStmt::Block(children.clone());

            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::FnDecl { name, params, body } => {
            let body_id = process_stmt(
                meta_ast,
                *body,
                staged_ast,
                id_provider,
                dependency_set,
                staged_forest,
                staged_forest_id_provider,
            )?;

            let stmt = StagedStmt::FnDecl {
                name: name.clone(),
                params: params.clone(),
                body: body_id,
            };

            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::StructDecl { name, fields } => {
            //ctx.decls.define_struct(
            //    name.clone(),
            //    StructDef {
            //        fields: fields.clone(),
            //    },
            //);
        }

        MetaStmt::Return(expr) => {
            let expr_id = expr
                .map(|e| {
                    process_expr(
                        meta_ast,
                        e,
                        staged_ast,
                        id_provider,
                        dependency_set,
                        staged_forest,
                        staged_forest_id_provider,
                    )
                })
                .transpose()?;

            let stmt = StagedStmt::Return(expr_id);

            let mut children = Vec::new();
            if let Some(id) = expr_id {
                children.push(id);
            }

            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::Gen(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());

            for s in stmts {
                let id = process_stmt(
                    meta_ast,
                    *s,
                    staged_ast,
                    id_provider,
                    dependency_set,
                    staged_forest,
                    staged_forest_id_provider,
                )?;
                children.push(id);
            }

            let stmt = StagedStmt::Gen(children);
            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::MetaBlock(parsed_stmt) => {
            // meta blocks spawn a new inner ast and associate it with the given id
            let ast_id = process_root(
                meta_ast,
                vec![*parsed_stmt],
                staged_forest,
                staged_forest_id_provider,
            )?;
            dependency_set.insert(ProcessDependency::MetaTree(ast_id));
            let meta_ref = MetaRef { ast_ref: ast_id };
            let stmt = StagedStmt::MetaStmt(meta_ref);
            staged_ast.insert_stmt(staged_stmt_id, stmt);
        }

        MetaStmt::Import(_mod_name) => {}
    };
    Ok(staged_stmt_id)
}
