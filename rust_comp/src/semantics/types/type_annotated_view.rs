use crate::frontend::meta_ast::*;
use crate::util::formatters::tree_formatter::*;
use super::typed_ast::TypeTable;

pub struct TypeAnnotatedView<'a> {
    pub ast: &'a MetaAst,
    pub types: &'a TypeTable,
}

impl<'a> TypeAnnotatedView<'a> {
    pub fn new(ast: &'a MetaAst, types: &'a TypeTable) -> Self {
        Self { ast, types }
    }

    fn type_leaf_stmt(&self, id: usize) -> Option<TreeNode> {
        self.types.get_stmt_type(id).map(|ty| TreeNode::leaf(format!("type: {ty}")))
    }

    fn type_leaf_expr(&self, id: usize) -> Option<TreeNode> {
        self.types.get_expr_type(id).map(|ty| TreeNode::leaf(format!("type: {ty}")))
    }

    fn convert_stmt(&self, id: usize) -> TreeNode {
        let stmt = self.ast.get_stmt(id).expect("invalid stmt id");

        let (base_label, mut children): (String, Vec<TreeNode>) = match stmt {
            MetaStmt::ExprStmt(e) => (
                "ExprStmt".into(),
                vec![self.convert_expr(*e)],
            ),

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

            MetaStmt::FnDecl { name, params, body, .. } => (
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

            MetaStmt::If { cond, body, else_branch } => {
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

            MetaStmt::ForEach { var, iterable, body } => (
                "ForEachStmt".into(),
                vec![
                    TreeNode::leaf(format!("Var({var})")),
                    TreeNode::node("Iterable", vec![self.convert_expr(*iterable)]),
                    TreeNode::node("Body", vec![self.convert_stmt(*body)]),
                ],
            ),

            MetaStmt::Return(e) => (
                "ReturnStmt".into(),
                e.map(|eid| vec![self.convert_expr(eid)]).unwrap_or_default(),
            ),

            MetaStmt::Block(stmts) => (
                "Block".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            MetaStmt::Import(decl) => ("Import".into(), vec![TreeNode::leaf(decl.path().to_string())]),

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

            MetaStmt::EnumDecl { name, .. } => (format!("EnumDecl({name})"), vec![]),

            MetaStmt::Match { scrutinee, arms } => (
                "Match".into(),
                std::iter::once(self.convert_expr(*scrutinee))
                    .chain(arms.iter().map(|arm| self.convert_stmt(arm.body)))
                    .collect(),
            ),

            MetaStmt::EffectDecl { name, .. } => (format!("EffectDecl({name})"), vec![]),

            MetaStmt::WithFn { op_name, body, .. } => (
                "WithFn".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            MetaStmt::WithCtl { op_name, body, .. } => (
                "WithCtl".into(),
                vec![TreeNode::leaf(format!("Op({op_name})")), self.convert_stmt(*body)],
            ),

            MetaStmt::HandlerDef { name, .. } => (format!("HandlerDef({name})"), vec![]),

            MetaStmt::Resume(opt_expr) => (
                "Resume".into(),
                opt_expr.map(|id| vec![self.convert_expr(id)]).unwrap_or_default(),
            ),

            MetaStmt::Defer(inner) => (
                "Defer".into(),
                vec![self.convert_stmt(*inner)],
            ),
        };

        children.insert(0, TreeNode::leaf(format!("id: {id}")));
        if let Some(ty_leaf) = self.type_leaf_stmt(id) {
            children.insert(1, ty_leaf);
        }
        TreeNode::node(base_label, children)
    }

    fn convert_expr(&self, id: usize) -> TreeNode {
        let expr = self.ast.get_expr(id).expect("invalid expr id");

        let (base_label, mut children): (String, Vec<TreeNode>) = match expr {
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

            MetaExpr::EnumConstructor { enum_name, variant, .. } => (
                format!("EnumConstructor({enum_name}::{variant})"),
                vec![],
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
        if let Some(ty_leaf) = self.type_leaf_expr(id) {
            children.insert(1, ty_leaf);
        }
        TreeNode::node(base_label, children)
    }
}

impl AsTree for TypeAnnotatedView<'_> {
    fn as_tree(&self) -> Vec<TreeNode> {
        self.ast
            .sem_root_stmts
            .iter()
            .map(|id| self.convert_stmt(*id))
            .collect()
    }
}
