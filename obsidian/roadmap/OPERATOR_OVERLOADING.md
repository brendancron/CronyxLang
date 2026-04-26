# Operator Overloading — Implementation Roadmap

**Status:** Not started  
**Last Updated:** 2026-04-21  
**Owner:** Brendan  

---

## Goals

- Operators like `+` are generic in the MetaAST but fully resolved in the RuntimeAST — no generic operators survive to eval
- Runtime efficiency is preserved for built-in types without hardcoding operator semantics in the compiler
- Operator overloads for all types (including `int`, `string`) live in the **standard library**, not the compiler
- Users define operator overloads for custom types the same way the stdlib does — no special compiler privileges
- The design works across all backends (interpreter, LLVM, WASM, etc.) without changing the stdlib

---

## Architecture: The `Builtin` Module

At some level, something has to actually add two integers. This unavoidable language/platform boundary is exposed through a compiler-provided `Builtin` module — a small, stable set of named operations the compiler knows how to lower per backend. The stdlib calls `Builtin`; users generally don't.

```
// Compiler-provided. Not user-writable.
module Builtin {
    fn int_add(a: int, b: int): int
    fn int_sub(a: int, b: int): int
    fn int_mul(a: int, b: int): int
    fn int_div(a: int, b: int): int
    fn int_eq(a: int, b: int): bool
    fn int_lt(a: int, b: int): bool
    fn int_gt(a: int, b: int): bool
    fn bool_and(a: bool, b: bool): bool
    fn bool_or(a: bool, b: bool): bool
    fn bool_not(a: bool): bool
    fn str_concat(a: string, b: string): string
    fn str_eq(a: string, b: string): bool
    fn write_stdout(s: string)
    ...
}
```

Each backend provides the lowering for these names:

| Builtin         | Interpreter     | LLVM             | WASM        |
|-----------------|-----------------|------------------|-------------|
| `int_add`       | Rust `a + b`    | `add i64 %a, %b` | `i64.add`   |
| `str_concat`    | Rust string ops | call runtime fn  | call rt fn  |
| `write_stdout`  | Rust `print!`   | call `printf`    | call host   |

The stdlib never changes when a new backend is added. Backends never touch the stdlib.

### The stdlib uses `Builtin` to define operators

```
impl Add for int {
    fn add(a: int, b: int): int {
        return Builtin.int_add(a, b);
    }
}

impl Add for string {
    fn add(a: string, b: string): string {
        return Builtin.str_concat(a, b);
    }
}
```

### User types use regular functions

```
impl Add for Vec2 {
    fn add(a: Vec2, b: Vec2): Vec2 {
        return Vec2 { x: a.x + b.x, y: a.y + b.y };
    }
}
```

`Vec2 + Vec2` calls `Vec2.add`, which calls `int_add` via `Builtin`. All the way down, it is function calls — just some functions are provided by the backend rather than written in Cronyx.

---

## What Is Temporary vs Permanent

**Temporary (will be removed):**
- `RuntimeExpr::Add`, `Sub`, `Mult`, `Div` etc. as dedicated AST nodes
- `RuntimeStmt::Print` as a dedicated AST node — becomes a stdlib function calling `Builtin.write_stdout`
- Any other operations with special AST treatment instead of going through the call path

**Permanent:**
- The `Builtin` module itself — the interface is stable, only the implementation changes per backend
- The set of `Builtin` names should be minimal and grow rarely; adding a new builtin requires touching every backend

The goal is to push the language/platform boundary as deep as possible. `print` stops being a compiler keyword and becomes a stdlib function. Arithmetic stops being a special AST node and becomes a desugared function call. Only the final, unavoidable operations remain in `Builtin`.

---

## Operator Resolution: Where It Happens

The staged forest processes trees in topological order (dependencies first). Before any tree is processed, all its dependencies have already been fully type-checked (Phase-2) and evaluated. Types are complete and concrete for each subtree when it is processed.

The processing loop for each subtree:

```
staged_ast
  → convert_to_runtime       (MetaAST → RuntimeAST lowering)
  → Phase-2 typecheck        (types fully known for this subtree)
  → operator desugar         ← dispatch table lookup, rewrite to Call nodes
  → evaluate (non-root) / monomorphize+compact (root)
```

Since the forest is processed in dependency order, by the time user code containing `a + b` is lowered, the stdlib (which defines the `Add` impls) has already been evaluated and its dispatch entries are registered.

### What the desugar pass does

```
MetaExpr::Add(a, b)  →  type lookup  →

  int + int     →  Call("__op_add_int_int", [a, b])
                     which calls Builtin.int_add
                     which the backend lowers to add i64

  string + str  →  Call("__op_add_str_str", [a, b])
                     which calls Builtin.str_concat

  Vec2 + Vec2   →  Call("__op_add_Vec2_Vec2", [a, b])
                     which calls int_add on components
```

After desugaring, no generic operator nodes exist in the RuntimeAST. The interpreter and LLVM backend only ever see `Call` nodes.

---

## Dispatch Table

Operator impls register entries as they are evaluated during metaprocessing:

```
(Op, LhsType, RhsType) → FunctionName
---
(Add, int,    int)    → "__op_add_int_int"
(Add, string, string) → "__op_add_str_str"
(Add, Vec2,   Vec2)   → "__op_add_Vec2_Vec2"
```

If no entry is found at desugar time: compile error — "no operator `+` defined for `Vec2` and `int`".

---

## Implementation Plan

### Phase 1 — `Builtin` module and interpreter backend

- [ ] Define `Builtin` module as a compiler-provided auto-import (not a `.cx` file)
- [ ] Pre-bind `Builtin.*` functions in the interpreter at startup (alongside `print` today)
- [ ] Add `Builtin` to the type environment so the type checker accepts calls to it
- [ ] Migrate `print(x)` from `RuntimeStmt::Print` to a stdlib function calling `Builtin.write_stdout`
- [ ] Add `--dump-builtins` or document the `Builtin` API surface

### Phase 2 — Operator dispatch mechanism

- [ ] Build dispatch table infrastructure `(Op, LhsType, RhsType) → FunctionName`
- [ ] Implement `operator_desugar` pass: rewrite `MetaExpr::Add` etc. to `Call` nodes using Phase-2 type info
- [ ] Wire desugar step into metaprocessing loop after Phase-2 type check per subtree
- [ ] Error on missing dispatch entry with a clear message

### Phase 3 — Standard library operator impls

- [ ] Create stdlib module with `impl Add/Sub/Mul/Div/Eq/Ord for int` using `Builtin.*`
- [ ] `impl Add/Eq for string` etc.
- [ ] Verify the full chain: `1 + 2` → dispatch → `Call("__op_add_int_int")` → `Builtin.int_add` → Rust `+`
- [ ] Remove `RuntimeExpr::Add` etc. from the AST once all arithmetic goes through this path

### Phase 4 — User-defined operator overloads

- [ ] Parser: `impl Op for Type { fn op_name(...) }` syntax
- [ ] Stager: emit overload as `FnDecl` with mangled name, register in dispatch table
- [ ] Error on duplicate overloads for the same type pair

### Phase 5 — LLVM backend

- [ ] Add LLVM lowering table: `Builtin.int_add` → `LLVMBuildAdd`, etc.
- [ ] Stdlib and operator dispatch unchanged — only the backend changes
- [ ] `Builtin.write_stdout` → `printf` / `write(2)`

### Phase 6 — Cleanup

- [ ] Remove all remaining special AST nodes for operations that now go through `Builtin`
- [ ] Confirm no generic operator nodes or special statement types reach eval

---

## Open Questions

| Question | Notes |
|---|---|
| `impl` syntax | `impl Add for Vec2 { }` or `operator +(a: Vec2, b: Vec2)` |
| Can users call `Builtin.*` directly? | Probably yes for unsafe/low-level code, but not idiomatic |
| Unary operators (`-x`, `!x`) | Same mechanism, unary dispatch table |
| Comparison / ordering | `Eq` and `Ord` traits, same approach |
| Error messages | Desugared call should preserve source span of the original operator |
| Operator precedence | Already handled by parser — no change needed |
| Monomorphization | Unbound type vars resolved same way as generics — no special case |
