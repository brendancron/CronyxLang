use super::types::Type;
use std::collections::HashMap;

/// Maps AST node IDs to their inferred types.
/// Produced by the type checker as an annotation pass over the MetaAst.
pub struct TypeTable {
    pub expr_types: HashMap<usize, Type>,
    pub stmt_types: HashMap<usize, Type>,
}

impl TypeTable {
    pub fn new() -> Self {
        TypeTable {
            expr_types: HashMap::new(),
            stmt_types: HashMap::new(),
        }
    }

    pub fn get_expr_type(&self, id: usize) -> Option<&Type> {
        self.expr_types.get(&id)
    }

    pub fn get_stmt_type(&self, id: usize) -> Option<&Type> {
        self.stmt_types.get(&id)
    }
}
