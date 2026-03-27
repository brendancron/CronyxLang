use super::process_dependency::*;
use super::staged_ast::*;
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
}

impl StagedForest {
    pub fn new() -> Self {
        StagedForest {
            root_id: 0,
            ast_map: HashMap::new(),
            dependency_map: HashMap::new(),
            source_dir: None,
        }
    }

    pub fn insert_tree(&mut self, staged_ast: StagedAst, id_provider: &mut IdProvider) -> usize {
        let new_id = id_provider.next();
        self.ast_map.insert(new_id, staged_ast);
        new_id
    }

    pub fn insert_deps(&mut self, dependency_set: HashSet<ProcessDependency>, id: usize) {
        self.dependency_map.insert(id, dependency_set);
    }
}

impl AsTree for StagedForest {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        nodes.push(TreeNode::leaf(format!("root_id: {}", self.root_id)));
        
        for (id, ast) in &self.ast_map {
            let ast_nodes = ast.as_tree();
            nodes.push(TreeNode::node(
                format!("Tree {}", id),
                ast_nodes,
            ));
        }
        
        nodes
    }
}
