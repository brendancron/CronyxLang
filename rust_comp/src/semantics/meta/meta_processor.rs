use super::runtime_ast::*;
use super::staged_ast::StagedAst;
use super::staged_forest::StagedForest;
use std::collections::{HashMap, VecDeque};

pub trait MetaEvaluator {
    type Error;

    fn evaluate(&mut self, ast: &RuntimeAst) -> Result<RuntimeStmt, Self::Error>;
}

// Using Kahn's Algorithm for Topological Sort
pub fn process<E: MetaEvaluator>(
    staged_forest: StagedForest,
    evaluator: &mut E,
) -> Result<RuntimeAst, E::Error> {
    let mut degree_map: HashMap<usize, usize> = HashMap::new();
    let mut tree_queue: VecDeque<usize> = VecDeque::new();

    for (id, deps) in staged_forest.dependency_map {
        let degree = deps.len();
        degree_map.insert(id, degree);
        if degree == 0 {
            tree_queue.push_back(id);
        }
    }

    while let Some(tree_id) = tree_queue.pop_front() {
        println!("Processing: {}", tree);
    }
}

pub fn process_tree<E: MetaEvaluator>(
    staged_forest: StagedForest,
    evaluator: &mut E,
    tree_id: usize,
) -> Result<(), E::Error> {
    let staged_ast = staged_forest.ast_map.get(&tree_id).unwrap();
    let runtime_ast = RuntimeAst::try_from(staged_ast)?;
    Ok(())
}
