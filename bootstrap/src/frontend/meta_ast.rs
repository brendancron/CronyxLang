use crate::util::id_provider::*;
use crate::util::formatters::tree_formatter::*;
use crate::util::node_id::MetaNodeId;
use std::collections::HashMap;

/// Loop variable binding in a `for` statement.
#[derive(Debug, Clone)]
pub enum ForVar {
    /// `for (x in ...)` — binds a single name.
    Name(String),
    /// `for ((a, b) in ...)` — destructures a tuple element.
    Tuple(Vec<String>),
}

impl std::fmt::Display for ForVar {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ForVar::Name(n) => write!(f, "{n}"),
            ForVar::Tuple(names) => write!(f, "({})", names.join(", ")),
        }
    }
}

impl From<String> for ForVar {
    fn from(s: String) -> Self { ForVar::Name(s) }
}

impl From<&str> for ForVar {
    fn from(s: &str) -> Self { ForVar::Name(s.to_string()) }
}

/// Structured representation of a type expression in source position.
/// Used in GADT variant payloads and return-type annotations.
#[derive(Debug, Clone)]
pub enum MetaTypeExpr {
    Named(String),
    App(String, Vec<MetaTypeExpr>),
    Tuple(Vec<MetaTypeExpr>),
    Slice(Box<MetaTypeExpr>),
}

impl std::fmt::Display for MetaTypeExpr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetaTypeExpr::Named(n) => write!(f, "{n}"),
            MetaTypeExpr::App(name, args) => {
                let s: Vec<String> = args.iter().map(|a| a.to_string()).collect();
                write!(f, "{name}<{}>", s.join(", "))
            }
            MetaTypeExpr::Tuple(elems) => {
                let s: Vec<String> = elems.iter().map(|e| e.to_string()).collect();
                write!(f, "({})", s.join(", "))
            }
            MetaTypeExpr::Slice(inner) => write!(f, "[{inner}]"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct MetaAst {
    pub sem_root_stmts: Vec<MetaNodeId>,
    exprs: HashMap<MetaNodeId, MetaExpr>,
    stmts: HashMap<MetaNodeId, MetaStmt>,
}

#[derive(Debug)]
pub enum MetaAstNode {
    Stmt(MetaNodeId),
    Expr(MetaNodeId),
}

impl MetaAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id_provider: &mut IdProvider, expr: MetaExpr) -> MetaNodeId {
        let id = id_provider.next_meta();
        self.exprs.insert(id, expr);
        id
    }

    pub fn insert_stmt(&mut self, id_provider: &mut IdProvider, stmt: MetaStmt) -> MetaNodeId {
        let id = id_provider.next_meta();
        self.stmts.insert(id, stmt);
        id
    }

    pub fn get_expr(&self, id: MetaNodeId) -> Option<&MetaExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: MetaNodeId) -> Option<&MetaStmt> {
        self.stmts.get(&id)
    }
}

#[derive(Debug, Clone)]
pub enum MetaExpr {
    // LITERAL REPRESENTATION
    Int(i64),
    String(String),
    Bool(bool),

    StructLiteral {
        type_name: String,
        fields: Vec<(String, MetaNodeId)>,
    },

    Variable(String),

    List(Vec<MetaNodeId>),

    Call {
        callee: String,
        args: Vec<MetaNodeId>,
    },

    DotAccess {
        object: MetaNodeId,
        field: String,
    },

    DotCall {
        object: MetaNodeId,
        method: String,
        args: Vec<MetaNodeId>,
    },

    Index {
        object: MetaNodeId,
        index: MetaNodeId,
    },

    Typeof(String),

    Embed(String),

    EnumConstructor {
        enum_name: String,
        variant: String,
        payload: ConstructorPayload,
    },

    // BINOPS
    Add(MetaNodeId, MetaNodeId),
    Sub(MetaNodeId, MetaNodeId),
    Mult(MetaNodeId, MetaNodeId),
    Div(MetaNodeId, MetaNodeId),
    Mod(MetaNodeId, MetaNodeId),
    Equals(MetaNodeId, MetaNodeId),
    NotEquals(MetaNodeId, MetaNodeId),
    Lt(MetaNodeId, MetaNodeId),
    Gt(MetaNodeId, MetaNodeId),
    Lte(MetaNodeId, MetaNodeId),
    Gte(MetaNodeId, MetaNodeId),
    And(MetaNodeId, MetaNodeId),
    Or(MetaNodeId, MetaNodeId),
    Not(MetaNodeId),

    Tuple(Vec<MetaNodeId>),
    TupleIndex {
        object: MetaNodeId,
        index: usize,
    },

    SliceRange {
        object: MetaNodeId,
        start: Option<MetaNodeId>,
        end: Option<MetaNodeId>,
    },

    Lambda {
        params: Vec<String>,
        body: MetaNodeId,
    },

    /// `resume` or `resume(expr)` used as an expression (returns the continuation's value).
    ResumeExpr(Option<MetaNodeId>),

    /// `run { body } handle eff1 { ops } handle eff2 { ops } ...`
    RunHandle {
        body: MetaNodeId,
        /// (effect_name, [WithFn/WithCtl stmt IDs])
        effects: Vec<(String, Vec<MetaNodeId>)>,
    },

    /// `run { body } with handler_name`
    RunWith {
        body: MetaNodeId,
        handler_name: String,
    },
}

#[derive(Debug, Clone)]
pub enum EffectOpKind {
    Fn,
    Ctl,
}

#[derive(Debug, Clone)]
pub struct EffectOp {
    pub kind: EffectOpKind,
    pub name: String,
    pub params: Vec<Param>,
    pub ret_ty: Option<String>,
}

#[derive(Debug, Clone)]
pub enum MetaStmt {
    // RAW EXPR STMTS
    ExprStmt(MetaNodeId),

    // DECLARATION
    VarDecl {
        name: String,
        type_annotation: Option<MetaTypeExpr>,
        expr: MetaNodeId,
    },

    Assign {
        name: String,
        expr: MetaNodeId,
    },

    IndexAssign {
        name: String,
        indices: Vec<MetaNodeId>,
        expr: MetaNodeId,
    },

    DotAssign {
        object: String,
        field: String,
        expr: MetaNodeId,
    },

    FnDecl {
        name: String,
        params: Vec<Param>,
        type_params: Vec<String>,
        ret_ty: Option<MetaTypeExpr>,
        body: MetaNodeId,
    },

    StructDecl {
        name: String,
        fields: Vec<MetaFieldDecl>,
    },

    EnumDecl {
        name: String,
        type_params: Vec<String>,
        variants: Vec<EnumVariant>,
    },

    Match {
        scrutinee: MetaNodeId,
        arms: Vec<MatchArm>,
    },

    // CONTROL
    If {
        cond: MetaNodeId,
        body: MetaNodeId,
        else_branch: Option<MetaNodeId>,
    },

    WhileLoop {
        cond: MetaNodeId,
        body: MetaNodeId,
    },

    ForEach {
        var: ForVar,
        iterable: MetaNodeId,
        body: MetaNodeId,
    },

    Return(Option<MetaNodeId>),

    Block(Vec<MetaNodeId>),

    // UTIL
    Import(ImportDecl),

    // META
    MetaBlock(MetaNodeId),
    MetaFnDecl {
        name: String,
        params: Vec<Param>,
        body: MetaNodeId,
    },
    Gen(Vec<MetaNodeId>),

    // EFFECTS
    EffectDecl {
        name: String,
        type_params: Vec<String>,
        ops: Vec<EffectOp>,
    },

    /// `handler name : effect_name { ops }` or `handle name { ops }`
    HandlerDef {
        name: String,
        effect_name: Option<String>,
        ops: Vec<MetaNodeId>,
    },

    WithFn {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: MetaNodeId,
    },

    WithCtl {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: MetaNodeId,
    },

    /// `resume` or `resume expr`
    Resume(Option<MetaNodeId>),

    // TEMPORARY
    Print(MetaNodeId),

    TraitDecl {
        name: String,
        /// Method names declared in the trait (signatures only — no bodies).
        methods: Vec<String>,
    },

    ImplDecl {
        trait_name: String,
        type_name: String,
        methods: Vec<ImplMethodDecl>,
    },

    /// `defer <stmt>` — executes deferred stmt in LIFO order when the enclosing block exits.
    Defer(MetaNodeId),
}

#[derive(Debug, Clone)]
pub struct ImplMethodDecl {
    pub name: String,
    pub params: Vec<Param>,  // first param is typically "self"
    pub body: MetaNodeId,
}

#[derive(Debug, Clone)]
pub struct EnumVariant {
    pub name: String,
    /// Type variables scoped to this constructor, e.g. `["A"]` for `If<A>(...)`.
    pub local_type_params: Vec<String>,
    pub payload: VariantPayload,
    /// GADT return-type annotation, e.g. `Some(App("Expr", [Named("A")]))` for `: Expr<A>`.
    pub return_type: Option<MetaTypeExpr>,
}

#[derive(Debug, Clone)]
pub enum VariantPayload {
    Unit,
    Tuple(Vec<MetaTypeExpr>),
    Struct(Vec<MetaFieldDecl>),
}

#[derive(Debug, Clone)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: MetaNodeId,
}

#[derive(Debug, Clone)]
pub enum Pattern {
    Wildcard,
    Enum {
        enum_name: String,
        variant: String,
        bindings: VariantBindings,
    },
}

#[derive(Debug, Clone)]
pub enum VariantBindings {
    Unit,
    Tuple(Vec<String>),
    Struct(Vec<String>),
}

#[derive(Debug, Clone)]
pub enum ConstructorPayload {
    Unit,
    Tuple(Vec<MetaNodeId>),
    Struct(Vec<(String, MetaNodeId)>),
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub ty: Option<MetaTypeExpr>,
}

#[derive(Debug, Clone)]
pub struct MetaFieldDecl {
    pub field_name: String,
    pub type_name: String,
}

#[derive(Debug, Clone)]
pub enum ImportDecl {
    /// `import "path";`
    Qualified { path: String },
    /// `import "path" as alias;`
    Aliased { path: String, alias: String },
    /// `import { name1, name2 } from "path";`
    Selective { names: Vec<String>, path: String },
    /// `import "dir/*";` — expanded to Qualified imports by the module loader before
    /// the rest of the pipeline sees it; never appears in a fully-loaded compilation.
    Wildcard { path: String },
}

impl ImportDecl {
    pub fn path(&self) -> &str {
        match self {
            ImportDecl::Qualified { path } => path,
            ImportDecl::Aliased { path, .. } => path,
            ImportDecl::Selective { path, .. } => path,
            ImportDecl::Wildcard { path } => path,
        }
    }
}

impl MetaAst {
    /// Insert a stmt with a freshly-generated ID that is guaranteed not to collide
    /// with any existing stmt or expr ID.  Useful for post-parse transformations.
    pub fn inject_stmt(&mut self, stmt: MetaStmt) -> MetaNodeId {
        let max_stmt = self.stmts.keys().map(|k| k.0).max().unwrap_or(0);
        let max_expr = self.exprs.keys().map(|k| k.0).max().unwrap_or(0);
        let id = MetaNodeId(max_stmt.max(max_expr) + 1);
        self.stmts.insert(id, stmt);
        id
    }

    /// Remove a stmt by ID (does not touch `sem_root_stmts`).
    pub fn remove_stmt(&mut self, id: MetaNodeId) {
        self.stmts.remove(&id);
    }
}

impl AsTree for MetaAst {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        for stmt_id in self.sem_root_stmts.iter() {
            nodes.push(self.convert_stmt(*stmt_id));
        }
        nodes
    }
}

impl MetaAst {
    fn convert_stmt(&self, id: MetaNodeId) -> TreeNode {
        let stmt = self.get_stmt(id).expect("invalid stmt id");

        let (label, mut children): (String, Vec<TreeNode>) = match stmt {
            MetaStmt::ExprStmt(e) => ("ExprStmt".into(), vec![self.convert_expr(*e)]),

            MetaStmt::VarDecl { name, type_annotation, expr } => (
                "VarDecl".into(),
                vec![
                    TreeNode::leaf(match type_annotation {
                        Some(ty) => format!("Name({name}: {ty})"),
                        None => format!("Name({name})"),
                    }),
                    self.convert_expr(*expr),
                ],
            ),

            MetaStmt::Assign { name, expr } => (
                "Assign".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    self.convert_expr(*expr),
                ],
            ),

            MetaStmt::IndexAssign { name, indices, expr } => (
                "IndexAssign".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(indices.iter().map(|i| self.convert_expr(*i)))
                    .chain(std::iter::once(self.convert_expr(*expr)))
                    .collect(),
            ),

            MetaStmt::DotAssign { object, field, expr } => (
                format!("DotAssign({object}.{field})"),
                vec![self.convert_expr(*expr)],
            ),

            MetaStmt::FnDecl { name, params, type_params, ret_ty, body } => (
                "FnDecl".into(),
                vec![
                    TreeNode::leaf(if type_params.is_empty() {
                        format!("Name({name})")
                    } else {
                        format!("Name({name}<{}>)", type_params.join(", "))
                    }),
                    TreeNode::node(
                        "Params",
                        params.iter().map(|p| TreeNode::leaf(match &p.ty {
                            Some(ty) => format!("{}: {ty}", p.name),
                            None => p.name.clone(),
                        })).collect(),
                    ),
                    TreeNode::leaf(match ret_ty {
                        Some(ty) => format!("Ret({ty})"),
                        None => "Ret(unit)".into(),
                    }),
                    self.convert_stmt(*body),
                ],
            ),

            MetaStmt::StructDecl { name, fields } => (
                "StructDecl".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    TreeNode::node(
                        "Fields",
                        fields
                            .iter()
                            .map(|f| TreeNode::leaf(format!("{}: {}", f.field_name, f.type_name)))
                            .collect(),
                    ),
                ],
            ),

            MetaStmt::If {
                cond,
                body,
                else_branch,
            } => {
                let mut v = vec![
                    TreeNode::node("Cond", vec![self.convert_expr(*cond)]),
                    TreeNode::node("Then", vec![self.convert_stmt(*body)]),
                ];
                if let Some(e) = else_branch {
                    v.push(TreeNode::node("Else", vec![self.convert_stmt(*e)]));
                }
                ("IfStmt".into(), v)
            }

            MetaStmt::WhileLoop { cond, body } => (
                "WhileLoop".into(),
                vec![
                    TreeNode::node("Cond", vec![self.convert_expr(*cond)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

            MetaStmt::ForEach {
                var,
                iterable,
                body,
            } => (
                "ForEachStmt".into(),
                vec![
                    TreeNode::leaf(format!("Var({var})")),
                    TreeNode::node("Iterable", vec![self.convert_expr(*iterable)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

            MetaStmt::Return(e) => (
                "ReturnStmt".into(),
                e.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),

            MetaStmt::Block(stmts) => (
                "Block".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            MetaStmt::Import(decl) => ("Import".into(), vec![TreeNode::leaf(decl.path().to_string())]),

            MetaStmt::EnumDecl { name, type_params, variants } => (
                "EnumDecl".into(),
                std::iter::once(TreeNode::leaf(if type_params.is_empty() {
                    format!("Name({name})")
                } else {
                    format!("Name({name}<{}>)", type_params.join(", "))
                }))
                    .chain(variants.iter().map(|v| TreeNode::leaf(format!("Variant({})", v.name))))
                    .collect(),
            ),

            MetaStmt::Match { scrutinee, arms } => (
                "Match".into(),
                std::iter::once(TreeNode::node("Scrutinee", vec![self.convert_expr(*scrutinee)]))
                    .chain(arms.iter().map(|arm| {
                        TreeNode::node("Arm", vec![
                            TreeNode::leaf(format!("{:?}", arm.pattern)),
                            self.convert_stmt(arm.body),
                        ])
                    }))
                    .collect(),
            ),

            MetaStmt::MetaBlock(s) => ("MetaBlock".into(), vec![self.convert_stmt(*s)]),

            MetaStmt::MetaFnDecl { name, params, body } => (
                "MetaFnDecl".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    TreeNode::node(
                        "Params",
                        params.iter().map(|p| TreeNode::leaf(match &p.ty {
                            Some(ty) => format!("{}: {}", p.name, ty),
                            None => p.name.clone(),
                        })).collect(),
                    ),
                    self.convert_stmt(*body),
                ],
            ),

            MetaStmt::Gen(stmts) => (
                "Gen".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            MetaStmt::Print(e) => ("PrintStmt".into(), vec![self.convert_expr(*e)]),

            MetaStmt::TraitDecl { name, methods } => (
                "TraitDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(methods.iter().map(|m| TreeNode::leaf(format!("Method({m})"))))
                    .collect(),
            ),

            MetaStmt::ImplDecl { trait_name, type_name, methods } => (
                "ImplDecl".into(),
                std::iter::once(TreeNode::leaf(format!("{trait_name} for {type_name}")))
                    .chain(methods.iter().map(|m| TreeNode::leaf(format!("Method({})", m.name))))
                    .collect(),
            ),

            MetaStmt::EffectDecl { name, ops, .. } => (
                "EffectDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(ops.iter().map(|op| TreeNode::leaf(format!(
                        "{:?} {}({}): {}",
                        op.kind, op.name,
                        op.params.iter().map(|p| p.name.clone()).collect::<Vec<_>>().join(", "),
                        op.ret_ty.as_deref().unwrap_or("unit"),
                    ))))
                    .collect(),
            ),

            MetaStmt::WithFn { op_name, params, ret_ty, body } => (
                "WithFn".into(),
                vec![
                    TreeNode::leaf(format!("Op({op_name}): {}", ret_ty.as_deref().unwrap_or("unit"))),
                    TreeNode::node(
                        "Params",
                        params.iter().map(|p| TreeNode::leaf(match &p.ty {
                            Some(ty) => format!("{}: {}", p.name, ty),
                            None => p.name.clone(),
                        })).collect(),
                    ),
                    self.convert_stmt(*body),
                ],
            ),

            MetaStmt::WithCtl { op_name, params, ret_ty, body } => (
                "WithCtl".into(),
                vec![
                    TreeNode::leaf(format!("Op({op_name}): {}", ret_ty.as_deref().unwrap_or("unit"))),
                    TreeNode::node(
                        "Params",
                        params.iter().map(|p| TreeNode::leaf(match &p.ty {
                            Some(ty) => format!("{}: {}", p.name, ty),
                            None => p.name.clone(),
                        })).collect(),
                    ),
                    self.convert_stmt(*body),
                ],
            ),

            MetaStmt::HandlerDef { name, effect_name, ops } => (
                format!("HandlerDef({}{})", name, effect_name.as_deref().map(|e| format!(":{e}")).unwrap_or_default()),
                ops.iter().map(|&s| self.convert_stmt(s)).collect(),
            ),

            MetaStmt::Resume(opt_expr) => (
                "Resume".into(),
                opt_expr.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),

            MetaStmt::Defer(stmt) => (
                "Defer".into(),
                vec![self.convert_stmt(*stmt)],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: MetaNodeId) -> TreeNode {
        let expr = self.get_expr(id).expect("invalid expr id");

        let (label, mut children) = match expr {
            MetaExpr::Int(v) => ("Int".into(), vec![TreeNode::leaf(v.to_string())]),

            MetaExpr::String(s) => ("String".into(), vec![TreeNode::leaf(format!("\"{s}\""))]),

            MetaExpr::Bool(b) => ("Bool".into(), vec![TreeNode::leaf(b.to_string())]),

            MetaExpr::Variable(name) => ("Var".into(), vec![TreeNode::leaf(name.clone())]),

            MetaExpr::StructLiteral { type_name, fields } => (
                format!("StructLiteral({type_name})"),
                fields
                    .iter()
                    .map(|(n, e)| TreeNode::node(n.clone(), vec![self.convert_expr(*e)]))
                    .collect(),
            ),

            MetaExpr::List(items) => (
                "List".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            MetaExpr::Call { callee, args } => (
                format!("Call({callee})"),
                args.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            MetaExpr::DotAccess { object, field } => (
                format!("DotAccess(.{field})"),
                vec![self.convert_expr(*object)],
            ),

            MetaExpr::DotCall { object, method, args } => (
                format!("DotCall(.{method})"),
                std::iter::once(self.convert_expr(*object))
                    .chain(args.iter().map(|e| self.convert_expr(*e)))
                    .collect(),
            ),

            MetaExpr::Index { object, index } => (
                "Index".into(),
                vec![self.convert_expr(*object), self.convert_expr(*index)],
            ),

            MetaExpr::EnumConstructor { enum_name, variant, payload } => (
                format!("EnumConstructor({enum_name}::{variant})"),
                match payload {
                    ConstructorPayload::Unit => vec![],
                    ConstructorPayload::Tuple(exprs) => exprs.iter().map(|e| self.convert_expr(*e)).collect(),
                    ConstructorPayload::Struct(fields) => fields.iter()
                        .map(|(n, e)| TreeNode::node(n.clone(), vec![self.convert_expr(*e)]))
                        .collect(),
                },
            ),

            MetaExpr::Typeof(name) => ("Typeof".into(), vec![TreeNode::leaf(name.clone())]),

            MetaExpr::Embed(path) => ("Embed".into(), vec![TreeNode::leaf(path.clone())]),

            MetaExpr::Add(a, b) => (
                "Add".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            MetaExpr::Sub(a, b) => (
                "Sub".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            MetaExpr::Mult(a, b) => (
                "Mult".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            MetaExpr::Div(a, b) => (
                "Div".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            MetaExpr::Mod(a, b) => (
                "Mod".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            MetaExpr::Equals(a, b) => (
                "Equals".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::NotEquals(a, b) => (
                "NotEquals".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Lt(a, b) => (
                "Lt".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Gt(a, b) => (
                "Gt".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Lte(a, b) => (
                "Lte".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Gte(a, b) => (
                "Gte".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::And(a, b) => (
                "And".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Or(a, b) => (
                "Or".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            MetaExpr::Not(a) => (
                "Not".into(),
                vec![self.convert_expr(*a)],
            ),
            MetaExpr::Tuple(items) => (
                "Tuple".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),
            MetaExpr::TupleIndex { object, index } => (
                format!("TupleIndex(.{index})"),
                vec![self.convert_expr(*object)],
            ),
            MetaExpr::SliceRange { object, start, end } => (
                "SliceRange".into(),
                std::iter::once(self.convert_expr(*object))
                    .chain(start.map(|s| self.convert_expr(s)))
                    .chain(end.map(|e| self.convert_expr(e)))
                    .collect(),
            ),
            MetaExpr::Lambda { params, body } => (
                format!("Lambda({})", params.join(", ")),
                vec![self.convert_stmt(*body)],
            ),
            MetaExpr::ResumeExpr(opt) => (
                "ResumeExpr".into(),
                opt.map(|e| vec![self.convert_expr(e)]).unwrap_or_default(),
            ),
            MetaExpr::RunHandle { body, effects } => (
                "RunHandle".into(),
                std::iter::once(self.convert_stmt(*body))
                    .chain(effects.iter().flat_map(|(_, stmts)| stmts.iter().map(|&s| self.convert_stmt(s))))
                    .collect(),
            ),
            MetaExpr::RunWith { body, handler_name } => (
                format!("RunWith({})", handler_name),
                vec![self.convert_stmt(*body)],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
