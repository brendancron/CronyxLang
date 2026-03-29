use crate::frontend::meta_ast::{
    ConstructorPayload, EnumVariant, ImportDecl, MatchArm,
};
use crate::util::formatters::tree_formatter::*;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct RuntimeAst {
    pub sem_root_stmts: Vec<usize>,
    pub exprs: HashMap<usize, RuntimeExpr>,
    pub stmts: HashMap<usize, RuntimeStmt>,
}

impl RuntimeAst {
    pub fn new() -> Self {
        Self {
            sem_root_stmts: vec![],
            exprs: HashMap::new(),
            stmts: HashMap::new(),
        }
    }

    pub fn insert_expr(&mut self, id: usize, expr: RuntimeExpr) {
        self.exprs.insert(id, expr);
    }

    pub fn insert_stmt(&mut self, id: usize, stmt: RuntimeStmt) {
        self.stmts.insert(id, stmt);
    }

    pub fn get_expr(&self, id: usize) -> Option<&RuntimeExpr> {
        self.exprs.get(&id)
    }

    pub fn get_stmt(&self, id: usize) -> Option<&RuntimeStmt> {
        self.stmts.get(&id)
    }

    /// Reassigns all IDs to a single compact 0..n range with no gaps.
    /// Stmts and exprs share the same ID space so every node has a unique ID.
    pub fn compact(&self) -> Self {
        // Interleave stmt and expr IDs into one sorted sequence, allocating
        // new IDs from a shared counter so no two nodes share an ID.
        let mut stmt_ids: Vec<usize> = self.stmts.keys().copied().collect();
        stmt_ids.sort_unstable();
        let mut expr_ids: Vec<usize> = self.exprs.keys().copied().collect();
        expr_ids.sort_unstable();

        let mut counter = 0usize;
        let mut next = || { let id = counter; counter += 1; id };

        let stmt_remap: HashMap<usize, usize> =
            stmt_ids.iter().map(|old| (*old, next())).collect();
        let expr_remap: HashMap<usize, usize> =
            expr_ids.iter().map(|old| (*old, next())).collect();

        let remap_stmt = |id: usize| *stmt_remap.get(&id).unwrap_or(&id);
        let remap_expr = |id: usize| *expr_remap.get(&id).unwrap_or(&id);

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
                RuntimeExpr::Equals(a, b) => {
                    RuntimeExpr::Equals(remap_expr(*a), remap_expr(*b))
                }
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
                RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
                    RuntimeExpr::EnumConstructor {
                        enum_name: enum_name.clone(),
                        variant: variant.clone(),
                        payload: match payload {
                            ConstructorPayload::Unit => ConstructorPayload::Unit,
                            ConstructorPayload::Tuple(ids) => {
                                ConstructorPayload::Tuple(ids.iter().map(|id| remap_expr(*id)).collect())
                            }
                            ConstructorPayload::Struct(fields) => {
                                ConstructorPayload::Struct(fields.iter().map(|(n, id)| (n.clone(), remap_expr(*id))).collect())
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
                RuntimeStmt::FnDecl { name, params, body } => RuntimeStmt::FnDecl {
                    name: name.clone(),
                    params: params.clone(),
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
                RuntimeStmt::If {
                    cond,
                    body,
                    else_branch,
                } => RuntimeStmt::If {
                    cond: remap_expr(*cond),
                    body: remap_stmt(*body),
                    else_branch: else_branch.map(|id| remap_stmt(id)),
                },
                RuntimeStmt::ForEach {
                    var,
                    iterable,
                    body,
                } => RuntimeStmt::ForEach {
                    var: var.clone(),
                    iterable: remap_expr(*iterable),
                    body: remap_stmt(*body),
                },
                RuntimeStmt::EnumDecl { name, variants } => RuntimeStmt::EnumDecl {
                    name: name.clone(),
                    variants: variants.clone(),
                },
                RuntimeStmt::Match { scrutinee, arms } => RuntimeStmt::Match {
                    scrutinee: remap_expr(*scrutinee),
                    arms: arms.iter().map(|arm| MatchArm {
                        pattern: arm.pattern.clone(),
                        body: remap_stmt(arm.body),
                    }).collect(),
                },
            };
            out.insert_stmt(remap_stmt(*old_id), new_stmt);
        }

        out
    }
}

// For util purposes

#[derive(Debug, Clone)]
pub enum RuntimeNode {
    Expr(RuntimeExpr),
    Stmt(RuntimeStmt),
}

#[derive(Debug, Clone)]
pub enum RuntimeExpr {
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
pub enum RuntimeStmt {
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

    FnDecl {
        name: String,
        params: Vec<String>,
        body: usize,
    },

    StructDecl {
        name: String,
        fields: Vec<RuntimeFieldDecl>,
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
    Gen(Vec<usize>),

    // TEMPORARY
    Print(usize),
}

#[derive(Debug, Clone)]
pub struct RuntimeFieldDecl {
    pub field_name: String,
    pub type_name: String,
}

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
    fn convert_stmt(&self, id: usize) -> TreeNode {
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

            RuntimeStmt::FnDecl { name, params, body } => (
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

            RuntimeStmt::If {
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

            RuntimeStmt::ForEach {
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

            RuntimeStmt::EnumDecl { name, variants } => (
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
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }

    fn convert_expr(&self, id: usize) -> TreeNode {
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

            RuntimeExpr::Add(a, b) => (
                "Add".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            RuntimeExpr::Sub(a, b) => (
                "Sub".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            RuntimeExpr::Mult(a, b) => (
                "Mult".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            RuntimeExpr::Div(a, b) => (
                "Div".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

            RuntimeExpr::Equals(a, b) => (
                "Equals".into(),
                vec![self.convert_expr(*a), self.convert_expr(*b)],
            ),

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

            RuntimeExpr::EnumConstructor { enum_name, variant, .. } => (
                format!("EnumConstructor({enum_name}::{variant})"),
                vec![],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        TreeNode::node(label, children)
    }
}
