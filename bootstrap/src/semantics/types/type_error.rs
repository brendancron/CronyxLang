use super::types::Type;
use crate::util::node_id::MetaNodeId;

#[derive(Debug, Clone)]
pub enum TypeErrorKind {
    InvalidReturn,
    Unsupported,
    UnboundVar(String),
    TypeMismatch { expected: Type, found: Type },
    /// Function called with multiple distinct concrete argument types across
    /// call sites. Codegen would silently use only the first call site's types.
    /// Proper monomorphization is not yet implemented.
    PolymorphicCall(String),
}

#[derive(Debug, Clone)]
pub struct TypeError {
    pub kind: TypeErrorKind,
    /// AST node ID of the expression/statement where the error occurred.
    /// None for errors from generated or unlocatable nodes.
    pub node_id: Option<MetaNodeId>,
}

impl TypeError {
    pub fn new(kind: TypeErrorKind) -> Self {
        TypeError { kind, node_id: None }
    }

    /// Attach a node ID if one hasn't been set yet (innermost wins).
    pub fn at(mut self, id: MetaNodeId) -> Self {
        self.node_id.get_or_insert(id);
        self
    }
}

// Convenience constructors — match the old enum variant names.
impl TypeError {
    pub fn unbound_var(name: impl Into<String>) -> Self {
        Self::new(TypeErrorKind::UnboundVar(name.into()))
    }
    pub fn type_mismatch(expected: Type, found: Type) -> Self {
        Self::new(TypeErrorKind::TypeMismatch { expected, found })
    }
    pub fn invalid_return() -> Self {
        Self::new(TypeErrorKind::InvalidReturn)
    }
    pub fn unsupported() -> Self {
        Self::new(TypeErrorKind::Unsupported)
    }
    pub fn polymorphic_call(name: impl Into<String>) -> Self {
        Self::new(TypeErrorKind::PolymorphicCall(name.into()))
    }
}
