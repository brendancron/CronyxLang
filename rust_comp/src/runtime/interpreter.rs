use super::environment::{EnvHandler, EnvRef};
use super::result::ExecResult;
use super::value::{EnumValuePayload, Function, NativeFunction, Value};
use crate::frontend::meta_ast::{Pattern, VariantBindings};
use crate::semantics::meta::conversion::AstConversionError;
use crate::semantics::meta::runtime_ast::*;
use crate::semantics::meta::staged_forest::ModuleBinding;
use crate::semantics::types::type_error::TypeError;
use crate::semantics::types::types::{self, Type};
use crate::semantics::meta::gen_collector::{collect_and_subst, GeneratedCollector};
use crate::util::node_id::RuntimeNodeId;
use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Write;
use std::rc::Rc;

#[derive(Debug)]
pub enum EvalError {
    ExprNotFound(RuntimeNodeId),
    StmtNotFound(RuntimeNodeId),
    UnknownStructType(String),
    UndefinedVariable(String),
    DivisionByZero,
    Internal(String),
    TypeError(Type),
    TypeCheckFailed(TypeError),
    NonFunctionCall,
    ArgumentMismatch,
    GenOutsideMetaContext,
    Unimplemented,
    /// A `ctl` handler ran to completion without calling `resume` — the remaining computation is discarded.
    EffectAborted,
    /// A multi-resume handler took over; abort the original computation at the call site.
    MultiResumed,
    /// A `ctl` handler collected multiple resume values; carries them up to the nearest
    /// `eval_stmts` so it can replay the suffix stmts for each value.
    CtlSuspend { op_name: String, resume_values: Vec<Value> },
    IoError(String),
    /// Wraps another error with the AST node ID of the expression or statement
    /// where it originated, enabling source-span enrichment in diagnostics.
    /// Innermost location wins — outer eval_expr/eval_stmt calls keep the first
    /// WithLocation they see unchanged.
    WithLocation { inner: Box<EvalError>, node_id: RuntimeNodeId },
}

/// Entry in the ctl handler stack installed by `with ctl`.
pub struct CtlHandlerEntry {
    pub op_name: String,
    pub params: Vec<String>,
    pub body: RuntimeNodeId,
    /// The outer continuation (`__k_N` of the enclosing `__handle_*` function) captured
    /// when this handler was installed. Used when the handler doesn't call `resume` — the
    /// computation aborts through the handler and the outer k is invoked to continue after
    /// the `run { } handle { }` block.
    pub outer_k: Option<Value>,
}

/// Entry in the fn handler stack installed by `with fn`.
/// `WithFn` handlers must be dynamically scoped — they're installed inside a
/// `run...handle` block but called by functions that captured their env before
/// the handler was installed. A separate stack (like `ctl_handlers`) lets
/// functions find the handler without it being in their lexical env chain.
pub struct FnHandlerEntry {
    pub op_name: String,
    pub func: Rc<Function>,
}

impl From<TypeError> for EvalError {
    fn from(e: TypeError) -> Self {
        EvalError::TypeCheckFailed(e)
    }
}

impl From<String> for EvalError {
    fn from(msg: String) -> Self {
        EvalError::Internal(msg)
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
    /// Stack of active `ctl` handlers — last installed wins on lookup.
    pub ctl_handlers: Vec<CtlHandlerEntry>,
    /// Stack of active `fn` effect handlers — last installed wins on lookup.
    /// Checked after lexical env lookup fails, enabling dynamic dispatch for
    /// effect operations called by lexically-scoped functions.
    pub fn_handlers: Vec<FnHandlerEntry>,
    /// When true, `resume` pushes to `collected_resumes` instead of returning `Resumed`.
    /// Used during multi-resume collection phase.
    pub collecting_resumes: bool,
    pub collected_resumes: Vec<Value>,
    /// Pre-decided return values for multi-resume replay passes.
    /// Each entry is (op_name, value). When a matching ctl op is called,
    /// the value is consumed and returned directly without dispatching to the handler.
    pub replay_stack: Vec<(String, Value)>,
    /// Stack of active CPS-mode continuations. When a ctl op is called with an extra
    /// continuation argument (CPS style), the continuation is pushed here so that
    /// `Resume` inside the handler body calls it instead of collecting.
    pub cps_continuations: Vec<Value>,
    /// Stack of outer continuations for CPS functions. When a function with a `__k_*`
    /// parameter is called, that continuation value is pushed here. After a ctl handler
    /// runs in CPS mode without calling resume, this is used to invoke the outer
    /// continuation (i.e., continue execution after the `run { } handle { }` block).
    pub handle_continuations: Vec<Value>,
    /// Counts how many times `resume` (or a CPS continuation) has been invoked during
    /// the current ctl handler execution. Compared before/after the handler runs to
    /// detect whether resume was called.
    pub cps_resume_count: usize,
}

pub fn eval_expr<W: Write>(expr_id: RuntimeNodeId, ctx: &mut EvalCtx<W>) -> Result<Value, EvalError> {
    eval_expr_inner(expr_id, ctx).map_err(|e| match e {
        EvalError::WithLocation { .. }
        | EvalError::EffectAborted
        | EvalError::MultiResumed
        | EvalError::CtlSuspend { .. } => e,
        _ => EvalError::WithLocation { inner: Box::new(e), node_id: expr_id },
    })
}

fn eval_expr_inner<W: Write>(expr_id: RuntimeNodeId, ctx: &mut EvalCtx<W>) -> Result<Value, EvalError> {
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
            if let Ok(var) = ctx.env.get(name) {
                Ok(var)
            } else if let Some(entry) = ctx.fn_handlers.iter().rev().find(|e| &e.op_name == name) {
                Ok(Value::Function(entry.func.clone()))
            } else {
                Err(EvalError::UndefinedVariable(format!("Undefined variable: '{name}'")))
            }
        }

        RuntimeExpr::List(exprs) => {
            let mut values = Vec::new();
            for e in exprs {
                values.push(eval_expr(*e, ctx)?);
            }
            Ok(Value::List(Rc::new(RefCell::new(values))))
        }

        RuntimeExpr::Add(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x + y)),
                (Value::String(x), Value::String(y)) => Ok(Value::String(x.clone() + y)),
                _ => dispatch_binop("Add", lhs, rhs, ctx),
            }
        }

        RuntimeExpr::Sub(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x - y)),
                _ => dispatch_binop("Sub", lhs, rhs, ctx),
            }
        }

        RuntimeExpr::Mult(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x * y)),
                _ => dispatch_binop("Mul", lhs, rhs, ctx),
            }
        }

        RuntimeExpr::Div(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => {
                    if *y == 0 { return Err(EvalError::DivisionByZero); }
                    Ok(Value::Int(x / y))
                }
                _ => dispatch_binop("Div", lhs, rhs, ctx),
            }
        }

        RuntimeExpr::Equals(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x == y)),
                (Value::String(x), Value::String(y)) => Ok(Value::Bool(x == y)),
                (Value::Bool(x), Value::Bool(y)) => Ok(Value::Bool(x == y)),
                _ => dispatch_binop("Eq", lhs, rhs, ctx),
            }
        }

        RuntimeExpr::NotEquals(a, b) => {
            let (lhs, rhs) = (eval_expr(*a, ctx)?, eval_expr(*b, ctx)?);
            match (&lhs, &rhs) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x != y)),
                (Value::String(x), Value::String(y)) => Ok(Value::Bool(x != y)),
                (Value::Bool(x), Value::Bool(y)) => Ok(Value::Bool(x != y)),
                _ => {
                    let result = dispatch_binop("Eq", lhs, rhs, ctx)?;
                    match result {
                        Value::Bool(b) => Ok(Value::Bool(!b)),
                        _ => Err(EvalError::TypeError(types::bool_type())),
                    }
                }
            }
        }
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
            let n = match idx {
                Value::Int(n) => n,
                _ => return Err(EvalError::TypeError(types::int_type())),
            };
            match obj {
                Value::List(items) => {
                    let borrowed = items.borrow();
                    let len = borrowed.len() as i64;
                    if n < 0 && n < -len {
                        return Err(EvalError::UndefinedVariable(format!("index {n} out of bounds")));
                    }
                    let i = if n < 0 { (len + n) as usize } else { n as usize };
                    borrowed.get(i).cloned().ok_or_else(|| EvalError::UndefinedVariable(format!("index {n} out of bounds")))
                }
                Value::String(s) => {
                    let len = s.chars().count() as i64;
                    if n < 0 && n < -len {
                        return Err(EvalError::UndefinedVariable(format!("index {n} out of bounds")));
                    }
                    let i = if n < 0 { (len + n) as usize } else { n as usize };
                    s.chars().nth(i).map(|c| Value::String(c.to_string()))
                        .ok_or_else(|| EvalError::UndefinedVariable(format!("index {n} out of bounds")))
                }
                _ => Err(EvalError::TypeError(types::unit_type())),
            }
        }

        RuntimeExpr::SliceRange { object, start, end } => {
            let obj = eval_expr(*object, ctx)?;
            match obj {
                Value::List(items) => {
                    let borrowed = items.borrow();
                    let len = borrowed.len() as i64;
                    let resolve = |n: i64| -> usize {
                        if n < 0 { (len + n).max(0) as usize } else { n.min(len) as usize }
                    };
                    let s = match start {
                        Some(id) => match eval_expr(*id, ctx)? {
                            Value::Int(n) => resolve(n),
                            _ => return Err(EvalError::TypeError(types::int_type())),
                        },
                        None => 0,
                    };
                    let e = match end {
                        Some(id) => match eval_expr(*id, ctx)? {
                            Value::Int(n) => resolve(n),
                            _ => return Err(EvalError::TypeError(types::int_type())),
                        },
                        None => len as usize,
                    };
                    let slice: Vec<Value> = borrowed[s.min(borrowed.len())..e.min(borrowed.len())].to_vec();
                    Ok(Value::List(std::rc::Rc::new(std::cell::RefCell::new(slice))))
                }
                Value::String(s) => {
                    let len = s.chars().count() as i64;
                    let resolve = |n: i64| -> usize {
                        if n < 0 { (len + n).max(0) as usize } else { n.min(len) as usize }
                    };
                    let start_i = match start {
                        Some(id) => match eval_expr(*id, ctx)? {
                            Value::Int(n) => resolve(n),
                            _ => return Err(EvalError::TypeError(types::int_type())),
                        },
                        None => 0,
                    };
                    let end_i = match end {
                        Some(id) => match eval_expr(*id, ctx)? {
                            Value::Int(n) => resolve(n),
                            _ => return Err(EvalError::TypeError(types::int_type())),
                        },
                        None => len as usize,
                    };
                    let slice: String = s.chars().skip(start_i).take(end_i.saturating_sub(start_i)).collect();
                    Ok(Value::String(slice))
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
                    let func = match ctx.env.get(&fn_name).map_err(EvalError::UndefinedVariable)? {
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
                        ExecResult::Resumed(v) => v,
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
                ExecResult::Resumed(v) => v,
            };
            ctx.env.pop_scope();
            Ok(result)
        }

        RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
            let val_payload = match payload {
                RuntimeConstructorPayload::Unit => EnumValuePayload::Unit,
                RuntimeConstructorPayload::Tuple(ids) => {
                    let vals: Result<Vec<_>, _> = ids.iter().map(|id| eval_expr(*id, ctx)).collect();
                    EnumValuePayload::Tuple(vals?)
                }
                RuntimeConstructorPayload::Struct(fields) => {
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

        RuntimeExpr::Unit => Ok(Value::Unit),

        RuntimeExpr::ResumeExpr(opt_expr) => {
            let val = match opt_expr {
                None => Value::Unit,
                Some(e) => eval_expr(*e, ctx)?,
            };
            if ctx.collecting_resumes {
                ctx.collected_resumes.push(val.clone());
                Ok(val)
            } else if let Ok(resume_fn) = ctx.env.get("__resume__") {
                // Prefer the lexically-captured __resume__ (set when a CPS handler runs).
                // This is correct both for direct handler-body resume (where __resume__ ==
                // cps_continuations.last()) and for closures that captured __resume__ at
                // handler-entry time (where cps_continuations may have grown since).
                ctx.cps_resume_count += 1;
                call_value(resume_fn, vec![val], ctx)
            } else if let Some(cont) = ctx.cps_continuations.last().cloned() {
                ctx.cps_resume_count += 1;
                let result = call_value(cont, vec![val], ctx)?;
                Ok(result)
            } else {
                Ok(Value::Unit)
            }
        }

        RuntimeExpr::Lambda { params, body } => {
            let func = std::rc::Rc::new(Function {
                params: params.clone(),
                body: *body,
                env: ctx.env.env_ref(),
                is_closure: true,
            });
            Ok(Value::Function(func))
        }

        RuntimeExpr::Call { callee, args } => {
            // Replay check must come first: a pre-decided value overrides everything,
            // including built-ins (so `choose` returns the replayed value on re-runs).
            let replay_pos = ctx.replay_stack.iter().rposition(|(op, _)| op == callee);
            if let Some(pos) = replay_pos {
                let (_, val) = ctx.replay_stack.remove(pos);
                return Ok(val);
            }

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
                "writefile" => {
                    let mut iter = args.iter();
                    let path = match eval_expr(*iter.next().ok_or(EvalError::ArgumentMismatch)?, ctx)? {
                        Value::String(s) => s,
                        _ => return Err(EvalError::ArgumentMismatch),
                    };
                    let content = match eval_expr(*iter.next().ok_or(EvalError::ArgumentMismatch)?, ctx)? {
                        Value::String(s) => s,
                        _ => return Err(EvalError::ArgumentMismatch),
                    };
                    std::fs::write(&path, content)
                        .map_err(|e| EvalError::UndefinedVariable(format!("writefile: {e}")))?;
                    return Ok(Value::Unit);
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
                // free(obj): unit — no-op at interpreter level; Rust's Rc handles cleanup.
                // At LLVM time this will dispatch to the active allocator's dealloc.
                "free" => {
                    let _ = eval_expr(*args.first().ok_or(EvalError::ArgumentMismatch)?, ctx)?;
                    return Ok(Value::Unit);
                }
                _ => {}
            }

            // Check ctl handler stack before env lookup (last installed wins).
            let ctl_info = ctx.ctl_handlers.iter().rev()
                .find(|h| h.op_name == *callee)
                .map(|h| (h.params.clone(), h.body, h.outer_k.clone()));

            if let Some((params, body, entry_outer_k)) = ctl_info {
                let arg_vals: Vec<Value> = args.iter()
                    .map(|a| eval_expr(*a, ctx))
                    .collect::<Result<_, _>>()?;

                // CPS mode: called with one extra argument (the continuation lambda).
                // The caller (a CPS-transformed function) passes the continuation explicitly,
                // so Resume inside the handler calls it directly instead of collecting.
                if arg_vals.len() == params.len() + 1 {
                    let continuation = arg_vals.last().unwrap().clone();
                    let handler_args = &arg_vals[..params.len()];
                    ctx.env.push_scope();
                    for (param, val) in params.iter().zip(handler_args) {
                        ctx.env.define(param.clone(), val.clone());
                    }
                    ctx.cps_continuations.push(continuation.clone());
                    // Inject __resume__ so lambdas created in the handler body can capture it.
                    ctx.env.define("__resume__".to_string(), continuation);
                    let resume_count_before = ctx.cps_resume_count;
                    let handler_result = eval_stmt(body, ctx);
                    let resume_was_called = ctx.cps_resume_count > resume_count_before;
                    ctx.cps_continuations.pop();
                    ctx.env.pop_scope();
                    // If the handler did not call resume, the run-block continuation chain
                    // was never invoked.  Call the outer continuation (`__k_N` of the
                    // enclosing `__handle_*` function) so that execution continues after
                    // the `run { } handle { }` expression.
                    if !resume_was_called {
                        let handler_val = match handler_result {
                            Ok(ExecResult::Return(v)) => v,
                            Ok(_) => Value::Unit,
                            Err(EvalError::EffectAborted) => Value::Unit,
                            Err(e) => return Err(e),
                        };
                        // Use the outer_k captured when this WithCtl was installed, not
                        // handle_continuations.last() — nested CPS calls (like divide) push
                        // their own __k continuations onto that stack, so .last() would pick
                        // the wrong one (e.g. the divide continuation instead of __handle_N's).
                        return if let Some(ok) = entry_outer_k {
                            call_value(ok, vec![handler_val], ctx)
                        } else {
                            Ok(handler_val)
                        };
                    }
                    return match handler_result {
                        Ok(ExecResult::Return(v)) => Ok(v),
                        Ok(_) => Ok(Value::Unit),
                        Err(EvalError::EffectAborted) => Ok(Value::Unit),
                        Err(e) => Err(e),
                    };
                }

                if params.len() != arg_vals.len() {
                    return Err(EvalError::ArgumentMismatch);
                }
                ctx.env.push_scope();
                for (param, val) in params.iter().zip(arg_vals) {
                    ctx.env.define(param.clone(), val);
                }

                // Run handler body in collection mode to capture all resume calls.
                let old_collecting = ctx.collecting_resumes;
                let old_resumes = std::mem::take(&mut ctx.collected_resumes);
                ctx.collecting_resumes = true;
                let _handler_result = eval_stmt(body, ctx)?;
                let resume_values = std::mem::replace(&mut ctx.collected_resumes, old_resumes);
                ctx.collecting_resumes = old_collecting;
                ctx.env.pop_scope();

                if resume_values.is_empty() {
                    return Err(EvalError::EffectAborted);
                }
                if resume_values.len() == 1 {
                    // Single resume — return the value directly (existing path, no changes).
                    return Ok(resume_values.into_iter().next().unwrap());
                }

                // Multi-resume — bubble the values up so eval_stmts can replay stmts[i..]
                // (the call-site suffix) once per resume value. This gives the correct
                // delimited continuation rather than re-running from the with-ctl boundary.
                let op_name = callee.clone();
                return Err(EvalError::CtlSuspend { op_name, resume_values });
            }

            // NativeFunction (e.g., injected __k): evaluate args and call directly.
            if let Ok(Value::NativeFunction(nf)) = ctx.env.get(callee) {
                let arg_vals: Vec<Value> = args.iter()
                    .map(|a| eval_expr(*a, ctx))
                    .collect::<Result<_, _>>()?;
                return Ok((nf.0)(arg_vals));
            }

            let callee_val = ctx.env.get(callee).ok().or_else(|| {
                ctx.fn_handlers.iter().rev()
                    .find(|e| &e.op_name == callee)
                    .map(|e| Value::Function(e.func.clone()))
            }).ok_or_else(|| EvalError::UndefinedVariable(format!("Undefined variable: '{callee}'")))?;
            let func = match callee_val {
                Value::Function(f) => f,
                _ => return Err(EvalError::NonFunctionCall),
            };

            let mut arg_vals: Vec<Value> = args.iter()
                .map(|a| eval_expr(*a, ctx))
                .collect::<Result<_, _>>()?;

            // HOF __k injection: CPS function called without its continuation from a
            // non-CPS context (e.g., as a HOF argument). Provide identity continuation.
            // Matches any "__k_*" suffix since each CPS fn gets a unique k-name.
            if func.params.len() == arg_vals.len() + 1
                && func.params.last().map(|p| p.starts_with("__k")).unwrap_or(false)
            {
                // Identity continuation: propagates the resumed value back to the caller.
                let identity = Value::NativeFunction(NativeFunction(Rc::new(|args| {
                    args.into_iter().next().unwrap_or(Value::Unit)
                })));
                arg_vals.push(identity);
            } else if func.params.len() != arg_vals.len() {
                return Err(EvalError::ArgumentMismatch);
            }

            // Lexical scoping for closures: temporarily switch to the captured env.
            let saved_env = if func.is_closure {
                Some(ctx.env.swap(func.env.clone()))
            } else {
                None
            };
            ctx.env.push_scope();
            let mut pushed_handle_k = false;
            for (param, value) in func.params.iter().zip(arg_vals) {
                // Track the outer continuation for CPS functions so that ctl handlers
                // that don't call resume can still invoke it after the handler body runs.
                if param.starts_with("__k") {
                    ctx.handle_continuations.push(value.clone());
                    pushed_handle_k = true;
                }
                ctx.env.define(param.clone(), value);
            }

            let result = match eval_stmt(func.body, ctx)? {
                ExecResult::Return(v) => v,
                ExecResult::Continue => Value::Unit,
                ExecResult::Resumed(v) => v,
            };
            ctx.env.pop_scope();
            if pushed_handle_k { ctx.handle_continuations.pop(); }
            if let Some(old) = saved_env { ctx.env.swap(old); }

            Ok(result)
        }
    }
}

pub fn eval_stmt<W: Write>(stmt_id: RuntimeNodeId, ctx: &mut EvalCtx<W>) -> Result<ExecResult, EvalError> {
    eval_stmt_inner(stmt_id, ctx).map_err(|e| match e {
        EvalError::WithLocation { .. }
        | EvalError::EffectAborted
        | EvalError::MultiResumed
        | EvalError::CtlSuspend { .. } => e,
        _ => EvalError::WithLocation { inner: Box::new(e), node_id: stmt_id },
    })
}

fn eval_stmt_inner<W: Write>(stmt_id: RuntimeNodeId, ctx: &mut EvalCtx<W>) -> Result<ExecResult, EvalError> {
    match ctx
        .ast
        .get_stmt(stmt_id)
        .ok_or(EvalError::StmtNotFound(stmt_id))?
    {
        RuntimeStmt::Print(expr) => {
            let value = eval_expr(*expr, ctx)?;
            writeln!(ctx.out, "{}", value).map_err(|e| EvalError::IoError(e.to_string()))?;
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
                    ExecResult::Resumed(v) => return Ok(ExecResult::Resumed(v)),
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

            for elem in value?.enumerate()?.iter() {
                ctx.env.push_scope();
                ctx.env.define(var.clone(), elem.clone());

                match eval_stmt(*body, ctx)? {
                    ExecResult::Return(v) => {
                        ctx.env.pop_scope();
                        return Ok(ExecResult::Return(v));
                    }
                    ExecResult::Resumed(v) => {
                        ctx.env.pop_scope();
                        return Ok(ExecResult::Resumed(v));
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
                env: ctx.env.env_ref(),
                is_closure: true,
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

        // Effects
        RuntimeStmt::EffectDecl { .. } => Ok(ExecResult::Continue),

        // Phase 2: fn effects — install handler as a regular function in the environment.
        // Normal name lookup then dispatches to it when op_name(...) is called.
        RuntimeStmt::WithFn { op_name, params, body, .. } => {
            let func = Rc::new(Function {
                params: params.iter().map(|p| p.name.clone()).collect(),
                body: *body,
                env: ctx.env.env_ref(),
                is_closure: true,
            });
            ctx.env.define(op_name.clone(), Value::Function(func));
            Ok(ExecResult::Continue)
        }

        // Note: WithCtl is normally intercepted before reaching here by the eval_stmts loop.
        // This arm is a fallback for any direct eval_stmt call on a WithCtl node.
        RuntimeStmt::WithCtl { op_name, params, body, .. } => {
            let outer_k = ctx.handle_continuations.last().cloned();
            ctx.ctl_handlers.push(CtlHandlerEntry {
                op_name: op_name.clone(),
                params: params.iter().map(|p| p.name.clone()).collect(),
                body: *body,
                outer_k,
            });
            Ok(ExecResult::Continue)
        }

        RuntimeStmt::Resume(opt_expr) => {
            let val = match opt_expr {
                None => Value::Unit,
                Some(expr_id) => eval_expr(*expr_id, ctx)?,
            };
            if ctx.collecting_resumes {
                // Old path: collection mode — gather the value and let the handler body continue.
                ctx.collected_resumes.push(val);
                Ok(ExecResult::Continue)
            } else if let Ok(resume_fn) = ctx.env.get("__resume__") {
                // Prefer lexically-captured __resume__ over the continuation stack.
                // Correct for both direct handler-body resume and closures.
                ctx.cps_resume_count += 1;
                call_value(resume_fn, vec![val], ctx)?;
                Ok(ExecResult::Continue)
            } else if let Some(cont) = ctx.cps_continuations.last().cloned() {
                ctx.cps_resume_count += 1;
                call_value(cont, vec![val], ctx)?;
                Ok(ExecResult::Continue)
            } else {
                Ok(ExecResult::Resumed(val))
            }
        }

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
fn hoist_fndecls<W: Write>(stmts: &[RuntimeNodeId], ctx: &mut EvalCtx<W>) {
    for &stmt_id in stmts {
        if let Some(RuntimeStmt::FnDecl { name, params, body, .. }) = ctx.ast.get_stmt(stmt_id) {
            let func = Rc::new(Function {
                params: params.clone(),
                body: *body,
                env: ctx.env.env_ref(),
                is_closure: true,
            });
            ctx.env.define(name.clone(), Value::Function(func));
        }
    }
}

/// Dispatch a binary operator to a user-defined impl.
/// Looks up (op_trait, lhs_type_name) in the op_dispatch table and calls the function.
/// Returns an error if no impl is found — callers should try primitive matching first.
fn dispatch_binop<W: Write>(
    op_trait: &str,
    lhs: Value,
    rhs: Value,
    ctx: &mut EvalCtx<W>,
) -> Result<Value, EvalError> {
    let type_name = match &lhs {
        Value::Struct { type_name, .. } => type_name.clone(),
        _ => return Err(EvalError::UndefinedVariable(
            format!("no impl `{}` for this type", op_trait)
        )),
    };
    let fn_name = ctx.ast.op_dispatch
        .get(&(op_trait.to_string(), type_name.clone()))
        .cloned()
        .ok_or_else(|| EvalError::UndefinedVariable(
            format!("no impl `{}` for `{}`", op_trait, type_name)
        ))?;
    let func = ctx.env.get(&fn_name).map_err(EvalError::UndefinedVariable)?;
    call_value(func, vec![lhs, rhs], ctx)
}

/// Call a `Value::Function` (or any callable value) with the given arguments.
/// Used by CPS mode to invoke continuation lambdas from `Resume`.
pub fn call_value<W: Write>(func: Value, args: Vec<Value>, ctx: &mut EvalCtx<W>) -> Result<Value, EvalError> {
    // Native functions (e.g., injected default __k continuations) — call directly.
    if let Value::NativeFunction(nf) = &func {
        return Ok((nf.0)(args));
    }
    let f = match func {
        Value::Function(f) => f,
        _ => return Err(EvalError::NonFunctionCall),
    };
    if f.params.len() != args.len() {
        return Err(EvalError::ArgumentMismatch);
    }
    // Lexical scoping for closures: temporarily switch to the captured env.
    let saved_env = if f.is_closure {
        Some(ctx.env.swap(f.env.clone()))
    } else {
        None
    };
    ctx.env.push_scope();
    for (param, val) in f.params.iter().zip(args) {
        ctx.env.define(param.clone(), val);
    }
    let result = match eval_stmt(f.body, ctx) {
        Ok(ExecResult::Return(v)) => Ok(v),
        Ok(ExecResult::Continue) => Ok(Value::Unit),
        Ok(ExecResult::Resumed(v)) => Ok(v),
        Err(e) => Err(e),
    };
    ctx.env.pop_scope();
    if let Some(old) = saved_env { ctx.env.swap(old); }
    result
}

pub fn eval_stmts<W: Write>(
    stmts: &[RuntimeNodeId],
    ctx: &mut EvalCtx<W>,
) -> Result<ExecResult, EvalError> {
    hoist_fndecls(stmts, ctx);
    let mut i = 0;
    while i < stmts.len() {
        let stmt_id = stmts[i];

        // Special handling for WithFn: push handler onto the dynamic fn_handlers stack
        // for the duration of the remaining stmts. This makes effect operations visible
        // to lexically-scoped functions that captured their env before the handler was installed.
        if let Some(RuntimeStmt::WithFn { op_name, params, body, .. }) = ctx.ast.get_stmt(stmt_id) {
            let func = Rc::new(Function {
                params: params.iter().map(|p| p.name.clone()).collect(),
                body: *body,
                env: ctx.env.env_ref(),
                is_closure: true,
            });
            let op_name = op_name.clone();
            let continuation: Vec<RuntimeNodeId> = stmts[i + 1..].to_vec();
            ctx.fn_handlers.push(FnHandlerEntry { op_name, func });
            let result = eval_stmts(&continuation, ctx);
            ctx.fn_handlers.pop();
            return result;
        }

        // Special handling for WithCtl: capture the remaining stmts as the continuation
        // so multi-resume can re-run them for each `resume` call.
        let with_ctl_info = match ctx.ast.get_stmt(stmt_id) {
            Some(RuntimeStmt::WithCtl { op_name, params, body, .. }) => {
                Some((op_name.clone(), params.iter().map(|p| p.name.clone()).collect::<Vec<_>>(), *body))
            }
            _ => None,
        };
        if let Some((op_name, param_names, body)) = with_ctl_info {
            let continuation: Vec<RuntimeNodeId> = stmts[i + 1..].to_vec();
            let outer_k = ctx.handle_continuations.last().cloned();
            ctx.ctl_handlers.push(CtlHandlerEntry { op_name, params: param_names, body, outer_k });
            let result = eval_stmts(&continuation, ctx);
            ctx.ctl_handlers.pop();
            return match result {
                Err(EvalError::MultiResumed) => Ok(ExecResult::Continue),
                other => other,
            };
        }

        match eval_stmt(stmt_id, ctx) {
            Ok(ExecResult::Continue) => {}
            Ok(ExecResult::Return(v)) => return Ok(ExecResult::Return(v)),
            Ok(ExecResult::Resumed(v)) => return Ok(ExecResult::Resumed(v)),
            // Multi-resume already completed all branches — propagate the abort signal.
            Err(EvalError::MultiResumed) => return Err(EvalError::MultiResumed),
            // A ctl op fired with multiple resume values. Replay stmts[i..] once per value:
            // stmts[i] re-runs the same statement but the effect call hits the replay_stack
            // and returns the pre-decided value, so stmts[i] completes normally. Then
            // stmts[i+1..] continue. Any further ctl ops in those stmts fire their own
            // CtlSuspend and are caught recursively by the inner eval_stmts.
            Err(EvalError::CtlSuspend { op_name, resume_values }) => {
                let suffix: Vec<RuntimeNodeId> = stmts[i..].to_vec();
                for resume_val in resume_values {
                    ctx.replay_stack.push((op_name.clone(), resume_val));
                    match eval_stmts(&suffix, ctx) {
                        Ok(_) | Err(EvalError::MultiResumed) => {}
                        // Branch pruned by assert(false) or an empty choose — skip silently.
                        Err(EvalError::EffectAborted) => {}
                        Err(e) => return Err(e),
                    }
                    ctx.replay_stack.retain(|(op, _)| op != &op_name);
                }
                return Err(EvalError::MultiResumed);
            }
            Err(e) => return Err(e),
        }
        i += 1;
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
                env: env.env_ref(),
                is_closure: true,
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
    root_stmts: &[RuntimeNodeId],
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
        ctl_handlers: Vec::new(),
        fn_handlers: Vec::new(),
        collecting_resumes: false,
        collected_resumes: Vec::new(),
        replay_stack: Vec::new(),
        cps_continuations: Vec::new(),
        handle_continuations: Vec::new(),
        cps_resume_count: 0,
    };
    match eval_stmts(&root_stmts, &mut ctx) {
        // Handler ran without resume — computation was intentionally discarded (e.g. abort).
        Err(EvalError::EffectAborted) => Ok(ExecResult::Continue),
        // Multi-resume completed normally (all continuations ran).
        Err(EvalError::MultiResumed) => Ok(ExecResult::Continue),
        other => other,
    }
}
