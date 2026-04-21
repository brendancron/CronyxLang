//! LLVM codegen — Milestone 2
//!
//! Adds over M1:
//!   - `StructDecl` → named LLVM struct types (`%Name = type { i64, ... }`)
//!   - `StructLiteral` → `malloc` + field `store`s
//!   - `DotAccess` → `getelementptr` + `load`
//!   - `free(x)` → `call void @free(ptr x)`
//!   - Struct params passed by pointer; type-aware locals (Int vs StructPtr)
//!
//! ### Param kind resolution
//!
//! The runtime type checker stores `Type::Func { params, .. }` in `type_map`
//! under each `FnDecl`'s stmt id.  After the final substitution these param
//! types are fully resolved (e.g. `Struct { name: "Point", .. }` for a struct
//! param), so codegen reads them directly without scanning call sites.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use inkwell::AddressSpace;
use inkwell::IntPredicate;
use inkwell::builder::BuilderError;
use inkwell::context::Context;
use inkwell::module::Linkage;
use inkwell::targets::{InitializationConfig, Target};
use inkwell::types::{ArrayType, BasicType, BasicTypeEnum, BasicMetadataTypeEnum, IntType, PointerType, StructType};
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

// ── Struct registry ───────────────────────────────────────────────────────────

struct StructMeta<'ctx> {
    llvm_ty: StructType<'ctx>,
    field_names: Vec<String>,
}

// ── Local variable info ───────────────────────────────────────────────────────

#[derive(Clone)]
enum LocalKind {
    Int,
    StructPtr(String), // Cronyx struct type name
}

struct Local<'ctx> {
    slot: PointerValue<'ctx>,
    kind: LocalKind,
}

type Locals<'ctx> = HashMap<String, Local<'ctx>>;

// ── Public entry point ────────────────────────────────────────────────────────

pub fn compile(
    ast: &RuntimeAst,
    type_map: &HashMap<usize, Type>,
    out_path: &Path,
) -> Result<(), CodegenError> {
    let ll_path = out_path.with_extension("ll");

    Target::initialize_native(&InitializationConfig::default())
        .map_err(|e| CodegenError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;

    let context = Context::create();
    let module  = context.create_module("cronyx");
    let builder = context.create_builder();

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

    // ── Primitive types ───────────────────────────────────────────────────────
    let ptr_ty = context.ptr_type(AddressSpace::default());
    let i32_ty = context.i32_type();
    let i64_ty = context.i64_type();

    // ── Declare printf ────────────────────────────────────────────────────────
    let printf_ty = i32_ty.fn_type(&[BasicMetadataTypeEnum::PointerType(ptr_ty)], true);
    let printf_fn = module.add_function("printf", printf_ty, Some(Linkage::External));

    // ── Format string global ──────────────────────────────────────────────────
    let fmt_bytes  = b"%lld\n";
    let fmt_array  = context.const_string(fmt_bytes, true);
    let fmt_ty     = context.i8_type().array_type((fmt_bytes.len() + 1) as u32);
    let fmt_global = module.add_global(fmt_ty, Some(AddressSpace::default()), "fmt_int");
    fmt_global.set_initializer(&fmt_array);
    fmt_global.set_constant(true);
    fmt_global.set_linkage(Linkage::Private);

    // ── Pass 0a: check for struct usage (gate malloc/free declarations) ───────
    let has_structs = ast.sem_root_stmts.iter()
        .any(|&id| matches!(ast.get_stmt(id), Some(RuntimeStmt::StructDecl { .. })));

    let malloc_fn = if has_structs {
        let malloc_fn_ty = ptr_ty.fn_type(&[BasicMetadataTypeEnum::IntType(i64_ty)], false);
        Some(module.add_function("malloc", malloc_fn_ty, Some(Linkage::External)))
    } else { None };

    let free_fn = if has_structs {
        let void_ty    = context.void_type();
        let free_fn_ty = void_ty.fn_type(&[BasicMetadataTypeEnum::PointerType(ptr_ty)], false);
        Some(module.add_function("free", free_fn_ty, Some(Linkage::External)))
    } else { None };

    // ── Pass 0b: build struct type registry ───────────────────────────────────
    let struct_decls: Vec<(String, Vec<(String, String)>)> = ast.sem_root_stmts.iter()
        .filter_map(|&id| match ast.get_stmt(id) {
            Some(RuntimeStmt::StructDecl { name, fields }) =>
                Some((name.clone(), fields.iter().map(|f| (f.field_name.clone(), f.type_name.clone())).collect())),
            _ => None,
        })
        .collect();

    let mut structs: HashMap<String, StructMeta<'_>> = HashMap::new();
    for (sname, fields) in &struct_decls {
        let llvm_ty = context.opaque_struct_type(sname);
        let field_types: Vec<BasicTypeEnum<'_>> = fields.iter()
            .map(|(_, type_name)| llvm_field_type(type_name, i64_ty, ptr_ty))
            .collect();
        llvm_ty.set_body(&field_types, /*packed=*/false);
        structs.insert(sname.clone(), StructMeta {
            llvm_ty,
            field_names: fields.iter().map(|(n, _)| n.clone()).collect(),
        });
    }

    // ── Pass 1: forward-declare all user functions ────────────────────────────
    // Param types come from type_map[stmt_id] which the type checker stores as
    // Type::Func { params, .. } after full substitution for each FnDecl.
    let fn_decls: Vec<(usize, String, Vec<String>, usize)> = ast.sem_root_stmts.iter()
        .filter_map(|&id| match ast.get_stmt(id) {
            Some(RuntimeStmt::FnDecl { name, params, body, .. }) =>
                Some((id, name.clone(), params.clone(), *body)),
            _ => None,
        })
        .collect();

    let mut user_fns: HashMap<String, FunctionValue<'_>> = HashMap::new();
    let mut fn_arg_types: HashMap<String, Vec<Option<Type>>> = HashMap::new();

    for (stmt_id, fname, params, _body_id) in &fn_decls {
        let resolved_param_types: Vec<Option<Type>> = match type_map.get(stmt_id) {
            Some(Type::Func { params: pt, .. }) => pt.iter().map(|t| Some(t.clone())).collect(),
            _ => vec![None; params.len()],
        };
        let param_meta: Vec<BasicMetadataTypeEnum<'_>> = resolved_param_types.iter()
            .map(|opt_ty| match opt_ty {
                Some(Type::Struct { .. }) => BasicMetadataTypeEnum::PointerType(ptr_ty),
                _ => BasicMetadataTypeEnum::IntType(i64_ty),
            })
            .collect();
        let fn_ty  = i64_ty.fn_type(&param_meta, false);
        let fn_val = module.add_function(fname, fn_ty, None);
        user_fns.insert(fname.clone(), fn_val);
        fn_arg_types.insert(fname.clone(), resolved_param_types);
    }

    let cg = Cg {
        ast, context: &context, builder: &builder,
        printf_fn, fmt_global, fmt_ty,
        malloc_fn, free_fn,
        i64_ty, ptr_ty,
        user_fns, structs,
        type_map,
    };

    // ── Pass 2: emit function bodies ──────────────────────────────────────────
    for (_stmt_id, fname, params, body_id) in &fn_decls {
        let fn_val    = cg.user_fns[fname.as_str()];
        let arg_types = &fn_arg_types[fname.as_str()];
        cg.emit_fn_body(fn_val, params, arg_types, *body_id)?;
    }

    // ── Pass 3: emit main() ───────────────────────────────────────────────────
    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let entry   = context.append_basic_block(main_fn, "entry");
    builder.position_at_end(entry);

    let mut main_locals: Locals<'_> = HashMap::new();
    for &stmt_id in &ast.sem_root_stmts {
        if matches!(ast.get_stmt(stmt_id),
            Some(RuntimeStmt::FnDecl { .. } | RuntimeStmt::StructDecl { .. }))
        {
            continue;
        }
        if cg.cur_block_terminated() { break; }
        cg.emit_stmt(stmt_id, &mut main_locals)?;
    }

    if !cg.cur_block_terminated() {
        builder.build_return(Some(&i32_ty.const_int(0, false)))?;
    }

    // ── Emit .ll and link ─────────────────────────────────────────────────────
    module.print_to_file(&ll_path)
        .map_err(|e| CodegenError::Io(std::io::Error::new(std::io::ErrorKind::Other, e.to_string())))?;

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
    ast:        &'ctx RuntimeAst,
    context:    &'ctx Context,
    builder:    &'ctx inkwell::builder::Builder<'ctx>,
    printf_fn:  FunctionValue<'ctx>,
    fmt_global: GlobalValue<'ctx>,
    fmt_ty:     ArrayType<'ctx>,
    malloc_fn:  Option<FunctionValue<'ctx>>,
    free_fn:    Option<FunctionValue<'ctx>>,
    i64_ty:     IntType<'ctx>,
    ptr_ty:     PointerType<'ctx>,
    user_fns:   HashMap<String, FunctionValue<'ctx>>,
    structs:    HashMap<String, StructMeta<'ctx>>,
    type_map:   &'ctx HashMap<usize, Type>,
}

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
        arg_types: &[Option<Type>],
        body_id: usize,
    ) -> Result<(), CodegenError> {
        let entry = self.context.append_basic_block(fn_val, "entry");
        self.builder.position_at_end(entry);

        let mut locals: Locals<'ctx> = HashMap::new();

        for (i, name) in param_names.iter().enumerate() {
            let param_val = fn_val.get_nth_param(i as u32).unwrap();
            let local = match param_val {
                BasicValueEnum::IntValue(iv) => {
                    let slot = self.builder.build_alloca(self.i64_ty, name)?;
                    self.builder.build_store(slot, iv)?;
                    Local { slot, kind: LocalKind::Int }
                }
                BasicValueEnum::PointerValue(pv) => {
                    let struct_name = match arg_types.get(i) {
                        Some(Some(Type::Struct { name: sname, .. })) => sname.clone(),
                        _ => String::new(), // shouldn't happen
                    };
                    let slot = self.builder.build_alloca(self.ptr_ty, name)?;
                    self.builder.build_store(slot, pv)?;
                    Local { slot, kind: LocalKind::StructPtr(struct_name) }
                }
                _ => continue,
            };
            locals.insert(name.clone(), local);
        }

        self.emit_stmt(body_id, &mut locals)?;

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
                let zero     = self.context.i32_type().const_int(0, false);
                let fmt_ptr  = unsafe {
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
                let val = self.emit_expr(*expr, locals)?;
                let local = match val {
                    BasicValueEnum::IntValue(iv) => {
                        let slot = self.builder.build_alloca(self.i64_ty, name)?;
                        self.builder.build_store(slot, iv)?;
                        Local { slot, kind: LocalKind::Int }
                    }
                    BasicValueEnum::PointerValue(pv) => {
                        // Get struct name: try AST node first (StructLiteral has it),
                        // then fall back to type_map (works for call-return struct vars).
                        let struct_name = match self.ast.get_expr(*expr) {
                            Some(RuntimeExpr::StructLiteral { type_name, .. }) =>
                                type_name.clone(),
                            _ => match self.type_map.get(expr) {
                                Some(Type::Struct { name: sname, .. }) => sname.clone(),
                                _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                            }
                        };
                        let slot = self.builder.build_alloca(self.ptr_ty, name)?;
                        self.builder.build_store(slot, pv)?;
                        Local { slot, kind: LocalKind::StructPtr(struct_name) }
                    }
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                };
                locals.insert(name.clone(), local);
            }

            RuntimeStmt::Assign { name, expr } => {
                let local = locals.get(name)
                    .ok_or_else(|| CodegenError::UnboundVar(name.clone()))?;
                let (slot, kind) = (local.slot, local.kind.clone());
                let val = self.emit_expr(*expr, locals)?;
                match (&kind, val) {
                    (LocalKind::Int, BasicValueEnum::IntValue(iv)) => {
                        self.builder.build_store(slot, iv)?;
                    }
                    (LocalKind::StructPtr(_), BasicValueEnum::PointerValue(pv)) => {
                        self.builder.build_store(slot, pv)?;
                    }
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                }
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

                self.builder.build_conditional_branch(cond_val, then_bb, else_bb.unwrap_or(merge_bb))?;

                self.builder.position_at_end(then_bb);
                self.emit_stmt(body_id, locals)?;
                if !self.cur_block_terminated() {
                    self.builder.build_unconditional_branch(merge_bb)?;
                }

                if let (Some(eb_id), Some(ebb)) = (else_id, else_bb) {
                    self.builder.position_at_end(ebb);
                    self.emit_stmt(eb_id, locals)?;
                    if !self.cur_block_terminated() {
                        self.builder.build_unconditional_branch(merge_bb)?;
                    }
                }

                self.builder.position_at_end(merge_bb);
            }

            // ── While loop ────────────────────────────────────────────────────
            RuntimeStmt::WhileLoop { cond, body } => {
                let cur_fn = self.builder.get_insert_block().unwrap().get_parent().unwrap();
                let cond_bb = self.context.append_basic_block(cur_fn, "loop_cond");
                let body_bb = self.context.append_basic_block(cur_fn, "loop_body");
                let exit_bb = self.context.append_basic_block(cur_fn, "loop_exit");

                self.builder.build_unconditional_branch(cond_bb)?;

                self.builder.position_at_end(cond_bb);
                let cond_val = self.emit_cond(*cond, locals)?;
                self.builder.build_conditional_branch(cond_val, body_bb, exit_bb)?;

                self.builder.position_at_end(body_bb);
                self.emit_stmt(*body, locals)?;
                if !self.cur_block_terminated() {
                    self.builder.build_unconditional_branch(cond_bb)?;
                }

                self.builder.position_at_end(exit_bb);
            }

            // ── Expression statements ─────────────────────────────────────────
            RuntimeStmt::ExprStmt(expr_id) => {
                self.emit_expr(*expr_id, locals)?;
            }

            // ── Declarations (handled in other passes) ────────────────────────
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
            RuntimeExpr::Int(n) =>
                Ok(self.i64_ty.const_int(*n as u64, true).as_basic_value_enum()),

            // ── Variable load ─────────────────────────────────────────────────
            RuntimeExpr::Variable(name) => {
                let local = locals.get(name)
                    .ok_or_else(|| CodegenError::UnboundVar(name.clone()))?;
                match &local.kind {
                    LocalKind::Int =>
                        Ok(self.builder.build_load(self.i64_ty, local.slot, name)?),
                    LocalKind::StructPtr(_) =>
                        Ok(self.builder.build_load(self.ptr_ty, local.slot, name)?),
                }
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

            // ── Comparisons ───────────────────────────────────────────────────
            RuntimeExpr::Lte(a, b) => self.emit_icmp(IntPredicate::SLE, *a, *b, "lte", locals),
            RuntimeExpr::Lt(a, b)  => self.emit_icmp(IntPredicate::SLT, *a, *b, "lt",  locals),
            RuntimeExpr::Gte(a, b) => self.emit_icmp(IntPredicate::SGE, *a, *b, "gte", locals),
            RuntimeExpr::Gt(a, b)  => self.emit_icmp(IntPredicate::SGT, *a, *b, "gt",  locals),
            RuntimeExpr::Equals(a, b)    => self.emit_icmp(IntPredicate::EQ, *a, *b, "eq", locals),
            RuntimeExpr::NotEquals(a, b) => self.emit_icmp(IntPredicate::NE, *a, *b, "ne", locals),

            // ── Struct literal → malloc + field stores ────────────────────────
            RuntimeExpr::StructLiteral { type_name, fields } => {
                let malloc_fn = self.malloc_fn.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let meta = self.structs.get(type_name)
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let size = meta.llvm_ty.size_of()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;

                let obj_ptr = self.builder
                    .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(size)], "malloc")?
                    .try_as_basic_value().basic()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                    .into_pointer_value();

                let i32_zero = self.context.i32_type().const_int(0, false);
                for (fname, fexpr_id) in fields {
                    let fidx = meta.field_names.iter().position(|n| n == fname)
                        .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                    let fptr = unsafe {
                        self.builder.build_gep(
                            meta.llvm_ty, obj_ptr,
                            &[i32_zero, self.context.i32_type().const_int(fidx as u64, false)],
                            &format!("{fname}_ptr"),
                        )?
                    };
                    let fval = self.emit_int_expr(*fexpr_id, locals)?;
                    self.builder.build_store(fptr, fval)?;
                }
                Ok(obj_ptr.as_basic_value_enum())
            }

            // ── Dot access → getelementptr + load ─────────────────────────────
            RuntimeExpr::DotAccess { object, field } => {
                // Resolve the struct name: prefer type_map (now reliable after the
                // type-checker fix), fall back to locals for Variable objects.
                let struct_name = match self.type_map.get(object) {
                    Some(Type::Struct { name, .. }) => name.clone(),
                    _ => {
                        if let Some(RuntimeExpr::Variable(vname)) = self.ast.get_expr(*object) {
                            match locals.get(vname.as_str()) {
                                Some(Local { kind: LocalKind::StructPtr(sname), .. }) => sname.clone(),
                                _ => return Err(CodegenError::UnsupportedExpr(expr_id)),
                            }
                        } else {
                            return Err(CodegenError::UnsupportedExpr(expr_id));
                        }
                    }
                };

                let meta = self.structs.get(&struct_name)
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let fidx = meta.field_names.iter().position(|n| n == field)
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;

                let obj_ptr = match self.emit_expr(*object, locals)? {
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err(CodegenError::UnsupportedExpr(expr_id)),
                };
                let fptr = unsafe {
                    self.builder.build_gep(
                        meta.llvm_ty, obj_ptr,
                        &[
                            self.context.i32_type().const_int(0, false),
                            self.context.i32_type().const_int(fidx as u64, false),
                        ],
                        &format!("{field}_ptr"),
                    )?
                };
                Ok(self.builder.build_load(self.i64_ty, fptr, field)?)
            }

            // ── Calls ─────────────────────────────────────────────────────────
            RuntimeExpr::Call { callee, args } => {
                // to_string(x) → pass through
                if callee == "to_string" && args.len() == 1 {
                    return self.emit_expr(args[0], locals);
                }
                // free(x) → call void @free(ptr x)
                if callee == "free" && args.len() == 1 {
                    if let Some(free_fn) = self.free_fn {
                        let ptr_val = match self.emit_expr(args[0], locals)? {
                            BasicValueEnum::PointerValue(p) => p,
                            _ => return Err(CodegenError::UnsupportedExpr(expr_id)),
                        };
                        self.builder.build_call(
                            free_fn,
                            &[BasicMetadataValueEnum::PointerValue(ptr_val)],
                            "free",
                        )?;
                        return Ok(self.i64_ty.const_int(0, false).as_basic_value_enum());
                    }
                }
                // user-defined function
                if let Some(&fn_val) = self.user_fns.get(callee.as_str()) {
                    let arg_vals: Vec<BasicMetadataValueEnum<'ctx>> = args.iter()
                        .map(|&a| self.emit_expr(a, locals).map(basic_to_meta))
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

    fn emit_int_expr(&self, expr_id: usize, locals: &Locals<'ctx>) -> Result<IntValue<'ctx>, CodegenError> {
        match self.emit_expr(expr_id, locals)? {
            BasicValueEnum::IntValue(v) => Ok(v),
            _ => Err(CodegenError::UnsupportedExpr(expr_id)),
        }
    }

    fn emit_cond(&self, expr_id: usize, locals: &Locals<'ctx>) -> Result<IntValue<'ctx>, CodegenError> {
        let val = self.emit_int_expr(expr_id, locals)?;
        if val.get_type().get_bit_width() == 1 { return Ok(val); }
        let zero = self.i64_ty.const_int(0, false);
        Ok(self.builder.build_int_compare(IntPredicate::NE, val, zero, "tobool")?)
    }

    fn emit_binop_ints(&self, a: usize, b: usize, locals: &Locals<'ctx>)
        -> Result<(IntValue<'ctx>, IntValue<'ctx>), CodegenError>
    {
        Ok((self.emit_int_expr(a, locals)?, self.emit_int_expr(b, locals)?))
    }

    fn emit_icmp(&self, pred: IntPredicate, a: usize, b: usize, name: &str, locals: &Locals<'ctx>)
        -> Result<BasicValueEnum<'ctx>, CodegenError>
    {
        let (lhs, rhs) = self.emit_binop_ints(a, b, locals)?;
        Ok(self.builder.build_int_compare(pred, lhs, rhs, name)?.as_basic_value_enum())
    }
}

// ── Free-standing helpers ─────────────────────────────────────────────────────

/// Map a Cronyx field type_name to the LLVM `BasicTypeEnum`.
fn llvm_field_type<'ctx>(type_name: &str, i64_ty: IntType<'ctx>, ptr_ty: PointerType<'ctx>) -> BasicTypeEnum<'ctx> {
    match type_name {
        "int" | "bool" => i64_ty.as_basic_type_enum(),
        _ => ptr_ty.as_basic_type_enum(),
    }
}

/// Convert `BasicValueEnum` to `BasicMetadataValueEnum` for call arguments.
fn basic_to_meta(val: BasicValueEnum<'_>) -> BasicMetadataValueEnum<'_> {
    match val {
        BasicValueEnum::IntValue(v)     => BasicMetadataValueEnum::IntValue(v),
        BasicValueEnum::PointerValue(v) => BasicMetadataValueEnum::PointerValue(v),
        BasicValueEnum::FloatValue(v)   => BasicMetadataValueEnum::FloatValue(v),
        BasicValueEnum::ArrayValue(v)   => BasicMetadataValueEnum::ArrayValue(v),
        BasicValueEnum::StructValue(v)  => BasicMetadataValueEnum::StructValue(v),
        BasicValueEnum::VectorValue(v)  => BasicMetadataValueEnum::VectorValue(v),
        _ => unreachable!("unsupported BasicValueEnum variant in basic_to_meta"),
    }
}

/// If `expr_id` is `to_string(inner)`, return `inner`. Otherwise return `expr_id`.
fn unwrap_to_string(ast: &RuntimeAst, expr_id: usize) -> Result<usize, CodegenError> {
    let expr = ast.get_expr(expr_id).ok_or(CodegenError::MissingNode(expr_id))?;
    match expr {
        RuntimeExpr::Call { callee, args } if callee == "to_string" && args.len() == 1 => Ok(args[0]),
        _ => Ok(expr_id),
    }
}
