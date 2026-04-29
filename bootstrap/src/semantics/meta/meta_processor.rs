use super::conversion::*;
use super::monomorphize::monomorphize;
use super::runtime_ast::*;
use super::staged_forest::{ModuleBinding, StagedForest};
use crate::semantics::meta::gen_collector::{CollectorMode, GeneratedCollector, GeneratedOutput};
use crate::semantics::meta::meta_process_error::MetaProcessError;
use crate::semantics::types::type_error::TypeError;
use crate::semantics::types::types::Type;
use crate::util::node_id::RuntimeNodeId;
use std::collections::{HashMap, VecDeque};

/// Errors returned by `process`. Evaluator errors (type check, eval) are
/// wrapped in `Eval`; structural errors that belong to the meta pipeline
/// (e.g. dependency cycles) are in `Meta` so the caller can route them to the
/// correct `CompilerError` variant.
#[derive(Debug)]
pub enum ProcessError<E> {
    Eval(E),
    Meta(MetaProcessError),
}

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
    fn type_check(&mut self, ast: &RuntimeAst) -> Result<HashMap<RuntimeNodeId, Type>, Self::Error> {
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
) -> Result<RuntimeAst, ProcessError<E::Error>>
where
    E::Error: From<AstConversionError> + From<String> + From<TypeError>,
{
    let staged_module_bindings = staged_forest.module_bindings.clone();
    evaluator.register_module_bindings(&staged_module_bindings).map_err(ProcessError::Eval)?;

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
    let max_tree_id = staged_forest.ast_map.keys().copied().max().unwrap_or(0);
    let max_node_id = staged_forest.ast_map.values()
        .flat_map(|a| a.stmts.keys().chain(a.exprs.keys()).map(|id| id.0))
        .max().unwrap_or(0);
    let global_max_id = max_tree_id.max(max_node_id);
    let collector_start_id = global_max_id + 1;

    let mut root_ast = None;

    while let Some(tree_id) = tree_queue.pop_front() {
        let Some(staged_ast) = staged_forest.ast_map.get(&tree_id) else {
            return Err(ProcessError::Eval(
                format!("internal error: tree {tree_id} missing from ast_map").into(),
            ));
        };
        let runtime_ast = convert_to_runtime(staged_ast, &meta_generated)
            .map_err(|e| ProcessError::Eval(e.into()))?;

        if tree_id == staged_forest.root_id {
            let type_map = evaluator.type_check(&runtime_ast).map_err(ProcessError::Eval)?;
            root_ast = Some((runtime_ast, type_map));
        } else {
            // Type-check and execute meta blocks at compile time
            evaluator.type_check(&runtime_ast).map_err(ProcessError::Eval)?;
            let mut collector = GeneratedCollector::new(CollectorMode::ManyStmts, collector_start_id);
            evaluator.evaluate(&runtime_ast, &mut collector).map_err(ProcessError::Eval)?;
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

    // If any trees were never processed, there's a cycle — trace the actual cycle
    // chain so the diagnostic can show A → B → A rather than an unordered set.
    let processed_count = degree_map.values().filter(|&&d| d == 0).count();
    if processed_count < staged_forest.ast_map.len() {
        let cyclic_ids: std::collections::HashSet<usize> = degree_map
            .iter()
            .filter(|(_, &d)| d > 0)
            .map(|(&id, _)| id)
            .collect();

        // Build a reverse map from tree_id → representative symbol name.
        let mut tree_name: HashMap<usize, String> = HashMap::new();
        for (name, &tid) in &staged_forest.symbol_provides {
            tree_name.entry(tid).or_insert_with(|| name.clone());
        }
        let id_to_name = |id: usize| -> String {
            tree_name.get(&id).cloned().unwrap_or_else(|| format!("<tree {id}>"))
        };

        // DFS to find a concrete cycle path among the stuck nodes.
        let chain = find_cycle_chain(&cyclic_ids, &staged_forest.dependency_map)
            .map(|path| path.iter().map(|&id| id_to_name(id)).collect::<Vec<_>>())
            .unwrap_or_else(|| {
                // Fallback: sorted list of all stuck symbol names.
                let mut names: Vec<String> = cyclic_ids.iter().map(|&id| id_to_name(id)).collect();
                names.sort();
                names
            });

        return Err(ProcessError::Meta(MetaProcessError::CircularDependency(chain)));
    }

    let meta_captures = evaluator.take_meta_captures();

    root_ast
        .map(|(mut ast, type_map)| {
            ast.meta_prints = meta_captures;
            ast.impl_registry = impl_registry;
            ast.op_dispatch = op_dispatch;
            monomorphize(&mut ast, &type_map);
            let (mut compacted, stmt_remap) = ast.compact();
            // Remap staged node IDs → post-compact runtime IDs for module namespace lookup.
            compacted.module_bindings = staged_module_bindings.iter()
                .filter_map(|b| match b {
                    ModuleBinding::Namespace { bind_name, exports } => {
                        let remapped: Vec<(String, Option<RuntimeNodeId>)> = exports.iter()
                            .filter_map(|(name, sid)| {
                                stmt_remap.get(&RuntimeNodeId(sid.0))
                                    .map(|new_id| (name.clone(), Some(*new_id)))
                            })
                            .collect();
                        Some((bind_name.clone(), remapped))
                    }
                    ModuleBinding::NamespaceByName { bind_name, names } => {
                        let entries: Vec<(String, Option<RuntimeNodeId>)> = names.iter()
                            .map(|n| (n.clone(), None))
                            .collect();
                        Some((bind_name.clone(), entries))
                    }
                    ModuleBinding::Selective { .. } => None,
                })
                .collect();
            compacted
        })
        .ok_or_else(|| {
            ProcessError::Eval(String::from("Root AST not found in dependency tree").into())
        })
}

/// DFS over the forward dependency graph (restricted to `cyclic` nodes) to find
/// a concrete cycle and return it as an ordered path including the repeated start
/// node at the end (e.g. `[A, B, A]`).
fn find_cycle_chain(
    cyclic: &std::collections::HashSet<usize>,
    deps: &HashMap<usize, std::collections::HashSet<super::process_dependency::ProcessDependency>>,
) -> Option<Vec<usize>> {
    let mut visited: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut path: Vec<usize> = Vec::new();
    let mut on_path: std::collections::HashSet<usize> = std::collections::HashSet::new();

    for &start in cyclic {
        if let Some(chain) = dfs_cycle(start, cyclic, deps, &mut path, &mut on_path, &mut visited) {
            return Some(chain);
        }
    }
    None
}

fn dfs_cycle(
    node: usize,
    cyclic: &std::collections::HashSet<usize>,
    deps: &HashMap<usize, std::collections::HashSet<super::process_dependency::ProcessDependency>>,
    path: &mut Vec<usize>,
    on_path: &mut std::collections::HashSet<usize>,
    visited: &mut std::collections::HashSet<usize>,
) -> Option<Vec<usize>> {
    if on_path.contains(&node) {
        let start = path.iter().position(|&n| n == node).unwrap();
        let mut cycle = path[start..].to_vec();
        cycle.push(node);
        return Some(cycle);
    }
    if visited.contains(&node) {
        return None;
    }
    on_path.insert(node);
    path.push(node);

    if let Some(neighbors) = deps.get(&node) {
        for dep in neighbors {
            let next = dep.dep_id();
            if cyclic.contains(&next) {
                if let Some(cycle) = dfs_cycle(next, cyclic, deps, path, on_path, visited) {
                    return Some(cycle);
                }
            }
        }
    }

    path.pop();
    on_path.remove(&node);
    visited.insert(node);
    None
}
