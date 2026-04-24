use crate::frontend::meta_ast::{ConstructorPayload, Pattern, VariantBindings, VariantPayload};
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};

pub struct Formatter<'a> {
    ast: &'a RuntimeAst,
    indent: usize,
}

impl<'a> Formatter<'a> {
    pub fn new(ast: &'a RuntimeAst) -> Self {
        Self { ast, indent: 0 }
    }

    fn pad(&self) -> String {
        "    ".repeat(self.indent)
    }

    pub fn format_root(&mut self) -> String {
        let root_ids: Vec<usize> = self.ast.sem_root_stmts.clone();
        root_ids
            .iter()
            .map(|id| self.fmt_stmt(*id))
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn fmt_stmt(&mut self, id: usize) -> String {
        let stmt = self.ast.get_stmt(id).expect("invalid stmt id").clone();
        match stmt {
            RuntimeStmt::ExprStmt(e) => {
                format!("{}{};", self.pad(), self.fmt_expr(e))
            }

            RuntimeStmt::VarDecl { name, expr } => {
                format!("{}var {} = {};", self.pad(), name, self.fmt_expr(expr))
            }

            RuntimeStmt::Assign { name, expr } => {
                format!("{}{} = {};", self.pad(), name, self.fmt_expr(expr))
            }

            RuntimeStmt::IndexAssign { name, indices, expr } => {
                let idx_str = indices.iter().map(|i| format!("[{}]", self.fmt_expr(*i))).collect::<String>();
                format!("{}{}{} = {};", self.pad(), name, idx_str, self.fmt_expr(expr))
            }

            RuntimeStmt::Print(e) => {
                format!("{}print({});", self.pad(), self.fmt_expr(e))
            }

            RuntimeStmt::Return(opt_e) => match opt_e {
                None => format!("{}return;", self.pad()),
                Some(e) => format!("{}return {};", self.pad(), self.fmt_expr(e)),
            },

            RuntimeStmt::FnDecl { name, params, body, .. } => {
                let params_str = params.join(", ");
                let body_str = self.fmt_block_body(body);
                format!("{}fn {}({}) {}", self.pad(), name, params_str, body_str)
            }

            RuntimeStmt::StructDecl { name, fields } => {
                let indent = self.pad();
                let fields_str = fields
                    .iter()
                    .map(|f| format!("    {}{}: {},", indent, f.field_name, f.type_name))
                    .collect::<Vec<_>>()
                    .join("\n");
                format!("{}struct {} {{\n{}\n{}}}", indent, name, fields_str, indent)
            }

            RuntimeStmt::EnumDecl { name, variants } => {
                let indent = self.pad();
                let variants_str = variants
                    .iter()
                    .map(|v| {
                        let payload = match &v.payload {
                            VariantPayload::Unit => String::new(),
                            VariantPayload::Tuple(types) => format!("({})", types.join(", ")),
                            VariantPayload::Struct(fields) => {
                                let fs = fields
                                    .iter()
                                    .map(|f| format!("{}: {}", f.field_name, f.type_name))
                                    .collect::<Vec<_>>()
                                    .join(", ");
                                format!(" {{ {} }}", fs)
                            }
                        };
                        format!("    {}{}{},", indent, v.name, payload)
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                format!("{}enum {} {{\n{}\n{}}}", indent, name, variants_str, indent)
            }

            RuntimeStmt::If { cond, body, else_branch } => {
                let cond_str = self.fmt_expr(cond);
                let body_str = self.fmt_block_body(body);
                let mut result = format!("{}if ({}) {}", self.pad(), cond_str, body_str);
                if let Some(else_id) = else_branch {
                    // Check if it's an else-if chain
                    let is_if = matches!(
                        self.ast.get_stmt(else_id),
                        Some(RuntimeStmt::If { .. })
                    );
                    if is_if {
                        let saved = self.indent;
                        self.indent = 0;
                        let else_str = self.fmt_stmt(else_id);
                        self.indent = saved;
                        result.push_str(&format!(" else {}", else_str.trim_start()));
                    } else {
                        let else_str = self.fmt_block_body(else_id);
                        result.push_str(&format!(" else {}", else_str));
                    }
                }
                result
            }

            RuntimeStmt::WhileLoop { cond, body } => {
                let cond_str = self.fmt_expr(cond);
                let body_str = self.fmt_block_body(body);
                format!("{}while ({}) {}", self.pad(), cond_str, body_str)
            }

            RuntimeStmt::ForEach { var, iterable, body } => {
                let iter_str = self.fmt_expr(iterable);
                let body_str = self.fmt_block_body(body);
                format!("{}for ({} in {}) {}", self.pad(), var, iter_str, body_str)
            }

            RuntimeStmt::Block(stmts) => {
                format!("{}{}", self.pad(), self.fmt_block_stmts(&stmts))
            }

            RuntimeStmt::Match { scrutinee, arms } => {
                let scrutinee_str = self.fmt_expr(scrutinee);
                let outer = self.pad();
                self.indent += 1;
                let arm_indent = self.pad();
                let arms_str: String = arms
                    .iter()
                    .map(|arm| {
                        let pattern_str = fmt_pattern(&arm.pattern);
                        let body_str = self.fmt_block_body(arm.body);
                        format!("{}{} => {}", arm_indent, pattern_str, body_str)
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                self.indent -= 1;
                format!("{}match {} {{\n{}\n{}}}", outer, scrutinee_str, arms_str, outer)
            }

            RuntimeStmt::Import(_) | RuntimeStmt::Gen(_) | RuntimeStmt::EffectDecl { .. } => String::new(),

            RuntimeStmt::WithFn { op_name, params, body, .. } => {
                let params_str = params.iter().map(|p| p.name.clone()).collect::<Vec<_>>().join(", ");
                let body_str = self.fmt_block_body(body);
                format!("{}with fn {}({}) {}", self.pad(), op_name, params_str, body_str)
            }

            RuntimeStmt::WithCtl { op_name, params, body, .. } => {
                let params_str = params.iter().map(|p| p.name.clone()).collect::<Vec<_>>().join(", ");
                let body_str = self.fmt_block_body(body);
                format!("{}with ctl {}({}) {}", self.pad(), op_name, params_str, body_str)
            }

            RuntimeStmt::Resume(opt_e) => match opt_e {
                None => format!("{}resume;", self.pad()),
                Some(e) => format!("{}resume {};", self.pad(), self.fmt_expr(e)),
            },
        }
    }

    /// Format a stmt ID as a braced block: `{\n    ...\n}`.
    fn fmt_block_body(&mut self, id: usize) -> String {
        let stmt = self.ast.get_stmt(id).expect("invalid stmt id").clone();
        match stmt {
            RuntimeStmt::Block(stmts) => self.fmt_block_stmts(&stmts),
            _ => {
                self.indent += 1;
                let body = self.fmt_stmt(id);
                self.indent -= 1;
                format!("{{\n{}\n{}}}", body, self.pad())
            }
        }
    }

    fn fmt_block_stmts(&mut self, stmts: &[usize]) -> String {
        let stmts = stmts.to_vec();
        self.indent += 1;
        let lines: Vec<String> = stmts
            .iter()
            .map(|id| self.fmt_stmt(*id))
            .filter(|l| !l.is_empty())
            .collect();
        self.indent -= 1;
        if lines.is_empty() {
            format!("{}{{}}", self.pad())
        } else {
            format!("{{\n{}\n{}}}", lines.join("\n"), self.pad())
        }
    }

    fn fmt_expr(&mut self, id: usize) -> String {
        let expr = self.ast.get_expr(id).expect("invalid expr id").clone();
        match expr {
            RuntimeExpr::Int(n) => n.to_string(),
            RuntimeExpr::String(s) => format!("\"{}\"", s),
            RuntimeExpr::Bool(b) => b.to_string(),
            RuntimeExpr::Variable(name) => name,

            RuntimeExpr::Add(a, b) => format!("{} + {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Sub(a, b) => {
                // Unary minus is stored as Sub(Int(0), operand) — render as -operand
                if matches!(self.ast.get_expr(a), Some(RuntimeExpr::Int(0))) {
                    format!("-{}", self.fmt_expr(b))
                } else {
                    format!("{} - {}", self.fmt_expr(a), self.fmt_expr(b))
                }
            }
            RuntimeExpr::Mult(a, b) => format!("{} * {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Div(a, b) => format!("{} / {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Equals(a, b) => format!("{} == {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::NotEquals(a, b) => format!("{} != {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Lt(a, b) => format!("{} < {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Gt(a, b) => format!("{} > {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Lte(a, b) => format!("{} <= {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Gte(a, b) => format!("{} >= {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::And(a, b) => format!("{} && {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Or(a, b) => format!("{} || {}", self.fmt_expr(a), self.fmt_expr(b)),
            RuntimeExpr::Not(a) => format!("!{}", self.fmt_expr(a)),

            RuntimeExpr::Call { callee, args } => {
                let args_str = args
                    .iter()
                    .map(|id| self.fmt_expr(*id))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{}({})", callee, args_str)
            }

            RuntimeExpr::DotAccess { object, field } => {
                format!("{}.{}", self.fmt_expr(object), field)
            }

            RuntimeExpr::DotCall { object, method, args } => {
                let args_str = args
                    .iter()
                    .map(|id| self.fmt_expr(*id))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{}.{}({})", self.fmt_expr(object), method, args_str)
            }

            RuntimeExpr::Index { object, index } => {
                format!("{}[{}]", self.fmt_expr(object), self.fmt_expr(index))
            }

            RuntimeExpr::Tuple(items) => {
                let items_str = items
                    .iter()
                    .map(|id| self.fmt_expr(*id))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("({})", items_str)
            }

            RuntimeExpr::TupleIndex { object, index } => {
                format!("{}.{}", self.fmt_expr(object), index)
            }

            RuntimeExpr::List(items) => {
                let items_str = items
                    .iter()
                    .map(|id| self.fmt_expr(*id))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("[{}]", items_str)
            }

            RuntimeExpr::StructLiteral { type_name, fields } => {
                let fields_str = fields
                    .iter()
                    .map(|(name, id)| format!("{}: {}", name, self.fmt_expr(*id)))
                    .collect::<Vec<_>>()
                    .join(", ");
                if type_name.is_empty() {
                    format!("{{ {} }}", fields_str)
                } else {
                    format!("{} {{ {} }}", type_name, fields_str)
                }
            }

            RuntimeExpr::EnumConstructor { enum_name, variant, payload } => match payload {
                ConstructorPayload::Unit => format!("{}::{}", enum_name, variant),
                ConstructorPayload::Tuple(ids) => {
                    let args = ids
                        .iter()
                        .map(|id| self.fmt_expr(*id))
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("{}::{}({})", enum_name, variant, args)
                }
                ConstructorPayload::Struct(fields) => {
                    let fs = fields
                        .iter()
                        .map(|(name, id)| format!("{}: {}", name, self.fmt_expr(*id)))
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("{}::{} {{ {} }}", enum_name, variant, fs)
                }
            },

            RuntimeExpr::SliceRange { object, start, end } => {
                let obj_str = self.fmt_expr(object);
                let start_str = start.map(|s| self.fmt_expr(s)).unwrap_or_default();
                let end_str = end.map(|e| self.fmt_expr(e)).unwrap_or_default();
                format!("{}[{}:{}]", obj_str, start_str, end_str)
            }

            RuntimeExpr::Lambda { params, body } => {
                let params_str = params.join(", ");
                let body_str = self.fmt_block_body(body);
                format!("fn({}) {}", params_str, body_str)
            }

            RuntimeExpr::Unit => "unit".to_string(),

            RuntimeExpr::ResumeExpr(opt) => match opt {
                None => "resume".to_string(),
                Some(e) => format!("resume({})", self.fmt_expr(e)),
            },
        }
    }
}

fn fmt_pattern(pattern: &Pattern) -> String {
    match pattern {
        Pattern::Wildcard => "_".to_string(),
        Pattern::Enum { enum_name, variant, bindings } => match bindings {
            VariantBindings::Unit => format!("{}::{}", enum_name, variant),
            VariantBindings::Tuple(names) => {
                format!("{}::{}({})", enum_name, variant, names.join(", "))
            }
            VariantBindings::Struct(names) => {
                format!("{}::{} {{ {} }}", enum_name, variant, names.join(", "))
            }
        },
    }
}

/// Format a `RuntimeAst` into source-like text for debugging.
pub fn format_runtime_ast(ast: &RuntimeAst) -> String {
    Formatter::new(ast).format_root()
}
