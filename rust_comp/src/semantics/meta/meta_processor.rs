use super::conversion::*;
use super::runtime_ast::*;
use super::staged_forest::StagedForest;
use super::process_dependency::ProcessDependency;
use crate::runtime::gen_collector::{CollectorMode, GeneratedCollector, GeneratedOutput};
use std::collections::{HashMap, VecDeque};

pub trait MetaEvaluator {
    type Error;

    fn evaluate(
        &mut self,
        ast: &RuntimeAst,
        collector: &mut GeneratedCollector,
    ) -> Result<(), Self::Error>;
}

// Using Kahn's Algorithm for Topological Sort
pub fn process<E: MetaEvaluator>(
    staged_forest: StagedForest,
    evaluator: &mut E,
) -> Result<RuntimeAst, E::Error>
where
    E::Error: From<AstConversionError> + From<String>,
{
    let mut degree_map: HashMap<usize, usize> = HashMap::new();
    let mut tree_queue: VecDeque<usize> = VecDeque::new();
    let mut reverse_deps: HashMap<usize, Vec<usize>> = HashMap::new();

    let mut meta_generated: HashMap<usize, GeneratedOutput> = HashMap::new();

    for (id, deps) in &staged_forest.dependency_map {
        let degree = deps.len();
        degree_map.insert(*id, degree);
        if degree == 0 {
            tree_queue.push_back(*id);
        }

        for dep in deps {
            if let ProcessDependency::MetaTree(dep_id) = dep {
                reverse_deps.entry(*dep_id).or_insert_with(Vec::new).push(*id);
            }
        }
    }

    let mut root_ast = None;

    while let Some(tree_id) = tree_queue.pop_front() {
        let staged_ast = staged_forest.ast_map.get(&tree_id).unwrap();
        let runtime_ast = convert_to_runtime(staged_ast, &meta_generated)?;

        if tree_id == staged_forest.root_id {
            root_ast = Some(runtime_ast);
        } else {
            // Execute meta blocks at compile time
            let mut collector = GeneratedCollector::new(CollectorMode::ManyStmts);
            evaluator.evaluate(&runtime_ast, &mut collector)?;
            meta_generated.insert(tree_id, collector.output);
        }

        // Mark this node as resolved and update dependents
        if let Some(dependents) = reverse_deps.get(&tree_id) {
            for dependent_id in dependents {
                let new_degree = degree_map.get(dependent_id).unwrap_or(&0) - 1;
                degree_map.insert(*dependent_id, new_degree);
                if new_degree == 0 {
                    tree_queue.push_back(*dependent_id);
                }
            }
        }
    }

    root_ast
        .map(|ast| ast.compact())
        .ok_or_else(|| {
            let err: E::Error = String::from("Root AST not found in dependency tree").into();
            err
        })
}

pub fn process_tree<E: MetaEvaluator>(
    staged_forest: StagedForest,
    _evaluator: &mut E,
    tree_id: usize,
) -> Result<RuntimeAst, AstConversionError> {
    let staged_ast = staged_forest.ast_map.get(&tree_id).unwrap();
    let runtime_ast = convert_to_runtime(staged_ast, &HashMap::new())?;
    Ok(runtime_ast)
}
