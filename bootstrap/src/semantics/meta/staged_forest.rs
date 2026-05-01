use super::meta_process_error::*;
use super::process_dependency::*;
use super::staged_ast::*;
use super::symbol_collector::*;
use crate::util::id_provider::IdProvider;
use crate::util::node_id::StagedNodeId;
use crate::util::formatters::tree_formatter::{AsTree, TreeNode};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// Describes how a module's names should be bound in the runtime environment.
#[derive(Debug, Clone)]
pub enum ModuleBinding {
    /// `import "path"` or `import "path" as alias` — wrap exports in a Module value.
    /// Uses node IDs to avoid name-collision bugs when multiple modules export the same name.
    Namespace {
        bind_name: String,
        /// (user-facing name, staged node ID of the FnDecl).
        exports: Vec<(String, StagedNodeId)>,
    },
    /// Transitive / circular import: the imported file's functions are already hoisted
    /// globally, so we build the namespace by name lookup rather than node ID.
    NamespaceByName {
        bind_name: String,
        names: Vec<String>,
    },
    /// `import { name1, name2 } from "path"` — bind each export directly into scope.
    Selective {
        names: Vec<String>,
    },
}

#[derive(Debug, Clone)]
pub struct StagedForest {
    pub root_id: usize,
    pub ast_map: HashMap<usize, StagedAst>,
    pub dependency_map: HashMap<usize, HashSet<ProcessDependency>>,
    pub source_dir: Option<PathBuf>,

    /// Name → tree_id: what each tree declares at its top level.
    pub symbol_provides: HashMap<String, usize>,
    /// tree_id → names: what each tree references but does not declare internally.
    pub symbol_uses: HashMap<usize, HashSet<String>>,

    /// Module bindings to create in the runtime env before executing entry code.
    pub module_bindings: Vec<ModuleBinding>,

    /// Impl method registry: (type_name, method_name) → mangled_fn_name.
    /// Populated by the stager when processing ImplDecl statements.
    pub impl_registry: Vec<(String, String, String)>,

    /// Operator dispatch registry: (op_trait, type_name) → mangled_fn_name.
    /// Populated when an ImplDecl uses a known operator trait (Add, Sub, Mul, Div, Eq).
    pub op_registry: Vec<(String, String, String)>,

    /// Function names that originated from stdlib auto-imports.
    /// Carried through to RuntimeAst so codegen can skip them.
    pub stdlib_fn_names: std::collections::HashSet<String>,
}

impl StagedForest {
    pub fn new() -> Self {
        StagedForest {
            root_id: 0,
            ast_map: HashMap::new(),
            dependency_map: HashMap::new(),
            source_dir: None,
            symbol_provides: HashMap::new(),
            symbol_uses: HashMap::new(),
            module_bindings: Vec::new(),
            impl_registry: Vec::new(),
            op_registry: Vec::new(),
            stdlib_fn_names: std::collections::HashSet::new(),
        }
    }

    pub fn insert_tree(&mut self, staged_ast: StagedAst, id_provider: &mut IdProvider) -> usize {
        let new_id = id_provider.next();
        self.register_symbols(new_id, &staged_ast);
        self.ast_map.insert(new_id, staged_ast);
        new_id
    }

    pub fn insert_deps(&mut self, dependency_set: HashSet<ProcessDependency>, id: usize) {
        self.dependency_map.insert(id, dependency_set);
    }

    fn register_symbols(&mut self, tree_id: usize, ast: &StagedAst) {
        let provides = collect_provides(ast);
        let external_uses = collect_external_uses(ast);
        for name in provides {
            self.symbol_provides.insert(name, tree_id);
        }
        self.symbol_uses.insert(tree_id, external_uses);
    }

    /// After all trees are staged, resolve symbol uses into SymbolTree dependencies.
    /// Names with no provider are skipped (builtins, runtime-injected names, etc.).
    pub fn resolve_symbol_deps(&mut self) -> Result<(), MetaProcessError> {
        let uses_snapshot: Vec<(usize, HashSet<String>)> = self
            .symbol_uses
            .iter()
            .map(|(&id, names)| (id, names.clone()))
            .collect();

        for (tree_id, uses) in uses_snapshot {
            // Root tree is runtime code — symbol ordering is handled by hoisting, not deps.
            // Only meta child trees need SymbolTree ordering constraints.
            if tree_id == self.root_id {
                continue;
            }
            for name in &uses {
                if let Some(&provider_id) = self.symbol_provides.get(name) {
                    if provider_id != tree_id {
                        self.dependency_map
                            .entry(tree_id)
                            .or_insert_with(HashSet::new)
                            .insert(ProcessDependency::SymbolTree(provider_id));
                    }
                }
            }
        }

        Ok(())
    }
}

impl AsTree for StagedForest {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        nodes.push(TreeNode::leaf(format!("root_id: {}", self.root_id)));

        for (id, ast) in &self.ast_map {
            let ast_nodes = ast.as_tree();
            nodes.push(TreeNode::node(format!("Tree {}", id), ast_nodes));
        }

        nodes
    }
}
