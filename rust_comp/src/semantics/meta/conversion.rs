use super::runtime_ast::*;
use super::staged_ast::*;
use std::convert::TryFrom;
use std::collections::HashMap;

#[derive(Debug)]
pub enum AstConversionError {
    UnresolvedMeta(usize),
}

pub fn convert_to_runtime(
    staged: &StagedAst,
    meta_generated: &HashMap<usize, (Vec<RuntimeStmt>, Vec<RuntimeExpr>)>,
) -> Result<RuntimeAst, AstConversionError> {
    println!("meta_generated: {:?}", meta_generated);
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
            StagedStmt::MetaStmt(meta_ref) => {
                let meta_id = meta_ref.ast_ref;
                println!("Resolving MetaId with id {} and meta_ref {:?}", id, meta_id);
                if let Some(generated_ast) = meta_generated.get(&meta_id) {
                    println!("Found generated AST for MetaId {:?}: {:?}", meta_id, generated_ast);
                    return Err(AstConversionError::UnresolvedMeta(*id));
                } else {
                    println!("MetaId {:?} not found in generated ASTs", meta_id);
                    return Err(AstConversionError::UnresolvedMeta(*id));
                }
            }
        };
        runtime.insert_stmt(*id, runtime_stmt);
    }

    Ok(runtime)
}
