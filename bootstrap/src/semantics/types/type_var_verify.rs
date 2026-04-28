use super::types::Type;
use std::collections::HashMap;

/// Walk a type recursively, returning true if any Type::Var is found.
fn contains_type_var(ty: &Type) -> bool {
    match ty {
        Type::Var(_) => true,
        Type::Func { params, ret, .. } => {
            params.iter().any(contains_type_var) || contains_type_var(ret)
        }
        Type::Record(fields) => fields.values().any(contains_type_var),
        Type::Struct { fields, .. } => fields.values().any(contains_type_var),
        Type::Tuple(items) => items.iter().any(contains_type_var),
        Type::Slice(elem) => contains_type_var(elem),
        Type::App(_, args) => args.iter().any(contains_type_var),
        Type::Primitive(_) | Type::Enum(_) => false,
    }
}

/// Assert that no `Type::Var` remains in the TypeTable after Phase 2 type checking.
///
/// Returns `Ok(())` if all types are concrete, or `Err(ids)` listing every
/// expression ID whose inferred type still contains a type variable.
/// Any entry in `Err` is a compiler bug — the type checker failed to resolve
/// a type variable that should have been unified away.
pub fn verify_no_type_vars(type_map: &HashMap<usize, Type>) -> Result<(), Vec<usize>> {
    let offenders: Vec<usize> = type_map
        .iter()
        .filter(|(_, ty)| contains_type_var(ty))
        .map(|(&id, _)| id)
        .collect();

    if offenders.is_empty() {
        Ok(())
    } else {
        Err(offenders)
    }
}
