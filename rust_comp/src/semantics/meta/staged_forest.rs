use super::process_dependency::*;
use super::staged_ast::*;
use crate::frontend::id_provider::IdProvider;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct StagedForest {
    pub root_ast: StagedAst,
    pub ast_map: HashMap<usize, StagedAst>,
    pub dependency_map: HashMap<usize, HashSet<ProcessDependency>>,
}

impl StagedForest {
    pub fn insert_tree(&mut self, staged_ast: StagedAst, id_provider: &mut IdProvider) -> usize {
        let new_id = id_provider.next();
        self.ast_map.insert(new_id, staged_ast);
        new_id
    }

    pub fn insert_deps(&mut self, dependency_set: HashSet<ProcessDependency>, id: usize) {
        self.dependency_map.insert(id, dependency_set);
    }
}
