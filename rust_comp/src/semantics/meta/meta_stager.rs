use crate::frontend::id_provider::IdProvider;
use crate::frontend::meta_ast::*;
use crate::semantics::meta::meta_process_error::*;
use crate::semantics::meta::runtime_ast::*;
use std::collections::HashMap;

pub struct StagedAst {
    pub runtime_ast: RuntimeAst,
    pub children: HashMap<usize, StagedAst>,
}

impl StagedAst {
    fn new() -> Self {
        Self {
            runtime_ast: RuntimeAst::new(),
            children: HashMap::new(),
        }
    }
}

pub trait MetaEvalutator {
    type Error;

    fn process(&mut self, runtime_ast: &RuntimeAst) -> Result<Vec<RuntimeStmt>, Self::Error>;
}

pub fn process_root(
    meta_ast: &MetaAst,
    root_stmts: Vec<usize>,
) -> Result<StagedAst, MetaProcessError> {
    let mut staged_ast = StagedAst::new();
    let mut id_provider = IdProvider::new();
    let mut sem_root_stmts = Vec::with_capacity(root_stmts.len());
    for stmt in root_stmts {
        let id = process_stmt(meta_ast, stmt, &mut staged_ast, &mut id_provider)?;
        sem_root_stmts.push(id);
    }
    staged_ast.runtime_ast.sem_root_stmts = sem_root_stmts;
    Ok(staged_ast)
}

pub fn process_expr(
    meta_ast: &MetaAst,
    meta_expr_id: usize,
    staged_ast: &mut StagedAst,
    id_provider: &mut IdProvider,
) -> Result<usize, MetaProcessError> {
    let runtime_expr_id = id_provider.next();
    let meta_expr = meta_ast
        .get_expr(meta_expr_id)
        .ok_or(MetaProcessError::ExprNotFound(meta_expr_id))?;
    match meta_expr {
        MetaExpr::Int(i) => {
            let expr = RuntimeExpr::Int(*i);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }
        MetaExpr::String(s) => {
            let expr = RuntimeExpr::String(s.clone());
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }
        MetaExpr::Bool(b) => {
            let expr = RuntimeExpr::Bool(*b);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::StructLiteral { type_name, fields } => {
            //let mut out_fields = Vec::with_capacity(fields.len());

            //for (name, meta_expr_id) in fields {
            //let expr_id = id_provider.next();
            //let field_expr_id = work_queue.queue_expr(id_provider, *meta_expr_id);
            //out_fields.push((name.clone(), field_expr_id));
            //}

            //let expr = RuntimeExpr::StructLiteral {
            //type_name: type_name.clone(),
            //fields: out_fields,
            //};

            //runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        //MetaExpr::Variable(name) => match ctx.env.borrow().get(name) {
        //    Some(x) => value_to_literal(x, ctx),
        //    None => Ok(RuntimeExpr::Variable(name.clone())),
        //},
        //TODO replace the value to lit inlining
        MetaExpr::Variable(name) => {
            let expr = RuntimeExpr::Variable(name.clone());
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::List(exprs) => {
            let mut ids = Vec::with_capacity(exprs.len());
            for e in exprs {
                let id = process_expr(meta_ast, *e, staged_ast, id_provider)?;
                ids.push(id);
            }

            let expr = RuntimeExpr::List(ids.clone());
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Add(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider)?;
            let expr = RuntimeExpr::Add(a_id, b_id);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Sub(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider)?;
            let expr = RuntimeExpr::Sub(a_id, b_id);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Mult(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider)?;
            let expr = RuntimeExpr::Mult(a_id, b_id);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Div(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider)?;
            let expr = RuntimeExpr::Div(a_id, b_id);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Equals(a, b) => {
            let a_id = process_expr(meta_ast, *a, staged_ast, id_provider)?;
            let b_id = process_expr(meta_ast, *b, staged_ast, id_provider)?;
            let expr = RuntimeExpr::Equals(a_id, b_id);
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Call { callee, args } => {
            let mut out_args = Vec::with_capacity(args.len());

            for meta_arg in args {
                let arg_id = process_expr(meta_ast, *meta_arg, staged_ast, id_provider)?;
                out_args.push(arg_id);
            }

            let expr = RuntimeExpr::Call {
                callee: callee.clone(),
                args: out_args.clone(),
            };

            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }

        MetaExpr::Typeof(ident) => {
            let type_expr = RuntimeExpr::String(ident.clone());
            staged_ast
                .runtime_ast
                .insert_expr(runtime_expr_id, type_expr);
        }

        MetaExpr::Embed(file_path) => {
            let expr = RuntimeExpr::String(file_path.clone());
            staged_ast.runtime_ast.insert_expr(runtime_expr_id, expr);
        }
    };
    Ok(runtime_expr_id)
}

pub fn process_stmt(
    meta_ast: &MetaAst,
    meta_stmt_id: usize,
    staged_ast: &mut StagedAst,
    id_provider: &mut IdProvider,
) -> Result<usize, MetaProcessError> {
    let runtime_stmt_id = id_provider.next();
    let meta_stmt = meta_ast
        .get_stmt(meta_stmt_id)
        .ok_or(MetaProcessError::StmtNotFound(meta_stmt_id))?;
    match meta_stmt {
        MetaStmt::ExprStmt(expr) => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider)?;
            let stmt = RuntimeStmt::ExprStmt(expr_id);
            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::VarDecl { name, expr } => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider)?;
            let stmt = RuntimeStmt::VarDecl {
                name: name.clone(),
                expr: expr_id,
            };
            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::Print(expr) => {
            let expr_id = process_expr(meta_ast, *expr, staged_ast, id_provider)?;
            let stmt = RuntimeStmt::Print(expr_id);
            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::If {
            cond,
            body,
            else_branch,
        } => {
            let cond_id = process_expr(meta_ast, *cond, staged_ast, id_provider)?;
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider)?;

            let else_id = else_branch
                .as_ref()
                .map(|s| process_stmt(meta_ast, *s, staged_ast, id_provider))
                .transpose()?;

            let stmt = RuntimeStmt::If {
                cond: cond_id,
                body: body_id,
                else_branch: else_id,
            };

            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::ForEach {
            var,
            iterable,
            body,
        } => {
            let iterable_id = process_expr(meta_ast, *iterable, staged_ast, id_provider)?;
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider)?;
            let stmt = RuntimeStmt::ForEach {
                var: var.clone(),
                iterable: iterable_id,
                body: body_id,
            };

            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::Block(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());

            for meta_stmt in stmts {
                let stmt_id = process_stmt(meta_ast, *meta_stmt, staged_ast, id_provider)?;
                children.push(stmt_id);
            }

            let stmt = RuntimeStmt::Block(children.clone());

            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::FnDecl { name, params, body } => {
            let body_id = process_stmt(meta_ast, *body, staged_ast, id_provider)?;

            let stmt = RuntimeStmt::FnDecl {
                name: name.clone(),
                params: params.clone(),
                body: body_id,
            };

            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
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
                .map(|e| process_expr(meta_ast, e, staged_ast, id_provider))
                .transpose()?;

            let stmt = RuntimeStmt::Return(expr_id);

            let mut children = Vec::new();
            if let Some(id) = expr_id {
                children.push(id);
            }

            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::Gen(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());

            for s in stmts {
                let id = process_stmt(meta_ast, *s, staged_ast, id_provider)?;
                children.push(id);
            }

            let stmt = RuntimeStmt::Gen(children);
            staged_ast.runtime_ast.insert_stmt(runtime_stmt_id, stmt);
        }

        MetaStmt::MetaBlock(parsed_stmt) => {
            // meta blocks spawn a new inner ast and associate it with the given id
            let child = process_root(meta_ast, vec![*parsed_stmt])?;
            staged_ast.children.insert(runtime_stmt_id, child);
        }

        MetaStmt::Import(_mod_name) => {}
    };
    Ok(runtime_stmt_id)
}
