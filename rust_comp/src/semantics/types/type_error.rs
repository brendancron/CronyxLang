use super::types::Type;

#[derive(Debug, Clone)]
pub enum TypeErrorKind {
    InvalidReturn,
    Unsupported,
    UnboundVar(String),
    TypeMismatch { expected: Type, found: Type },
}

#[derive(Debug, Clone)]
pub struct TypeError {
    pub kind: TypeErrorKind,
    /// AST node ID of the expression/statement where the error occurred.
    /// None for errors from generated or unlocatable nodes.
    pub node_id: Option<usize>,
}

impl TypeError {
    pub fn new(kind: TypeErrorKind) -> Self {
        TypeError { kind, node_id: None }
    }

    /// Attach a node ID if one hasn't been set yet (innermost wins).
    pub fn at(mut self, id: usize) -> Self {
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
}
