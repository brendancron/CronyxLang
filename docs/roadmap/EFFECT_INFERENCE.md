# Effect Inference — Chunk 1 & 2 Design

**Status:** Chunk 1 in progress  
**Date:** 2026-04-21

---

## Overview

Cronyx uses algebraic effects with selective CPS. The effect system has two jobs:

1. **Inference** — figure out which `ctl` ops each function transitively performs, and surface that as an `EffectRow` in function types (so `typeof(range)` prints `(int, int) -> unit <yield>`).
2. **Checking** — reject programs that call ctl ops (directly or through functions) without an active handler.

Both are inferred; no annotations are required. Annotations, when added later, will be checked as constraints against the inferred row.

---

## Chunk 1 — Monomorphic Inference + Call-site Checking

### Design Decisions

- **Effect granularity:** op names (e.g., `"yield"`, `"flip"`), not effect group names (`"Yield"`, `"Flip"`). Matches existing `CpsInfo.ctl_ops`.
- **Annotation strategy:** fully inferred; annotations are future Chunk 2+ work.
- **Unhandled effects:** hard compile error (`CompilerError::EffectNotHandled`).
- **Checked scope:** only top-level execution paths; function bodies propagate effects upward via their inferred effect row.
- **`fn` effects excluded:** only `ctl` ops appear in effect rows. `fn`-style handlers are resolved statically by name and don't need CPS.

### Phase A — Effect Row Inference (two passes)

**Pass A1 (MetaAst, before staging):**  
Runs on the MetaAst to update `TypeEnv` with effect rows before `stage_all_files` runs. This is required so `typeof(range)` resolves to the correct type string during staging.

Algorithm:
1. Collect ctl op names from all `MetaStmt::EffectDecl` nodes.
2. For each `MetaStmt::FnDecl`, walk its body and collect direct ctl op calls.
3. Fixed-point iterate: propagate effects through function calls (if `A` calls `B` and `B` has row `R`, add `R` to `A`'s row).
4. For each function whose inferred row is non-empty, update `TypeEnv` by replacing the `effects` field of its `Type::Func` with the inferred `EffectRow`.

**Pass A2 (RuntimeAst, after staging + meta-processing):**  
Produces `EffectInfo { fn_rows: HashMap<String, BTreeSet<String>> }`. Same fixed-point algorithm, now on the RuntimeAst. This is the authoritative effect info used by Chunk 2 and codegen.

### Phase B — Call-site Checking

Runs on the RuntimeAst after Phase A2. Walks `sem_root_stmts` in order, maintaining an `active: BTreeSet<String>` of currently-handled ctl ops.

Rules:
- `WithCtl { op_name }` → add `op_name` to `active` for all subsequent stmts in the block.
- `Call { callee }` where `callee ∈ ctl_ops` → error if `callee ∉ active`.
- `Call { callee }` where `callee ∈ fn_rows` → error if any `op ∈ fn_rows[callee]` is not in `active`.
- `If`, `WhileLoop`, `Block` → recursively check sub-stmts with the current `active` set.
- `FnDecl` → skip body (callee-side effects are checked at call sites, not at definition time).

New error variant: `CompilerError::EffectNotHandled { op: String }`.

### Pipeline Placement

```
type_check(meta_ast) → type_env
effect_inference::infer_meta(meta_ast, type_env)   ← NEW (Pass A1, updates type_env)
stage_all_files(...)                                 ← typeof() now sees effect rows
...meta processing...
mark_cps(runtime_ast) → cps_info
effect_inference::infer_and_check(runtime_ast, cps_info) → effect_info   ← NEW (Pass A2 + B)
cps_transform(runtime_ast, cps_info)
type_check_runtime(runtime_ast) → type_map
```

### Files Changed

| File | Change |
|------|--------|
| `rust_comp/src/semantics/types/effect_inference.rs` | New — `EffectInfo`, `infer_meta`, `infer_and_check` |
| `rust_comp/src/semantics/types/mod.rs` | Add `pub mod effect_inference` |
| `rust_comp/src/error.rs` | Add `CompilerError::EffectNotHandled { op }` + diagnostic |
| `rust_comp/src/main.rs` | Wire up both passes |
| `rust_comp/tests/script_integration.rs` | Wire `infer_meta` + `infer_and_check`; add error tests |

### Test Cases

**TDD typeof tests** (already in `tests/types/`):
- `typeof_effect_ctl.cx` — `typeof(range)` → `(int, int) -> unit <yield>`
- `typeof_effect_transitive.cx` — transitive propagation
- `typeof_effect_multi.cx` — multiple ops in same effect row
- `typeof_effect_fn_vs_ctl.cx` — fn-style ops not in row, ctl-style ops are

**New error tests** (in `tests/effects/`):
- `unhandled_direct/` — direct ctl op call at top level with no handler → compile error
- `unhandled_transitive/` — calling a function that performs ctl ops, no handler → compile error

---

## Chunk 2 — Row Polymorphism (Future)

### Motivation

Without row polymorphism, higher-order functions that take function arguments can't propagate effects:

```text
fn map(f: (int) -> unit, xs: [int]) { for x in xs { f(x); } }
```

If `f` is passed as `range` (with effect `yield`), then `map` must also have effect `yield`. But at definition time of `map`, `f` has no known effect row.

### Design

Introduce **effect row variables** (`RowVar`) that stand for an unknown set of effects:

```text
fn map(f: (int) -> unit <E>, xs: [int]) -> unit <E> { ... }
```

The `E` is a row variable that unifies with the actual effect row when `map` is called:
- `map(range, xs)` → `E = <yield>` → `map` has effect `<yield>` at this call site.

### EffectRow Extension

```rust
pub struct EffectRow {
    pub effects: BTreeSet<String>,   // concrete ops
    pub row_var: Option<RowVar>,     // polymorphic tail (None = closed row)
}

pub struct RowVar { pub id: usize }
```

A closed row `<yield>` has `row_var = None`.  
An open row `<yield | E>` has `row_var = Some(E)`.

### Inference Rule Changes

- Function parameters of function type get fresh row variables.
- Call-site unification: `E` in the parameter's effect row unifies with the actual argument's effect row.
- Effect checking: after unification, check the resolved row against the active handler stack.

### Interaction with Chunk 1

Chunk 1 checks are sound but incomplete without row polymorphism — programs using higher-order functions with effects will be incorrectly rejected. Chunk 2 makes them accepted when correct.

Row polymorphism requires extending `Type::Func { effects }` in `types.rs` and updating unification in `type_subst.rs`.

---

## Non-Goals (Chunk 1)

- Annotations on function signatures
- Effect polymorphism / row variables
- Checking inside function bodies (only top-level execution paths checked)
- Effect masking / shadowing handlers
- `fn`-style ops in effect rows
