use crate::frontend::meta_ast::{
    ConstructorPayload, EffectOp, EnumVariant, ImportDecl, MatchArm, Param,
};
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

#[derive(Debug, Clone, Eq, Hash, PartialEq)]
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

    SliceRange {
        object: usize,
        start: Option<usize>,
        end: Option<usize>,
    },

    Lambda {
        params: Vec<String>,
        body: usize,
    },

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
        params: Vec<String>,
        type_params: Vec<String>,
        body: usize,
    },

    StructDecl {
        name: String,
        fields: Vec<StagedFieldDecl>,
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
    Gen(Vec<usize>),
    MetaStmt(MetaRef),

    // EFFECTS
    EffectDecl {
        name: String,
        ops: Vec<EffectOp>,
    },

    WithFn {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: usize,
    },

    WithCtl {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: usize,
    },

    Resume(Option<usize>),

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

            StagedStmt::Assign { name, expr } => (
                "Assign".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    self.convert_expr(*expr),
                ],
            ),

            StagedStmt::IndexAssign { name, indices, expr } => (
                "IndexAssign".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(indices.iter().map(|i| self.convert_expr(*i)))
                    .chain(std::iter::once(self.convert_expr(*expr)))
                    .collect(),
            ),

            StagedStmt::FnDecl { name, params, type_params: _, body } => (
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

            StagedStmt::WhileLoop { cond, body } => (
                "WhileLoop".into(),
                vec![
                    TreeNode::node("Cond", vec![self.convert_expr(*cond)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

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

            StagedStmt::Import(decl) => ("Import".into(), vec![TreeNode::leaf(decl.path().to_string())]),

            StagedStmt::Gen(stmts) => (
                "Gen".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            StagedStmt::EnumDecl { name, variants } => (
                "EnumDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(variants.iter().map(|v| TreeNode::leaf(format!("Variant({})", v.name))))
                    .collect(),
            ),

            StagedStmt::Match { scrutinee, arms } => (
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

            StagedStmt::MetaStmt(meta_ref) => (
                "MetaRef".into(),
                vec![TreeNode::leaf(meta_ref.ast_ref.to_string())],
            ),

            StagedStmt::Print(e) => ("PrintStmt".into(), vec![self.convert_expr(*e)]),

            StagedStmt::EffectDecl { name, ops } => (
                "EffectDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(ops.iter().map(|op| TreeNode::leaf(op.name.clone())))
                    .collect(),
            ),

            StagedStmt::WithFn { op_name, body, .. } => (
                "WithFn".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            StagedStmt::WithCtl { op_name, body, .. } => (
                "WithCtl".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            StagedStmt::Resume(opt_expr) => (
                "Resume".into(),
                opt_expr.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),
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

            StagedExpr::DotAccess { object, field } => (
                format!("DotAccess(.{field})"),
                vec![self.convert_expr(*object)],
            ),

            StagedExpr::DotCall { object, method, args } => (
                format!("DotCall(.{method})"),
                std::iter::once(self.convert_expr(*object))
                    .chain(args.iter().map(|e| self.convert_expr(*e)))
                    .collect(),
            ),

            StagedExpr::Index { object, index } => (
                "Index".into(),
                vec![self.convert_expr(*object), self.convert_expr(*index)],
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
            StagedExpr::NotEquals(a, b) => (
                "NotEquals".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Lt(a, b) => (
                "Lt".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Gt(a, b) => (
                "Gt".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Lte(a, b) => (
                "Lte".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Gte(a, b) => (
                "Gte".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::And(a, b) => (
                "And".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Or(a, b) => (
                "Or".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),
            StagedExpr::Not(a) => (
                "Not".into(),
                vec![self.convert_expr(*a)],
            ),

            StagedExpr::EnumConstructor { enum_name, variant, .. } => (
                format!("EnumConstructor({enum_name}::{variant})"),
                vec![],
            ),

            StagedExpr::Tuple(items) => (
                "Tuple".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),
            StagedExpr::TupleIndex { object, index } => (
                format!("TupleIndex(.{index})"),
                vec![self.convert_expr(*object)],
            ),
            StagedExpr::SliceRange { object, start, end } => (
                "SliceRange".into(),
                std::iter::once(self.convert_expr(*object))
                    .chain(start.map(|s| self.convert_expr(s)))
                    .chain(end.map(|e| self.convert_expr(e)))
                    .collect(),
            ),
            StagedExpr::Lambda { params, .. } => (
                format!("Lambda({})", params.join(", ")),
                vec![],
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
