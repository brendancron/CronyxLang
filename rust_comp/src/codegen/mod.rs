//! LLVM codegen — Milestone 0
//!
//! Compiles the minimal subset needed for `print(to_string(1 + 2))`:
//!   - RuntimeStmt::Print(expr_id)
//!   - RuntimeExpr::Int(n)
//!   - RuntimeExpr::Add / Sub / Mult / Div
//!   - RuntimeExpr::Call { callee: "to_string", args: [int_expr] } — pass-through

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use inkwell::AddressSpace;
use inkwell::builder::BuilderError;
use inkwell::context::Context;
use inkwell::module::Linkage;
use inkwell::targets::{InitializationConfig, Target};
use inkwell::types::{ArrayType, BasicMetadataTypeEnum, IntType};
use inkwell::values::{BasicMetadataValueEnum, FunctionValue, GlobalValue, IntValue};

use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::semantics::types::types::Type;

// ── Error ─────────────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum CodegenError {
    Builder(BuilderError),
    UnsupportedExpr(usize),
    MissingNode(usize),
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
            CodegenError::Builder(e)          => write!(f, "LLVM builder error: {e}"),
            CodegenError::UnsupportedExpr(id) => write!(f, "unsupported expr at M0 (id={id})"),
            CodegenError::MissingNode(id)     => write!(f, "missing AST node (id={id})"),
            CodegenError::Io(e)               => write!(f, "I/O error: {e}"),
            CodegenError::ClangFailed(msg)    => write!(f, "clang failed: {msg}"),
        }
    }
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Compile `ast` to a native binary at `out_path`.
/// Emits LLVM IR to `<out_path>.ll`, then shells out to `clang` to produce the binary.
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

    // ── Format string global: "%lld\n\0" (6 bytes) ───────────────────────────
    let fmt_bytes = b"%lld\n";
    let fmt_array = context.const_string(fmt_bytes, /*null_terminated=*/true);
    let fmt_ty    = context.i8_type().array_type((fmt_bytes.len() + 1) as u32);
    let fmt_global = module.add_global(fmt_ty, Some(AddressSpace::default()), "fmt_int");
    fmt_global.set_initializer(&fmt_array);
    fmt_global.set_constant(true);
    fmt_global.set_linkage(Linkage::Private);

    // ── Define main() ─────────────────────────────────────────────────────────
    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let entry   = context.append_basic_block(main_fn, "entry");
    builder.position_at_end(entry);

    let i64_ty = context.i64_type();
    let cg = Cg { ast, context: &context, builder: &builder, printf_fn, fmt_global, fmt_ty, i64_ty };

    for &stmt_id in &ast.sem_root_stmts {
        cg.emit_stmt(stmt_id)?;
    }

    builder.build_return(Some(&i32_ty.const_int(0, false)))?;

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
}

impl<'ctx> Cg<'ctx> {
    fn emit_stmt(&self, stmt_id: usize) -> Result<(), CodegenError> {
        let stmt = self.ast.get_stmt(stmt_id).ok_or(CodegenError::MissingNode(stmt_id))?;
        match stmt {
            RuntimeStmt::Print(expr_id) => {
                let inner_id = unwrap_to_string(self.ast, *expr_id)?;
                let val = self.emit_int_expr(inner_id)?;

                // GEP([6 x i8]*, ptr @fmt_int, i32 0, i32 0) → ptr to first byte
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
            // All other statements silently skipped at M0.
            _ => {}
        }
        Ok(())
    }

    fn emit_int_expr(&self, expr_id: usize) -> Result<IntValue<'ctx>, CodegenError> {
        let expr = self.ast.get_expr(expr_id).ok_or(CodegenError::MissingNode(expr_id))?;
        match expr {
            RuntimeExpr::Int(n) => {
                Ok(self.i64_ty.const_int(*n as u64, /*sign_extend=*/true))
            }
            RuntimeExpr::Add(a, b) => {
                let lhs = self.emit_int_expr(*a)?;
                let rhs = self.emit_int_expr(*b)?;
                Ok(self.builder.build_int_add(lhs, rhs, "add")?)
            }
            RuntimeExpr::Sub(a, b) => {
                let lhs = self.emit_int_expr(*a)?;
                let rhs = self.emit_int_expr(*b)?;
                Ok(self.builder.build_int_sub(lhs, rhs, "sub")?)
            }
            RuntimeExpr::Mult(a, b) => {
                let lhs = self.emit_int_expr(*a)?;
                let rhs = self.emit_int_expr(*b)?;
                Ok(self.builder.build_int_mul(lhs, rhs, "mul")?)
            }
            RuntimeExpr::Div(a, b) => {
                let lhs = self.emit_int_expr(*a)?;
                let rhs = self.emit_int_expr(*b)?;
                Ok(self.builder.build_int_signed_div(lhs, rhs, "div")?)
            }
            // to_string(int) nested elsewhere: unwrap and recurse
            RuntimeExpr::Call { callee, args } if callee == "to_string" && args.len() == 1 => {
                self.emit_int_expr(args[0])
            }
            _ => Err(CodegenError::UnsupportedExpr(expr_id)),
        }
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
