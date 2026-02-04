use super::dependency_scheduler::*;
use crate::frontend::id_provider::*;
use crate::frontend::meta_ast::*;
use crate::runtime::environment::*;
use crate::runtime::interpreter::*;
use crate::runtime::value::Value;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::meta_process_error::*;
use crate::semantics::meta::work_queue::*;
use std::collections::VecDeque;
use std::io::Write;

pub struct MetaProcessor<'a> {
    meta_ast: &'a MetaAst,
    runtime_ast: &'a mut RuntimeAst,
    id_provider: &'a mut IdProvider,
    dependency_scheduler: &'a mut DependencyScheduler<Dependency, Event>,
    completion_queue: &'a mut VecDeque<Dependency>,
}

// TODO this is used for meta execution to collect generated nodes
pub struct MetaContext {
    pub emitted: Vec<RuntimeStmt>,
}

#[derive(Debug)]
pub enum Event {
    DependencyChain(Dependency),
    MetaExec(usize),
}

#[derive(Debug, PartialEq, Eq, Hash, Clone)]
pub enum Dependency {
    NodeDone(usize),
}

pub fn process<W: Write>(meta_ast: &MetaAst, out: &mut W) -> Result<RuntimeAst, MetaProcessError> {
    let processor = MetaProcessor {
        meta_ast: meta_ast,
        runtime_ast: &mut RuntimeAst::new(),
        id_provider: &mut IdProvider::new(),
        dependency_scheduler: &mut DependencyScheduler::new(),
        completion_queue: &mut VecDeque::new(),
    };

    let mut work_queue = WorkQueue::new();

    process_root(
        meta_ast,
        &meta_ast.sem_root_stmts,
        &mut runtime_ast,
        out,
        &mut id_provider,
        &mut dependency_scheduler,
        &mut completion_queue,
    )?;

    Ok(runtime_ast)
}

impl MetaProcessor {
    
    pub fn process_stmts<W: Write>(&mut self) -> Result<(), MetaProcessError> {
        let work_queue = WorkQueue::new();

        while let Some(work_item) = work_queue.next() {
            self.process_item(work_item);

            while let Some(dep) = self.completion_queue.pop_front() {
                self.process_completion(dep)
            }
        }
    }

    pub fn process_item(&mut self, work_item: WorkItem) {
        println!("{:?}", work_item);
    }

    pub fn process_completion(&mut self, dependency: Dependency) {
        println!("dependency completed: {:?}", dependency);
        let events = self.dependency_scheduler.resolve_dependency(dependency);
        for event in events {
            println!("event emitted: {:?}", event);
            match event {
                Event::DependencyChain(new_dependency) => {
                    completion_queue.push_back(new_dependency);
                }

                Event::MetaExec(ast_id) => {
                    let stmts = vec![ast_id];
                    eval(&runtime_ast, &stmts, Environment::new(), &mut None, out)?;
                }
            }
        }
    }

}

pub fn process_stmts<W: Write>(
    meta_ast: &MetaAst,
    root_stmts: &Vec<usize>,
    runtime_ast: &mut RuntimeAst,
    out: &mut W,
    id_provider: &mut IdProvider,
    dependency_scheduler: &mut DependencyScheduler<Dependency, Event>,
    completion_queue: &mut VecDeque<Dependency>,
    work_queue: &mut WorkQueue,
) -> Result<(), MetaProcessError> {
    for stmt in root_stmts {
        let runtime_id = work_queue.queue_stmt(id_provider, *stmt);
        runtime_ast.sem_root_stmts.push(runtime_id);
    }

    while let Some(work_item) = work_queue.next() {
        println!("{:?}", work_item);
        match work_item {
            WorkItem::LowerExpr {
                runtime_id,
                meta_id,
            } => {
                process_expr(
                    meta_id,
                    runtime_id,
                    work_queue,
                    dependency_scheduler,
                    completion_queue,
                    meta_ast,
                    runtime_ast,
                    id_provider,
                )?;
            }

            WorkItem::LowerStmt {
                runtime_id,
                meta_id,
            } => {
                process_stmt(
                    meta_id,
                    runtime_id,
                    work_queue,
                    dependency_scheduler,
                    completion_queue,
                    meta_ast,
                    runtime_ast,
                    id_provider,
                )?;
            }
        }

        println!("{:?}", dependency_scheduler);

        while let Some(dep) = completion_queue.pop_front() {
            println!("dependency completed: {:?}", dep);
            let events = dependency_scheduler.resolve_dependency(dep);
            for event in events {
                println!("event emitted: {:?}", event);
                match event {
                    Event::DependencyChain(dependency) => {
                        completion_queue.push_back(dependency);
                    }

                    Event::MetaExec(ast_id) => {
                        let stmts = vec![ast_id];
                        eval(&runtime_ast, &stmts, Environment::new(), &mut None, out)?;
                    }
                }
            }
        }
    }

    Ok(())
}

pub fn insert_node(
    node_id: usize,
    node: RuntimeNode,
    children: Vec<usize>,
    dependency_scheduler: &mut DependencyScheduler<Dependency, Event>,
    ast: &mut RuntimeAst,
) {
    match node {
        RuntimeNode::Expr(expr) => ast.insert_expr(node_id, expr),
        RuntimeNode::Stmt(stmt) => ast.insert_stmt(node_id, stmt),
    }
    dependency_scheduler.add_task(
        &children
            .iter()
            .map(|&c| Dependency::NodeDone(c))
            .collect::<Vec<_>>(),
        Event::DependencyChain(Dependency::NodeDone(node_id)),
    );
}

pub fn insert_leaf(
    node_id: usize,
    node: RuntimeNode,
    completion_queue: &mut VecDeque<Dependency>,
    ast: &mut RuntimeAst,
) {
    match node {
        RuntimeNode::Expr(expr) => ast.insert_expr(node_id, expr),
        RuntimeNode::Stmt(stmt) => ast.insert_stmt(node_id, stmt),
    }
    completion_queue.push_back(Dependency::NodeDone(node_id));
}

pub fn process_expr(
    meta_expr_id: usize,
    runtime_expr_id: usize,
    work_queue: &mut WorkQueue,
    dependency_scheduler: &mut DependencyScheduler<Dependency, Event>,
    completion_queue: &mut VecDeque<Dependency>,
    meta_ast: &MetaAst,
    runtime_ast: &mut RuntimeAst,
    id_provider: &mut IdProvider,
) -> Result<(), MetaProcessError> {
    let meta_expr = meta_ast
        .get_expr(meta_expr_id)
        .ok_or(MetaProcessError::ExprNotFound(meta_expr_id))?;
    match meta_expr {
        MetaExpr::Int(i) => {
            let expr = RuntimeExpr::Int(*i);
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }
        MetaExpr::String(s) => {
            let expr = RuntimeExpr::String(s.clone());
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }
        MetaExpr::Bool(b) => {
            let expr = RuntimeExpr::Bool(*b);
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }

        MetaExpr::StructLiteral { type_name, fields } => {
            let mut out_fields = Vec::with_capacity(fields.len());

            for (name, meta_expr_id) in fields {
                let field_expr_id = work_queue.queue_expr(id_provider, *meta_expr_id);
                out_fields.push((name.clone(), field_expr_id));
            }

            let expr = RuntimeExpr::StructLiteral {
                type_name: type_name.clone(),
                fields: out_fields,
            };

            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }

        //MetaExpr::Variable(name) => match ctx.env.borrow().get(name) {
        //    Some(x) => value_to_literal(x, ctx),
        //    None => Ok(RuntimeExpr::Variable(name.clone())),
        //},
        //TODO replace the value to lit inlining
        MetaExpr::Variable(name) => {
            let expr = RuntimeExpr::Variable(name.clone());
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }

        MetaExpr::List(exprs) => {
            let mut ids = Vec::with_capacity(exprs.len());
            for e in exprs {
                let id = work_queue.queue_expr(id_provider, *e);
                ids.push(id);
            }

            let expr = RuntimeExpr::List(ids.clone());
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                ids,
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Add(a, b) => {
            let a_id = work_queue.queue_expr(id_provider, *a);
            let b_id = work_queue.queue_expr(id_provider, *b);
            let expr = RuntimeExpr::Add(a_id, b_id);
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                vec![a_id, b_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Sub(a, b) => {
            let a_id = work_queue.queue_expr(id_provider, *a);
            let b_id = work_queue.queue_expr(id_provider, *b);
            let expr = RuntimeExpr::Sub(a_id, b_id);
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                vec![a_id, b_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Mult(a, b) => {
            let a_id = work_queue.queue_expr(id_provider, *a);
            let b_id = work_queue.queue_expr(id_provider, *b);
            let expr = RuntimeExpr::Mult(a_id, b_id);
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                vec![a_id, b_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Div(a, b) => {
            let a_id = work_queue.queue_expr(id_provider, *a);
            let b_id = work_queue.queue_expr(id_provider, *b);
            let expr = RuntimeExpr::Div(a_id, b_id);
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                vec![a_id, b_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Equals(a, b) => {
            let a_id = work_queue.queue_expr(id_provider, *a);
            let b_id = work_queue.queue_expr(id_provider, *b);
            let expr = RuntimeExpr::Equals(a_id, b_id);
            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                vec![a_id, b_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaExpr::Call { callee, args } => {
            let mut out_args = Vec::with_capacity(args.len());

            for meta_arg in args {
                let arg_id = work_queue.queue_expr(id_provider, *meta_arg);
                out_args.push(arg_id);
            }

            let expr = RuntimeExpr::Call {
                callee: callee.clone(),
                args: out_args.clone(),
            };

            insert_node(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                out_args,
                dependency_scheduler,
                runtime_ast,
            );
        }

        //match ctx.env.borrow().get(&callee) {
        //    Some(_) => {
        //        let val = interpreter::eval_expr(
        //            &call_expr,
        //            ctx.env.clone(),
        //            ctx.decls,
        //            &mut None,
        //            ctx.out,
        //        )?;
        //        value_to_literal(val)
        //    }
        //    None => Ok(call_expr),
        //}
        MetaExpr::Typeof(ident) => {
            //let def = ctx
            //    .decls
            //    .get_struct(ident)
            //    .ok_or_else(|| MetaProcessError::UnknownType(ident.clone()))?;

            let type_expr = RuntimeExpr::String(ident.clone());
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(type_expr),
                completion_queue,
                runtime_ast,
            );
        }

        MetaExpr::Embed(file_path) => {
            let expr = RuntimeExpr::String(file_path.clone());
            insert_leaf(
                runtime_expr_id,
                RuntimeNode::Expr(expr),
                completion_queue,
                runtime_ast,
            );
        }
    };
    Ok(())
}

pub fn process_stmt(
    meta_stmt_id: usize,
    runtime_stmt_id: usize,
    work_queue: &mut WorkQueue,
    dependency_scheduler: &mut DependencyScheduler<Dependency, Event>,
    completion_queue: &mut VecDeque<Dependency>,
    meta_ast: &MetaAst,
    runtime_ast: &mut RuntimeAst,
    id_provider: &mut IdProvider,
) -> Result<(), MetaProcessError> {
    let meta_stmt = meta_ast
        .get_stmt(meta_stmt_id)
        .ok_or(MetaProcessError::StmtNotFound(meta_stmt_id))?;
    match meta_stmt {
        MetaStmt::ExprStmt(expr) => {
            let expr_id = work_queue.queue_expr(id_provider, *expr);
            let stmt = RuntimeStmt::ExprStmt(expr_id);
            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                vec![expr_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::VarDecl { name, expr } => {
            let expr_id = work_queue.queue_expr(id_provider, *expr);
            let stmt = RuntimeStmt::VarDecl {
                name: name.clone(),
                expr: expr_id,
            };
            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                vec![expr_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::Print(expr) => {
            let expr_id = work_queue.queue_expr(id_provider, *expr);
            let stmt = RuntimeStmt::Print(expr_id);
            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                vec![expr_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::If {
            cond,
            body,
            else_branch,
        } => {
            let cond_id = work_queue.queue_expr(id_provider, *cond);
            let body_id = work_queue.queue_stmt(id_provider, *body);

            let else_id = else_branch
                .as_ref()
                .map(|s| work_queue.queue_stmt(id_provider, *s));

            let stmt = RuntimeStmt::If {
                cond: cond_id,
                body: body_id,
                else_branch: else_id,
            };

            let mut children = vec![cond_id, body_id];
            if let Some(eid) = else_id {
                children.push(eid);
            }

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                children,
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::ForEach {
            var,
            iterable,
            body,
        } => {
            let iterable_id = work_queue.queue_expr(id_provider, *iterable);
            let body_id = work_queue.queue_stmt(id_provider, *body);

            let stmt = RuntimeStmt::ForEach {
                var: var.clone(),
                iterable: iterable_id,
                body: body_id,
            };

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                vec![iterable_id, body_id],
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::Block(stmts) => {
            let mut children = Vec::with_capacity(stmts.len());

            for meta_stmt in stmts {
                let stmt_id = work_queue.queue_stmt(id_provider, *meta_stmt);
                children.push(stmt_id);
            }

            let stmt = RuntimeStmt::Block(children.clone());

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                children,
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::FnDecl { name, params, body } => {
            let body_id = work_queue.queue_stmt(id_provider, *body);

            let stmt = RuntimeStmt::FnDecl {
                name: name.clone(),
                params: params.clone(),
                body: body_id,
            };

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                vec![body_id],
                dependency_scheduler,
                runtime_ast,
            );
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
            let expr_id = expr.map(|e| work_queue.queue_expr(id_provider, e));

            let stmt = RuntimeStmt::Return(expr_id);

            let mut children = Vec::new();
            if let Some(id) = expr_id {
                children.push(id);
            }

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                children,
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::Gen(stmts) => {
            let children: Vec<_> = stmts
                .iter()
                .map(|s| work_queue.queue_stmt(id_provider, *s))
                .collect();

            let stmt = RuntimeStmt::Gen(children.clone());

            insert_node(
                runtime_stmt_id,
                RuntimeNode::Stmt(stmt),
                children,
                dependency_scheduler,
                runtime_ast,
            );
        }

        MetaStmt::MetaBlock(parsed_stmt) => {
            let body_id = work_queue.queue_stmt(id_provider, *parsed_stmt);

            dependency_scheduler
                .add_task(&[Dependency::NodeDone(body_id)], Event::MetaExec(body_id));
        }

        MetaStmt::Import(_mod_name) => {}
    };
    Ok(())
}

pub fn value_to_literal<W: Write>(
    val: Value,
    runtime_expr_id: usize,
    runtime_ast: &mut RuntimeAst,
) -> Result<(), MetaProcessError> {
    match val {
        Value::Int(n) => {
            let expr = RuntimeExpr::Int(n);
            runtime_ast.insert_expr(runtime_expr_id, expr);
            Ok(())
        }
        Value::String(s) => {
            let expr = RuntimeExpr::String(s);
            runtime_ast.insert_expr(runtime_expr_id, expr);
            Ok(())
        }
        Value::Bool(b) => {
            let expr = RuntimeExpr::Bool(b);
            runtime_ast.insert_expr(runtime_expr_id, expr);
            Ok(())
        }
        Value::Unit => Err(MetaProcessError::Unimplemented(
            "Unit has no literal representation".to_string(),
        )),
        _ => Err(MetaProcessError::Unimplemented(
            "non-primitive value not supported yet".to_string(),
        )),
    }
}

