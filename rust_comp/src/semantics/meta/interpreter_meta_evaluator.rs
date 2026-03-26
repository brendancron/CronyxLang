use crate::runtime::environment::EnvRef;
use crate::runtime::gen_collector::GeneratedCollector;
use crate::runtime::interpreter::{eval, EvalError};
use crate::semantics::meta::meta_processor::*;
use crate::semantics::meta::runtime_ast::*;
use std::io::Write;

pub struct InterpreterMetaEvaluator<'a, W: Write> {
    pub env: EnvRef,
    pub out: &'a mut W,
}

impl<'a, W: Write> MetaEvaluator for InterpreterMetaEvaluator<'a, W> {
    type Error = EvalError;

    fn evaluate(
        &mut self,
        ast: &RuntimeAst,
        collector: &mut GeneratedCollector,
    ) -> Result<(), Self::Error> {
        eval(ast, &ast.sem_root_stmts, self.env.clone(), self.out, Some(collector))?;
        Ok(())
    }
}
