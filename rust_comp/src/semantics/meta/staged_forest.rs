use super::meta_process_error::*;
use super::process_dependency::*;
use super::staged_ast::*;
use super::symbol_collector::*;
use crate::frontend::id_provider::IdProvider;
use crate::util::formatters::tree_formatter::{AsTree, TreeNode};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct StagedForest {
    pub root_id: usize,
    pub ast_map: HashMap<usize, StagedAst>,
    pub dependency_map: HashMap<usize, HashSet<ProcessDependency>>,
    pub source_dir: Option<PathBuf>,

    /// Name → tree_id: what each tree declares at its top level.
    pub symbol_provides: HashMap<String, usize>,
    /// tree_id → names: what each tree references but does not declare internally.
    pub symbol_uses: HashMap<usize, HashSet<String>>,
}

impl StagedForest {
    pub fn new() -> Self {
        StagedForest {
            root_id: 0,
            ast_map: HashMap::new(),
            dependency_map: HashMap::new(),
            source_dir: None,
            symbol_provides: HashMap::new(),
            symbol_uses: HashMap::new(),
        }
    }

    pub fn insert_tree(&mut self, staged_ast: StagedAst, id_provider: &mut IdProvider) -> usize {
        let new_id = id_provider.next();
        self.register_symbols(new_id, &staged_ast);
        self.ast_map.insert(new_id, staged_ast);
        new_id
    }

    pub fn insert_deps(&mut self, dependency_set: HashSet<ProcessDependency>, id: usize) {
        self.dependency_map.insert(id, dependency_set);
    }

    fn register_symbols(&mut self, tree_id: usize, ast: &StagedAst) {
        let provides = collect_provides(ast);
        let external_uses = collect_external_uses(ast);
        for name in provides {
            self.symbol_provides.insert(name, tree_id);
        }
        self.symbol_uses.insert(tree_id, external_uses);
    }

    /// After all trees are staged, resolve symbol uses into SymbolTree dependencies.
    /// Names with no provider are skipped (builtins, runtime-injected names, etc.).
    pub fn resolve_symbol_deps(&mut self) -> Result<(), MetaProcessError> {
        let uses_snapshot: Vec<(usize, HashSet<String>)> = self
            .symbol_uses
            .iter()
            .map(|(&id, names)| (id, names.clone()))
            .collect();

        for (tree_id, uses) in uses_snapshot {
            for name in &uses {
                if let Some(&provider_id) = self.symbol_provides.get(name) {
                    if provider_id != tree_id {
                        self.dependency_map
                            .entry(tree_id)
                            .or_insert_with(HashSet::new)
                            .insert(ProcessDependency::SymbolTree(provider_id));
                    }
                }
            }
        }

        Ok(())
    }
}

impl AsTree for StagedForest {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        nodes.push(TreeNode::leaf(format!("root_id: {}", self.root_id)));

        for (id, ast) in &self.ast_map {
            let ast_nodes = ast.as_tree();
            nodes.push(TreeNode::node(format!("Tree {}", id), ast_nodes));
        }

        nodes
    }
}
