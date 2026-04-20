use super::type_env::TypeEnv;
use super::type_subst::{ApplySubst, TypeSubst};
use super::types::{Type, TypeScheme, TypeVar};
use std::collections::HashSet;

pub trait FreeTypeVars {
    fn free_type_vars(&self) -> HashSet<TypeVar>;
}

impl FreeTypeVars for Type {
    fn free_type_vars(&self) -> HashSet<TypeVar> {
        match self {
            Type::Var(tv) => [tv.clone()].into(),
            Type::Func { params, ret, .. } => {
                let mut set = HashSet::new();
                for p in params {
                    set.extend(p.free_type_vars());
                }
                set.extend(ret.free_type_vars());
                set
            }
            Type::Record(fields) => {
                let mut set = HashSet::new();
                for v in fields.values() {
                    set.extend(v.free_type_vars());
                }
                set
            }
            Type::Tuple(items) => {
                let mut set = HashSet::new();
                for t in items {
                    set.extend(t.free_type_vars());
                }
                set
            }
            Type::Slice(elem) => elem.free_type_vars(),
            _ => HashSet::new(),
        }
    }
}

impl FreeTypeVars for TypeEnv {
    fn free_type_vars(&self) -> HashSet<TypeVar> {
        let mut set = HashSet::new();
        for ty in self.all_types() {
            set.extend(ty.free_type_vars());
        }
        set
    }
}

impl FreeTypeVars for TypeScheme {
    fn free_type_vars(&self) -> HashSet<TypeVar> {
        match self {
            TypeScheme::MonoType(ty) => ty.free_type_vars(),

            TypeScheme::PolyType { vars, ty } => {
                let mut set = ty.free_type_vars();
                for v in vars {
                    set.remove(v);
                }
                set
            }
        }
    }
}

pub fn generalize(env: &TypeEnv, ty: Type) -> TypeScheme {
    let ty_vars = ty.free_type_vars();
    let env_vars = env.free_type_vars();

    let vars: Vec<TypeVar> = ty_vars.difference(&env_vars).cloned().collect();

    if vars.is_empty() {
        TypeScheme::MonoType(ty)
    } else {
        TypeScheme::PolyType { vars, ty }
    }
}

pub fn instantiate(scheme: &TypeScheme, env: &mut TypeEnv) -> Type {
    match scheme {
        TypeScheme::MonoType(ty) => ty.clone(),

        TypeScheme::PolyType { vars, ty } => {
            let mut subst = TypeSubst::new();

            for v in vars {
                subst.map.insert(v.clone(), Type::Var(env.fresh()));
            }

            ty.apply(&subst)
        }
    }
}
