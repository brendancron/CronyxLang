use std::collections::BTreeMap;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeVar {
    pub id: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeScheme {
    MonoType(Type),
    PolyType { vars: Vec<TypeVar>, ty: Type },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Type {
    Primitive(PrimitiveType),
    Var(TypeVar),
    Func { params: Vec<Type>, ret: Box<Type> },
    Record(BTreeMap<String, Type>),
    Enum(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum PrimitiveType {
    Unit,
    Int,
    String,
    Bool,
}

pub fn type_var(n: usize) -> Type {
    Type::Var(TypeVar { id: n })
}

pub fn unit_type() -> Type {
    Type::Primitive(PrimitiveType::Unit)
}

pub fn bool_type() -> Type {
    Type::Primitive(PrimitiveType::Bool)
}

pub fn int_type() -> Type {
    Type::Primitive(PrimitiveType::Int)
}

pub fn string_type() -> Type {
    Type::Primitive(PrimitiveType::String)
}

pub fn record_type(fields: impl IntoIterator<Item = (String, Type)>) -> Type {
    Type::Record(fields.into_iter().collect())
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Type::Primitive(PrimitiveType::Unit) => write!(f, "unit"),
            Type::Primitive(PrimitiveType::Int) => write!(f, "int"),
            Type::Primitive(PrimitiveType::Bool) => write!(f, "bool"),
            Type::Primitive(PrimitiveType::String) => write!(f, "string"),
            Type::Var(tv) => write!(f, "'{}", tv.id),
            Type::Func { params, ret } => {
                let ps: Vec<String> = params.iter().map(|p| p.to_string()).collect();
                write!(f, "({}) -> {}", ps.join(", "), ret)
            }
            Type::Record(fields) => {
                let fs: Vec<String> = fields.iter().map(|(k, v)| format!("{k}: {v}")).collect();
                write!(f, "{{ {} }}", fs.join(", "))
            }
            Type::Enum(name) => write!(f, "{name}"),
        }
    }
}
