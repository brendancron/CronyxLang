use super::runtime_ast::*;
use super::staged_ast::*;
use std::convert::TryFrom;

#[derive(Debug)]
pub enum AstConversionError {
    UnresolvedMeta(usize),
}

impl TryFrom<&StagedAst> for RuntimeAst {
    type Error = AstConversionError;

    fn try_from(staged: &StagedAst) -> Result<Self, Self::Error> {
        let mut runtime = RuntimeAst::new();
        runtime.sem_root_stmts = staged.sem_root_stmts.clone();

        // Convert all Expressions
        for (id, expr) in &staged.exprs {
            let runtime_expr = match expr.clone() {
                StagedExpr::Int(v) => RuntimeExpr::Int(v),
                StagedExpr::String(s) => RuntimeExpr::String(s),
                StagedExpr::Bool(b) => RuntimeExpr::Bool(b),
                StagedExpr::Variable(v) => RuntimeExpr::Variable(v),
                StagedExpr::List(l) => RuntimeExpr::List(l),
                StagedExpr::Add(a, b) => RuntimeExpr::Add(a, b),
                StagedExpr::Sub(a, b) => RuntimeExpr::Sub(a, b),
                StagedExpr::Mult(a, b) => RuntimeExpr::Mult(a, b),
                StagedExpr::Div(a, b) => RuntimeExpr::Div(a, b),
                StagedExpr::Equals(a, b) => RuntimeExpr::Equals(a, b),
                StagedExpr::StructLiteral { type_name, fields } => {
                    RuntimeExpr::StructLiteral { type_name, fields }
                }
                StagedExpr::Call { callee, args } => RuntimeExpr::Call { callee, args },
                // The Error Case:
                StagedExpr::MetaExpr(_) => return Err(AstConversionError::UnresolvedMeta(*id)),
            };
            runtime.insert_expr(*id, runtime_expr);
        }

        // Convert all Statements
        for (id, stmt) in &staged.stmts {
            let runtime_stmt = match stmt.clone() {
                StagedStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(e),
                StagedStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl { name, expr },
                StagedStmt::FnDecl { name, params, body } => {
                    RuntimeStmt::FnDecl { name, params, body }
                }
                StagedStmt::Print(e) => RuntimeStmt::Print(e),
                StagedStmt::Return(e) => RuntimeStmt::Return(e),
                StagedStmt::Block(b) => RuntimeStmt::Block(b),
                StagedStmt::Import(s) => RuntimeStmt::Import(s),
                StagedStmt::Gen(g) => RuntimeStmt::Gen(g),
                StagedStmt::If {
                    cond,
                    body,
                    else_branch,
                } => RuntimeStmt::If {
                    cond,
                    body,
                    else_branch,
                },
                StagedStmt::ForEach {
                    var,
                    iterable,
                    body,
                } => RuntimeStmt::ForEach {
                    var,
                    iterable,
                    body,
                },
                StagedStmt::StructDecl { name, fields } => {
                    let runtime_fields = fields
                        .into_iter()
                        .map(|f| RuntimeFieldDecl {
                            field_name: f.field_name,
                            type_name: f.type_name,
                        })
                        .collect();
                    RuntimeStmt::StructDecl {
                        name,
                        fields: runtime_fields,
                    }
                }
                // The Error Case:
                StagedStmt::MetaStmt(_) => return Err(AstConversionError::UnresolvedMeta(*id)),
            };
            runtime.insert_stmt(*id, runtime_stmt);
        }

        Ok(runtime)
    }
}
