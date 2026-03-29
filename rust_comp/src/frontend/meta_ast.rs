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
}

impl ImportDecl {
    pub fn path(&self) -> &str {
        match self {
            ImportDecl::Qualified { path } => path,
            ImportDecl::Aliased { path, .. } => path,
            ImportDecl::Selective { path, .. } => path,
        }
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
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
