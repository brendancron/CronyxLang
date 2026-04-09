# Path to LLVM Compilation

This document describes the technical path from the current tree-walking interpreter to an LLVM compilation backend. Each phase is a self-contained prerequisite for the next. The interpreter is never broken — the LLVM backend is a parallel output path from the same runtime AST.

---

## Overview

The pipeline gains a new backend after the existing stages:

```
Lexer → Parser → Type Checker (Phase 1) → Metaprocessor → Type Checker (Phase 2) → [existing]
                                                                                         ↓
                                                                              LLVM Codegen
```

The interpreter continues to use the runtime AST directly, unchanged. The LLVM path branches after Phase 2 type checking.

---

## Phase 1 — Complete the Type Representation ✓

**Status: Done.**

`Tuple(Vec<Type>)` and `Slice(Box<Type>)` have been added to `Type`. Unification (`unify`), substitution (`ApplySubst`), free variable computation (`FreeTypeVars`), name mangling (`mangle_type`), and `Display` are all updated. The `TypeTable` — a `HashMap<usize, Type>` keyed by expression ID — is produced by Phase 2 type checking and covers all expression nodes including those introduced by monomorphization.

```rust
pub enum Type {
    Primitive(PrimitiveType),  // int, bool, string, unit
    Var(TypeVar),
    Func { params: Vec<Type>, ret: Box<Type> },
    Record(BTreeMap<String, Type>),
    Tuple(Vec<Type>),
    Slice(Box<Type>),
    Enum(String),
}
```

---

## Phase 2 — Solidify Before Codegen

These are the remaining gaps between the current type system and what LLVM codegen actually needs. None of them require designing the codegen — they are type-layer prerequisites.

### 2a. TypeVar Verification Pass

**What:** After Phase 2 type checking, walk the entire `TypeTable` and assert that no `Type::Var` remains. Any lingering type variable at this point is a compiler bug, not a user error.

**Why:** The LLVM backend cannot lower `Type::Var` to an LLVM type. Catching it here gives a clear internal error rather than a panic deep in codegen.

**Where:** A short post-pass in `runtime_type_checker.rs` or as a standalone verification step in the pipeline entry point.

---

### 2b. Enum Variant Registry

**What:** `Type::Enum(String)` only carries the enum name. The LLVM backend needs to know, for each enum name, the ordered list of variants, their tag integers, and the type of each payload field.

**Why:** To lower a `Shape::Circle(r)` to LLVM IR, codegen needs to know `Circle` is tag `0`, its payload is a single `i64`, and the total struct is `{ i32, i64 }`. None of that is in `Type::Enum("Shape")`.

**What to build:** A `EnumRegistry` (a `HashMap<String, Vec<EnumVariant>>`) built during Phase 2 from `RuntimeStmt::EnumDecl` nodes. `EnumVariant` already carries `VariantPayload` — the registry just makes this accessible to the codegen pass without re-scanning the AST.

`VariantPayload` currently stores field types as strings (the raw source type names). Before codegen those need to be resolved to `Type` values, either during registry construction or as a separate resolve step.

---

### 2c. Named Struct Types

**What:** `Type::Record(BTreeMap<String, Type>)` is anonymous — it describes the field layout but not the struct name. The TypeTable today records a `StructLiteral` expression as `Type::Record(...)`, losing the name.

**Why:** The LLVM backend needs the struct name to deduplicate type definitions and emit named LLVM struct types (e.g., `%Point = type { i64, i64 }`). Two different structs with the same field layout are still different types.

**Options:**
- Add `Type::Struct { name: String, fields: BTreeMap<String, Type> }` as a distinct variant
- Or keep `Record` anonymous and add a separate `StructRegistry` mapping names to layouts, with the TypeTable for struct-literal expressions pointing at the named type rather than an anonymous record

The second option is less invasive. Either way, the TypeTable entry for a `StructLiteral` expression must carry the struct name through to codegen.

---

### 2d. String Slice Syntax

**What:** `SliceRange` currently only works on `Slice` types in both the type checker and the interpreter. String range-slicing (`s[1:]`, `s[-1]`) is handled for single-index access but not for range syntax.

**Why:** This is a minor language completeness gap. If strings support negative indexing, they should support range slicing for consistency. And once LLVM codegen needs to lower `SliceRange`, it needs to know the result type — for a `String` object that's `String`, for a `Slice(T)` it's `Slice(T)`.

**Where:** Add a `String` arm to `SliceRange` evaluation in both type checkers and the interpreter. The result type is `Primitive(String)`.

---

### 2e. ForEach Variable Type

**What:** The `ForEach` loop variable (e.g., `x` in `for (x in nums)`) needs its type recorded in the TypeTable. The iterable's type is `Slice(T)` — the loop variable's type is `T`.

**Why:** In the interpreter, `x` gets its type dynamically from the `Value` it's bound to. In LLVM, the alloca for `x` needs a concrete type upfront. The loop variable binding is currently not an expression node and has no TypeTable entry.

**Where:** During Phase 2 type checking of `RuntimeStmt::ForEach`, after inferring the iterable type as `Slice(T)`, record `T` in the TypeTable keyed by a stable ID associated with the `ForEach` node. One approach: add a synthetic expression ID for the loop variable in the runtime AST.

---

## Phase 3 — LLVM Codegen

**Goal:** Walk the runtime AST, guided by the fully-resolved `TypeTable` and supporting registries, and emit LLVM IR.

**Type lowering — Cronyx types to LLVM types:**

| Cronyx type | LLVM type |
|---|---|
| `int` | `i64` |
| `bool` | `i1` |
| `unit` | void / omitted |
| `string` | `{ ptr, i64 }` (data + length) |
| `[int]` | `{ ptr, i64, i64 }` (data, length, capacity) |
| `(int, string)` | `{ i64, { ptr, i64 } }` (flattened tuple fields) |
| `Point { x: int, y: int }` | `%Point = type { i64, i64 }` |
| `Shape::Circle(int)` | `{ i32, i64 }` (tag + payload union) |

**Codegen pass:**

A `CodegenVisitor` walks the runtime AST. For each node it looks up the expression ID in the `TypeTable`, lowers the `Type` to an LLVM type, and emits IR.

- `VarDecl` → `alloca` + `store`
- `Assign` → `store` into existing alloca
- `Call` → `call` with typed arguments; monomorphization ensures no generic call sites remain
- `If` / `While` / `ForEach` → basic block structure with branches
- `Match` → switch on enum tag field, one basic block per arm
- `FnDecl` → LLVM function definition with typed parameters
- `Return` → `ret` of the appropriate type
- `SliceRange` → call into runtime support (slice + bounds calculation)

**Runtime support library:**

A thin Rust or C static library provides:

- String: allocation, concatenation, split, trim, contains, indexing, slice range
- Slice: allocation, push, pop, contains, indexing, slice range, bounds checking
- `to_string`, `to_int`, `readfile`, `print`

The codegen emits `call` instructions to these. They are linked at compile time.

**Toolchain:** `inkwell` crate (safe Rust bindings to the LLVM C API). Target LLVM 17+. Emit `.o` object files, link with `lld` or the system linker.

---

## Sequencing Summary

| Phase | Status | Output |
|---|---|---|
| 1. Complete type representation | Done | `Tuple` and `Slice` in `Type`; `TypeTable` produced by Phase 2 |
| 2a. TypeVar verification pass | Pending | Hard guarantee that no `Type::Var` reaches codegen |
| 2b. Enum variant registry | Pending | Tag integers + payload types accessible to codegen |
| 2c. Named struct types | Pending | Struct name preserved in `TypeTable` |
| 2d. String slice syntax | Pending | `SliceRange` on `String` typed and evaluated |
| 2e. ForEach variable type | Pending | Loop variable has a `TypeTable` entry |
| 3. LLVM codegen | Pending | Native binary via LLVM IR + runtime support library |

Phases 2a–2e are independent and can be done in any order. Phase 3 depends on all of them.

---

## Future: Allocator Injection

Once the compiled backend is working, the malloc approach can be replaced with implicit allocator injection:

- **Effect inference** — the type checker infers which functions allocate, propagating the `allocates` effect from callees to callers automatically
- **Meta injection** — a meta pass rewrites allocating function signatures to carry an implicit `__allocator` parameter, threading it through call sites invisibly
- **Programmer experience** — the entry point binds `__allocator` to `SystemAllocator` by default; callers can pass an `ArenaAllocator` or custom implementation at any call site

This design is fully compatible with the current pipeline — effect inference slots between Phase 2 type checking and codegen, and the injection runs as a meta pass. It is deferred because it is a significant undertaking in its own right.
