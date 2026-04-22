//! LLVM codegen — Milestone 3
//!
//! Adds over M2:
//!   - `List(items)` → malloc data array + malloc `%__slice = { i64, i64, ptr }` struct
//!   - `ForEach { var, iterable, body }` → induction-variable loop with GEP element access
//!   - `[T]` params passed by pointer (same as struct params)
//!
//! Adds over M1 (M2):
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

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::process::Command;

use inkwell::AddressSpace;
use inkwell::IntPredicate;
use inkwell::basic_block::BasicBlock;
use inkwell::builder::BuilderError;
use inkwell::context::Context;
use inkwell::module::Linkage;
use inkwell::targets::{InitializationConfig, Target};
use inkwell::types::{ArrayType, BasicType, BasicTypeEnum, BasicMetadataTypeEnum, IntType, PointerType, StructType};
use inkwell::values::{BasicMetadataValueEnum, BasicValue, BasicValueEnum, FunctionValue, GlobalValue, IntValue, PointerValue};

use crate::frontend::meta_ast::{ConstructorPayload, Param, Pattern, VariantBindings};
use crate::semantics::cps::effect_marker::CpsInfo;
use crate::semantics::meta::runtime_ast::{RuntimeAst, RuntimeExpr, RuntimeStmt};
use crate::semantics::types::enum_registry::EnumRegistry;
use crate::semantics::types::types::{PrimitiveType, Type};

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
    Str,               // string pointer (ptr to [N x i8] global)
    Slice,             // ptr to %__slice = { i64 len, i64 cap, ptr data }
    Closure,           // ptr to %__closure = { ptr fn_ptr, ptr env_ptr }
    EnumPtr,           // ptr to %__enum_cell = { i64 tag, i64 payload }
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
    cps_info: &CpsInfo,
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

    // ── Format string globals ─────────────────────────────────────────────────
    let fmt_bytes  = b"%lld\n";
    let fmt_array  = context.const_string(fmt_bytes, true);
    let fmt_ty     = context.i8_type().array_type((fmt_bytes.len() + 1) as u32);
    let fmt_global = module.add_global(fmt_ty, Some(AddressSpace::default()), "fmt_int");
    fmt_global.set_initializer(&fmt_array);
    fmt_global.set_constant(true);
    fmt_global.set_linkage(Linkage::Private);

    // fmt_str is only emitted when the program uses string values (keeps IR
    // for int-only milestones identical to their regression baselines).
    let has_strings = ast.exprs.values().any(|e| matches!(e, RuntimeExpr::String(_)));
    let fmt_str = if has_strings {
        let bytes = b"%s\n";
        let arr   = context.const_string(bytes, true);
        let ty    = context.i8_type().array_type((bytes.len() + 1) as u32);
        let g = module.add_global(ty, Some(AddressSpace::default()), "fmt_str");
        g.set_initializer(&arr);
        g.set_constant(true);
        g.set_linkage(Linkage::Private);
        Some((g, ty))
    } else {
        None
    };

    // ── Pass 0a: check for struct/slice/closure/enum usage (gate malloc/free) ──
    let has_structs   = ast.sem_root_stmts.iter()
        .any(|&id| matches!(ast.get_stmt(id), Some(RuntimeStmt::StructDecl { .. })));
    let has_slices    = ast.exprs.values().any(|e| matches!(e, RuntimeExpr::List(_)));
    let has_closures  = ast.exprs.values().any(|e| matches!(e, RuntimeExpr::Lambda { .. }));
    let has_enums     = ast.exprs.values().any(|e| matches!(e, RuntimeExpr::EnumConstructor { .. }));
    let needs_heap    = has_structs || has_slices || has_closures || has_enums;

    let malloc_fn = if needs_heap {
        let malloc_fn_ty = ptr_ty.fn_type(&[BasicMetadataTypeEnum::IntType(i64_ty)], false);
        Some(module.add_function("malloc", malloc_fn_ty, Some(Linkage::External)))
    } else { None };

    let free_fn = if needs_heap {
        let void_ty    = context.void_type();
        let free_fn_ty = void_ty.fn_type(&[BasicMetadataTypeEnum::PointerType(ptr_ty)], false);
        Some(module.add_function("free", free_fn_ty, Some(Linkage::External)))
    } else { None };

    // ── Pass 0a2: create %__slice named type if needed ────────────────────────
    // Layout: { i64 len, i64 cap, ptr data }
    let slice_ty: Option<StructType<'_>> = if has_slices {
        let st = context.opaque_struct_type("__slice");
        st.set_body(&[
            BasicTypeEnum::IntType(i64_ty),
            BasicTypeEnum::IntType(i64_ty),
            BasicTypeEnum::PointerType(ptr_ty),
        ], false);
        Some(st)
    } else { None };

    // ── Pass 0a3: create %__closure named type if needed ──────────────────────
    // Layout: { ptr fn_ptr, ptr env_ptr }
    let closure_ty: Option<StructType<'_>> = if has_closures {
        let st = context.opaque_struct_type("__closure");
        st.set_body(&[
            BasicTypeEnum::PointerType(ptr_ty),
            BasicTypeEnum::PointerType(ptr_ty),
        ], false);
        Some(st)
    } else { None };

    // ── Pass 0a4: create %__enum_cell named type if needed ────────────────────
    // Layout: { i64 tag, i64 payload } — uniform for all enum variants.
    // The tag is the variant's ordinal; the payload holds at most one i64.
    let enum_cell_ty: Option<StructType<'_>> = if has_enums {
        let st = context.opaque_struct_type("__enum_cell");
        st.set_body(&[
            BasicTypeEnum::IntType(i64_ty), // tag
            BasicTypeEnum::IntType(i64_ty), // payload (0 for unit variants)
        ], false);
        Some(st)
    } else { None };

    // ── Pass 0a5: build enum registry ─────────────────────────────────────────
    let enum_registry = EnumRegistry::build(ast);

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

    // ── Pass 0c: create LLVM globals for all string literals ─────────────────
    let mut string_globals: HashMap<String, GlobalValue<'_>> = HashMap::new();
    let mut str_counter = 0usize;
    for expr in ast.exprs.values() {
        if let RuntimeExpr::String(s) = expr {
            if !string_globals.contains_key(s.as_str()) {
                let bytes = s.as_bytes();
                let const_str = context.const_string(bytes, true);
                let str_ty = context.i8_type().array_type((bytes.len() + 1) as u32);
                let global = module.add_global(
                    str_ty, Some(AddressSpace::default()), &format!(".str.{str_counter}"),
                );
                global.set_initializer(&const_str);
                global.set_constant(true);
                global.set_linkage(Linkage::Private);
                string_globals.insert(s.clone(), global);
                str_counter += 1;
            }
        }
    }

    // ── Pass 0d: forward-declare lambda functions ─────────────────────────────
    // Each lambda becomes `define i64 @__lambda_N(ptr %env, [params...])`.
    // Bodies are emitted in Pass 2d after user functions.
    // Sort by DESCENDING ID: the CPS transform creates inner continuations first
    // (lower IDs) and outer ones later (higher IDs). We must emit outer lambda
    // bodies first so that inner lambdas' capture sets are populated before their
    // own bodies are emitted.
    let mut lambda_exprs: Vec<(usize, Vec<String>)> = ast.exprs.iter()
        .filter_map(|(&id, expr)| match expr {
            RuntimeExpr::Lambda { params, .. } => Some((id, params.clone())),
            _ => None,
        })
        .collect();
    lambda_exprs.sort_by(|a, b| b.0.cmp(&a.0));

    // Precompute which names each lambda references (for closure capture).
    let lambda_ref_names: HashMap<usize, Vec<String>> = lambda_exprs.iter()
        .map(|(id, _)| (*id, collect_lambda_refs(ast, *id)))
        .collect();

    let mut lambda_fns: HashMap<usize, FunctionValue<'_>> = HashMap::new();
    for (lambda_id, params) in &lambda_exprs {
        // Param types: env ptr first, then int for each lambda param.
        // Type::Func in type_map could refine this, but i64 is safe for M4.
        let resolved_lam_params: Vec<Option<Type>> = match type_map.get(lambda_id) {
            Some(Type::Func { params: pt, .. }) => pt.iter().map(|t| Some(t.clone())).collect(),
            _ => vec![None; params.len()],
        };
        let mut lam_meta: Vec<BasicMetadataTypeEnum<'_>> = vec![
            BasicMetadataTypeEnum::PointerType(ptr_ty), // env
        ];
        for opt_ty in &resolved_lam_params {
            lam_meta.push(match opt_ty {
                Some(Type::Struct { .. })
                | Some(Type::Primitive(PrimitiveType::String))
                | Some(Type::Slice(_))
                | Some(Type::Func { .. }) =>
                    BasicMetadataTypeEnum::PointerType(ptr_ty),
                _ => BasicMetadataTypeEnum::IntType(i64_ty),
            });
        }
        let lam_ty  = i64_ty.fn_type(&lam_meta, false);
        let lam_val = module.add_function(
            &format!("__lambda_{lambda_id}"),
            lam_ty, None,
        );
        lambda_fns.insert(*lambda_id, lam_val);
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

    // Collect `with fn` handlers — treated as named functions in codegen.
    let with_fn_decls: Vec<(String, Vec<Param>, usize)> = ast.sem_root_stmts.iter()
        .filter_map(|&id| match ast.get_stmt(id) {
            Some(RuntimeStmt::WithFn { op_name, params, body, .. }) =>
                Some((op_name.clone(), params.clone(), *body)),
            _ => None,
        })
        .collect();

    // Collect `with ctl` handlers — like `with fn` but with an implicit `ptr __k` continuation param.
    let with_ctl_decls: Vec<(String, Vec<Param>, usize)> = ast.sem_root_stmts.iter()
        .filter_map(|&id| match ast.get_stmt(id) {
            Some(RuntimeStmt::WithCtl { op_name, params, body, .. }) =>
                Some((op_name.clone(), params.clone(), *body)),
            _ => None,
        })
        .collect();

    let mut user_fns: HashMap<String, FunctionValue<'_>> = HashMap::new();
    let mut fn_arg_types: HashMap<String, Vec<Option<Type>>> = HashMap::new();
    let mut fn_is_ptr_return: HashMap<String, bool> = HashMap::new();

    for (stmt_id, fname, params, _body_id) in &fn_decls {
        let (resolved_param_types, is_ptr_ret) = match type_map.get(stmt_id) {
            Some(Type::Func { params: pt, ret, .. }) => {
                let pts = pt.iter().map(|t| Some(t.clone())).collect();
                let ptr_ret = matches!(ret.as_ref(), Type::Enum(_) | Type::Struct { .. });
                (pts, ptr_ret)
            }
            _ => (vec![None; params.len()], false),
        };
        let param_meta: Vec<BasicMetadataTypeEnum<'_>> = resolved_param_types.iter()
            .map(|opt_ty| match opt_ty {
                Some(Type::Struct { .. })
                | Some(Type::Primitive(PrimitiveType::String))
                | Some(Type::Slice(_))
                | Some(Type::Func { .. })
                | Some(Type::Enum(_)) =>
                    BasicMetadataTypeEnum::PointerType(ptr_ty),
                _ => BasicMetadataTypeEnum::IntType(i64_ty),
            })
            .collect();
        let fn_ty = if is_ptr_ret {
            ptr_ty.fn_type(&param_meta, false)
        } else {
            i64_ty.fn_type(&param_meta, false)
        };
        let fn_val = module.add_function(fname, fn_ty, None);
        user_fns.insert(fname.clone(), fn_val);
        fn_arg_types.insert(fname.clone(), resolved_param_types);
        fn_is_ptr_return.insert(fname.clone(), is_ptr_ret);
    }

    // Forward-declare `with fn` handlers using param type annotations.
    for (op_name, params, _body_id) in &with_fn_decls {
        let param_meta: Vec<BasicMetadataTypeEnum<'_>> = params.iter()
            .map(|p| param_llvm_type(p.ty.as_deref(), i64_ty, ptr_ty))
            .collect();
        let fn_ty = i64_ty.fn_type(&param_meta, false);
        let fn_val = module.add_function(op_name, fn_ty, None);
        let arg_types: Vec<Option<Type>> = params.iter()
            .map(|p| param_type_from_annot(p.ty.as_deref()))
            .collect();
        user_fns.insert(op_name.clone(), fn_val);
        fn_arg_types.insert(op_name.clone(), arg_types);
        fn_is_ptr_return.insert(op_name.clone(), false);
    }

    // Forward-declare `with ctl` handlers: same as `with fn` but append an implicit `ptr __k` param.
    for (op_name, params, _body_id) in &with_ctl_decls {
        let mut param_meta: Vec<BasicMetadataTypeEnum<'_>> = params.iter()
            .map(|p| param_llvm_type(p.ty.as_deref(), i64_ty, ptr_ty))
            .collect();
        param_meta.push(BasicMetadataTypeEnum::PointerType(ptr_ty)); // __k closure ptr
        let fn_ty = i64_ty.fn_type(&param_meta, false);
        let fn_val = module.add_function(op_name, fn_ty, None);
        let mut arg_types: Vec<Option<Type>> = params.iter()
            .map(|p| param_type_from_annot(p.ty.as_deref()))
            .collect();
        // __k is a closure (Func type → LocalKind::Closure in emit_fn_body)
        arg_types.push(Some(Type::Func {
            params: vec![],
            ret: Box::new(Type::Primitive(PrimitiveType::Int)),
            effects: crate::semantics::types::types::EffectRow::empty(),
        }));
        user_fns.insert(op_name.clone(), fn_val);
        fn_arg_types.insert(op_name.clone(), arg_types);
        fn_is_ptr_return.insert(op_name.clone(), false);
    }

    let cg = Cg {
        ast, context: &context, builder: &builder,
        printf_fn, fmt_global, fmt_ty, fmt_str,
        malloc_fn, free_fn, slice_ty, closure_ty, enum_cell_ty,
        i64_ty, ptr_ty,
        user_fns, structs, string_globals,
        lambda_fns, enum_registry,
        type_map,
        lambda_ref_names,
        lambda_actual_captures: RefCell::new(HashMap::new()),
    };

    // ── Pass 2: emit function bodies ──────────────────────────────────────────
    // `params` already includes `__k` for CPS functions (added by cps_transform).
    for (_stmt_id, fname, params, body_id) in &fn_decls {
        let fn_val     = cg.user_fns[fname.as_str()];
        let arg_types  = &fn_arg_types[fname.as_str()];
        let is_ptr_ret = fn_is_ptr_return.get(fname.as_str()).copied().unwrap_or(false);
        cg.emit_fn_body(fn_val, params, arg_types, *body_id, is_ptr_ret)?;
    }

    // ── Pass 2e: emit `with fn` handler bodies ───────────────────────────────
    for (op_name, params, body_id) in &with_fn_decls {
        let fn_val    = cg.user_fns[op_name.as_str()];
        let param_names: Vec<String> = params.iter().map(|p| p.name.clone()).collect();
        let arg_types = &fn_arg_types[op_name.as_str()];
        cg.emit_fn_body(fn_val, &param_names, arg_types, *body_id, false)?;
    }

    // ── Pass 2f: emit `with ctl` handler bodies ───────────────────────────────
    for (op_name, params, body_id) in &with_ctl_decls {
        let fn_val = cg.user_fns[op_name.as_str()];
        let mut param_names: Vec<String> = params.iter().map(|p| p.name.clone()).collect();
        param_names.push("__k".to_string());
        let arg_types = &fn_arg_types[op_name.as_str()];
        cg.emit_fn_body(fn_val, &param_names, arg_types, *body_id, false)?;
    }

    // ── Pass 2d: emit lambda function bodies ──────────────────────────────────
    // env ptr is the first LLVM arg (index 0); lambda params start at index 1.
    for (lambda_id, params) in &lambda_exprs {
        let lam_val = cg.lambda_fns[lambda_id];
        let body_id = match ast.get_expr(*lambda_id) {
            Some(RuntimeExpr::Lambda { body, .. }) => *body,
            _ => continue,
        };
        let resolved_lam_params: Vec<Option<Type>> = match type_map.get(lambda_id) {
            Some(Type::Func { params: pt, .. }) => pt.iter().map(|t| Some(t.clone())).collect(),
            _ => vec![None; params.len()],
        };
        // emit_fn_body handles param index 0..n; we offset by 1 (skip env arg)
        cg.emit_lambda_body(lam_val, *lambda_id, params, &resolved_lam_params, body_id)?;
    }

    // ── Pass 3: emit main() ───────────────────────────────────────────────────
    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let entry   = context.append_basic_block(main_fn, "entry");
    builder.position_at_end(entry);

    let mut main_locals: Locals<'_> = HashMap::new();
    for &stmt_id in &ast.sem_root_stmts {
        if matches!(ast.get_stmt(stmt_id),
            Some(RuntimeStmt::FnDecl { .. } | RuntimeStmt::StructDecl { .. }
                | RuntimeStmt::WithFn { .. } | RuntimeStmt::WithCtl { .. }))
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
    ast:            &'ctx RuntimeAst,
    context:        &'ctx Context,
    builder:        &'ctx inkwell::builder::Builder<'ctx>,
    printf_fn:      FunctionValue<'ctx>,
    fmt_global:     GlobalValue<'ctx>,
    fmt_ty:         ArrayType<'ctx>,
    fmt_str:        Option<(GlobalValue<'ctx>, ArrayType<'ctx>)>,
    malloc_fn:      Option<FunctionValue<'ctx>>,
    free_fn:        Option<FunctionValue<'ctx>>,
    slice_ty:       Option<StructType<'ctx>>,
    closure_ty:     Option<StructType<'ctx>>,
    enum_cell_ty:   Option<StructType<'ctx>>,
    i64_ty:         IntType<'ctx>,
    ptr_ty:         PointerType<'ctx>,
    user_fns:       HashMap<String, FunctionValue<'ctx>>,
    structs:        HashMap<String, StructMeta<'ctx>>,
    string_globals: HashMap<String, GlobalValue<'ctx>>,
    /// Maps lambda expr_id → emitted LLVM function (for closure creation)
    lambda_fns:     HashMap<usize, FunctionValue<'ctx>>,
    enum_registry:  EnumRegistry,
    type_map:       &'ctx HashMap<usize, Type>,
    /// Pre-computed: all names referenced in each lambda's body (not its own params).
    lambda_ref_names: HashMap<usize, Vec<String>>,
    /// Populated at emit time: actual captures per lambda (names + kinds from locals).
    lambda_actual_captures: RefCell<HashMap<usize, Vec<(String, LocalKind)>>>,
}

impl<'ctx> Cg<'ctx> {
    fn fmt_int_ptr(&self) -> Result<PointerValue<'ctx>, BuilderError> {
        let zero = self.context.i32_type().const_int(0, false);
        unsafe { self.builder.build_gep(self.fmt_ty, self.fmt_global.as_pointer_value(), &[zero, zero], "fmt_int_ptr") }
    }

    fn fmt_str_ptr(&self) -> Result<PointerValue<'ctx>, CodegenError> {
        let (g, ty) = self.fmt_str.as_ref().ok_or(CodegenError::UnsupportedStmt(0))?;
        let zero = self.context.i32_type().const_int(0, false);
        unsafe { self.builder.build_gep(*ty, g.as_pointer_value(), &[zero, zero], "fmt_str_ptr") }
            .map_err(CodegenError::Builder)
    }

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
        is_ptr_return: bool,
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
                    let kind = match arg_types.get(i) {
                        Some(Some(Type::Struct { name: sname, .. })) =>
                            LocalKind::StructPtr(sname.clone()),
                        Some(Some(Type::Primitive(PrimitiveType::String))) =>
                            LocalKind::Str,
                        Some(Some(Type::Slice(_))) =>
                            LocalKind::Slice,
                        Some(Some(Type::Func { .. })) =>
                            LocalKind::Closure,
                        _ => LocalKind::Str,
                    };
                    let slot = self.builder.build_alloca(self.ptr_ty, name)?;
                    self.builder.build_store(slot, pv)?;
                    Local { slot, kind }
                }
                _ => continue,
            };
            locals.insert(name.clone(), local);
        }

        self.emit_stmt(body_id, &mut locals)?;

        if !self.cur_block_terminated() {
            // Unit-returning functions have no explicit `return`. Emit a typed
            // null/zero fallback so LLVM IR is valid.
            if is_ptr_return {
                self.builder.build_return(Some(&self.ptr_ty.const_null()))?;
            } else {
                self.builder.build_return(Some(&self.i64_ty.const_int(0, false)))?;
            }
        }
        Ok(())
    }

    // ── Lambda body emission ──────────────────────────────────────────────────
    // Lambda LLVM signature: `i64 (ptr env, [param types...])`
    // LLVM param index 0 = env (unused for non-capturing lambdas).
    // LLVM param index 1..n = lambda params.

    fn emit_lambda_body(
        &self,
        fn_val: FunctionValue<'ctx>,
        lambda_id: usize,
        param_names: &[String],
        arg_types: &[Option<Type>],
        body_id: usize,
    ) -> Result<(), CodegenError> {
        let entry = self.context.append_basic_block(fn_val, "entry");
        self.builder.position_at_end(entry);

        let mut locals: Locals<'ctx> = HashMap::new();

        // LLVM param 0 = env ptr — load captured vars from it.
        let env_ptr = fn_val.get_nth_param(0)
            .map(|v| v.into_pointer_value())
            .unwrap_or_else(|| self.ptr_ty.const_null());

        let captures = self.lambda_actual_captures.borrow()
            .get(&lambda_id).cloned().unwrap_or_default();

        for (slot_idx, (cap_name, cap_kind)) in captures.iter().enumerate() {
            let slot_ptr = unsafe {
                self.builder.build_gep(
                    self.i64_ty, env_ptr,
                    &[self.i64_ty.const_int(slot_idx as u64, false)],
                    &format!("cap_slot{slot_idx}"),
                )?
            };
            let local = match cap_kind {
                LocalKind::Int => {
                    let val = self.builder.build_load(self.i64_ty, slot_ptr, cap_name)?.into_int_value();
                    let alloca = self.builder.build_alloca(self.i64_ty, cap_name)?;
                    self.builder.build_store(alloca, val)?;
                    Local { slot: alloca, kind: LocalKind::Int }
                }
                kind => {
                    let as_int = self.builder.build_load(self.i64_ty, slot_ptr, &format!("{cap_name}_int"))?.into_int_value();
                    let ptr_val = self.builder.build_int_to_ptr(as_int, self.ptr_ty, cap_name)?;
                    let alloca = self.builder.build_alloca(self.ptr_ty, cap_name)?;
                    self.builder.build_store(alloca, ptr_val)?;
                    Local { slot: alloca, kind: kind.clone() }
                }
            };
            locals.insert(cap_name.clone(), local);
        }

        // LLVM params 1..n = lambda params
        for (i, name) in param_names.iter().enumerate() {
            let llvm_idx = (i + 1) as u32; // skip env at index 0
            let param_val = match fn_val.get_nth_param(llvm_idx) {
                Some(v) => v,
                None => continue,
            };
            let local = match param_val {
                BasicValueEnum::IntValue(iv) => {
                    let slot = self.builder.build_alloca(self.i64_ty, name)?;
                    self.builder.build_store(slot, iv)?;
                    Local { slot, kind: LocalKind::Int }
                }
                BasicValueEnum::PointerValue(pv) => {
                    let kind = match arg_types.get(i) {
                        Some(Some(Type::Struct { name: sname, .. })) => LocalKind::StructPtr(sname.clone()),
                        Some(Some(Type::Primitive(PrimitiveType::String))) => LocalKind::Str,
                        Some(Some(Type::Slice(_))) => LocalKind::Slice,
                        Some(Some(Type::Func { .. })) => LocalKind::Closure,
                        _ => LocalKind::Str,
                    };
                    let slot = self.builder.build_alloca(self.ptr_ty, name)?;
                    self.builder.build_store(slot, pv)?;
                    Local { slot, kind }
                }
                _ => continue,
            };
            locals.insert(name.clone(), local);
        }

        self.emit_stmt(body_id, &mut locals)?;

        if !self.cur_block_terminated() {
            self.builder.build_return(Some(&self.i64_ty.const_int(0, false)))?;
        }
        Ok(())
    }

    // ── Indirect closure call ─────────────────────────────────────────────────
    // Extracts fn_ptr and env_ptr from the closure struct and calls indirectly.
    // The function type is built from the arg values: i64(ptr env, [arg types]).

    fn emit_closure_call(
        &self,
        closure_slot: PointerValue<'ctx>,
        args: &[usize],
        locals: &Locals<'ctx>,
        expr_id: usize,
    ) -> Result<BasicValueEnum<'ctx>, CodegenError> {
        let closure_ty = self.closure_ty.ok_or(CodegenError::UnsupportedExpr(expr_id))?;

        // Load the closure pointer from its alloca slot
        let closure_ptr = self.builder
            .build_load(self.ptr_ty, closure_slot, "closure")?
            .into_pointer_value();

        let i32_zero = self.context.i32_type().const_int(0, false);

        // Extract fn_ptr (field 0)
        let fn_ptr_field = unsafe {
            self.builder.build_gep(closure_ty, closure_ptr,
                &[i32_zero, self.context.i32_type().const_int(0, false)], "fn_ptr_field")?
        };
        let fn_ptr = self.builder.build_load(self.ptr_ty, fn_ptr_field, "fn_ptr")?
            .into_pointer_value();

        // Extract env_ptr (field 1)
        let env_ptr_field = unsafe {
            self.builder.build_gep(closure_ty, closure_ptr,
                &[i32_zero, self.context.i32_type().const_int(1, false)], "env_ptr_field")?
        };
        let env_ptr = self.builder.build_load(self.ptr_ty, env_ptr_field, "env_ptr")?
            .into_pointer_value();

        // Emit args
        let arg_vals: Vec<BasicValueEnum<'ctx>> = args.iter()
            .map(|&a| self.emit_expr(a, locals))
            .collect::<Result<_, _>>()?;

        // Build call arg list: env_ptr first, then the actual args
        let mut call_args: Vec<BasicMetadataValueEnum<'ctx>> = vec![
            BasicMetadataValueEnum::PointerValue(env_ptr),
        ];
        for v in &arg_vals {
            call_args.push(basic_to_meta(*v));
        }

        // Build the indirect function type: i64(ptr, [arg_types...])
        let mut param_types: Vec<BasicMetadataTypeEnum<'ctx>> = vec![
            BasicMetadataTypeEnum::PointerType(self.ptr_ty), // env
        ];
        for v in &arg_vals {
            param_types.push(match v {
                BasicValueEnum::PointerValue(_) => BasicMetadataTypeEnum::PointerType(self.ptr_ty),
                _ => BasicMetadataTypeEnum::IntType(self.i64_ty),
            });
        }
        let indirect_fn_ty = self.i64_ty.fn_type(&param_types, false);

        let call_site = self.builder
            .build_indirect_call(indirect_fn_ty, fn_ptr, &call_args, "closure_call")?;
        call_site.try_as_basic_value().basic()
            .ok_or(CodegenError::UnsupportedExpr(expr_id))
    }

    // ── Statement emission ────────────────────────────────────────────────────

    fn emit_stmt(&self, stmt_id: usize, locals: &mut Locals<'ctx>) -> Result<(), CodegenError> {
        let stmt = self.ast.get_stmt(stmt_id).ok_or(CodegenError::MissingNode(stmt_id))?;
        match stmt {
            // ── Print ─────────────────────────────────────────────────────────
            RuntimeStmt::Print(expr_id) => {
                let inner_id = unwrap_to_string(self.ast, *expr_id)?;
                match self.emit_expr(inner_id, locals)? {
                    BasicValueEnum::IntValue(iv) => {
                        let fmt_ptr = self.fmt_int_ptr()?;
                        self.builder.build_call(self.printf_fn, &[
                            BasicMetadataValueEnum::PointerValue(fmt_ptr),
                            BasicMetadataValueEnum::IntValue(iv),
                        ], "printf_ret")?;
                    }
                    BasicValueEnum::PointerValue(pv) => {
                        let fmt_ptr = self.fmt_str_ptr()?;
                        self.builder.build_call(self.printf_fn, &[
                            BasicMetadataValueEnum::PointerValue(fmt_ptr),
                            BasicMetadataValueEnum::PointerValue(pv),
                        ], "printf_ret")?;
                    }
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                }
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
                        let kind = match self.ast.get_expr(*expr) {
                            Some(RuntimeExpr::StructLiteral { type_name, .. }) =>
                                LocalKind::StructPtr(type_name.clone()),
                            Some(RuntimeExpr::String(_)) =>
                                LocalKind::Str,
                            Some(RuntimeExpr::List(_)) =>
                                LocalKind::Slice,
                            Some(RuntimeExpr::Lambda { .. }) =>
                                LocalKind::Closure,
                            Some(RuntimeExpr::EnumConstructor { .. }) =>
                                LocalKind::EnumPtr,
                            _ => match self.type_map.get(expr) {
                                Some(Type::Struct { name: sname, .. }) =>
                                    LocalKind::StructPtr(sname.clone()),
                                Some(Type::Primitive(PrimitiveType::String)) =>
                                    LocalKind::Str,
                                Some(Type::Slice(_)) =>
                                    LocalKind::Slice,
                                Some(Type::Func { .. }) =>
                                    LocalKind::Closure,
                                Some(Type::Enum(_)) =>
                                    LocalKind::EnumPtr,
                                _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                            }
                        };
                        let slot = self.builder.build_alloca(self.ptr_ty, name)?;
                        self.builder.build_store(slot, pv)?;
                        Local { slot, kind }
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
                    (LocalKind::StructPtr(_) | LocalKind::Str | LocalKind::Slice | LocalKind::Closure | LocalKind::EnumPtr, BasicValueEnum::PointerValue(pv)) => {
                        self.builder.build_store(slot, pv)?;
                    }
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                }
            }

            // ── Control flow ──────────────────────────────────────────────────
            RuntimeStmt::Return(opt_expr) => {
                if let Some(expr_id) = opt_expr {
                    match self.emit_expr(*expr_id, locals)? {
                        BasicValueEnum::IntValue(iv) => {
                            self.builder.build_return(Some(&iv))?;
                        }
                        BasicValueEnum::PointerValue(pv) => {
                            self.builder.build_return(Some(&pv))?;
                        }
                        _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                    }
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

            // ── ForEach loop ──────────────────────────────────────────────────
            RuntimeStmt::ForEach { var, iterable, body } => {
                let slice_ty = self.slice_ty.ok_or(CodegenError::UnsupportedStmt(stmt_id))?;

                // Load the slice pointer (it may be a local or a function arg)
                let slice_ptr = match self.emit_expr(*iterable, locals)? {
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                };

                let i32_zero = self.context.i32_type().const_int(0, false);

                // Load len from slice.field[0]
                let len_ptr = unsafe {
                    self.builder.build_gep(slice_ty, slice_ptr,
                        &[i32_zero, self.context.i32_type().const_int(0, false)], "len_ptr")?
                };
                let len = self.builder.build_load(self.i64_ty, len_ptr, "len")?.into_int_value();

                // Load data ptr from slice.field[2]
                let data_field_ptr = unsafe {
                    self.builder.build_gep(slice_ty, slice_ptr,
                        &[i32_zero, self.context.i32_type().const_int(2, false)], "data_field_ptr")?
                };
                let data_ptr = self.builder.build_load(self.ptr_ty, data_field_ptr, "data")?.into_pointer_value();

                // Induction variable
                let i_slot = self.builder.build_alloca(self.i64_ty, "__i")?;
                self.builder.build_store(i_slot, self.i64_ty.const_int(0, false))?;

                // Loop variable slot (always int for now)
                let var_slot = self.builder.build_alloca(self.i64_ty, var)?;
                locals.insert(var.clone(), Local { slot: var_slot, kind: LocalKind::Int });

                let cur_fn = self.builder.get_insert_block().unwrap().get_parent().unwrap();
                let cond_bb = self.context.append_basic_block(cur_fn, "foreach_cond");
                let body_bb = self.context.append_basic_block(cur_fn, "foreach_body");
                let exit_bb = self.context.append_basic_block(cur_fn, "foreach_exit");

                self.builder.build_unconditional_branch(cond_bb)?;

                // Condition: i < len
                self.builder.position_at_end(cond_bb);
                let i_val = self.builder.build_load(self.i64_ty, i_slot, "i")?.into_int_value();
                let cond_val = self.builder.build_int_compare(IntPredicate::SLT, i_val, len, "lt")?;
                self.builder.build_conditional_branch(cond_val, body_bb, exit_bb)?;

                // Body: GEP element, store to var slot, run body, increment i
                self.builder.position_at_end(body_bb);
                let i_val2 = self.builder.build_load(self.i64_ty, i_slot, "i")?.into_int_value();
                let elem_ptr = unsafe {
                    self.builder.build_gep(self.i64_ty, data_ptr, &[i_val2], "elem_ptr")?
                };
                let elem_val = self.builder.build_load(self.i64_ty, elem_ptr, var)?.into_int_value();
                self.builder.build_store(var_slot, elem_val)?;

                self.emit_stmt(*body, locals)?;

                if !self.cur_block_terminated() {
                    let i_val3 = self.builder.build_load(self.i64_ty, i_slot, "i")?.into_int_value();
                    let i_next = self.builder.build_int_add(i_val3, self.i64_ty.const_int(1, false), "i_next")?;
                    self.builder.build_store(i_slot, i_next)?;
                    self.builder.build_unconditional_branch(cond_bb)?;
                }

                self.builder.position_at_end(exit_bb);
                locals.remove(var.as_str());
            }

            // ── Match statement ───────────────────────────────────────────────
            RuntimeStmt::Match { scrutinee, arms } => {
                let enum_cell_ty = self.enum_cell_ty.ok_or(CodegenError::UnsupportedStmt(stmt_id))?;

                // Emit scrutinee — must be a pointer to %__enum_cell
                let enum_ptr = match self.emit_expr(*scrutinee, locals)? {
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err(CodegenError::UnsupportedStmt(stmt_id)),
                };

                let i32_zero = self.context.i32_type().const_int(0, false);

                // Load tag from field 0
                let tag_field_ptr = unsafe {
                    self.builder.build_gep(enum_cell_ty, enum_ptr,
                        &[i32_zero, i32_zero], "tag_ptr")?
                };
                let tag_val = self.builder.build_load(self.i64_ty, tag_field_ptr, "tag")?.into_int_value();

                let cur_fn = self.builder.get_insert_block().unwrap().get_parent().unwrap();
                let merge_bb = self.context.append_basic_block(cur_fn, "match_merge");

                // Collect arm data: (body_id, arm_bb, optional_binding)
                // and switch cases: (tag_const, arm_bb)
                let mut cases: Vec<(IntValue<'ctx>, BasicBlock<'ctx>)> = Vec::new();
                let mut arm_emit: Vec<(usize, BasicBlock<'ctx>, Option<String>)> = Vec::new();
                let mut wildcard_body: Option<usize> = None;

                for arm in arms.iter() {
                    match &arm.pattern {
                        Pattern::Wildcard => {
                            wildcard_body = Some(arm.body);
                        }
                        Pattern::Enum { enum_name, variant, bindings } => {
                            let tag = self.enum_registry.get(enum_name)
                                .and_then(|vs| vs.iter().find(|v| &v.name == variant))
                                .map(|v| v.tag as u64)
                                .unwrap_or(0);
                            let arm_bb = self.context.append_basic_block(cur_fn, &format!("arm_{variant}"));
                            let tag_const = self.i64_ty.const_int(tag, false);
                            let binding = match bindings {
                                VariantBindings::Tuple(names) if !names.is_empty() => Some(names[0].clone()),
                                _ => None,
                            };
                            cases.push((tag_const, arm_bb));
                            arm_emit.push((arm.body, arm_bb, binding));
                        }
                    }
                }

                let default_bb = self.context.append_basic_block(cur_fn, "arm_default");
                self.builder.build_switch(tag_val, default_bb, &cases)?;

                // Emit specific arm blocks
                for (body_id, arm_bb, binding) in arm_emit {
                    self.builder.position_at_end(arm_bb);
                    if let Some(var_name) = binding {
                        // Load payload from field 1
                        let payload_ptr = unsafe {
                            self.builder.build_gep(enum_cell_ty, enum_ptr,
                                &[i32_zero, self.context.i32_type().const_int(1, false)], "payload_ptr")?
                        };
                        let payload_val = self.builder.build_load(self.i64_ty, payload_ptr, &var_name)?.into_int_value();
                        let var_slot = self.builder.build_alloca(self.i64_ty, &var_name)?;
                        self.builder.build_store(var_slot, payload_val)?;
                        locals.insert(var_name.clone(), Local { slot: var_slot, kind: LocalKind::Int });
                    }
                    self.emit_stmt(body_id, locals)?;
                    if !self.cur_block_terminated() {
                        self.builder.build_unconditional_branch(merge_bb)?;
                    }
                }

                // Default / wildcard block
                self.builder.position_at_end(default_bb);
                if let Some(wildcard_id) = wildcard_body {
                    self.emit_stmt(wildcard_id, locals)?;
                }
                if !self.cur_block_terminated() {
                    self.builder.build_unconditional_branch(merge_bb)?;
                }

                self.builder.position_at_end(merge_bb);
            }

            // ── Expression statements ─────────────────────────────────────────
            RuntimeStmt::ExprStmt(expr_id) => {
                self.emit_expr(*expr_id, locals)?;
            }

            // ── Resume: call __k continuation closure with resumed value ──────
            RuntimeStmt::Resume(opt_expr) => {
                let closure_ty = self.closure_ty.ok_or(CodegenError::UnsupportedStmt(stmt_id))?;
                let k_slot = locals.get("__k")
                    .ok_or_else(|| CodegenError::UnboundVar("__k".to_string()))?.slot;

                let resume_val = if let Some(expr_id) = opt_expr {
                    self.emit_int_expr(*expr_id, locals)?
                } else {
                    self.i64_ty.const_int(0, false)
                };

                let closure_ptr = self.builder
                    .build_load(self.ptr_ty, k_slot, "k_closure")?.into_pointer_value();
                let i32_zero = self.context.i32_type().const_int(0, false);
                let fn_ptr_field = unsafe {
                    self.builder.build_gep(closure_ty, closure_ptr,
                        &[i32_zero, self.context.i32_type().const_int(0, false)], "fn_ptr_field")?
                };
                let fn_ptr = self.builder.build_load(self.ptr_ty, fn_ptr_field, "fn_ptr")?
                    .into_pointer_value();
                let env_ptr_field = unsafe {
                    self.builder.build_gep(closure_ty, closure_ptr,
                        &[i32_zero, self.context.i32_type().const_int(1, false)], "env_ptr_field")?
                };
                let env_ptr = self.builder.build_load(self.ptr_ty, env_ptr_field, "env_ptr")?
                    .into_pointer_value();

                let indirect_fn_ty = self.i64_ty.fn_type(&[
                    BasicMetadataTypeEnum::PointerType(self.ptr_ty),
                    BasicMetadataTypeEnum::IntType(self.i64_ty),
                ], false);
                self.builder.build_indirect_call(
                    indirect_fn_ty, fn_ptr,
                    &[
                        BasicMetadataValueEnum::PointerValue(env_ptr),
                        BasicMetadataValueEnum::IntValue(resume_val),
                    ],
                    "resume_call",
                )?;
            }

            // ── Declarations (handled in other passes) ────────────────────────
            RuntimeStmt::FnDecl { .. }
            | RuntimeStmt::StructDecl { .. }
            | RuntimeStmt::EnumDecl { .. }
            | RuntimeStmt::WithFn { .. }
            | RuntimeStmt::EffectDecl { .. }
            | RuntimeStmt::WithCtl { .. }
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
            RuntimeExpr::Unit =>
                Ok(self.i64_ty.const_int(0, false).as_basic_value_enum()),

            RuntimeExpr::Int(n) =>
                Ok(self.i64_ty.const_int(*n as u64, true).as_basic_value_enum()),

            // ── Variable load ─────────────────────────────────────────────────
            RuntimeExpr::Variable(name) => {
                let local = locals.get(name)
                    .ok_or_else(|| CodegenError::UnboundVar(name.clone()))?;
                match &local.kind {
                    LocalKind::Int =>
                        Ok(self.builder.build_load(self.i64_ty, local.slot, name)?),
                    LocalKind::StructPtr(_) | LocalKind::Str | LocalKind::Slice | LocalKind::Closure | LocalKind::EnumPtr =>
                        Ok(self.builder.build_load(self.ptr_ty, local.slot, name)?),
                }
            }

            // ── String literal ────────────────────────────────────────────────
            RuntimeExpr::String(s) => {
                let global = self.string_globals.get(s.as_str())
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                Ok(global.as_pointer_value().as_basic_value_enum())
            }

            // ── List literal → malloc data array + malloc slice struct ────────
            RuntimeExpr::List(items) => {
                let malloc_fn  = self.malloc_fn.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let slice_ty   = self.slice_ty.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let n          = items.len() as u64;
                let i32_zero   = self.context.i32_type().const_int(0, false);

                // Allocate data array: malloc(n * 8)
                let data_size = self.i64_ty.const_int(n * 8, false);
                let data_ptr = self.builder
                    .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(data_size)], "data_malloc")?
                    .try_as_basic_value().basic()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                    .into_pointer_value();

                // Store each element
                for (idx, &item_id) in items.iter().enumerate() {
                    let elem_val = self.emit_int_expr(item_id, locals)?;
                    let elem_ptr = unsafe {
                        self.builder.build_gep(
                            self.i64_ty, data_ptr,
                            &[self.i64_ty.const_int(idx as u64, false)],
                            &format!("elem{idx}_ptr"),
                        )?
                    };
                    self.builder.build_store(elem_ptr, elem_val)?;
                }

                // Allocate slice struct: malloc(sizeof %__slice)
                let slice_size = slice_ty.size_of()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let slice_ptr = self.builder
                    .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(slice_size)], "slice_malloc")?
                    .try_as_basic_value().basic()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                    .into_pointer_value();

                // Store len (field 0)
                let len_ptr = unsafe {
                    self.builder.build_gep(slice_ty, slice_ptr,
                        &[i32_zero, self.context.i32_type().const_int(0, false)], "len_ptr")?
                };
                self.builder.build_store(len_ptr, self.i64_ty.const_int(n, false))?;

                // Store cap (field 1)
                let cap_ptr = unsafe {
                    self.builder.build_gep(slice_ty, slice_ptr,
                        &[i32_zero, self.context.i32_type().const_int(1, false)], "cap_ptr")?
                };
                self.builder.build_store(cap_ptr, self.i64_ty.const_int(n, false))?;

                // Store data ptr (field 2)
                let data_field_ptr = unsafe {
                    self.builder.build_gep(slice_ty, slice_ptr,
                        &[i32_zero, self.context.i32_type().const_int(2, false)], "data_field_ptr")?
                };
                self.builder.build_store(data_field_ptr, data_ptr)?;

                Ok(slice_ptr.as_basic_value_enum())
            }

            // ── Lambda → closure struct { fn_ptr, env_ptr } ──────────────────
            RuntimeExpr::Lambda { params, .. } => {
                let malloc_fn  = self.malloc_fn.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let closure_ty = self.closure_ty.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let lam_val    = *self.lambda_fns.get(&expr_id)
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;

                // ── Closure capture ───────────────────────────────────────────
                // Find free variables: names referenced in the body that are
                // in `locals` but not in the lambda's own param list.
                let param_set: BTreeSet<&str> = params.iter().map(|s| s.as_str()).collect();
                let captures: Vec<(String, LocalKind)> = self.lambda_ref_names
                    .get(&expr_id)
                    .map(|refs| {
                        refs.iter()
                            .filter(|name| !param_set.contains(name.as_str()))
                            .filter_map(|name| locals.get(name).map(|l| (name.clone(), l.kind.clone())))
                            .collect()
                    })
                    .unwrap_or_default();

                // ── Allocate env if there are captures ────────────────────────
                let env_ptr = if captures.is_empty() {
                    self.ptr_ty.const_null()
                } else {
                    // Env layout: flat array of 8-byte slots (i64 for ints, ptrtoint for ptrs).
                    let env_size = self.i64_ty.const_int((captures.len() as u64) * 8, false);
                    let env_raw = self.builder
                        .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(env_size)], "env_malloc")?
                        .try_as_basic_value().basic()
                        .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                        .into_pointer_value();
                    for (slot_idx, (cap_name, cap_kind)) in captures.iter().enumerate() {
                        let local = locals.get(cap_name).ok_or_else(|| CodegenError::UnboundVar(cap_name.clone()))?;
                        let slot_ptr = unsafe {
                            self.builder.build_gep(
                                self.i64_ty, env_raw,
                                &[self.i64_ty.const_int(slot_idx as u64, false)],
                                &format!("env_slot{slot_idx}"),
                            )?
                        };
                        match cap_kind {
                            LocalKind::Int => {
                                let val = self.builder.build_load(self.i64_ty, local.slot, cap_name)?.into_int_value();
                                self.builder.build_store(slot_ptr, val)?;
                            }
                            _ => {
                                let ptr_val = self.builder.build_load(self.ptr_ty, local.slot, cap_name)?.into_pointer_value();
                                let as_int = self.builder.build_ptr_to_int(ptr_val, self.i64_ty, &format!("{cap_name}_as_int"))?;
                                self.builder.build_store(slot_ptr, as_int)?;
                            }
                        }
                    }
                    env_raw
                };

                // Record captures so emit_lambda_body can load them from env_ptr.
                self.lambda_actual_captures.borrow_mut().insert(expr_id, captures);

                // ── Allocate closure struct ───────────────────────────────────
                let closure_size = closure_ty.size_of()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let closure_ptr = self.builder
                    .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(closure_size)], "closure_malloc")?
                    .try_as_basic_value().basic()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                    .into_pointer_value();

                let i32_zero = self.context.i32_type().const_int(0, false);

                let fn_ptr_field = unsafe {
                    self.builder.build_gep(closure_ty, closure_ptr,
                        &[i32_zero, self.context.i32_type().const_int(0, false)], "fn_ptr_field")?
                };
                let fn_as_ptr = lam_val.as_global_value().as_pointer_value();
                self.builder.build_store(fn_ptr_field, fn_as_ptr)?;

                let env_ptr_field = unsafe {
                    self.builder.build_gep(closure_ty, closure_ptr,
                        &[i32_zero, self.context.i32_type().const_int(1, false)], "env_ptr_field")?
                };
                self.builder.build_store(env_ptr_field, env_ptr)?;

                Ok(closure_ptr.as_basic_value_enum())
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

            // ── Enum constructor → malloc %__enum_cell { tag, payload } ──────
            RuntimeExpr::EnumConstructor { enum_name, variant, payload } => {
                let malloc_fn    = self.malloc_fn.ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let enum_cell_ty = self.enum_cell_ty.ok_or(CodegenError::UnsupportedExpr(expr_id))?;

                let tag = self.enum_registry.get(enum_name)
                    .and_then(|vs| vs.iter().find(|v| &v.name == variant))
                    .map(|v| v.tag as u64)
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?;

                let cell_size = enum_cell_ty.size_of().ok_or(CodegenError::UnsupportedExpr(expr_id))?;
                let cell_ptr = self.builder
                    .build_call(malloc_fn, &[BasicMetadataValueEnum::IntValue(cell_size)], "enum_malloc")?
                    .try_as_basic_value().basic()
                    .ok_or(CodegenError::UnsupportedExpr(expr_id))?
                    .into_pointer_value();

                let i32_zero = self.context.i32_type().const_int(0, false);

                // Store tag at field 0
                let tag_ptr = unsafe {
                    self.builder.build_gep(enum_cell_ty, cell_ptr,
                        &[i32_zero, i32_zero], "tag_ptr")?
                };
                self.builder.build_store(tag_ptr, self.i64_ty.const_int(tag, false))?;

                // Store payload at field 1 (i64; 0 for unit)
                let payload_val = match payload {
                    ConstructorPayload::Tuple(exprs) if !exprs.is_empty() =>
                        self.emit_int_expr(exprs[0], locals)?,
                    _ => self.i64_ty.const_int(0, false),
                };
                let payload_ptr = unsafe {
                    self.builder.build_gep(enum_cell_ty, cell_ptr,
                        &[i32_zero, self.context.i32_type().const_int(1, false)], "payload_ptr")?
                };
                self.builder.build_store(payload_ptr, payload_val)?;

                Ok(cell_ptr.as_basic_value_enum())
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
                // closure call: callee is a local of kind Closure
                if let Some(local) = locals.get(callee.as_str()) {
                    if matches!(local.kind, LocalKind::Closure) {
                        return self.emit_closure_call(local.slot, args, locals, expr_id);
                    }
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

// ── Free-variable analysis ────────────────────────────────────────────────────
//
// For each lambda, we collect all names that appear as:
//   - RuntimeExpr::Variable(name)
//   - RuntimeExpr::Call { callee, .. } where callee might be a local closure
// that are NOT bound by the lambda's own param list (inner lambdas' params also
// shadow names for their sub-bodies).
//
// At lambda-creation time we intersect with `locals` to get the actual captures.

fn collect_lambda_refs(ast: &RuntimeAst, lambda_id: usize) -> Vec<String> {
    let (params, body) = match ast.get_expr(lambda_id) {
        Some(RuntimeExpr::Lambda { params, body }) => (params.clone(), *body),
        _ => return vec![],
    };
    let bound: BTreeSet<String> = params.into_iter().collect();
    let mut refs: BTreeSet<String> = BTreeSet::new();
    collect_refs_stmt(ast, body, &bound, &mut refs);
    refs.into_iter().collect()
}

fn collect_refs_stmt(
    ast: &RuntimeAst,
    stmt_id: usize,
    bound: &BTreeSet<String>,
    refs: &mut BTreeSet<String>,
) {
    match ast.get_stmt(stmt_id) {
        Some(RuntimeStmt::Block(stmts)) => {
            let stmts = stmts.clone();
            for id in stmts { collect_refs_stmt(ast, id, bound, refs); }
        }
        Some(RuntimeStmt::VarDecl { expr, .. }) | Some(RuntimeStmt::ExprStmt(expr)) => {
            collect_refs_expr(ast, *expr, bound, refs);
        }
        Some(RuntimeStmt::Print(expr)) => collect_refs_expr(ast, *expr, bound, refs),
        Some(RuntimeStmt::Return(Some(expr))) => collect_refs_expr(ast, *expr, bound, refs),
        Some(RuntimeStmt::If { cond, body, else_branch }) => {
            collect_refs_expr(ast, *cond, bound, refs);
            collect_refs_stmt(ast, *body, bound, refs);
            if let Some(e) = *else_branch { collect_refs_stmt(ast, e, bound, refs); }
        }
        Some(RuntimeStmt::WhileLoop { cond, body }) => {
            collect_refs_expr(ast, *cond, bound, refs);
            collect_refs_stmt(ast, *body, bound, refs);
        }
        _ => {}
    }
}

fn collect_refs_expr(
    ast: &RuntimeAst,
    expr_id: usize,
    bound: &BTreeSet<String>,
    refs: &mut BTreeSet<String>,
) {
    match ast.get_expr(expr_id) {
        Some(RuntimeExpr::Variable(name)) => {
            if !bound.contains(name) { refs.insert(name.clone()); }
        }
        Some(RuntimeExpr::Call { callee, args }) => {
            // Include callee — may be a local closure (e.g. `__k`)
            if !bound.contains(callee) { refs.insert(callee.clone()); }
            let args = args.clone();
            for arg in args { collect_refs_expr(ast, arg, bound, refs); }
        }
        Some(RuntimeExpr::Lambda { params, body }) => {
            // Inner lambda: its own params are bound inside its body.
            let mut inner_bound = bound.clone();
            inner_bound.extend(params.iter().cloned());
            collect_refs_stmt(ast, *body, &inner_bound, refs);
        }
        Some(
            RuntimeExpr::Add(a, b) | RuntimeExpr::Sub(a, b)
            | RuntimeExpr::Mult(a, b) | RuntimeExpr::Div(a, b)
            | RuntimeExpr::Equals(a, b) | RuntimeExpr::NotEquals(a, b)
            | RuntimeExpr::Lt(a, b) | RuntimeExpr::Gt(a, b)
            | RuntimeExpr::Lte(a, b) | RuntimeExpr::Gte(a, b)
            | RuntimeExpr::And(a, b) | RuntimeExpr::Or(a, b),
        ) => {
            collect_refs_expr(ast, *a, bound, refs);
            collect_refs_expr(ast, *b, bound, refs);
        }
        Some(RuntimeExpr::Not(a)) => collect_refs_expr(ast, *a, bound, refs),
        _ => {}
    }
}

/// Map a `with fn` param type annotation string to an LLVM metadata type.
fn param_llvm_type<'ctx>(
    ty_str: Option<&str>,
    i64_ty: IntType<'ctx>,
    ptr_ty: PointerType<'ctx>,
) -> BasicMetadataTypeEnum<'ctx> {
    match ty_str {
        Some("string") | Some("fn") => BasicMetadataTypeEnum::PointerType(ptr_ty),
        Some(s) if s.starts_with('[') => BasicMetadataTypeEnum::PointerType(ptr_ty),
        _ => BasicMetadataTypeEnum::IntType(i64_ty),
    }
}

/// Map a `with fn` param type annotation string to a `Type` for LocalKind resolution.
fn param_type_from_annot(ty_str: Option<&str>) -> Option<Type> {
    match ty_str {
        Some("string") => Some(Type::Primitive(PrimitiveType::String)),
        Some("int") | Some("bool") => Some(Type::Primitive(PrimitiveType::Int)),
        Some(s) if s.starts_with('[') =>
            Some(Type::Slice(Box::new(Type::Primitive(PrimitiveType::Int)))),
        Some("fn") => Some(Type::Func {
            params: vec![],
            ret: Box::new(Type::Primitive(PrimitiveType::Int)),
            effects: crate::semantics::types::types::EffectRow::empty(),
        }),
        _ => None,
    }
}

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
