use super::type_utils::instantiate;
use super::types::{Type, TypeScheme, TypeVar};
use crate::frontend::meta_ast::EnumVariant;
use std::collections::HashMap;

pub struct TypeEnv {
    scopes: Vec<HashMap<String, TypeScheme>>,
    next_id: usize,
    pub enums: HashMap<String, Vec<EnumVariant>>,
}

impl TypeEnv {
    pub fn new() -> Self {
        Self {
            scopes: vec![HashMap::new()],
            next_id: 0,
            enums: HashMap::new(),
        }
    }

    pub fn register_enum(&mut self, name: &str, variants: Vec<EnumVariant>) {
        self.enums.insert(name.to_string(), variants);
    }

    pub fn lookup_enum(&self, name: &str) -> Option<&Vec<EnumVariant>> {
        self.enums.get(name)
    }

    pub fn fresh(&mut self) -> TypeVar {
        let id = self.next_id;
        self.next_id += 1;
        return TypeVar { id };
    }

    pub fn get_type(&self, name: &str) -> Option<TypeScheme> {
        for scope in self.scopes.iter().rev() {
            if let Some(ty) = scope.get(name) {
                return Some(ty.clone());
            }
        }
        None
    }

    pub fn lookup(&mut self, name: &str) -> Option<Type> {
        for scope in self.scopes.iter().rev() {
            if let Some(scheme) = scope.get(name).cloned() {
                return Some(instantiate(&scheme, self));
            }
        }
        None
    }

    pub fn bind(&mut self, name: &str, ty: TypeScheme) {
        self.scopes.last_mut().unwrap().insert(name.to_string(), ty);
    }

    pub fn bind_mono(&mut self, name: &str, mono: Type) {
        self.bind(name, TypeScheme::MonoType(mono))
    }

    pub fn all_types(&self) -> impl Iterator<Item = &TypeScheme> {
        self.scopes.iter().flat_map(|s| s.values())
    }

    pub fn push_scope(&mut self) {
        self.scopes.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.scopes.pop().expect("cannot pop global type scope");
    }
}
