use super::conversion::*;
use super::monomorphize::monomorphize;
use super::runtime_ast::*;
use super::staged_forest::{ModuleBinding, StagedForest};
use crate::semantics::meta::gen_collector::{CollectorMode, GeneratedCollector, GeneratedOutput};
use crate::semantics::types::type_error::TypeError;
use crate::semantics::types::types::Type;
use std::collections::{HashMap, VecDeque};

pub trait MetaEvaluator {
    type Error;

    /// Called once at the start of `process` with all module bindings so
    /// implementations can seed their type environments. Default is a no-op.
    fn register_module_bindings(&mut self, _bindings: &[ModuleBinding]) -> Result<(), Self::Error> {
        Ok(())
    }

    /// Called before a RuntimeAst is evaluated or returned.
    /// Returns a map from expression ID to its inferred type (used for monomorphization).
    /// Default is a no-op that returns an empty map.
    fn type_check(&mut self, ast: &RuntimeAst) -> Result<HashMap<usize, Type>, Self::Error> {
        let _ = ast;
        Ok(HashMap::new())
    }

    fn evaluate(
        &mut self,
        ast: &RuntimeAst,
        collector: &mut GeneratedCollector,
    ) -> Result<(), Self::Error>;

    /// Returns the lines printed by `print` statements during meta-block evaluation,
    /// in topological execution order (innermost meta first). Called once after all
    /// meta blocks are evaluated. Default returns nothing.
    fn take_meta_captures(&mut self) -> Vec<String> {
        vec![]
    }
}

// Using Kahn's Algorithm for Topological Sort
pub fn process<E: MetaEvaluator>(
    staged_forest: StagedForest,
    evaluator: &mut E,
) -> Result<RuntimeAst, E::Error>
where
    E::Error: From<AstConversionError> + From<String> + From<TypeError>,
{
    evaluator.register_module_bindings(&staged_forest.module_bindings)?;

    let impl_registry: HashMap<(String, String), String> = staged_forest
        .impl_registry
        .iter()
        .map(|(t, m, f)| ((t.clone(), m.clone()), f.clone()))
        .collect();

    let op_dispatch: HashMap<(String, String), String> = staged_forest
        .op_registry
        .iter()
        .map(|(op, ty, f)| ((op.clone(), ty.clone()), f.clone()))
        .collect();

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
            reverse_deps.entry(dep.dep_id()).or_insert_with(Vec::new).push(*id);
        }
    }

    // Collector IDs must not collide with any staged node or tree ID across the whole forest.
    let global_max_id = staged_forest.ast_map
        .keys()
        .chain(staged_forest.ast_map.values().flat_map(|a| a.stmts.keys().chain(a.exprs.keys())))
        .max()
        .copied()
        .unwrap_or(0);
    let collector_start_id = global_max_id + 1;

    let mut root_ast = None;

    while let Some(tree_id) = tree_queue.pop_front() {
        let staged_ast = staged_forest.ast_map.get(&tree_id).unwrap();
        let runtime_ast = convert_to_runtime(staged_ast, &meta_generated)?;

        if tree_id == staged_forest.root_id {
            let type_map = evaluator.type_check(&runtime_ast)?;
            root_ast = Some((runtime_ast, type_map));
        } else {
            // Type-check and execute meta blocks at compile time
            evaluator.type_check(&runtime_ast)?;
            let mut collector = GeneratedCollector::new(CollectorMode::ManyStmts, collector_start_id);
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

    // If any trees were never processed, there's a cycle.
    let processed_count = degree_map.values().filter(|&&d| d == 0).count();
    if processed_count < staged_forest.ast_map.len() {
        return Err(String::from("Circular dependency detected between trees").into());
    }

    let meta_captures = evaluator.take_meta_captures();

    root_ast
        .map(|(mut ast, type_map)| {
            ast.meta_prints = meta_captures;
            ast.impl_registry = impl_registry;
            ast.op_dispatch = op_dispatch;
            monomorphize(&mut ast, &type_map);
            ast.compact()
        })
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
