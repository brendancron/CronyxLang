use super::type_error::TypeError;
use super::types::{Type, TypeVar};
use std::collections::HashMap;

pub struct TypeSubst {
    pub map: HashMap<TypeVar, Type>,
}

impl TypeSubst {
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
        }
    }
}

pub trait ApplySubst {
    fn apply(&self, subst: &TypeSubst) -> Self;
}

impl ApplySubst for Type {
    fn apply(&self, subst: &TypeSubst) -> Type {
        match self {
            Type::Var(tv) => subst.map.get(tv).cloned().unwrap_or(self.clone()),
            Type::Func { params, ret } => Type::Func {
                params: params.iter().map(|t| t.apply(subst)).collect(),
                ret: Box::new(ret.apply(subst)),
            },
            Type::Record(fields) => Type::Record(
                fields.iter().map(|(k, v)| (k.clone(), v.apply(subst))).collect()
            ),
            _ => self.clone(),
        }
    }
}

fn contains(tv: TypeVar, ty: &Type) -> bool {
    match ty {
        Type::Var(v) => *v == tv,
        Type::Func { params, ret } => params.iter().any(|p| contains(tv, p)) || contains(tv, ret),
        _ => false,
    }
}

pub fn unify(a: &Type, b: &Type, subst: &mut TypeSubst) -> Result<(), TypeError> {
    let a = a.apply(subst);
    let b = b.apply(subst);

    match (&a, &b) {
        (Type::Var(v), t) => {
            if let Type::Var(v2) = t {
                if v == v2 {
                    return Ok(()); // same var → {}
                }
            }

            if contains(*v, t) {
                return Err(TypeError::Unsupported);
            }

            subst.map.insert(*v, t.clone());
            Ok(())
        }

        (_, Type::Var(_)) => unify(&b, &a, subst),

        (Type::Primitive(p1), Type::Primitive(p2)) if p1 == p2 => Ok(()),

        (
            Type::Func {
                params: p1,
                ret: r1,
            },
            Type::Func {
                params: p2,
                ret: r2,
            },
        ) => {
            if p1.len() != p2.len() {
                return Err(TypeError::TypeMismatch {
                    expected: a,
                    found: b,
                });
            }

            for (x, y) in p1.iter().zip(p2.iter()) {
                unify(x, y, subst)?;
            }

            unify(r1, r2, subst)
        }

        (Type::Record(fa), Type::Record(fb)) => {
            if fa.keys().collect::<Vec<_>>() != fb.keys().collect::<Vec<_>>() {
                return Err(TypeError::TypeMismatch {
                    expected: a,
                    found: b,
                });
            }
            for (k, ta) in fa.iter() {
                let tb = fb.get(k).unwrap();
                unify(ta, tb, subst)?;
            }
            Ok(())
        }

        _ => Err(TypeError::TypeMismatch {
            expected: a,
            found: b,
        }),
    }
}
