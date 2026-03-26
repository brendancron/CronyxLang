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

            MetaStmt::VarDecl { name, expr } => (
                "VarDecl".into(),
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
                        params.iter().map(|p| TreeNode::leaf(p.clone())).collect(),
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

            MetaStmt::Import(path) => ("Import".into(), vec![TreeNode::leaf(path.clone())]),

            MetaStmt::MetaBlock(s) => ("MetaBlock".into(), vec![self.convert_stmt(*s)]),

            MetaStmt::Gen(stmts) => (
                "Gen".into(),
                stmts.iter().map(|s| self.convert_stmt(*s)).collect(),
            ),

            MetaStmt::Print(e) => ("PrintStmt".into(), vec![self.convert_expr(*e)]),
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
