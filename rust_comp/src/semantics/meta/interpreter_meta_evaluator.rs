use crate::runtime::environment::EnvRef;
use crate::runtime::interpreter::{eval, EvalError};
use crate::runtime::result::ExecResult;
use crate::semantics::meta::meta_processor::*;
use crate::semantics::meta::runtime_ast::*;
use std::io::Write;

pub struct InterpreterMetaEvaluator<'a, W: Write> {
    pub env: EnvRef,
    pub out: &'a mut W,
}

impl<'a, W: Write> MetaEvaluator for InterpreterMetaEvaluator<'a, W> {
    type Error = EvalError;

    fn evaluate(&mut self, ast: &RuntimeAst) -> Result<RuntimeStmt, Self::Error> {
        match eval(ast, &ast.sem_root_stmts, self.env.clone(), self.out)? {
            ExecResult::Continue => ast
                .sem_root_stmts
                .last()
                .and_then(|id| ast.get_stmt(*id).cloned())
                .ok_or(EvalError::Unimplemented),
            ExecResult::Return(_) => Err(EvalError::Unimplemented),
        }
    }
}
