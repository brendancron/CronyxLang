use crate::util::formatters::tree_formatter::*;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct StagedAst {
    pub sem_root_stmts: Vec<usize>,
    pub exprs: HashMap<usize, StagedExpr>,
    pub stmts: HashMap<usize, StagedStmt>,
}

impl StagedAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id: usize, expr: StagedExpr) {
        self.exprs.insert(id, expr);
    }

    pub fn insert_stmt(&mut self, id: usize, stmt: StagedStmt) {
        self.stmts.insert(id, stmt);
    }

    pub fn get_expr(&self, id: usize) -> Option<&StagedExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: usize) -> Option<&StagedStmt> {
        self.stmts.get(&id)
    }
}

// For util purposes

#[derive(Debug, Clone)]
pub enum StagedNode {
    Expr(StagedExpr),
    Stmt(StagedStmt),
}

#[derive(Debug, Clone)]
pub struct MetaRef {
    pub ast_ref: usize,
}

#[derive(Debug, Clone)]
pub enum StagedExpr {
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

    // BINOPS
    Add(usize, usize),
    Sub(usize, usize),
    Mult(usize, usize),
    Div(usize, usize),
    Equals(usize, usize),

    MetaExpr(MetaRef),
}

#[derive(Debug, Clone)]
pub enum StagedStmt {
    // RAW EXPR STMTS
    ExprStmt(usize),

    // DECLARATION
    VarDecl {
        name: String,
        expr: usize,
    },

    FnDecl {
        name: String,
        params: Vec<String>,
        body: usize,
    },

    StructDecl {
        name: String,
        fields: Vec<StagedFieldDecl>,
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
    Import(String),

    // META
    Gen(Vec<usize>),
    MetaStmt(MetaRef),

    // TEMPORARY
    Print(usize),
}

#[derive(Debug, Clone)]
pub struct StagedFieldDecl {
    pub field_name: String,
    pub type_name: String,
}

impl AsTree for StagedAst {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        for stmt_id in self.sem_root_stmts.iter() {
            nodes.push(self.convert_stmt(*stmt_id));
        }
        nodes
    }
}

impl StagedAst {
    fn convert_stmt(&self, id: usize) -> TreeNode {
        let stmt = self
            .get_stmt(id)
            .unwrap_or_else(|| panic!("invalid stmt id: {}", id));

        let (label, mut children): (String, Vec<TreeNode>) = match stmt {
            StagedStmt::ExprStmt(e) => ("ExprStmt".into(), vec![self.convert_expr(*e)]),

            StagedStmt::VarDecl { name, expr } => (
                "VarDecl".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    self.convert_expr(*expr),
                ],
            ),

            StagedStmt::FnDecl { name, params, body } => (
                "FnDecl".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    TreeNode::node(
                        "Params",
                        params.iter().map(|p| TreeNode::leaf(p.clone())).collect(),
                    ),
                    self.convert_stmt(*body),
                ],
            ),

            StagedStmt::StructDecl { name, fields } => (
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

            StagedStmt::If {
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

            StagedStmt::ForEach {
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

            StagedStmt::Return(e) => (
                "ReturnStmt".into(),
                e.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),

            StagedStmt::Block(stmts) => (
                "Block".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            StagedStmt::Import(path) => ("Import".into(), vec![TreeNode::leaf(path.clone())]),

            StagedStmt::Gen(stmts) => (
                "Gen".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            StagedStmt::MetaStmt(meta_ref) => (
                "MetaRef".into(),
                vec![TreeNode::leaf(meta_ref.ast_ref.to_string())],
            ),

            StagedStmt::Print(e) => ("PrintStmt".into(), vec![self.convert_expr(*e)]),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: usize) -> TreeNode {
        let expr = self.get_expr(id).expect("invalid expr id");

        let (label, mut children) = match expr {
            StagedExpr::Int(v) => ("Int".into(), vec![TreeNode::leaf(v.to_string())]),

            StagedExpr::String(s) => ("String".into(), vec![TreeNode::leaf(format!("\"{s}\""))]),

            StagedExpr::Bool(b) => ("Bool".into(), vec![TreeNode::leaf(b.to_string())]),

            StagedExpr::Variable(name) => ("Var".into(), vec![TreeNode::leaf(name.clone())]),

            StagedExpr::StructLiteral { type_name, fields } => (
                format!("StructLiteral({type_name})"),
                fields
                    .iter()
                    .map(|(n, e)| TreeNode::node(n.clone(), vec![self.convert_expr(*e)]))
                    .collect(),
            ),

            StagedExpr::List(items) => (
                "List".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            StagedExpr::Call { callee, args } => (
                format!("Call({callee})"),
                args.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            StagedExpr::Add(a, b) => (
                "Add".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            StagedExpr::Sub(a, b) => (
                "Sub".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            StagedExpr::Mult(a, b) => (
                "Mult".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            StagedExpr::Div(a, b) => (
                "Div".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            StagedExpr::Equals(a, b) => (
                "Equals".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            StagedExpr::MetaExpr(meta_ref) => (
                "MetaRef".into(),
                vec![TreeNode::leaf(meta_ref.ast_ref.to_string())],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
