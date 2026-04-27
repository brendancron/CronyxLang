use crate::runtime::environment::*;
use crate::util::node_id::RuntimeNodeId;
use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::rc::Rc;

#[derive(Debug, Clone)]
pub enum EnumValuePayload {
    Unit,
    Tuple(Vec<Value>),
    Struct(Vec<(String, Value)>),
}

/// A Rust-native callable, used for injected default continuations (`__k`).
/// Wrapped in `Rc` so it's cheap to clone and share.
pub struct NativeFunction(pub Rc<dyn Fn(Vec<Value>) -> Value>);

impl Clone for NativeFunction {
    fn clone(&self) -> Self { NativeFunction(self.0.clone()) }
}
impl fmt::Debug for NativeFunction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { write!(f, "<native fn>") }
}

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    String(String),
    Bool(bool),

    Struct {
        type_name: String,
        fields: Rc<RefCell<Vec<(String, Value)>>>,
    },

    Enum {
        enum_name: String,
        variant: String,
        payload: EnumValuePayload,
    },

    List(Rc<RefCell<Vec<Value>>>),

    Tuple(Vec<Value>),

    Function(Rc<Function>),

    /// Native Rust callable, used internally for injected default continuations.
    NativeFunction(NativeFunction),

    /// A module namespace (imported via `use`). Intentionally immutable — no
    /// `RefCell` wrapper — because modules represent read-only export tables.
    /// `Struct` and `List` use `Rc<RefCell<...>>` to support in-place mutation
    /// and shared identity; modules have neither requirement.
    Module(Rc<HashMap<String, Value>>),

    Unit,
}

#[derive(Debug, Clone)]
pub struct Function {
    pub params: Vec<String>,
    pub body: RuntimeNodeId,
    pub env: Rc<RefCell<Environment>>,
    /// True when this function should use lexical scoping: the call swaps to
    /// the captured `env` before executing the body. All functions — both
    /// named declarations and lambda expressions — capture their definition
    /// environment and set this to true.
    pub is_closure: bool,
}

impl Value {
    pub fn enumerate(&self) -> Result<std::cell::Ref<'_, Vec<Value>>, String> {
        match self {
            Value::List(list) => Ok(list.borrow()),
            _ => Err(format!("value is not iterable: {self}")),
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{n}"),
            Value::String(s) => write!(f, "{s}"),
            Value::Bool(b) => write!(f, "{b}"),
            Value::Unit => write!(f, ""),
            Value::List(list) => {
                let elems = list.borrow();
                write!(f, "[")?;
                for (i, v) in elems.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{v}")?;
                }
                write!(f, "]")
            }
            Value::Tuple(items) => {
                write!(f, "(")?;
                for (i, v) in items.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{v}")?;
                }
                write!(f, ")")
            }
            Value::Struct { type_name, fields } => {
                let map = fields.borrow();
                write!(f, "{} {{", type_name)?;
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}: {}", k, v)?;
                }
                write!(f, "}}")
            }

            Value::Enum { variant, payload, .. } => match payload {
                EnumValuePayload::Unit => write!(f, "{}", variant),
                EnumValuePayload::Tuple(items) => {
                    write!(f, "{}(", variant)?;
                    for (i, v) in items.iter().enumerate() {
                        if i > 0 { write!(f, ", ")?; }
                        write!(f, "{v}")?;
                    }
                    write!(f, ")")
                }
                EnumValuePayload::Struct(fields) => {
                    write!(f, "{} {{", variant)?;
                    for (i, (k, v)) in fields.iter().enumerate() {
                        if i > 0 { write!(f, ", ")?; }
                        write!(f, "{}: {}", k, v)?;
                    }
                    write!(f, "}}")
                }
            },

            _ => write!(f, ""),
        }
    }
}
