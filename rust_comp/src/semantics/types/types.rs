use std::collections::BTreeMap;

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
