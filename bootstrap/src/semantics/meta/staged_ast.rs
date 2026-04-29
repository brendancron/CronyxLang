use crate::frontend::meta_ast::{EffectOp, EnumVariant, ForVar, ImportDecl, Param, Pattern};
use crate::util::formatters::tree_formatter::*;
use crate::util::node_id::StagedNodeId;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct StagedAst {
    pub sem_root_stmts: Vec<StagedNodeId>,
    pub exprs: HashMap<StagedNodeId, StagedExpr>,
    pub stmts: HashMap<StagedNodeId, StagedStmt>,
}

impl StagedAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id: StagedNodeId, expr: StagedExpr) {
        self.exprs.insert(id, expr);
    }

    pub fn insert_stmt(&mut self, id: StagedNodeId, stmt: StagedStmt) {
        self.stmts.insert(id, stmt);
    }

    pub fn get_expr(&self, id: StagedNodeId) -> Option<&StagedExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: StagedNodeId) -> Option<&StagedStmt> {
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
pub struct StagedMatchArm {
    pub pattern: Pattern,
    pub body: StagedNodeId,
}

#[derive(Debug, Clone)]
pub enum StagedConstructorPayload {
    Unit,
    Tuple(Vec<StagedNodeId>),
    Struct(Vec<(String, StagedNodeId)>),
}

#[derive(Debug, Clone)]
pub enum StagedExpr {
    // LITERAL REPRESENTATION
    Int(i64),
    String(String),
    Bool(bool),

    StructLiteral {
        type_name: String,
        fields: Vec<(String, StagedNodeId)>,
    },

    Variable(String),

    List(Vec<StagedNodeId>),

    Call {
        callee: String,
        args: Vec<StagedNodeId>,
    },

    DotAccess {
        object: StagedNodeId,
        field: String,
    },

    DotCall {
        object: StagedNodeId,
        method: String,
        args: Vec<StagedNodeId>,
    },

    Index {
        object: StagedNodeId,
        index: StagedNodeId,
    },

    EnumConstructor {
        enum_name: String,
        variant: String,
        payload: StagedConstructorPayload,
    },

    // BINOPS
    Add(StagedNodeId, StagedNodeId),
    Sub(StagedNodeId, StagedNodeId),
    Mult(StagedNodeId, StagedNodeId),
    Div(StagedNodeId, StagedNodeId),
    Mod(StagedNodeId, StagedNodeId),
    Equals(StagedNodeId, StagedNodeId),
    NotEquals(StagedNodeId, StagedNodeId),
    Lt(StagedNodeId, StagedNodeId),
    Gt(StagedNodeId, StagedNodeId),
    Lte(StagedNodeId, StagedNodeId),
    Gte(StagedNodeId, StagedNodeId),
    And(StagedNodeId, StagedNodeId),
    Or(StagedNodeId, StagedNodeId),
    Not(StagedNodeId),

    Tuple(Vec<StagedNodeId>),
    TupleIndex {
        object: StagedNodeId,
        index: usize,
    },

    SliceRange {
        object: StagedNodeId,
        start: Option<StagedNodeId>,
        end: Option<StagedNodeId>,
    },

    Lambda {
        params: Vec<String>,
        body: StagedNodeId,
    },

    /// `resume` or `resume(expr)` as an expression.
    ResumeExpr(Option<StagedNodeId>),

    /// `run { body } handle eff1 { ops } handle eff2 { ops } ...`
    RunHandle {
        body: StagedNodeId,
        effects: Vec<(String, Vec<StagedNodeId>)>,
    },

    /// `run { body } with handler_name`
    RunWith {
        body: StagedNodeId,
        handler_name: String,
    },

    MetaExpr(MetaRef),
}

#[derive(Debug, Clone)]
pub enum StagedStmt {
    // RAW EXPR STMTS
    ExprStmt(StagedNodeId),

    // DECLARATION
    VarDecl {
        name: String,
        expr: StagedNodeId,
    },

    Assign {
        name: String,
        expr: StagedNodeId,
    },

    IndexAssign {
        name: String,
        indices: Vec<StagedNodeId>,
        expr: StagedNodeId,
    },

    DotAssign {
        object: String,
        field: String,
        expr: StagedNodeId,
    },

    FnDecl {
        name: String,
        params: Vec<String>,
        type_params: Vec<String>,
        body: StagedNodeId,
    },

    StructDecl {
        name: String,
        fields: Vec<StagedFieldDecl>,
    },

    EnumDecl {
        name: String,
        type_params: Vec<String>,
        variants: Vec<EnumVariant>,
    },

    Match {
        scrutinee: StagedNodeId,
        arms: Vec<StagedMatchArm>,
    },

    // CONTROL
    If {
        cond: StagedNodeId,
        body: StagedNodeId,
        else_branch: Option<StagedNodeId>,
    },

    WhileLoop {
        cond: StagedNodeId,
        body: StagedNodeId,
    },

    ForEach {
        var: ForVar,
        iterable: StagedNodeId,
        body: StagedNodeId,
    },

    Return(Option<StagedNodeId>),

    Block(Vec<StagedNodeId>),

    // UTIL
    Import(ImportDecl),

    // META
    Gen(Vec<StagedNodeId>),
    MetaStmt(MetaRef),

    // EFFECTS
    EffectDecl {
        name: String,
        type_params: Vec<String>,
        ops: Vec<EffectOp>,
    },

    HandlerDef {
        name: String,
        effect_name: Option<String>,
        ops: Vec<StagedNodeId>,
    },

    WithFn {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: StagedNodeId,
    },

    WithCtl {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: StagedNodeId,
    },

    Resume(Option<StagedNodeId>),

    // TEMPORARY
    Print(StagedNodeId),
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
    fn convert_stmt(&self, id: StagedNodeId) -> TreeNode {
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

            StagedStmt::DotAssign { object, field, expr } => (
                format!("DotAssign({object}.{field})"),
                vec![self.convert_expr(*expr)],
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

            StagedStmt::EnumDecl { name, variants, .. } => (
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

            StagedStmt::EffectDecl { name, ops, .. } => (
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

            StagedStmt::HandlerDef { name, effect_name, ops } => (
                format!("HandlerDef({}{})", name, effect_name.as_deref().map(|e| format!(":{e}")).unwrap_or_default()),
                ops.iter().map(|&s| self.convert_stmt(s)).collect(),
            ),

            StagedStmt::Resume(opt_expr) => (
                "Resume".into(),
                opt_expr.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: StagedNodeId) -> TreeNode {
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

            StagedExpr::Mod(a, b) => (
                "Mod".into(),
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
            StagedExpr::ResumeExpr(opt) => (
                "ResumeExpr".into(),
                opt.map(|e| vec![self.convert_expr(e)]).unwrap_or_default(),
            ),
            StagedExpr::RunHandle { body, effects } => (
                "RunHandle".into(),
                std::iter::once(self.convert_stmt(*body))
                    .chain(effects.iter().flat_map(|(_, stmts)| stmts.iter().map(|&s| self.convert_stmt(s))))
                    .collect(),
            ),
            StagedExpr::RunWith { body, handler_name } => (
                format!("RunWith({})", handler_name),
                vec![self.convert_stmt(*body)],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
