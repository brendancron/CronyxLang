use crate::util::id_provider::IdProvider;
use crate::util::node_id::RuntimeNodeId;
use crate::runtime::environment::EnvHandler;
use crate::runtime::value::Value;
use crate::semantics::meta::runtime_ast::*;
use std::collections::HashMap;

/// The output produced by a meta block execution.
/// Self-contained: carries generated stmts plus every stmt/expr they transitively reference.
#[derive(Debug, Clone)]
pub struct GeneratedOutput {
    pub stmts: Vec<RuntimeStmt>,
    pub supporting_stmts: HashMap<RuntimeNodeId, RuntimeStmt>,
    pub exprs: HashMap<RuntimeNodeId, RuntimeExpr>,
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
    pub id_provider: IdProvider,
}

impl GeneratedCollector {
    pub fn new(mode: CollectorMode, start_id: usize) -> Self {
        GeneratedCollector {
            mode,
            output: GeneratedOutput::new(),
            id_provider: IdProvider::starting_from(start_id),
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

    pub fn collect_expr_map(&mut self, id: RuntimeNodeId, expr: RuntimeExpr) -> Result<(), String> {
        match self.mode {
            CollectorMode::SingleExpr => {
                self.output.exprs.insert(id, expr);
                Ok(())
            }
            _ => Err("Generated expressions not allowed in this context".to_string()),
        }
    }
}

/// Copies `root_stmt` and all transitively referenced nodes out of `ast`,
/// assigning fresh IDs from `id_provider` and substituting variables from `env`.
///
/// Returns `(transformed_root, new_stmts, new_exprs)`:
/// - `transformed_root`: the substituted root stmt (stored by value, inserted into output.stmts)
/// - `new_stmts`: all child stmts keyed by their fresh IDs (for supporting_stmts)
/// - `new_exprs`: all exprs keyed by their fresh IDs
pub fn collect_and_subst(
    ast: &RuntimeAst,
    root_stmt: &RuntimeStmt,
    env: &EnvHandler,
    id_provider: &mut IdProvider,
) -> (RuntimeStmt, HashMap<RuntimeNodeId, RuntimeStmt>, HashMap<RuntimeNodeId, RuntimeExpr>) {
    let mut ctx = SubstCtx {
        ast,
        env,
        id_provider,
        stmt_remap: HashMap::new(),
        expr_remap: HashMap::new(),
        stmts: HashMap::new(),
        exprs: HashMap::new(),
    };
    let transformed = ctx.transform_stmt(root_stmt);
    (transformed, ctx.stmts, ctx.exprs)
}

struct SubstCtx<'a> {
    ast: &'a RuntimeAst,
    env: &'a EnvHandler,
    id_provider: &'a mut IdProvider,
    stmt_remap: HashMap<RuntimeNodeId, RuntimeNodeId>,
    expr_remap: HashMap<RuntimeNodeId, RuntimeNodeId>,
    stmts: HashMap<RuntimeNodeId, RuntimeStmt>,
    exprs: HashMap<RuntimeNodeId, RuntimeExpr>,
}

impl<'a> SubstCtx<'a> {
    fn remap_stmt(&mut self, old_id: RuntimeNodeId) -> RuntimeNodeId {
        if let Some(&new_id) = self.stmt_remap.get(&old_id) {
            return new_id;
        }
        let new_id = self.id_provider.next_runtime();
        self.stmt_remap.insert(old_id, new_id);
        if let Some(stmt) = self.ast.get_stmt(old_id).cloned() {
            let transformed = self.transform_stmt(&stmt);
            self.stmts.insert(new_id, transformed);
        }
        new_id
    }

    fn remap_expr(&mut self, old_id: RuntimeNodeId) -> RuntimeNodeId {
        if let Some(&new_id) = self.expr_remap.get(&old_id) {
            return new_id;
        }
        let new_id = self.id_provider.next_runtime();
        self.expr_remap.insert(old_id, new_id);
        if let Some(expr) = self.ast.get_expr(old_id).cloned() {
            let transformed = self.transform_expr(&expr);
            self.exprs.insert(new_id, transformed);
        }
        new_id
    }

    fn transform_stmt(&mut self, stmt: &RuntimeStmt) -> RuntimeStmt {
        match stmt {
            RuntimeStmt::Print(e) => RuntimeStmt::Print(self.remap_expr(*e)),
            RuntimeStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(self.remap_expr(*e)),
            RuntimeStmt::Return(opt) => RuntimeStmt::Return(opt.map(|e| self.remap_expr(e))),
            RuntimeStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl {
                name: name.clone(),
                expr: self.remap_expr(*expr),
            },
            RuntimeStmt::Assign { name, expr } => RuntimeStmt::Assign {
                name: name.clone(),
                expr: self.remap_expr(*expr),
            },
            RuntimeStmt::IndexAssign { name, indices, expr } => RuntimeStmt::IndexAssign {
                name: name.clone(),
                indices: indices.iter().map(|i| self.remap_expr(*i)).collect(),
                expr: self.remap_expr(*expr),
            },
            RuntimeStmt::FnDecl { name, params, type_params, body } => RuntimeStmt::FnDecl {
                name: self.subst_name(name),
                params: params.clone(),
                type_params: type_params.clone(),
                body: self.remap_stmt(*body),
            },
            RuntimeStmt::Block(children) => {
                RuntimeStmt::Block(children.iter().map(|id| self.remap_stmt(*id)).collect())
            }
            RuntimeStmt::Gen(children) => {
                RuntimeStmt::Gen(children.iter().map(|id| self.remap_stmt(*id)).collect())
            }
            RuntimeStmt::If { cond, body, else_branch } => RuntimeStmt::If {
                cond: self.remap_expr(*cond),
                body: self.remap_stmt(*body),
                else_branch: else_branch.map(|id| self.remap_stmt(id)),
            },
            RuntimeStmt::WhileLoop { cond, body } => RuntimeStmt::WhileLoop {
                cond: self.remap_expr(*cond),
                body: self.remap_stmt(*body),
            },
            RuntimeStmt::ForEach { var, iterable, body } => RuntimeStmt::ForEach {
                var: var.clone(),
                iterable: self.remap_expr(*iterable),
                body: self.remap_stmt(*body),
            },
            RuntimeStmt::StructDecl { .. }
            | RuntimeStmt::Import(_)
            | RuntimeStmt::EnumDecl { .. }
            | RuntimeStmt::EffectDecl { .. } => stmt.clone(),
            RuntimeStmt::WithFn { op_name, params, ret_ty, body } => RuntimeStmt::WithFn {
                op_name: op_name.clone(),
                params: params.clone(),
                ret_ty: ret_ty.clone(),
                body: self.remap_stmt(*body),
            },
            RuntimeStmt::WithCtl { op_name, params, ret_ty, body, outer_k } => RuntimeStmt::WithCtl {
                op_name: op_name.clone(),
                params: params.clone(),
                ret_ty: ret_ty.clone(),
                body: self.remap_stmt(*body),
                outer_k: outer_k.clone(),
            },
            RuntimeStmt::Resume(opt_expr) => {
                RuntimeStmt::Resume(opt_expr.map(|e| self.remap_expr(e)))
            },
            RuntimeStmt::Match { scrutinee, arms } => RuntimeStmt::Match {
                scrutinee: self.remap_expr(*scrutinee),
                arms: arms.iter().map(|arm| RuntimeMatchArm {
                    pattern: arm.pattern.clone(),
                    body: self.remap_stmt(arm.body),
                }).collect(),
            },
        }
    }

    fn transform_expr(&mut self, expr: &RuntimeExpr) -> RuntimeExpr {
        match expr {
            RuntimeExpr::Variable(name) => match self.env.get(name) {
                Ok(Value::String(s)) => RuntimeExpr::String(s),
                Ok(Value::Int(n)) => RuntimeExpr::Int(n),
                Ok(Value::Bool(b)) => RuntimeExpr::Bool(b),
                _ => RuntimeExpr::Variable(name.clone()),
            },
            RuntimeExpr::Call { callee, args } => RuntimeExpr::Call {
                callee: self.subst_name(callee),
                args: args.iter().map(|id| self.remap_expr(*id)).collect(),
            },
            RuntimeExpr::StructLiteral { type_name, fields } => RuntimeExpr::StructLiteral {
                type_name: self.subst_name(type_name),
                fields: fields.iter().map(|(n, id)| (n.clone(), self.remap_expr(*id))).collect(),
            },
            RuntimeExpr::Add(a, b) => RuntimeExpr::Add(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Sub(a, b) => RuntimeExpr::Sub(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Mult(a, b) => RuntimeExpr::Mult(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Div(a, b) => RuntimeExpr::Div(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Equals(a, b) => RuntimeExpr::Equals(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::NotEquals(a, b) => RuntimeExpr::NotEquals(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Lt(a, b) => RuntimeExpr::Lt(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Gt(a, b) => RuntimeExpr::Gt(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Lte(a, b) => RuntimeExpr::Lte(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Gte(a, b) => RuntimeExpr::Gte(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::And(a, b) => RuntimeExpr::And(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Or(a, b) => RuntimeExpr::Or(self.remap_expr(*a), self.remap_expr(*b)),
            RuntimeExpr::Not(a) => RuntimeExpr::Not(self.remap_expr(*a)),
            RuntimeExpr::Index { object, index } => RuntimeExpr::Index {
                object: self.remap_expr(*object),
                index: self.remap_expr(*index),
            },
            RuntimeExpr::List(items) => {
                RuntimeExpr::List(items.iter().map(|id| self.remap_expr(*id)).collect())
            }
            RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
                RuntimeExpr::EnumConstructor {
                    enum_name: self.subst_name(enum_name),
                    variant: variant.clone(),
                    payload: match payload {
                        RuntimeConstructorPayload::Unit => RuntimeConstructorPayload::Unit,
                        RuntimeConstructorPayload::Tuple(ids) => {
                            RuntimeConstructorPayload::Tuple(ids.iter().map(|id| self.remap_expr(*id)).collect())
                        }
                        RuntimeConstructorPayload::Struct(fields) => {
                            RuntimeConstructorPayload::Struct(fields.iter().map(|(n, id)| (n.clone(), self.remap_expr(*id))).collect())
                        }
                    },
                }
            }
            RuntimeExpr::Tuple(items) => {
                RuntimeExpr::Tuple(items.iter().map(|id| self.remap_expr(*id)).collect())
            }
            RuntimeExpr::TupleIndex { object, index } => RuntimeExpr::TupleIndex {
                object: self.remap_expr(*object),
                index: *index,
            },
            RuntimeExpr::ResumeExpr(opt) => RuntimeExpr::ResumeExpr(opt.map(|id| self.remap_expr(id))),
            _ => expr.clone(), // Int, String, Bool, Unit, Lambda, DotAccess, DotCall, SliceRange
        }
    }

    fn subst_name(&self, name: &str) -> String {
        match self.env.get(name) {
            Ok(Value::String(s)) => s,
            _ => name.to_string(),
        }
    }
}
