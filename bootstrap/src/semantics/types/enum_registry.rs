use crate::frontend::meta_ast::VariantPayload;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeStmt};
use crate::semantics::types::types::{bool_type, int_type, string_type, unit_type, Type};
use std::collections::HashMap;

/// Payload of a resolved enum variant — field type strings converted to `Type`.
#[derive(Debug, Clone, PartialEq)]
pub enum ResolvedPayload {
    Unit,
    Tuple(Vec<Type>),
    Struct(Vec<(String, Type)>),
}

/// One variant in the registry with its integer tag and resolved payload.
#[derive(Debug, Clone)]
pub struct ResolvedVariant {
    pub name: String,
    pub tag: u32,
    pub payload: ResolvedPayload,
}

/// Maps enum names to their ordered, tagged variant list.
/// Built from `RuntimeStmt::EnumDecl` nodes in the AST before codegen.
#[derive(Debug, Default)]
pub struct EnumRegistry {
    enums: HashMap<String, Vec<ResolvedVariant>>,
}

impl EnumRegistry {
    /// Build the registry by scanning all `EnumDecl` statements in the AST.
    pub fn build(ast: &RuntimeAst) -> Self {
        let mut registry = EnumRegistry::default();
        for stmt in ast.stmts.values() {
            if let RuntimeStmt::EnumDecl { name, variants, .. } = stmt {
                let resolved: Vec<ResolvedVariant> = variants
                    .iter()
                    .enumerate()
                    .map(|(i, v)| ResolvedVariant {
                        name: v.name.clone(),
                        tag: i as u32,
                        payload: resolve_payload(&v.payload),
                    })
                    .collect();
                if let Some(existing) = registry.enums.get(name.as_str()) {
                    // Duplicate EnumDecl (e.g. from module re-imports). Identical
                    // definitions are fine; conflicting ones indicate a compiler bug.
                    debug_assert_eq!(
                        existing.iter().map(|v| &v.name).collect::<Vec<_>>(),
                        resolved.iter().map(|v| &v.name).collect::<Vec<_>>(),
                        "EnumRegistry: conflicting EnumDecl for `{name}`"
                    );
                } else {
                    registry.enums.insert(name.clone(), resolved);
                }
            }
        }
        registry
    }

    /// Look up an enum by name.
    pub fn get(&self, name: &str) -> Option<&Vec<ResolvedVariant>> {
        self.enums.get(name)
    }

    /// Iterate over all registered enums.
    pub fn iter(&self) -> impl Iterator<Item = (&String, &Vec<ResolvedVariant>)> {
        self.enums.iter()
    }
}

/// Resolve a `VariantPayload` (with string type names) to `ResolvedPayload` (with `Type` values).
fn resolve_payload(payload: &VariantPayload) -> ResolvedPayload {
    match payload {
        VariantPayload::Unit => ResolvedPayload::Unit,
        VariantPayload::Tuple(type_exprs) => {
            ResolvedPayload::Tuple(type_exprs.iter().map(|e| resolve_type_name(&e.to_string())).collect())
        }
        VariantPayload::Struct(fields) => {
            ResolvedPayload::Struct(
                fields
                    .iter()
                    .map(|f| (f.field_name.clone(), resolve_type_name(&f.type_name)))
                    .collect(),
            )
        }
    }
}

/// Convert a source-level type name string to a `Type`.
/// Primitives map to their concrete types; everything else becomes `Type::Enum`.
fn resolve_type_name(name: &str) -> Type {
    match name {
        "int"    => int_type(),
        "string" => string_type(),
        "bool"   => bool_type(),
        "unit"   => unit_type(),
        other if other.starts_with('[') && other.ends_with(']') => {
            let inner = &other[1..other.len() - 1];
            Type::Slice(Box::new(resolve_type_name(inner)))
        }
        other    => Type::Enum(other.into()),
    }
}
