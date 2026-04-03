use super::environment::{EnvHandler, EnvRef, Environment};
use super::result::ExecResult;
use super::value::{EnumValuePayload, Function, Value};
use crate::frontend::meta_ast::{ConstructorPayload, Pattern, VariantBindings};
use crate::semantics::meta::conversion::AstConversionError;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_forest::ModuleBinding;
use crate::semantics::types::type_error::TypeError;
use crate::semantics::types::types::{self, Type};
use crate::semantics::meta::gen_collector::{collect_and_subst, GeneratedCollector};
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
    TypeCheckFailed(TypeError),
    NonFunctionCall,
    ArgumentMismatch,
    GenOutsideMetaContext,
    Unimplemented,
}

impl From<TypeError> for EvalError {
    fn from(e: TypeError) -> Self {
        EvalError::TypeCheckFailed(e)
    }
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
    pub source_dir: Option<std::path::PathBuf>,
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
        RuntimeExpr::NotEquals(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x != y)),
            (Value::String(x), Value::String(y)) => Ok(Value::Bool(x != y)),
            (Value::Bool(x), Value::Bool(y)) => Ok(Value::Bool(x != y)),
            _ => Err(EvalError::TypeError(types::unit_type())),
        },
        RuntimeExpr::Lt(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x < y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },
        RuntimeExpr::Gt(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x > y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },
        RuntimeExpr::Lte(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x <= y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },
        RuntimeExpr::Gte(a, b) => match (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x >= y)),
            _ => Err(EvalError::TypeError(types::int_type())),
        },
        RuntimeExpr::And(a, b) => {
            match eval_expr(*a, ctx)? {
                Value::Bool(false) => Ok(Value::Bool(false)),
                Value::Bool(true) => match eval_expr(*b, ctx)? {
                    Value::Bool(v) => Ok(Value::Bool(v)),
                    _ => Err(EvalError::TypeError(types::bool_type())),
                },
                _ => Err(EvalError::TypeError(types::bool_type())),
            }
        }
        RuntimeExpr::Or(a, b) => {
            match eval_expr(*a, ctx)? {
                Value::Bool(true) => Ok(Value::Bool(true)),
                Value::Bool(false) => match eval_expr(*b, ctx)? {
                    Value::Bool(v) => Ok(Value::Bool(v)),
                    _ => Err(EvalError::TypeError(types::bool_type())),
                },
                _ => Err(EvalError::TypeError(types::bool_type())),
            }
        }
        RuntimeExpr::Not(a) => match eval_expr(*a, ctx)? {
            Value::Bool(v) => Ok(Value::Bool(!v)),
            _ => Err(EvalError::TypeError(types::bool_type())),
        },

        RuntimeExpr::Index { object, index } => {
            let obj = eval_expr(*object, ctx)?;
            let idx = eval_expr(*index, ctx)?;
            let i = match idx {
                Value::Int(n) => n as usize,
                _ => return Err(EvalError::TypeError(types::int_type())),
            };
            match obj {
                Value::List(items) => {
                    let borrowed = items.borrow();
                    borrowed.get(i).cloned().ok_or_else(|| EvalError::UndefinedVariable(format!("index {i} out of bounds")))
                }
                Value::String(s) => {
                    let ch = s.chars().nth(i)
                        .ok_or_else(|| EvalError::UndefinedVariable(format!("index {i} out of bounds")))?;
                    Ok(Value::String(ch.to_string()))
                }
                _ => Err(EvalError::TypeError(types::unit_type())),
            }
        }

        RuntimeExpr::Tuple(items) => {
            let vals: Result<Vec<Value>, EvalError> = items.iter().map(|id| eval_expr(*id, ctx)).collect();
            Ok(Value::Tuple(vals?))
        }

        RuntimeExpr::TupleIndex { object, index } => {
            match eval_expr(*object, ctx)? {
                Value::Tuple(items) => items.into_iter().nth(*index)
                    .ok_or_else(|| EvalError::UndefinedVariable(format!("tuple index {} out of bounds", index))),
                _ => Err(EvalError::TypeError(types::unit_type())),
            }
        }

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
            let arg_vals: Result<Vec<Value>, EvalError> = args.iter().map(|a| eval_expr(*a, ctx)).collect();
            let arg_vals = arg_vals?;

            // String built-in methods
            if let Value::String(ref s) = obj {
                match method.as_str() {
                    "len" => return Ok(Value::Int(s.chars().count() as i64)),
                    "split" => {
                        let delim = match arg_vals.first() {
                            Some(Value::String(d)) => d.clone(),
                            _ => return Err(EvalError::ArgumentMismatch),
                        };
                        let parts: Vec<Value> = s.split(delim.as_str()).map(|p| Value::String(p.to_string())).collect();
                        return Ok(Value::List(Rc::new(RefCell::new(parts))));
                    }
                    "chars" => {
                        let chars: Vec<Value> = s.chars().map(|c| Value::String(c.to_string())).collect();
                        return Ok(Value::List(Rc::new(RefCell::new(chars))));
                    }
                    "trim" => return Ok(Value::String(s.trim().to_string())),
                    "contains" => {
                        let sub = match arg_vals.first() {
                            Some(Value::String(d)) => d.clone(),
                            _ => return Err(EvalError::ArgumentMismatch),
                        };
                        return Ok(Value::Bool(s.contains(sub.as_str())));
                    }
                    _ => {}
                }
            }

            // List built-in methods
            if let Value::List(ref items) = obj {
                match method.as_str() {
                    "len" => return Ok(Value::Int(items.borrow().len() as i64)),
                    "push" => {
                        let item = arg_vals.into_iter().next().ok_or(EvalError::ArgumentMismatch)?;
                        items.borrow_mut().push(item);
                        return Ok(Value::Unit);
                    }
                    "pop" => {
                        let item = items.borrow_mut().pop().ok_or_else(|| EvalError::UndefinedVariable("pop on empty list".into()))?;
                        return Ok(item);
                    }
                    "contains" => {
                        let needle = arg_vals.first().ok_or(EvalError::ArgumentMismatch)?;
                        let found = items.borrow().iter().any(|v| values_equal(v, needle));
                        return Ok(Value::Bool(found));
                    }
                    _ => {}
                }
            }

            // Trait method dispatch: struct value + impl_registry lookup
            if let Value::Struct { ref type_name, .. } = obj {
                if let Some(fn_name) = ctx.ast.impl_registry.get(&(type_name.clone(), method.clone())).cloned() {
                    let func = match ctx.env.get(&fn_name)? {
                        Value::Function(f) => f,
                        _ => return Err(EvalError::NonFunctionCall),
                    };
                    // params includes "self" as first entry
                    if func.params.len() != arg_vals.len() + 1 {
                        return Err(EvalError::ArgumentMismatch);
                    }
                    ctx.env.push_scope();
                    ctx.env.define(func.params[0].clone(), obj.clone());
                    for (param, value) in func.params[1..].iter().zip(arg_vals) {
                        ctx.env.define(param.clone(), value);
                    }
                    let result = match eval_stmt(func.body, ctx)? {
                        ExecResult::Return(v) => v,
                        ExecResult::Continue => Value::Unit,
                    };
                    ctx.env.pop_scope();
                    return Ok(result);
                }
            }

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
            if func.params.len() != arg_vals.len() {
                return Err(EvalError::ArgumentMismatch);
            }
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

        RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
            let val_payload = match payload {
                ConstructorPayload::Unit => EnumValuePayload::Unit,
                ConstructorPayload::Tuple(ids) => {
                    let vals: Result<Vec<_>, _> = ids.iter().map(|id| eval_expr(*id, ctx)).collect();
                    EnumValuePayload::Tuple(vals?)
                }
                ConstructorPayload::Struct(fields) => {
                    let vals: Result<Vec<_>, _> = fields.iter()
                        .map(|(name, id)| eval_expr(*id, ctx).map(|v| (name.clone(), v)))
                        .collect();
                    EnumValuePayload::Struct(vals?)
                }
            };
            Ok(Value::Enum {
                enum_name: enum_name.clone(),
                variant: variant.clone(),
                payload: val_payload,
            })
        }

        RuntimeExpr::Call { callee, args } => {
            // Built-in runtime functions
            match callee.as_str() {
                "readfile" => {
                    let path = match eval_expr(*args.first().ok_or(EvalError::ArgumentMismatch)?, ctx)? {
                        Value::String(s) => s,
                        _ => return Err(EvalError::ArgumentMismatch),
                    };
                    let resolved = if let Some(ref dir) = ctx.source_dir {
                        dir.join(&path)
                    } else {
                        std::path::PathBuf::from(&path)
                    };
                    let contents = std::fs::read_to_string(&resolved)
                        .map_err(|e| EvalError::UndefinedVariable(format!("readfile: {e}")))?;
                    return Ok(Value::String(contents));
                }
                "to_string" => {
                    let v = eval_expr(*args.first().ok_or(EvalError::ArgumentMismatch)?, ctx)?;
                    let s = match v {
                        Value::Int(n) => n.to_string(),
                        Value::Bool(b) => b.to_string(),
                        Value::String(s) => s,
                        _ => return Err(EvalError::TypeError(types::string_type())),
                    };
                    return Ok(Value::String(s));
                }
                "to_int" => {
                    let v = eval_expr(*args.first().ok_or(EvalError::ArgumentMismatch)?, ctx)?;
                    let n = match v {
                        Value::String(s) => s.trim().parse::<i64>()
                            .map_err(|_| EvalError::UndefinedVariable(format!("to_int: cannot parse '{s}'")))?,
                        Value::Int(n) => n,
                        _ => return Err(EvalError::TypeError(types::int_type())),
                    };
                    return Ok(Value::Int(n));
                }
                _ => {}
            }

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

        RuntimeStmt::WhileLoop { cond, body } => {
            loop {
                match eval_expr(*cond, ctx)? {
                    Value::Bool(true) => {}
                    Value::Bool(false) => break,
                    _ => return Err(EvalError::TypeError(types::bool_type())),
                }
                match eval_stmt(*body, ctx)? {
                    ExecResult::Return(v) => return Ok(ExecResult::Return(v)),
                    ExecResult::Continue => {}
                }
            }
            Ok(ExecResult::Continue)
        }

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

        RuntimeStmt::IndexAssign { name, indices, expr } => {
            let new_val = eval_expr(*expr, ctx)?;
            let root = ctx.env.get(name).map_err(EvalError::UndefinedVariable)?;
            let mut idx_vals = Vec::new();
            for &idx_id in indices.iter() {
                let v = eval_expr(idx_id, ctx)?;
                idx_vals.push(match v {
                    Value::Int(n) => n as usize,
                    _ => return Err(EvalError::TypeError(types::int_type())),
                });
            }
            // Walk the nested list chain, mutation happens at the last index
            let mut current = root;
            for &i in idx_vals[..idx_vals.len() - 1].iter() {
                current = match current {
                    Value::List(items) => {
                        let borrowed = items.borrow();
                        borrowed.get(i).cloned().ok_or_else(|| EvalError::UndefinedVariable(format!("index {i} out of bounds")))?
                    }
                    _ => return Err(EvalError::TypeError(types::unit_type())),
                };
            }
            let last = *idx_vals.last().unwrap();
            match current {
                Value::List(items) => {
                    let mut borrowed = items.borrow_mut();
                    if last < borrowed.len() {
                        borrowed[last] = new_val;
                    } else {
                        return Err(EvalError::UndefinedVariable(format!("index {last} out of bounds")));
                    }
                }
                _ => return Err(EvalError::TypeError(types::unit_type())),
            }
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Block(stmts) => {
            ctx.env.push_scope();
            let res = eval_stmts(stmts, ctx);
            ctx.env.pop_scope();
            res
        }

        RuntimeStmt::FnDecl { name, params, body, .. } => {
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

        RuntimeStmt::EnumDecl { .. } => Ok(ExecResult::Continue),

        RuntimeStmt::Match { scrutinee, arms } => {
            let val = eval_expr(*scrutinee, ctx)?;
            for arm in arms {
                ctx.env.push_scope();
                let matched = match_pattern(&arm.pattern, &val, ctx)?;
                if matched {
                    let result = eval_stmt(arm.body, ctx)?;
                    ctx.env.pop_scope();
                    return Ok(result);
                }
                ctx.env.pop_scope();
            }
            Ok(ExecResult::Continue)
        }
    }
}

fn values_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => x == y,
        (Value::String(x), Value::String(y)) => x == y,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        _ => false,
    }
}

fn match_pattern<W: Write>(
    pattern: &Pattern,
    value: &Value,
    ctx: &mut EvalCtx<W>,
) -> Result<bool, EvalError> {
    match pattern {
        Pattern::Wildcard => Ok(true),
        Pattern::Enum { enum_name: _, variant, bindings } => {
            if let Value::Enum { variant: val_variant, payload, .. } = value {
                if val_variant != variant {
                    return Ok(false);
                }
                match (bindings, payload) {
                    (VariantBindings::Unit, EnumValuePayload::Unit) => {}
                    (VariantBindings::Tuple(names), EnumValuePayload::Tuple(vals)) => {
                        for (name, val) in names.iter().zip(vals.iter()) {
                            ctx.env.define(name.clone(), val.clone());
                        }
                    }
                    (VariantBindings::Struct(names), EnumValuePayload::Struct(fields)) => {
                        for name in names {
                            let val = fields.iter()
                                .find(|(f, _)| f == name)
                                .map(|(_, v)| v.clone())
                                .ok_or_else(|| EvalError::UndefinedVariable(name.clone()))?;
                            ctx.env.define(name.clone(), val);
                        }
                    }
                    _ => return Ok(false),
                }
                Ok(true)
            } else {
                Ok(false)
            }
        }
    }
}

/// Hoist all FnDecl statements in `stmts` into the current scope before any statements run.
/// This allows functions to be called before their definition point in the source.
fn hoist_fndecls<W: Write>(stmts: &[usize], ctx: &mut EvalCtx<W>) {
    for &stmt_id in stmts {
        if let Some(RuntimeStmt::FnDecl { name, params, body, .. }) = ctx.ast.get_stmt(stmt_id) {
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
        if let RuntimeStmt::FnDecl { name, params, body, .. } = stmt {
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
    source_dir: Option<std::path::PathBuf>,
) -> Result<ExecResult, EvalError> {
    let mut ctx = EvalCtx {
        ast,
        env: &mut EnvHandler::from(env),
        out,
        gen_collector,
        source_dir,
    };
    eval_stmts(&root_stmts, &mut ctx)
}
