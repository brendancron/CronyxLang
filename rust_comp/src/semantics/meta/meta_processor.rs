use super::meta_stager::StagedAst;
use super::runtime_ast::*;

pub trait MetaEvaluator {
    type Error;

    fn evaluate(&mut self, ast: &RuntimeAst) -> Result<RuntimeStmt, Self::Error>;
}

fn process<E: MetaEvaluator>(staged: StagedAst, evaluator: &mut E) -> Result<RuntimeAst, E::Error> {
    let mut ast = staged.runtime_ast;

    for (slot, child) in staged.children {
        let child_ast = process(child, evaluator)?;
        let produced = evaluator.evaluate(&child_ast)?;
        ast.insert_stmt(slot, produced.clone());
    }

    Ok(ast)
}
