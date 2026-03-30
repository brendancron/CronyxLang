use crate::runtime::environment::EnvRef;
use crate::semantics::meta::gen_collector::GeneratedCollector;
use crate::runtime::interpreter::{eval, EvalError};
use crate::semantics::meta::meta_processor::*;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_forest::ModuleBinding;
use crate::semantics::types::runtime_type_checker::type_check_runtime;
use crate::semantics::types::type_env::TypeEnv;
use crate::semantics::types::types::Type;
use std::io::Write;

pub struct InterpreterMetaEvaluator<'a, W: Write> {
    pub env: EnvRef,
    pub type_env: TypeEnv,
    pub out: &'a mut W,
}

impl<'a, W: Write> MetaEvaluator for InterpreterMetaEvaluator<'a, W> {
    type Error = EvalError;

    fn register_module_bindings(&mut self, bindings: &[ModuleBinding]) -> Result<(), Self::Error> {
        for binding in bindings {
            match binding {
                ModuleBinding::Namespace { bind_name, .. } => {
                    let ty = Type::Var(self.type_env.fresh());
                    self.type_env.bind_mono(bind_name, ty);
                }
                ModuleBinding::Selective { names } => {
                    for name in names {
                        let ty = Type::Var(self.type_env.fresh());
                        self.type_env.bind_mono(name, ty);
                    }
                }
            }
        }
        Ok(())
    }

    fn type_check(&mut self, ast: &RuntimeAst) -> Result<(), Self::Error> {
        type_check_runtime(ast, &mut self.type_env).map_err(EvalError::from)
    }

    fn evaluate(
        &mut self,
        ast: &RuntimeAst,
        collector: &mut GeneratedCollector,
    ) -> Result<(), Self::Error> {
        eval(ast, &ast.sem_root_stmts, self.env.clone(), self.out, Some(collector), None)?;
        Ok(())
    }
}
