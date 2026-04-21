//! LLVM codegen — Milestone 1
//!
//! Adds over M0:
//!   - `FnDecl` → LLVM function with i64 parameters (two-pass: forward-declare then fill body)
//!   - `Return` → `ret`
//!   - `If` / else → basic blocks + conditional branch
//!   - `VarDecl` / `Assign` → `alloca` + `store` / `store`
//!   - `Variable` → `load` from `alloca`
//!   - Comparison ops (Lte, Lt, Gte, Gt, Equals, NotEquals) → `icmp`
//!   - Recursive `Call` → look up in pre-declared function table

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use inkwell::AddressSpace;
use inkwell::IntPredicate;
use inkwell::builder::BuilderError;
use inkwell::context::Context;
use inkwell::module::Linkage;
use inkwell::targets::{InitializationConfig, Target};
use inkwell::types::{ArrayType, BasicMetadataTypeEnum, IntType};
use inkwell::values::{BasicMetadataValueEnum, BasicValue, BasicValueEnum, FunctionValue, GlobalValue, IntValue, PointerValue};

use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::semantics::types::types::Type;

// ── Error ─────────────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum CodegenError {
    Builder(BuilderError),
    UnsupportedExpr(usize),
    UnsupportedStmt(usize),
    MissingNode(usize),
    UnboundVar(String),
    Io(std::io::Error),
    ClangFailed(String),
}

impl From<BuilderError> for CodegenError {
    fn from(e: BuilderError) -> Self { CodegenError::Builder(e) }
}
impl From<std::io::Error> for CodegenError {
    fn from(e: std::io::Error) -> Self { CodegenError::Io(e) }
}
impl std::fmt::Display for CodegenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CodegenError::Builder(e)           => write!(f, "LLVM builder error: {e}"),
            CodegenError::UnsupportedExpr(id)  => write!(f, "unsupported expression (id={id})"),
            CodegenError::UnsupportedStmt(id)  => write!(f, "unsupported statement (id={id})"),
            CodegenError::MissingNode(id)      => write!(f, "missing AST node (id={id})"),
            CodegenError::UnboundVar(name)     => write!(f, "unbound variable: {name}"),
            CodegenError::Io(e)                => write!(f, "I/O error: {e}"),
            CodegenError::ClangFailed(msg)     => write!(f, "clang failed: {msg}"),
        }
    }
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Compile `ast` to a native binary at `out_path`.
/// Emits LLVM IR to `<out_path>.ll`, then shells out to `clang`.
pub fn compile(
    ast: &RuntimeAst,
    _type_map: &HashMap<usize, Type>,
    out_path: &Path,
) -> Result<(), CodegenError> {
    let ll_path = out_path.with_extension("ll");

    Target::initialize_native(&InitializationConfig::default())
        .map_err(|e| CodegenError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;

    let context = Context::create();
    let module  = context.create_module("cronyx");
    let builder = context.create_builder();

    // Use clang's canonical triple so it doesn't warn about overriding.
    let clang_triple = Command::new("clang")
        .arg("-print-target-triple")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if !clang_triple.is_empty() {
        module.set_triple(&inkwell::targets::TargetTriple::create(&clang_triple));
    } else {
        module.set_triple(&inkwell::targets::TargetMachine::get_default_triple());
    }

    // ── Declare printf: i32 @printf(ptr, ...) ────────────────────────────────
    let ptr_ty    = context.ptr_type(AddressSpace::default());
    let i32_ty    = context.i32_type();
    let printf_ty = i32_ty.fn_type(&[BasicMetadataTypeEnum::PointerType(ptr_ty)], true);
    let printf_fn = module.add_function("printf", printf_ty, Some(Linkage::External));

    // ── Format string global: "%lld\n\0" ─────────────────────────────────────
    let fmt_bytes  = b"%lld\n";
    let fmt_array  = context.const_string(fmt_bytes, /*null_terminated=*/true);
    let fmt_ty     = context.i8_type().array_type((fmt_bytes.len() + 1) as u32);
    let fmt_global = module.add_global(fmt_ty, Some(AddressSpace::default()), "fmt_int");
    fmt_global.set_initializer(&fmt_array);
    fmt_global.set_constant(true);
    fmt_global.set_linkage(Linkage::Private);

    let i64_ty = context.i64_type();

    // ── Pass 1: forward-declare all user functions (all i64 for M1) ──────────
    let mut user_fns: HashMap<String, FunctionValue<'_>> = HashMap::new();
    for &stmt_id in &ast.sem_root_stmts {
        if let Some(RuntimeStmt::FnDecl { name, params, .. }) = ast.get_stmt(stmt_id) {
            let param_types: Vec<BasicMetadataTypeEnum<'_>> =
                vec![i64_ty.into(); params.len()];
            let fn_ty  = i64_ty.fn_type(&param_types, false);
            let fn_val = module.add_function(name, fn_ty, None);
            user_fns.insert(name.clone(), fn_val);
        }
    }

    let cg = Cg { ast, context: &context, builder: &builder, printf_fn, fmt_global, fmt_ty, i64_ty, user_fns };

    // ── Pass 2: emit function bodies ──────────────────────────────────────────
    // Collect first to avoid holding borrows across emit calls.
    let fn_decls: Vec<(String, Vec<String>, usize)> = ast.sem_root_stmts.iter()
        .filter_map(|&id| match ast.get_stmt(id) {
            Some(RuntimeStmt::FnDecl { name, params, body, .. }) =>
                Some((name.clone(), params.clone(), *body)),
            _ => None,
        })
        .collect();

    for (name, params, body_id) in &fn_decls {
        let fn_val = cg.user_fns[name.as_str()];
        cg.emit_fn_body(fn_val, params, *body_id)?;
    }

    // ── Pass 3: emit main() from non-FnDecl root stmts ───────────────────────
    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let entry   = context.append_basic_block(main_fn, "entry");
    builder.position_at_end(entry);

    let mut main_locals: HashMap<String, PointerValue<'_>> = HashMap::new();
    for &stmt_id in &ast.sem_root_stmts {
        if matches!(ast.get_stmt(stmt_id), Some(RuntimeStmt::FnDecl { .. })) {
            continue;
        }
        if cg.cur_block_terminated() { break; }
        cg.emit_stmt(stmt_id, &mut main_locals)?;
    }

    if !cg.cur_block_terminated() {
        builder.build_return(Some(&i32_ty.const_int(0, false)))?;
    }

    // ── Emit .ll ──────────────────────────────────────────────────────────────
    module.print_to_file(&ll_path)
        .map_err(|e| CodegenError::Io(std::io::Error::new(std::io::ErrorKind::Other, e.to_string())))?;

    // ── Link with clang ───────────────────────────────────────────────────────
    let status = Command::new("clang")
        .arg("-Wno-override-module")
        .arg(&ll_path)
        .arg("-o").arg(out_path)
        .status()?;

    if !status.success() {
        return Err(CodegenError::ClangFailed(format!("clang exited with {status}")));
    }

    Ok(())
}

// ── Codegen context ───────────────────────────────────────────────────────────

struct Cg<'ctx> {
    ast: &'ctx RuntimeAst,
    context: &'ctx Context,
    builder: &'ctx inkwell::builder::Builder<'ctx>,
    printf_fn: FunctionValue<'ctx>,
    fmt_global: GlobalValue<'ctx>,
    fmt_ty: ArrayType<'ctx>,
    i64_ty: IntType<'ctx>,
    /// User-defined functions, forward-declared in pass 1.
    user_fns: HashMap<String, FunctionValue<'ctx>>,
}

type Locals<'ctx> = HashMap<String, PointerValue<'ctx>>;

impl<'ctx> Cg<'ctx> {
    fn cur_block_terminated(&self) -> bool {
        self.builder
            .get_insert_block()
            .and_then(|b| b.get_terminator())
            .is_some()
    }

    // ── Function body emission ────────────────────────────────────────────────

    fn emit_fn_body(
        &self,
        fn_val: FunctionValue<'ctx>,
        param_names: &[String],
        body_id: usize,
    ) -> Result<(), CodegenError> {
        let entry = self.context.append_basic_block(fn_val, "entry");
        self.builder.position_at_end(entry);

        let mut locals: Locals<'ctx> = HashMap::new();

        // Alloca + store each parameter so they can be re-assigned later.
        for (i, name) in param_names.iter().enumerate() {
            let param_val = fn_val.get_nth_param(i as u32).unwrap().into_int_value();
            let slot = self.builder.build_alloca(self.i64_ty, name)?;
            self.builder.build_store(slot, param_val)?;
            locals.insert(name.clone(), slot);
        }

        self.emit_stmt(body_id, &mut locals)?;

        // Guard: every path must end with a terminator.
        if !self.cur_block_terminated() {
            self.builder.build_unreachable()?;
        }
        Ok(())
    }

    // ── Statement emission ────────────────────────────────────────────────────

    fn emit_stmt(&self, stmt_id: usize, locals: &mut Locals<'ctx>) -> Result<(), CodegenError> {
        let stmt = self.ast.get_stmt(stmt_id).ok_or(CodegenError::MissingNode(stmt_id))?;
        match stmt {
            // ── Print ─────────────────────────────────────────────────────────
            RuntimeStmt::Print(expr_id) => {
                let inner_id = unwrap_to_string(self.ast, *expr_id)?;
                let val      = self.emit_int_expr(inner_id, locals)?;

                let zero = self.context.i32_type().const_int(0, false);
                let fmt_ptr = unsafe {
                    self.builder.build_gep(
                        self.fmt_ty,
                        self.fmt_global.as_pointer_value(),
                        &[zero, zero],
                        "fmt_ptr",
                    )?
                };
                self.builder.build_call(
                    self.printf_fn,
                    &[
                        BasicMetadataValueEnum::PointerValue(fmt_ptr),
                        BasicMetadataValueEnum::IntValue(val),
                    ],
                    "printf_ret",
                )?;
            }

            // ── Variables ─────────────────────────────────────────────────────
            RuntimeStmt::VarDecl { name, expr } => {
                let val  = self.emit_int_expr(*expr, locals)?;
                let slot = self.builder.build_alloca(self.i64_ty, name)?;
                self.builder.build_store(slot, val)?;
                locals.insert(name.clone(), slot);
            }

            RuntimeStmt::Assign { name, expr } => {
                let val  = self.emit_int_expr(*expr, locals)?;
                let slot = locals.get(name)
                    .ok_or_else(|| CodegenError::UnboundVar(name.clone()))?;
                self.builder.build_store(*slot, val)?;
            }

            // ── Control flow ──────────────────────────────────────────────────
            RuntimeStmt::Return(opt_expr) => {
                if let Some(expr_id) = opt_expr {
                    let val = self.emit_int_expr(*expr_id, locals)?;
                    self.builder.build_return(Some(&val))?;
                } else {
                    self.builder.build_return(None)?;
                }
            }

            RuntimeStmt::Block(children) => {
                for &child_id in children {
                    if self.cur_block_terminated() { break; }
                    self.emit_stmt(child_id, locals)?;
                }
            }

            RuntimeStmt::If { cond, body, else_branch } => {
                let (cond_id, body_id, else_id) = (*cond, *body, *else_branch);
                let cond_val = self.emit_cond(cond_id, locals)?;

                let cur_fn   = self.builder.get_insert_block().unwrap().get_parent().unwrap();
                let then_bb  = self.context.append_basic_block(cur_fn, "then");
                let else_bb  = else_id.map(|_| self.context.append_basic_block(cur_fn, "else"));
                let merge_bb = self.context.append_basic_block(cur_fn, "merge");

                let false_dest = else_bb.unwrap_or(merge_bb);
                self.builder.build_conditional_branch(cond_val, then_bb, false_dest)?;

                // then
                self.builder.position_at_end(then_bb);
                self.emit_stmt(body_id, locals)?;
                if !self.cur_block_terminated() {
                    self.builder.build_unconditional_branch(merge_bb)?;
                }

                // else (optional)
                if let (Some(eb_id), Some(ebb)) = (else_id, else_bb) {
                    self.builder.position_at_end(ebb);
                    self.emit_stmt(eb_id, locals)?;
                    if !self.cur_block_terminated() {
                        self.builder.build_unconditional_branch(merge_bb)?;
                    }
                }

                self.builder.position_at_end(merge_bb);
            }

            // ── Expression statements ─────────────────────────────────────────
            RuntimeStmt::ExprStmt(expr_id) => {
                self.emit_expr(*expr_id, locals)?;
            }

            // ── Declarations handled elsewhere / no codegen needed ────────────
            RuntimeStmt::FnDecl { .. }
            | RuntimeStmt::StructDecl { .. }
            | RuntimeStmt::EnumDecl { .. }
            | RuntimeStmt::Import(_)
            | RuntimeStmt::Gen(_) => {}

            _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
        }
        Ok(())
    }

    // ── Expression emission ───────────────────────────────────────────────────

    fn emit_expr(&self, expr_id: usize, locals: &Locals<'ctx>) -> Result<BasicValueEnum<'ctx>, CodegenError> {
        let expr = self.ast.get_expr(expr_id).ok_or(CodegenError::MissingNode(expr_id))?;
        match expr {
            // ── Literals ──────────────────────────────────────────────────────
            RuntimeExpr::Int(n) => {
                Ok(self.i64_ty.const_int(*n as u64, /*sign_extend=*/true).as_basic_value_enum())
            }

            // ── Variable load ─────────────────────────────────────────────────
            RuntimeExpr::Variable(name) => {
                let slot = locals.get(name)
                    .ok_or_else(|| CodegenError::UnboundVar(name.clone()))?;
                Ok(self.builder.build_load(self.i64_ty, *slot, name)?)
            }

            // ── Arithmetic ────────────────────────────────────────────────────
            RuntimeExpr::Add(a, b) => {
                let (lhs, rhs) = self.emit_binop_ints(*a, *b, locals)?;
                Ok(self.builder.build_int_add(lhs, rhs, "add")?.as_basic_value_enum())
            }
            RuntimeExpr::Sub(a, b) => {
                let (lhs, rhs) = self.emit_binop_ints(*a, *b, locals)?;
                Ok(self.builder.build_int_sub(lhs, rhs, "sub")?.as_basic_value_enum())
            }
            RuntimeExpr::Mult(a, b) => {
                let (lhs, rhs) = self.emit_binop_ints(*a, *b, locals)?;
                Ok(self.builder.build_int_mul(lhs, rhs, "mul")?.as_basic_value_enum())
            }
            RuntimeExpr::Div(a, b) => {
                let (lhs, rhs) = self.emit_binop_ints(*a, *b, locals)?;
                Ok(self.builder.build_int_signed_div(lhs, rhs, "div")?.as_basic_value_enum())
            }

            // ── Comparisons → i1 ─────────────────────────────────────────────
            RuntimeExpr::Lte(a, b) => self.emit_icmp(IntPredicate::SLE, *a, *b, "lte", locals),
            RuntimeExpr::Lt(a, b)  => self.emit_icmp(IntPredicate::SLT, *a, *b, "lt",  locals),
            RuntimeExpr::Gte(a, b) => self.emit_icmp(IntPredicate::SGE, *a, *b, "gte", locals),
            RuntimeExpr::Gt(a, b)  => self.emit_icmp(IntPredicate::SGT, *a, *b, "gt",  locals),
            RuntimeExpr::Equals(a, b)    => self.emit_icmp(IntPredicate::EQ, *a, *b, "eq", locals),
            RuntimeExpr::NotEquals(a, b) => self.emit_icmp(IntPredicate::NE, *a, *b, "ne", locals),

            // ── Calls ─────────────────────────────────────────────────────────
            RuntimeExpr::Call { callee, args } => {
                // to_string(x) is a pass-through at M1
                if callee == "to_string" && args.len() == 1 {
                    return self.emit_expr(args[0], locals);
                }
                // user-defined function
                if let Some(&fn_val) = self.user_fns.get(callee.as_str()) {
                    let arg_vals: Vec<BasicMetadataValueEnum<'ctx>> = args.iter()
                        .map(|&a| self.emit_int_expr(a, locals).map(BasicMetadataValueEnum::IntValue))
                        .collect::<Result<_, _>>()?;
                    let call_site = self.builder.build_call(fn_val, &arg_vals, "call")?;
                    return call_site.try_as_basic_value()
                        .basic()
                        .ok_or(CodegenError::UnsupportedExpr(expr_id));
                }
                Err(CodegenError::UnsupportedExpr(expr_id))
            }

            _ => Err(CodegenError::UnsupportedExpr(expr_id)),
        }
    }

    /// Emit an expression expected to produce an i64.
    fn emit_int_expr(&self, expr_id: usize, locals: &Locals<'ctx>) -> Result<IntValue<'ctx>, CodegenError> {
        match self.emit_expr(expr_id, locals)? {
            BasicValueEnum::IntValue(v) => Ok(v),
            _ => Err(CodegenError::UnsupportedExpr(expr_id)),
        }
    }

    /// Emit a condition expression, yielding an i1 for use in `br`.
    /// Comparison ops already produce i1; anything else is compared != 0.
    fn emit_cond(&self, expr_id: usize, locals: &Locals<'ctx>) -> Result<IntValue<'ctx>, CodegenError> {
        let val = self.emit_int_expr(expr_id, locals)?;
        if val.get_type().get_bit_width() == 1 {
            return Ok(val);
        }
        // i64 fallback: val != 0
        let zero = self.i64_ty.const_int(0, false);
        Ok(self.builder.build_int_compare(IntPredicate::NE, val, zero, "tobool")?)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    fn emit_binop_ints(
        &self,
        a: usize,
        b: usize,
        locals: &Locals<'ctx>,
    ) -> Result<(IntValue<'ctx>, IntValue<'ctx>), CodegenError> {
        Ok((self.emit_int_expr(a, locals)?, self.emit_int_expr(b, locals)?))
    }

    fn emit_icmp(
        &self,
        pred: IntPredicate,
        a: usize,
        b: usize,
        name: &str,
        locals: &Locals<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, CodegenError> {
        let (lhs, rhs) = self.emit_binop_ints(a, b, locals)?;
        Ok(self.builder.build_int_compare(pred, lhs, rhs, name)?.as_basic_value_enum())
    }
}

/// If `expr_id` is `to_string(inner)`, return `inner`. Otherwise return `expr_id` unchanged.
fn unwrap_to_string(ast: &RuntimeAst, expr_id: usize) -> Result<usize, CodegenError> {
    let expr = ast.get_expr(expr_id).ok_or(CodegenError::MissingNode(expr_id))?;
    match expr {
        RuntimeExpr::Call { callee, args } if callee == "to_string" && args.len() == 1 => {
            Ok(args[0])
        }
        _ => Ok(expr_id),
    }
}
