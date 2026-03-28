use super::environment::{EnvHandler, EnvRef, Environment};
use super::result::ExecResult;
use super::value::{Function, Value};
use crate::semantics::meta::conversion::AstConversionError;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_forest::ModuleBinding;
use crate::semantics::types::types::{self, Type};
use crate::runtime::gen_collector::{collect_and_subst, GeneratedCollector};
use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Write;
use std::rc::Rc;

#[derive(Debug)]
pub enum EvalError {
    ExprNotFound(usize),
    StmtNotFound(usize),
    UnknownStructType(String),
    UndefinedVariable(String),
    TypeError(Type),
    NonFunctionCall,
    ArgumentMismatch,
    GenOutsideMetaContext,
    Unimplemented,
}

// TODO this is not the correct way to do this
impl From<String> for EvalError {
    fn from(name: String) -> Self {
        EvalError::UndefinedVariable(name)
    }
}

impl From<AstConversionError> for EvalError {
    fn from(_err: AstConversionError) -> Self {
        EvalError::Unimplemented
    }
}

pub struct EvalCtx<'a, W> {
    pub out: W,
    pub env: &'a mut EnvHandler,
    pub ast: &'a RuntimeAst,
    pub gen_collector: Option<&'a mut GeneratedCollector>,
}

pub fn eval_expr<W: Write>(expr_id: usize, ctx: &mut EvalCtx<W>) -> Result<Value, EvalError> {
    match ctx
        .ast
        .get_expr(expr_id)
        .ok_or(EvalError::ExprNotFound(expr_id))?
    {
        RuntimeExpr::Int(n) => Ok(Value::Int(*n)),
        RuntimeExpr::String(s) => Ok(Value::String(s.clone())),
        RuntimeExpr::Bool(b) => Ok(Value::Bool(*b)),

        RuntimeExpr::StructLiteral { type_name, fields } => {
            //let _struct_def = decls
            //    .get_struct(type_name)
            //    .ok_or_else(|| EvalError::UnknownStructType(type_name.clone()))?;

            let mut fs = vec![];

            for (field_name, expr) in fields {
                let value = eval_expr(*expr, ctx)?;
                fs.push((field_name.clone(), value));
            }

            Ok(Value::Struct {
                type_name: type_name.clone(),
                fields: Rc::new(RefCell::new(fs)),
            })
        }

        RuntimeExpr::Variable(name) => {
            let var = ctx.env.get(name)?;
            Ok(var)
        }

        RuntimeExpr::List(exprs) => {
            let mut values = Vec::new();
            for e in exprs {
                values.push(eval_expr(*e, ctx)?);
            }
            Ok(Value::List(Rc::new(RefCell::new(values))))
        }

        RuntimeExpr::Add(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x + y)),
            (Value::String(x), Value::String(y)) => Ok(Value::String(x + &y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },

        RuntimeExpr::Sub(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x - y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },

        RuntimeExpr::Mult(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x * y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },

        RuntimeExpr::Div(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x / y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },

        RuntimeExpr::Equals(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x == y)),
            (Value::String(x), Value::String(y)) => Ok(Value::Bool(x == y)),
            (Value::Bool(x), Value::Bool(y)) => Ok(Value::Bool(x == y)),
            _ => Err(EvalError::TypeError(types::unit_type())),
        },

        RuntimeExpr::DotAccess { object, field } => {
            let obj = eval_expr(*object, ctx)?;
            match obj {
                Value::Struct { fields, .. } => {
                    let borrowed = fields.borrow();
                    borrowed.iter()
                        .find(|(name, _)| name == field)
                        .map(|(_, v)| v.clone())
                        .ok_or_else(|| EvalError::UndefinedVariable(field.clone()))
                }
                Value::Module(map) => map.get(field)
                    .cloned()
                    .ok_or_else(|| EvalError::UndefinedVariable(field.clone())),
                _ => Err(EvalError::TypeError(types::unit_type())),
            }
        }

        RuntimeExpr::DotCall { object, method, args } => {
            let obj = eval_expr(*object, ctx)?;
            let func = match &obj {
                Value::Module(map) => map.get(method)
                    .cloned()
                    .ok_or_else(|| EvalError::UndefinedVariable(method.clone()))?,
                _ => return Err(EvalError::NonFunctionCall),
            };
            let func = match func {
                Value::Function(f) => f,
                _ => return Err(EvalError::NonFunctionCall),
            };
            if func.params.len() != args.len() {
                return Err(EvalError::ArgumentMismatch);
            }
            let arg_vals = args.iter()
                .try_fold(Vec::new(), |mut v, a| -> Result<Vec<Value>, EvalError> {
                    v.push(eval_expr(*a, ctx)?);
                    Ok(v)
                })?;
            ctx.env.push_scope();
            for (param, value) in func.params.iter().zip(arg_vals) {
                ctx.env.define(param.clone(), value);
            }
            let result = match eval_stmt(func.body, ctx)? {
                ExecResult::Return(v) => v,
                ExecResult::Continue => Value::Unit,
            };
            ctx.env.pop_scope();
            Ok(result)
        }

        RuntimeExpr::Call { callee, args } => {
            let func = match ctx.env.get(callee)? {
                Value::Function(f) => f,
                _ => return Err(EvalError::NonFunctionCall),
            };

            if func.params.len() != args.len() {
                return Err(EvalError::ArgumentMismatch);
            }

            let arg_vals =
                args.iter()
                    .try_fold(Vec::new(), |mut v, a| -> Result<Vec<Value>, EvalError> {
                        v.push(eval_expr(*a, ctx)?);
                        Ok(v)
                    })?;

            ctx.env.push_scope();
            for (param, value) in func.params.iter().zip(arg_vals) {
                ctx.env.define(param.clone(), value);
            }

            let result = match eval_stmt(func.body, ctx)? {
                ExecResult::Return(v) => v,
                ExecResult::Continue => Value::Unit,
            };
            ctx.env.pop_scope();

            Ok(result)
        }
    }
}

pub fn eval_stmt<W: Write>(stmt_id: usize, ctx: &mut EvalCtx<W>) -> Result<ExecResult, EvalError> {
    match ctx
        .ast
        .get_stmt(stmt_id)
        .ok_or(EvalError::StmtNotFound(stmt_id))?
    {
        RuntimeStmt::Print(expr) => {
            let value = eval_expr(*expr, ctx)?;
            writeln!(ctx.out, "{}", value).unwrap();
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::If {
            cond,
            body,
            else_branch,
        } => match eval_expr(*cond, ctx)? {
            Value::Bool(true) => eval_stmt(*body, ctx),
            Value::Bool(false) => match else_branch {
                Some(else_stmt) => eval_stmt(*else_stmt, ctx),
                None => Ok(ExecResult::Continue),
            },
            _ => Err(EvalError::TypeError(types::bool_type())),
        },

        RuntimeStmt::ForEach {
            var,
            iterable,
            body,
        } => {
            let value = eval_expr(*iterable, ctx);

            for elem in value?.enumerate().iter() {
                ctx.env.push_scope();
                ctx.env.define(var.clone(), elem.clone());

                match eval_stmt(*body, ctx)? {
                    ExecResult::Return(v) => {
                        ctx.env.pop_scope();
                        return Ok(ExecResult::Return(v));
                    }
                    ExecResult::Continue => {}
                }

                ctx.env.pop_scope();
            }

            Ok(ExecResult::Continue)
        }

        RuntimeStmt::ExprStmt(expr) => {
            eval_expr(*expr, ctx)?;
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::VarDecl { name, expr } => {
            let value = eval_expr(*expr, ctx)?;
            ctx.env.define(name.clone(), value);
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Assign { name, expr } => {
            let value = eval_expr(*expr, ctx)?;
            ctx.env.assign(name, value).map_err(EvalError::UndefinedVariable)?;
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Block(stmts) => {
            ctx.env.push_scope();
            let res = eval_stmts(stmts, ctx);
            ctx.env.pop_scope();
            res
        }

        RuntimeStmt::FnDecl { name, params, body } => {
            let func = Rc::new(Function {
                params: params.clone(),
                body: *body,
                env: Environment::new(),
            });
            ctx.env.define(name.clone(), Value::Function(func));
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Return(opt_expr) => {
            let val = match opt_expr {
                None => Value::Unit,
                Some(expr) => eval_expr(*expr, ctx)?,
            };
            Ok(ExecResult::Return(val))
        }

        RuntimeStmt::Gen(stmt_ids) => {
            let stmts: Vec<RuntimeStmt> = stmt_ids
                .iter()
                .map(|id| ctx.ast.get_stmt(*id).cloned().ok_or(EvalError::Unimplemented))
                .collect::<Result<_, _>>()?;

            let collector = ctx
                .gen_collector
                .as_mut()
                .ok_or(EvalError::GenOutsideMetaContext)?;

            for stmt in &stmts {
                let (transformed, new_stmts, new_exprs) =
                    collect_and_subst(ctx.ast, stmt, ctx.env, &mut collector.id_provider);
                collector.output.supporting_stmts.extend(new_stmts);
                collector.output.exprs.extend(new_exprs);
                collector.collect_stmt(transformed).map_err(|_| EvalError::Unimplemented)?;
            }
            Ok(ExecResult::Continue)
        }

        // Import stmts are handled before eval by setup_modules; nothing to do at runtime.
        RuntimeStmt::Import(_) => Ok(ExecResult::Continue),

        RuntimeStmt::StructDecl { .. } => Ok(ExecResult::Continue),
    }
}

/// Hoist all FnDecl statements in `stmts` into the current scope before any statements run.
/// This allows functions to be called before their definition point in the source.
fn hoist_fndecls<W: Write>(stmts: &[usize], ctx: &mut EvalCtx<W>) {
    for &stmt_id in stmts {
        if let Some(RuntimeStmt::FnDecl { name, params, body }) = ctx.ast.get_stmt(stmt_id) {
            let func = Rc::new(Function {
                params: params.clone(),
                body: *body,
                env: Environment::new(),
            });
            ctx.env.define(name.clone(), Value::Function(func));
        }
    }
}

pub fn eval_stmts<W: Write>(
    stmts: &Vec<usize>,
    ctx: &mut EvalCtx<W>,
) -> Result<ExecResult, EvalError> {
    hoist_fndecls(stmts, ctx);
    for stmt in stmts {
        match eval_stmt(*stmt, ctx)? {
            ExecResult::Continue => {}
            ExecResult::Return(v) => {
                return Ok(ExecResult::Return(v));
            }
        }
    }
    Ok(ExecResult::Continue)
}

/// Pre-hoist all FnDecls in the entire RuntimeAst into the env, then create Module namespace
/// values for each explicit import binding.
///
/// Call this once before `eval` when running a multi-file compilation.
pub fn setup_modules(ast: &RuntimeAst, bindings: &[ModuleBinding], env: &mut EnvHandler) {
    // Hoist every FnDecl in the AST (regardless of which tree it came from).
    for stmt in ast.stmts.values() {
        if let RuntimeStmt::FnDecl { name, params, body } = stmt {
            let func = Rc::new(Function {
                params: params.clone(),
                body: *body,
                env: Environment::new(),
            });
            env.define(name.clone(), Value::Function(func));
        }
    }

    // Create namespace Module values for explicit imports.
    for binding in bindings {
        match binding {
            ModuleBinding::Namespace { bind_name, exports } => {
                let map: HashMap<String, Value> = exports
                    .iter()
                    .filter_map(|name| env.get(name).ok().map(|v| (name.clone(), v)))
                    .collect();
                env.define(bind_name.clone(), Value::Module(Rc::new(map)));
            }
            ModuleBinding::Selective { names } => {
                // Selective imports are already in the env from hoisting; nothing to do.
                let _ = names;
            }
        }
    }
}

pub fn eval<W: Write>(
    ast: &RuntimeAst,
    root_stmts: &Vec<usize>,
    env: EnvRef,
    out: &mut W,
    gen_collector: Option<&mut GeneratedCollector>,
) -> Result<ExecResult, EvalError> {
    let mut ctx = EvalCtx {
        ast,
        env: &mut EnvHandler::from(env),
        out,
        gen_collector,
    };
    eval_stmts(&root_stmts, &mut ctx)
}
