use crate::util::node_id::MetaNodeId;

#[derive(Debug)]
pub enum MetaProcessError {
    ExprNotFound(MetaNodeId),
    StmtNotFound(MetaNodeId),
    EmbedFailed { path: String, error: String },
    UnknownType(String),
    Unimplemented(String),
    UnresolvedSymbol(String),
    /// Symbols involved in the cycle (for user-facing diagnostics).
    CircularDependency(Vec<String>),
}
