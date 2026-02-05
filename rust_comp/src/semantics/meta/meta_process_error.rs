#[derive(Debug)]
pub enum MetaProcessError {
    ExprNotFound(usize),
    StmtNotFound(usize),
    EmbedFailed { path: String, error: String },
    UnknownType(String),
    Unimplemented(String),
}
