use super::environment::{EnvHandler, EnvRef, Environment};
use super::result::ExecResult;
use super::value::Value;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::types::types::{self, Type};
use std::io::Write;

#[derive(Debug)]
pub enum EvalError {
    ExprNotFound(usize),
    StmtNotFound(usize),
    UnknownStructType(String),
    UndefinedVariable(String),
    TypeError(Type),
    NonFunctionCall,
    ArgumentMismatch,
    Unimplemented,
}

// TODO this is not the correct way to do this
impl From<String> for EvalError {
    fn from(name: String) -> Self {
        EvalError::UndefinedVariable(name)
    }
}

pub struct EvalCtx<'a, W> {
    pub out: W,
    pub env: &'a mut EnvHandler,
    pub ast: &'a RuntimeAst,
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

            //Ok(Value::Struct {
            //    type_name: type_name.clone(),
            //    fields: Rc::new(RefCell::new(fs)),
            //})
            Err(EvalError::Unimplemented)
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

            //Ok(Value::List(Rc::new(RefCell::new(values))))
            Err(EvalError::Unimplemented)
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

            //let callee_env = Env::new_child(Rc::clone(&func.env));
            let callee_env = Environment::new();

            {
                let mut e = callee_env.borrow_mut();
                for (param, value) in func.params.iter().zip(arg_vals) {
                    e.define(param.clone(), value);
                }
            }

            let result = match eval_stmt(func.body, ctx)? {
                ExecResult::Return(v) => v,
                ExecResult::Continue => Value::Unit,
            };

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

        RuntimeStmt::Block(stmts) => {
            ctx.env.push_scope();
            let res = eval_stmts(stmts, ctx);
            ctx.env.pop_scope();
            res
        }

        RuntimeStmt::FnDecl { name, params, body } => {
            //let func = Rc::new(Function {
            //    params: params.clone(),
            //    body: body.clone(),
            //    env: Rc::clone(&env),
            //});

            //ctx.env.define(name.clone(), Value::Function(func));

            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Return(opt_expr) => {
            let val = match opt_expr {
                None => Value::Unit,
                Some(expr) => eval_expr(*expr, ctx)?,
            };
            Ok(ExecResult::Return(val))
        }

        RuntimeStmt::Gen(stmts) => Ok(ExecResult::Continue),

        _ => Err(EvalError::Unimplemented),
    }
}

pub fn eval_stmts<W: Write>(
    stmts: &Vec<usize>,
    ctx: &mut EvalCtx<W>,
) -> Result<ExecResult, EvalError> {
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

pub fn eval<W: Write>(
    ast: &RuntimeAst,
    root_stmts: &Vec<usize>,
    env: EnvRef,
    out: &mut W,
) -> Result<ExecResult, EvalError> {
    let mut ctx = EvalCtx {
        ast,
        env: &mut EnvHandler::from(env),
        out,
    };
    eval_stmts(&root_stmts, &mut ctx)
}
