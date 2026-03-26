use super::runtime_ast::*;
use super::staged_ast::*;
use std::collections::HashMap;

#[derive(Debug)]
pub enum AstConversionError {
    UnresolvedMeta(usize),
}

pub fn convert_to_runtime(
    staged: &StagedAst,
    meta_generated: &HashMap<usize, (Vec<RuntimeStmt>, Vec<RuntimeExpr>)>,
) -> Result<RuntimeAst, AstConversionError> {
    let mut runtime = RuntimeAst::new();

    // Compute the next fresh ID (above all existing staged IDs)
    let mut next_id = staged
        .stmts
        .keys()
        .chain(staged.exprs.keys())
        .max()
        .copied()
        .unwrap_or(0)
        + 1;

    // --- Pass 1: resolve MetaStmts ---
    // For each MetaStmt, assign fresh IDs to the generated stmts and record
    // the mapping so parent blocks and sem_root_stmts can be expanded.
    let mut expansion_map: HashMap<usize, Vec<usize>> = HashMap::new();

    for (id, stmt) in &staged.stmts {
        if let StagedStmt::MetaStmt(meta_ref) = stmt {
            let tree_id = meta_ref.ast_ref;
            let (gen_stmts, _) = meta_generated
                .get(&tree_id)
                .ok_or(AstConversionError::UnresolvedMeta(*id))?;

            let mut new_ids = Vec::with_capacity(gen_stmts.len());
            for gen_stmt in gen_stmts {
                let new_id = next_id;
                next_id += 1;
                runtime.insert_stmt(new_id, gen_stmt.clone());
                new_ids.push(new_id);
            }
            expansion_map.insert(*id, new_ids);
        }
    }

    // --- Pass 2: convert everything else ---

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

    // Convert all Statements (MetaStmts are skipped — already handled in pass 1)
    for (id, stmt) in &staged.stmts {
        let runtime_stmt = match stmt.clone() {
            StagedStmt::MetaStmt(_) => continue,
            StagedStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(e),
            StagedStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl { name, expr },
            StagedStmt::FnDecl { name, params, body } => {
                RuntimeStmt::FnDecl { name, params, body }
            }
            StagedStmt::Print(e) => RuntimeStmt::Print(e),
            StagedStmt::Return(e) => RuntimeStmt::Return(e),
            StagedStmt::Import(s) => RuntimeStmt::Import(s),
            StagedStmt::Gen(g) => RuntimeStmt::Gen(g),
            StagedStmt::Block(children) => {
                // Flatten: a MetaStmt child expands to 0..N IDs
                let expanded = expand_ids(&children, &expansion_map);
                RuntimeStmt::Block(expanded)
            }
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
        };
        runtime.insert_stmt(*id, runtime_stmt);
    }

    // Expand sem_root_stmts (MetaStmts may appear at the top level)
    runtime.sem_root_stmts = expand_ids(&staged.sem_root_stmts, &expansion_map);

    Ok(runtime)
}

/// Replaces any MetaStmt ID in `ids` with its expanded list from `expansion_map`.
/// Non-meta IDs pass through unchanged.
fn expand_ids(ids: &[usize], expansion_map: &HashMap<usize, Vec<usize>>) -> Vec<usize> {
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        match expansion_map.get(id) {
            Some(new_ids) => out.extend(new_ids),
            None => out.push(*id),
        }
    }
    out
}
