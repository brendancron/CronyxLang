use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_ast::MetaRef;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy)]
pub enum CollectorMode {
    SingleExpr,
    SingleStmt,
    ManyStmts,
    RejectAll,
}

pub struct GeneratedCollector {
    pub mode: CollectorMode,
    pub statements: Vec<RuntimeStmt>,
    pub expressions: Vec<RuntimeExpr>,
}

impl GeneratedCollector {
    pub fn new(mode: CollectorMode) -> Self {
        GeneratedCollector {
            mode,
            statements: Vec::new(),
            expressions: Vec::new(),
        }
    }

    pub fn collect_stmt(&mut self, stmt: RuntimeStmt) -> Result<(), String> {
        match self.mode {
            CollectorMode::SingleStmt => {
                if self.statements.is_empty() {
                    self.statements.push(stmt);
                    Ok(())
                } else {
                    Err("Only one statement allowed".to_string())
                }
            }
            CollectorMode::ManyStmts => {
                self.statements.push(stmt);
                Ok(())
            }
            _ => Err("Generated statements not allowed in this context".to_string()),
        }
    }

    pub fn collect_expr(&mut self, expr: RuntimeExpr) -> Result<(), String> {
        match self.mode {
            CollectorMode::SingleExpr => {
                if self.expressions.is_empty() {
                    self.expressions.push(expr);
                    Ok(())
                } else {
                    Err("Only one expression allowed".to_string())
                }
            }
            _ => Err("Generated expressions not allowed in this context".to_string()),
        }
    }

    pub fn collect_stmts(&mut self, stmts: Vec<RuntimeStmt>) -> Result<(), String> {
        match self.mode {
            CollectorMode::ManyStmts => {
                self.statements.extend(stmts);
                Ok(())
            }
            _ => Err("Generated statements not allowed in this context".to_string()),
        }
    }
}

/// Maps MetaRef to generated statements/expressions
#[derive(Debug, Clone)]
pub struct MetaGeneratedMap {
    pub stmts: HashMap<MetaRef, Vec<usize>>,
    pub exprs: HashMap<MetaRef, Vec<usize>>,
}

impl MetaGeneratedMap {
    pub fn new() -> Self {
        MetaGeneratedMap {
            stmts: HashMap::new(),
            exprs: HashMap::new(),
        }
    }

    pub fn insert_stmts(&mut self, meta_ref: MetaRef, stmt_ids: Vec<usize>) {
        self.stmts.insert(meta_ref, stmt_ids);
    }

    pub fn insert_exprs(&mut self, meta_ref: MetaRef, expr_ids: Vec<usize>) {
        self.exprs.insert(meta_ref, expr_ids);
    }

    pub fn get_stmts(&self, meta_ref: &MetaRef) -> Option<&Vec<usize>> {
        self.stmts.get(meta_ref)
    }

    pub fn get_exprs(&self, meta_ref: &MetaRef) -> Option<&Vec<usize>> {
        self.exprs.get(meta_ref)
    }
}

impl Default for MetaGeneratedMap {
    fn default() -> Self {
        Self::new()
    }
}
