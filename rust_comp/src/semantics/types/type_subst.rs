use super::type_error::TypeError;
use super::types::{Type, TypeVar};
use std::collections::HashMap;

#[derive(Clone)]
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
            Type::Var(tv) => match subst.map.get(tv) {
                Some(t) => t.apply(subst),  // follow substitution chains
                None => self.clone(),
            },
            Type::Func { params, ret, effects } => Type::Func {
                params: params.iter().map(|t| t.apply(subst)).collect(),
                ret: Box::new(ret.apply(subst)),
                effects: effects.clone(),
            },
            Type::Record(fields) => Type::Record(
                fields.iter().map(|(k, v)| (k.clone(), v.apply(subst))).collect()
            ),
            Type::Struct { name, fields } => Type::Struct {
                name: name.clone(),
                fields: fields.iter().map(|(k, v)| (k.clone(), v.apply(subst))).collect(),
            },
            Type::Tuple(items) => Type::Tuple(items.iter().map(|t| t.apply(subst)).collect()),
            Type::Slice(elem) => Type::Slice(Box::new(elem.apply(subst))),
            Type::App(name, args) => Type::App(name.clone(), args.iter().map(|t| t.apply(subst)).collect()),
            _ => self.clone(),
        }
    }
}

fn contains(tv: TypeVar, ty: &Type) -> bool {
    match ty {
        Type::Var(v) => *v == tv,
        Type::Func { params, ret, .. } => params.iter().any(|p| contains(tv, p)) || contains(tv, ret),
        Type::Tuple(items) => items.iter().any(|t| contains(tv, t)),
        Type::Slice(elem) => contains(tv, elem),
        Type::App(_, args) => args.iter().any(|t| contains(tv, t)),
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
                return Err(TypeError::unsupported());
            }

            subst.map.insert(*v, t.clone());
            Ok(())
        }

        (_, Type::Var(_)) => unify(&b, &a, subst),

        (Type::Primitive(p1), Type::Primitive(p2)) if p1 == p2 => Ok(()),

        (
            Type::Func { params: p1, ret: r1, .. },
            Type::Func { params: p2, ret: r2, .. },
        ) => {
            if p1.len() != p2.len() {
                return Err(TypeError::type_mismatch(a, b));
            }

            for (x, y) in p1.iter().zip(p2.iter()) {
                unify(x, y, subst)?;
            }

            unify(r1, r2, subst)
        }

        (Type::Record(fa), Type::Record(fb)) => {
            if fa.keys().collect::<Vec<_>>() != fb.keys().collect::<Vec<_>>() {
                return Err(TypeError::type_mismatch(a, b));
            }
            for (k, ta) in fa.iter() {
                let tb = fb.get(k).ok_or_else(|| TypeError::type_mismatch(a.clone(), b.clone()))?;
                unify(ta, tb, subst)?;
            }
            Ok(())
        }

        (Type::Struct { name: na, fields: fa }, Type::Struct { name: nb, fields: fb }) => {
            if na != nb {
                return Err(TypeError::type_mismatch(a, b));
            }
            if fa.keys().collect::<Vec<_>>() != fb.keys().collect::<Vec<_>>() {
                return Err(TypeError::type_mismatch(a, b));
            }
            for (k, ta) in fa.iter() {
                let tb = fb.get(k).ok_or_else(|| TypeError::type_mismatch(a.clone(), b.clone()))?;
                unify(ta, tb, subst)?;
            }
            Ok(())
        }

        (Type::Slice(ea), Type::Slice(eb)) => unify(ea, eb, subst),

        (Type::Tuple(ta), Type::Tuple(tb)) => {
            if ta.len() != tb.len() {
                return Err(TypeError::type_mismatch(a, b));
            }
            for (x, y) in ta.iter().zip(tb.iter()) {
                unify(x, y, subst)?;
            }
            Ok(())
        }

        (Type::Enum(na), Type::Enum(nb)) if na == nb => Ok(()),

        (Type::App(na, aa), Type::App(nb, ab)) if na == nb && aa.len() == ab.len() => {
            for (x, y) in aa.iter().zip(ab.iter()) {
                unify(x, y, subst)?;
            }
            Ok(())
        }

        _ => Err(TypeError::type_mismatch(a, b)),
    }
}
