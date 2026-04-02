use crate::util::id_provider::*;
use crate::util::formatters::tree_formatter::*;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct MetaAst {
    pub sem_root_stmts: Vec<usize>,
    exprs: HashMap<usize, MetaExpr>,
    stmts: HashMap<usize, MetaStmt>,
}

#[derive(Debug)]
pub enum MetaAstNode {
    Stmt(usize),
    Expr(usize),
}

impl MetaAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id_provider: &mut IdProvider, expr: MetaExpr) -> usize {
        let id = id_provider.next();
        self.exprs.insert(id, expr);
        id
    }

    pub fn insert_stmt(&mut self, id_provider: &mut IdProvider, stmt: MetaStmt) -> usize {
        let id = id_provider.next();
        self.stmts.insert(id, stmt);
        id
    }

    pub fn get_expr(&self, id: usize) -> Option<&MetaExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: usize) -> Option<&MetaStmt> {
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
        fields: Vec<(String, usize)>,
    },

    Variable(String),

    List(Vec<usize>),

    Call {
        callee: String,
        args: Vec<usize>,
    },

    DotAccess {
        object: usize,
        field: String,
    },

    DotCall {
        object: usize,
        method: String,
        args: Vec<usize>,
    },

    Index {
        object: usize,
        index: usize,
    },

    Typeof(String),

    Embed(String),

    EnumConstructor {
        enum_name: String,
        variant: String,
        payload: ConstructorPayload,
    },

    // BINOPS
    Add(usize, usize),
    Sub(usize, usize),
    Mult(usize, usize),
    Div(usize, usize),
    Equals(usize, usize),
    NotEquals(usize, usize),
    Lt(usize, usize),
    Gt(usize, usize),
    Lte(usize, usize),
    Gte(usize, usize),
    And(usize, usize),
    Or(usize, usize),
    Not(usize),

    Tuple(Vec<usize>),
    TupleIndex {
        object: usize,
        index: usize,
    },
}

#[derive(Debug, Clone)]
pub enum MetaStmt {
    // RAW EXPR STMTS
    ExprStmt(usize),

    // DECLARATION
    VarDecl {
        name: String,
        type_annotation: Option<String>,
        expr: usize,
    },

    Assign {
        name: String,
        expr: usize,
    },

    IndexAssign {
        name: String,
        indices: Vec<usize>,
        expr: usize,
    },

    FnDecl {
        name: String,
        params: Vec<Param>,
        body: usize,
    },

    StructDecl {
        name: String,
        fields: Vec<MetaFieldDecl>,
    },

    EnumDecl {
        name: String,
        variants: Vec<EnumVariant>,
    },

    Match {
        scrutinee: usize,
        arms: Vec<MatchArm>,
    },

    // CONTROL
    If {
        cond: usize,
        body: usize,
        else_branch: Option<usize>,
    },

    WhileLoop {
        cond: usize,
        body: usize,
    },

    ForEach {
        var: String,
        iterable: usize,
        body: usize,
    },

    Return(Option<usize>),

    Block(Vec<usize>),

    // UTIL
    Import(ImportDecl),

    // META
    MetaBlock(usize),
    MetaFnDecl {
        name: String,
        params: Vec<Param>,
        body: usize,
    },
    Gen(Vec<usize>),

    // TEMPORARY
    Print(usize),

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
}

#[derive(Debug, Clone)]
pub struct ImplMethodDecl {
    pub name: String,
    pub params: Vec<Param>,  // first param is typically "self"
    pub body: usize,
}

#[derive(Debug, Clone)]
pub struct EnumVariant {
    pub name: String,
    pub payload: VariantPayload,
}

#[derive(Debug, Clone)]
pub enum VariantPayload {
    Unit,
    Tuple(Vec<String>),
    Struct(Vec<MetaFieldDecl>),
}

#[derive(Debug, Clone)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: usize,
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
    Tuple(Vec<usize>),
    Struct(Vec<(String, usize)>),
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub ty: Option<String>,
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
    pub fn inject_stmt(&mut self, stmt: MetaStmt) -> usize {
        let max_stmt = self.stmts.keys().max().copied().unwrap_or(0);
        let max_expr = self.exprs.keys().max().copied().unwrap_or(0);
        let id = max_stmt.max(max_expr) + 1;
        self.stmts.insert(id, stmt);
        id
    }

    /// Remove a stmt by ID (does not touch `sem_root_stmts`).
    pub fn remove_stmt(&mut self, id: usize) {
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
    fn convert_stmt(&self, id: usize) -> TreeNode {
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

            MetaStmt::FnDecl { name, params, body } => (
                "FnDecl".into(),
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

            MetaStmt::EnumDecl { name, variants } => (
                "EnumDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
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
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: usize) -> TreeNode {
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
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
