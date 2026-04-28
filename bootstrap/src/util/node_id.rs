use std::fmt;

/// A node ID in the `MetaAst` (pre-metaprocessing).
/// Produced by the parser; used by Phase 1 type checker and meta stager.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MetaNodeId(pub usize);

impl fmt::Display for MetaNodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A node ID in the `StagedAst` (intermediate staging representation).
/// Produced by the meta stager from MetaAst; consumed by conversion to RuntimeAst.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StagedNodeId(pub usize);

impl fmt::Display for StagedNodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A node ID in the `RuntimeAst` (post-metaprocessing).
/// Used by the interpreter, codegen, CPS transform, and runtime type checker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RuntimeNodeId(pub usize);

impl fmt::Display for RuntimeNodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}
