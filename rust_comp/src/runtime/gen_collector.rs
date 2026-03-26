use crate::semantics::meta::runtime_ast::*;
use std::collections::HashMap;

/// The output produced by a meta block execution.
/// Self-contained: carries generated stmts plus every stmt/expr they transitively reference.
#[derive(Debug, Clone)]
pub struct GeneratedOutput {
    pub stmts: Vec<RuntimeStmt>,
    pub supporting_stmts: HashMap<usize, RuntimeStmt>,
    pub exprs: HashMap<usize, RuntimeExpr>,
}

impl GeneratedOutput {
    pub fn new() -> Self {
        GeneratedOutput {
            stmts: Vec::new(),
            supporting_stmts: HashMap::new(),
            exprs: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum CollectorMode {
    SingleExpr,
    ManyStmts,
    RejectAll,
}

pub struct GeneratedCollector {
    pub mode: CollectorMode,
    pub output: GeneratedOutput,
}

impl GeneratedCollector {
    pub fn new(mode: CollectorMode) -> Self {
        GeneratedCollector {
            mode,
            output: GeneratedOutput::new(),
        }
    }

    pub fn collect_stmt(&mut self, stmt: RuntimeStmt) -> Result<(), String> {
        match self.mode {
            CollectorMode::ManyStmts => {
                self.output.stmts.push(stmt);
                Ok(())
            }
            _ => Err("Generated statements not allowed in this context".to_string()),
        }
    }

    pub fn collect_expr_map(&mut self, id: usize, expr: RuntimeExpr) -> Result<(), String> {
        match self.mode {
            CollectorMode::SingleExpr => {
                self.output.exprs.insert(id, expr);
                Ok(())
            }
            _ => Err("Generated expressions not allowed in this context".to_string()),
        }
    }
}

/// Recursively collects all stmts and exprs reachable from `stmt` out of `ast`.
pub fn collect_nodes_for_stmt(
    ast: &RuntimeAst,
    stmt: &RuntimeStmt,
    supporting_stmts: &mut HashMap<usize, RuntimeStmt>,
    exprs: &mut HashMap<usize, RuntimeExpr>,
) {
    match stmt {
        RuntimeStmt::ExprStmt(e) => collect_expr(ast, *e, exprs),
        RuntimeStmt::Print(e) => collect_expr(ast, *e, exprs),
        RuntimeStmt::Return(Some(e)) => collect_expr(ast, *e, exprs),
        RuntimeStmt::Return(None) => {}
        RuntimeStmt::VarDecl { expr, .. } => collect_expr(ast, *expr, exprs),
        RuntimeStmt::FnDecl { body, .. } => collect_stmt(ast, *body, supporting_stmts, exprs),
        RuntimeStmt::Block(children) | RuntimeStmt::Gen(children) => {
            for id in children {
                collect_stmt(ast, *id, supporting_stmts, exprs);
            }
        }
        RuntimeStmt::If { cond, body, else_branch } => {
            collect_expr(ast, *cond, exprs);
            collect_stmt(ast, *body, supporting_stmts, exprs);
            if let Some(e) = else_branch {
                collect_stmt(ast, *e, supporting_stmts, exprs);
            }
        }
        RuntimeStmt::ForEach { iterable, body, .. } => {
            collect_expr(ast, *iterable, exprs);
            collect_stmt(ast, *body, supporting_stmts, exprs);
        }
        RuntimeStmt::StructDecl { .. } | RuntimeStmt::Import(_) => {}
    }
}

fn collect_stmt(
    ast: &RuntimeAst,
    id: usize,
    supporting_stmts: &mut HashMap<usize, RuntimeStmt>,
    exprs: &mut HashMap<usize, RuntimeExpr>,
) {
    if supporting_stmts.contains_key(&id) {
        return;
    }
    if let Some(stmt) = ast.get_stmt(id).cloned() {
        supporting_stmts.insert(id, stmt.clone());
        collect_nodes_for_stmt(ast, &stmt, supporting_stmts, exprs);
    }
}

fn collect_expr(ast: &RuntimeAst, id: usize, out: &mut HashMap<usize, RuntimeExpr>) {
    if out.contains_key(&id) {
        return;
    }
    let expr = match ast.get_expr(id) {
        Some(e) => e.clone(),
        None => return,
    };
    out.insert(id, expr.clone());
    match &expr {
        RuntimeExpr::Int(_)
        | RuntimeExpr::String(_)
        | RuntimeExpr::Bool(_)
        | RuntimeExpr::Variable(_) => {}
        RuntimeExpr::List(items) => {
            for i in items {
                collect_expr(ast, *i, out);
            }
        }
        RuntimeExpr::Add(a, b)
        | RuntimeExpr::Sub(a, b)
        | RuntimeExpr::Mult(a, b)
        | RuntimeExpr::Div(a, b)
        | RuntimeExpr::Equals(a, b) => {
            collect_expr(ast, *a, out);
            collect_expr(ast, *b, out);
        }
        RuntimeExpr::StructLiteral { fields, .. } => {
            for (_, e) in fields {
                collect_expr(ast, *e, out);
            }
        }
        RuntimeExpr::Call { args, .. } => {
            for a in args {
                collect_expr(ast, *a, out);
            }
        }
    }
}
