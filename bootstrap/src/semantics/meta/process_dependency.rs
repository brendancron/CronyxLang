#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ProcessDependency {
    MetaTree(usize),
    SymbolTree(usize),
}

impl ProcessDependency {
    pub fn dep_id(&self) -> usize {
        match self {
            ProcessDependency::MetaTree(id) => *id,
            ProcessDependency::SymbolTree(id) => *id,
        }
    }
}
