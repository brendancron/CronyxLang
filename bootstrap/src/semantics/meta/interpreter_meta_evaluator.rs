use crate::runtime::environment::EnvRef;
use crate::semantics::meta::gen_collector::GeneratedCollector;
use crate::runtime::interpreter::{eval, EvalError};
use crate::semantics::meta::meta_processor::*;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_forest::ModuleBinding;
use crate::semantics::types::runtime_type_checker::type_check_runtime;
use crate::semantics::types::type_env::TypeEnv;
use crate::semantics::types::types::Type;
use crate::util::node_id::RuntimeNodeId;
use std::collections::HashMap;
use std::io::Write;

pub struct InterpreterMetaEvaluator<'a, W: Write> {
    pub env: EnvRef,
    pub type_env: TypeEnv,
    pub out: &'a mut W,
    /// Accumulates lines printed by meta-block `print` stmts, in topo order.
    pub meta_captures: Vec<String>,
}

impl<'a, W: Write> MetaEvaluator for InterpreterMetaEvaluator<'a, W> {
    type Error = EvalError;

    fn register_module_bindings(&mut self, bindings: &[ModuleBinding]) -> Result<(), Self::Error> {
        for binding in bindings {
            match binding {
                ModuleBinding::Namespace { bind_name, .. }
                | ModuleBinding::NamespaceByName { bind_name, .. } => {
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

    fn type_check(&mut self, ast: &RuntimeAst) -> Result<HashMap<RuntimeNodeId, Type>, Self::Error> {
        let mut warnings = Vec::new();
        type_check_runtime(ast, &mut self.type_env, &mut warnings).map_err(EvalError::from)
        // Polymorphic-call warnings from meta evaluation are intentionally
        // ignored: the interpreter handles polymorphism correctly at runtime.
    }

    fn evaluate(
        &mut self,
        ast: &RuntimeAst,
        collector: &mut GeneratedCollector,
    ) -> Result<(), Self::Error> {
        // Write to a local buffer so we can capture the printed lines.
        let mut local_buf: Vec<u8> = Vec::new();
        eval(ast, &ast.sem_root_stmts, self.env.clone(), &mut local_buf, Some(collector), None)?;
        // Forward to the primary out (needed for interpreter mode where out = stdout).
        self.out.write_all(&local_buf).unwrap();
        // Capture lines for meta_prints injection in compile mode.
        if let Ok(s) = String::from_utf8(local_buf) {
            for line in s.lines() {
                self.meta_captures.push(line.to_string());
            }
        }
        Ok(())
    }

    fn take_meta_captures(&mut self) -> Vec<String> {
        std::mem::take(&mut self.meta_captures)
    }
}
