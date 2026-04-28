use crate::frontend::meta_ast::{
    EffectOp, EnumVariant, ImportDecl, Param, Pattern,
};
use crate::util::formatters::tree_formatter::*;
use crate::util::node_id::RuntimeNodeId;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct RuntimeAst {
    pub sem_root_stmts: Vec<RuntimeNodeId>,
    pub exprs: HashMap<RuntimeNodeId, RuntimeExpr>,
    pub stmts: HashMap<RuntimeNodeId, RuntimeStmt>,
    /// Maps (type_name, method_name) → mangled FnDecl name in this AST.
    pub impl_registry: HashMap<(String, String), String>,
    /// Maps (op_trait, type_name) → mangled FnDecl name.
    pub op_dispatch: HashMap<(String, String), String>,
    /// Lines printed by meta-block `print` statements during compile-time evaluation.
    pub meta_prints: Vec<String>,
    /// One past the highest ID ever inserted. Safe starting point for any pass that
    /// needs to allocate fresh nodes without scanning all existing IDs.
    pub next_id: usize,
    /// Type hints for lambda params set by handler_transform.
    /// Maps lambda expr_id → param type name strings (parallel to Lambda.params).
    pub lambda_param_hints: HashMap<RuntimeNodeId, Vec<Option<String>>>,
}

impl RuntimeAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
            impl_registry: HashMap::new(),
            op_dispatch: HashMap::new(),
            meta_prints: vec![],
            next_id: 0,
            lambda_param_hints: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id: RuntimeNodeId, expr: RuntimeExpr) {
        self.next_id = self.next_id.max(id.0 + 1);
        self.exprs.insert(id, expr);
    }

    pub fn insert_stmt(&mut self, id: RuntimeNodeId, stmt: RuntimeStmt) {
        self.next_id = self.next_id.max(id.0 + 1);
        self.stmts.insert(id, stmt);
    }

    pub fn get_expr(&self, id: RuntimeNodeId) -> Option<&RuntimeExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: RuntimeNodeId) -> Option<&RuntimeStmt> {
        self.stmts.get(&id)
    }

    /// Reassigns all IDs to a single compact 0..n range with no gaps.
    pub fn compact(&self) -> Self {
        let mut stmt_ids: Vec<RuntimeNodeId> = self.stmts.keys().copied().collect();
        stmt_ids.sort_unstable();
        let mut expr_ids: Vec<RuntimeNodeId> = self.exprs.keys().copied().collect();
        expr_ids.sort_unstable();

        let mut counter = 0usize;
        let mut next = || { let id = counter; counter += 1; RuntimeNodeId(id) };

        let stmt_remap: HashMap<RuntimeNodeId, RuntimeNodeId> =
            stmt_ids.iter().map(|old| (*old, next())).collect();
        let expr_remap: HashMap<RuntimeNodeId, RuntimeNodeId> =
            expr_ids.iter().map(|old| (*old, next())).collect();

        let remap_stmt = |id: RuntimeNodeId| *stmt_remap.get(&id).unwrap_or(&id);
        let remap_expr = |id: RuntimeNodeId| *expr_remap.get(&id).unwrap_or(&id);

        let mut out = RuntimeAst::new();

        out.sem_root_stmts = self.sem_root_stmts.iter().map(|id| remap_stmt(*id)).collect();

        for (old_id, expr) in &self.exprs {
            let new_expr = match expr {
                RuntimeExpr::Int(_)
                | RuntimeExpr::String(_)
                | RuntimeExpr::Bool(_)
                | RuntimeExpr::Variable(_) => expr.clone(),
                RuntimeExpr::List(items) => {
                    RuntimeExpr::List(items.iter().map(|id| remap_expr(*id)).collect())
                }
                RuntimeExpr::Add(a, b) => RuntimeExpr::Add(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Sub(a, b) => RuntimeExpr::Sub(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Mult(a, b) => RuntimeExpr::Mult(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Div(a, b) => RuntimeExpr::Div(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Equals(a, b) => RuntimeExpr::Equals(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::NotEquals(a, b) => RuntimeExpr::NotEquals(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Lt(a, b) => RuntimeExpr::Lt(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Gt(a, b) => RuntimeExpr::Gt(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Lte(a, b) => RuntimeExpr::Lte(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Gte(a, b) => RuntimeExpr::Gte(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::And(a, b) => RuntimeExpr::And(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Or(a, b) => RuntimeExpr::Or(remap_expr(*a), remap_expr(*b)),
                RuntimeExpr::Not(a) => RuntimeExpr::Not(remap_expr(*a)),
                RuntimeExpr::Tuple(items) => {
                    RuntimeExpr::Tuple(items.iter().map(|id| remap_expr(*id)).collect())
                }
                RuntimeExpr::TupleIndex { object, index } => RuntimeExpr::TupleIndex {
                    object: remap_expr(*object),
                    index: *index, // plain tuple position, not a node ID
                },
                RuntimeExpr::SliceRange { object, start, end } => RuntimeExpr::SliceRange {
                    object: remap_expr(*object),
                    start: start.map(|id| remap_expr(id)),
                    end: end.map(|id| remap_expr(id)),
                },
                RuntimeExpr::Lambda { params, body } => RuntimeExpr::Lambda {
                    params: params.clone(),
                    body: remap_stmt(*body),
                },
                RuntimeExpr::Unit => RuntimeExpr::Unit,
                RuntimeExpr::ResumeExpr(opt) => RuntimeExpr::ResumeExpr(opt.map(|id| remap_expr(id))),
                RuntimeExpr::StructLiteral { type_name, fields } => {
                    RuntimeExpr::StructLiteral {
                        type_name: type_name.clone(),
                        fields: fields
                            .iter()
                            .map(|(name, id)| (name.clone(), remap_expr(*id)))
                            .collect(),
                    }
                }
                RuntimeExpr::Call { callee, args } => RuntimeExpr::Call {
                    callee: callee.clone(),
                    args: args.iter().map(|id| remap_expr(*id)).collect(),
                },
                RuntimeExpr::DotAccess { object, field } => RuntimeExpr::DotAccess {
                    object: remap_expr(*object),
                    field: field.clone(),
                },
                RuntimeExpr::DotCall { object, method, args } => RuntimeExpr::DotCall {
                    object: remap_expr(*object),
                    method: method.clone(),
                    args: args.iter().map(|id| remap_expr(*id)).collect(),
                },
                RuntimeExpr::Index { object, index } => RuntimeExpr::Index {
                    object: remap_expr(*object),
                    index: remap_expr(*index),
                },
                RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
                    RuntimeExpr::EnumConstructor {
                        enum_name: enum_name.clone(),
                        variant: variant.clone(),
                        payload: match payload {
                            RuntimeConstructorPayload::Unit => RuntimeConstructorPayload::Unit,
                            RuntimeConstructorPayload::Tuple(ids) => {
                                RuntimeConstructorPayload::Tuple(ids.iter().map(|id| remap_expr(*id)).collect())
                            }
                            RuntimeConstructorPayload::Struct(fields) => {
                                RuntimeConstructorPayload::Struct(fields.iter().map(|(n, id)| (n.clone(), remap_expr(*id))).collect())
                            }
                        },
                    }
                }
            };
            out.insert_expr(remap_expr(*old_id), new_expr);
        }

        for (old_id, stmt) in &self.stmts {
            let new_stmt = match stmt {
                RuntimeStmt::Import(_) => stmt.clone(),
                RuntimeStmt::ExprStmt(e) => RuntimeStmt::ExprStmt(remap_expr(*e)),
                RuntimeStmt::Print(e) => RuntimeStmt::Print(remap_expr(*e)),
                RuntimeStmt::Return(e) => {
                    RuntimeStmt::Return(e.map(|id| remap_expr(id)))
                }
                RuntimeStmt::VarDecl { name, expr } => RuntimeStmt::VarDecl {
                    name: name.clone(),
                    expr: remap_expr(*expr),
                },
                RuntimeStmt::Assign { name, expr } => RuntimeStmt::Assign {
                    name: name.clone(),
                    expr: remap_expr(*expr),
                },
                RuntimeStmt::IndexAssign { name, indices, expr } => RuntimeStmt::IndexAssign {
                    name: name.clone(),
                    indices: indices.iter().map(|i| remap_expr(*i)).collect(),
                    expr: remap_expr(*expr),
                },
                RuntimeStmt::FnDecl { name, params, type_params, body } => RuntimeStmt::FnDecl {
                    name: name.clone(),
                    params: params.clone(),
                    type_params: type_params.clone(),
                    body: remap_stmt(*body),
                },
                RuntimeStmt::StructDecl { name, fields } => RuntimeStmt::StructDecl {
                    name: name.clone(),
                    fields: fields.clone(),
                },
                RuntimeStmt::Block(children) => {
                    RuntimeStmt::Block(children.iter().map(|id| remap_stmt(*id)).collect())
                }
                RuntimeStmt::Gen(children) => {
                    RuntimeStmt::Gen(children.iter().map(|id| remap_stmt(*id)).collect())
                }
                RuntimeStmt::If { cond, body, else_branch } => RuntimeStmt::If {
                    cond: remap_expr(*cond),
                    body: remap_stmt(*body),
                    else_branch: else_branch.map(|id| remap_stmt(id)),
                },
                RuntimeStmt::WhileLoop { cond, body } => RuntimeStmt::WhileLoop {
                    cond: remap_expr(*cond),
                    body: remap_stmt(*body),
                },
                RuntimeStmt::ForEach { var, iterable, body } => RuntimeStmt::ForEach {
                    var: var.clone(),
                    iterable: remap_expr(*iterable),
                    body: remap_stmt(*body),
                },
                RuntimeStmt::EnumDecl { name, type_params, variants } => RuntimeStmt::EnumDecl {
                    name: name.clone(),
                    type_params: type_params.clone(),
                    variants: variants.clone(),
                },
                RuntimeStmt::Match { scrutinee, arms } => RuntimeStmt::Match {
                    scrutinee: remap_expr(*scrutinee),
                    arms: arms.iter().map(|arm| RuntimeMatchArm {
                        pattern: arm.pattern.clone(),
                        body: remap_stmt(arm.body),
                    }).collect(),
                },
                RuntimeStmt::EffectDecl { name, ops } => RuntimeStmt::EffectDecl {
                    name: name.clone(),
                    ops: ops.clone(),
                },
                RuntimeStmt::WithFn { op_name, params, ret_ty, body } => RuntimeStmt::WithFn {
                    op_name: op_name.clone(),
                    params: params.clone(),
                    ret_ty: ret_ty.clone(),
                    body: remap_stmt(*body),
                },
                RuntimeStmt::WithCtl { op_name, params, ret_ty, body, outer_k } => RuntimeStmt::WithCtl {
                    op_name: op_name.clone(),
                    params: params.clone(),
                    ret_ty: ret_ty.clone(),
                    body: remap_stmt(*body),
                    outer_k: outer_k.clone(),
                },
                RuntimeStmt::Resume(opt_expr) => {
                    RuntimeStmt::Resume(opt_expr.map(|id| remap_expr(id)))
                },
            };
            out.insert_stmt(remap_stmt(*old_id), new_stmt);
        }

        out.impl_registry = self.impl_registry.clone();
        out.op_dispatch = self.op_dispatch.clone();
        out.meta_prints = self.meta_prints.clone();
        out.lambda_param_hints = self.lambda_param_hints.iter()
            .map(|(old_id, hints)| (*expr_remap.get(old_id).unwrap_or(old_id), hints.clone()))
            .collect();

        out
    }
}

// ── Runtime-specific payload/arm types ───────────────────────────────────────

/// Runtime version of `ConstructorPayload` — uses `RuntimeNodeId` instead of `usize`.
#[derive(Debug, Clone)]
pub enum RuntimeConstructorPayload {
    Unit,
    Tuple(Vec<RuntimeNodeId>),
    Struct(Vec<(String, RuntimeNodeId)>),
}

/// Runtime version of `MatchArm` — uses `RuntimeNodeId` for the body.
#[derive(Debug, Clone)]
pub struct RuntimeMatchArm {
    pub pattern: Pattern,
    pub body: RuntimeNodeId,
}

// ── AST node types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum RuntimeNode {
    Expr(RuntimeExpr),
    Stmt(RuntimeStmt),
}

#[derive(Debug, Clone)]
pub enum RuntimeExpr {
    Int(i64),
    String(String),
    Bool(bool),

    StructLiteral {
        type_name: String,
        fields: Vec<(String, RuntimeNodeId)>,
    },

    Variable(String),

    List(Vec<RuntimeNodeId>),

    Call {
        callee: String,
        args: Vec<RuntimeNodeId>,
    },

    DotAccess {
        object: RuntimeNodeId,
        field: String,
    },

    DotCall {
        object: RuntimeNodeId,
        method: String,
        args: Vec<RuntimeNodeId>,
    },

    Index {
        object: RuntimeNodeId,
        index: RuntimeNodeId,
    },

    EnumConstructor {
        enum_name: String,
        variant: String,
        payload: RuntimeConstructorPayload,
    },

    Add(RuntimeNodeId, RuntimeNodeId),
    Sub(RuntimeNodeId, RuntimeNodeId),
    Mult(RuntimeNodeId, RuntimeNodeId),
    Div(RuntimeNodeId, RuntimeNodeId),
    Equals(RuntimeNodeId, RuntimeNodeId),
    NotEquals(RuntimeNodeId, RuntimeNodeId),
    Lt(RuntimeNodeId, RuntimeNodeId),
    Gt(RuntimeNodeId, RuntimeNodeId),
    Lte(RuntimeNodeId, RuntimeNodeId),
    Gte(RuntimeNodeId, RuntimeNodeId),
    And(RuntimeNodeId, RuntimeNodeId),
    Or(RuntimeNodeId, RuntimeNodeId),
    Not(RuntimeNodeId),

    Tuple(Vec<RuntimeNodeId>),
    TupleIndex {
        object: RuntimeNodeId,
        index: usize, // plain tuple position, not a node ID
    },

    SliceRange {
        object: RuntimeNodeId,
        start: Option<RuntimeNodeId>,
        end: Option<RuntimeNodeId>,
    },

    Lambda {
        params: Vec<String>,
        body: RuntimeNodeId,
    },
    Unit,
    ResumeExpr(Option<RuntimeNodeId>),
}

#[derive(Debug, Clone)]
pub enum RuntimeStmt {
    ExprStmt(RuntimeNodeId),

    VarDecl {
        name: String,
        expr: RuntimeNodeId,
    },

    Assign {
        name: String,
        expr: RuntimeNodeId,
    },

    IndexAssign {
        name: String,
        indices: Vec<RuntimeNodeId>,
        expr: RuntimeNodeId,
    },

    FnDecl {
        name: String,
        params: Vec<String>,
        type_params: Vec<String>,
        body: RuntimeNodeId,
    },

    StructDecl {
        name: String,
        fields: Vec<RuntimeFieldDecl>,
    },

    EnumDecl {
        name: String,
        type_params: Vec<String>,
        variants: Vec<EnumVariant>,
    },

    Match {
        scrutinee: RuntimeNodeId,
        arms: Vec<RuntimeMatchArm>,
    },

    If {
        cond: RuntimeNodeId,
        body: RuntimeNodeId,
        else_branch: Option<RuntimeNodeId>,
    },

    WhileLoop {
        cond: RuntimeNodeId,
        body: RuntimeNodeId,
    },

    ForEach {
        var: String,
        iterable: RuntimeNodeId,
        body: RuntimeNodeId,
    },

    Return(Option<RuntimeNodeId>),

    Block(Vec<RuntimeNodeId>),

    Import(ImportDecl),

    Gen(Vec<RuntimeNodeId>),

    EffectDecl {
        name: String,
        ops: Vec<EffectOp>,
    },

    WithFn {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: RuntimeNodeId,
    },

    WithCtl {
        op_name: String,
        params: Vec<Param>,
        ret_ty: Option<String>,
        body: RuntimeNodeId,
        outer_k: Option<String>,
    },

    Resume(Option<RuntimeNodeId>),

    Print(RuntimeNodeId),
}

#[derive(Debug, Clone)]
pub struct RuntimeFieldDecl {
    pub field_name: String,
    pub type_name: String,
}

// ── Tree rendering ────────────────────────────────────────────────────────────

impl AsTree for RuntimeAst {
    fn as_tree(&self) -> Vec<TreeNode> {
        let mut nodes = vec![];
        for stmt_id in self.sem_root_stmts.iter() {
            nodes.push(self.convert_stmt(*stmt_id));
        }
        nodes
    }
}

impl RuntimeAst {
    fn convert_stmt(&self, id: RuntimeNodeId) -> TreeNode {
        let stmt = self
            .get_stmt(id)
            .unwrap_or_else(|| panic!("invalid stmt id: {}", id));

        let (label, mut children): (String, Vec<TreeNode>) = match stmt {
            RuntimeStmt::ExprStmt(e) => ("ExprStmt".into(), vec![self.convert_expr(*e)]),

            RuntimeStmt::VarDecl { name, expr } => (
                "VarDecl".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    self.convert_expr(*expr),
                ],
            ),

            RuntimeStmt::Assign { name, expr } => (
                "Assign".into(),
                vec![
                    TreeNode::leaf(format!("Name({name})")),
                    self.convert_expr(*expr),
                ],
            ),

            RuntimeStmt::IndexAssign { name, indices, expr } => (
                "IndexAssign".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(indices.iter().map(|i| self.convert_expr(*i)))
                    .chain(std::iter::once(self.convert_expr(*expr)))
                    .collect(),
            ),

            RuntimeStmt::FnDecl { name, params, type_params: _, body } => (
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

            RuntimeStmt::StructDecl { name, fields } => (
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

            RuntimeStmt::If { cond, body, else_branch } => {
                let mut v = vec![
                    TreeNode::node("Cond", vec![self.convert_expr(*cond)]),
                    TreeNode::node("Then", vec![self.convert_stmt(*body)]),
                ];
                if let Some(e) = else_branch {
                    v.push(TreeNode::node("Else", vec![self.convert_stmt(*e)]));
                }
                ("IfStmt".into(), v)
            }

            RuntimeStmt::WhileLoop { cond, body } => (
                "WhileLoop".into(),
                vec![
                    TreeNode::node("Cond", vec![self.convert_expr(*cond)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

            RuntimeStmt::ForEach { var, iterable, body } => (
                "ForEachStmt".into(),
                vec![
                    TreeNode::leaf(format!("Var({var})")),
                    TreeNode::node("Iterable", vec![self.convert_expr(*iterable)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

            RuntimeStmt::Return(e) => (
                "ReturnStmt".into(),
                e.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),

            RuntimeStmt::Block(stmts) => (
                "Block".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            RuntimeStmt::Import(decl) => ("Import".into(), vec![TreeNode::leaf(decl.path().to_string())]),

            RuntimeStmt::Gen(stmts) => (
                "Gen".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            RuntimeStmt::Print(e) => ("PrintStmt".into(), vec![self.convert_expr(*e)]),

            RuntimeStmt::EnumDecl { name, variants, .. } => (
                "EnumDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(variants.iter().map(|v| TreeNode::leaf(format!("Variant({})", v.name))))
                    .collect(),
            ),

            RuntimeStmt::Match { scrutinee, arms } => (
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

            RuntimeStmt::EffectDecl { name, ops } => (
                "EffectDecl".into(),
                std::iter::once(TreeNode::leaf(format!("Name({name})")))
                    .chain(ops.iter().map(|op| TreeNode::leaf(op.name.clone())))
                    .collect(),
            ),

            RuntimeStmt::WithFn { op_name, body, .. } => (
                "WithFn".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            RuntimeStmt::WithCtl { op_name, body, .. } => (
                "WithCtl".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            RuntimeStmt::Resume(opt_expr) => (
                "Resume".into(),
                opt_expr.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: RuntimeNodeId) -> TreeNode {
        let expr = self.get_expr(id).expect("invalid expr id");

        let (label, mut children) = match expr {
            RuntimeExpr::Int(v) => ("Int".into(), vec![TreeNode::leaf(v.to_string())]),
            RuntimeExpr::String(s) => ("String".into(), vec![TreeNode::leaf(format!("\"{s}\""))]),
            RuntimeExpr::Bool(b) => ("Bool".into(), vec![TreeNode::leaf(b.to_string())]),
            RuntimeExpr::Variable(name) => ("Var".into(), vec![TreeNode::leaf(name.clone())]),

            RuntimeExpr::StructLiteral { type_name, fields } => (
                format!("StructLiteral({type_name})"),
                fields
                    .iter()
                    .map(|(n, e)| TreeNode::node(n.clone(), vec![self.convert_expr(*e)]))
                    .collect(),
            ),

            RuntimeExpr::List(items) => (
                "List".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            RuntimeExpr::Call { callee, args } => (
                format!("Call({callee})"),
                args.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            RuntimeExpr::Add(a, b) => ("Add".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Sub(a, b) => ("Sub".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Mult(a, b) => ("Mult".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Div(a, b) => ("Div".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Equals(a, b) => ("Equals".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::NotEquals(a, b) => ("NotEquals".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Lt(a, b) => ("Lt".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Gt(a, b) => ("Gt".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Lte(a, b) => ("Lte".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Gte(a, b) => ("Gte".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::And(a, b) => ("And".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Or(a, b) => ("Or".into(), vec![self.convert_expr(*a), self.convert_expr(*b)]),
            RuntimeExpr::Not(a) => ("Not".into(), vec![self.convert_expr(*a)]),

            RuntimeExpr::DotAccess { object, field } => (
                format!("DotAccess(.{field})"),
                vec![self.convert_expr(*object)],
            ),

            RuntimeExpr::DotCall { object, method, args } => (
                format!("DotCall(.{method})"),
                std::iter::once(self.convert_expr(*object))
                    .chain(args.iter().map(|e| self.convert_expr(*e)))
                    .collect(),
            ),

            RuntimeExpr::Index { object, index } => (
                "Index".into(),
                vec![self.convert_expr(*object), self.convert_expr(*index)],
            ),

            RuntimeExpr::EnumConstructor { enum_name, variant, .. } => (
                format!("EnumConstructor({enum_name}::{variant})"),
                vec![],
            ),

            RuntimeExpr::Tuple(items) => (
                "Tuple".into(),
                items.iter().map(|e| self.convert_expr(*e)).collect(),
            ),

            RuntimeExpr::TupleIndex { object, index } => (
                format!("TupleIndex(.{index})"),
                vec![self.convert_expr(*object)],
            ),

            RuntimeExpr::SliceRange { object, start, end } => (
                "SliceRange".into(),
                std::iter::once(self.convert_expr(*object))
                    .chain(start.map(|s| self.convert_expr(s)))
                    .chain(end.map(|e| self.convert_expr(e)))
                    .collect(),
            ),

            RuntimeExpr::Lambda { params, body } => (
                format!("Lambda({})", params.join(", ")),
                vec![self.convert_stmt(*body)],
            ),

            RuntimeExpr::Unit => ("Unit".into(), vec![]),
            RuntimeExpr::ResumeExpr(opt) => (
                "ResumeExpr".into(),
                opt.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
