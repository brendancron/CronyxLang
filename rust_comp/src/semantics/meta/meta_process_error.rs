#[derive(Debug)]
pub enum MetaProcessError {
    ExprNotFound(AstId),
    StmtNotFound(AstId),
    EmbedFailed { path: String, error: String },
    UnknownType(String),
    Unimplemented(String),
    Eval(EvalError),
}

impl From<EvalError> for MetaProcessError {
    fn from(e: EvalError) -> Self {
        MetaProcessError::Eval(e)
    }
}
