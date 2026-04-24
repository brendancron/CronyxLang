# Code Review: llvm-compilation branch

Generated from diff against `main`. Covers Milestones 0–11.

---

## codegen/mod.rs

**`compile()`: 1684-line mega-function.** Pass 0–3 all live inside one function scope. Extract each pass to a method or free fn.

**L~430 `lambda_exprs` sort order.** Sorted descending by ID with comment "outer ones created later (higher IDs)." CPS assigns IDs sequentially — outer continuations get higher IDs only by accident of current transform ordering. One refactor breaks this silently. Use explicit ordering or topological sort.

**L~560 `emit_fn_body` / L~640 `emit_lambda_body`: ~80 lines of copy-pasted param-binding logic.** Extract `bind_params()`.

**L~750 `emit_closure_call`: `indirect_fn_ty` rebuilt from live arg values.** Infers `i64` for any non-pointer, wrong for bool args (i1). Resolve from `type_map` instead of sniffing the value.

**L~670: env slots stored as `i64` via `ptrtoint`/`inttoptr`.** Pointer-to-int-to-pointer round-trip breaks LLVM alias analysis and is UB under a GC. Use a `ptr` slot in the env struct instead.

**L~870 `ForEach`: loop var `kind` hardcoded `LocalKind::Int`.** Slice of structs silently breaks. Add a TODO at minimum.

**L~1000 `Match`: only `names[0]` extracted from `VariantBindings::Tuple`.** Fields 1..n silently ignored for multi-field tuple variants.

**L~1100 `emit_expr VarDecl`: `RuntimeExpr::Call` return type not handled.** A function returning a struct hits the `_` arm and falls through, possibly returning `UnsupportedStmt`. Cover `RuntimeExpr::Call` explicitly in the kind-inference match.

**L~1430 `DotAccess` fallback struct resolution.** Reads `locals` only for `Variable` objects. Chained access `a.b.c` — inner `a.b` is `DotAccess`, not `Variable`, so fallback is unreachable in practice. Either document or remove it.

**`collect_refs_stmt`: `ForEach`, `Match`, `Resume`, `Assign` not handled.** Variables inside `for` bodies are invisible to capture analysis. Lambdas capturing variables from a `for` body will silently produce empty capture sets. **This is a bug.**

**`param_type_from_annot`: `Some("fn")` erases to `Func { params: vec![], .. }`.** Annotated higher-order handler params with typed args always produce a zero-param type. Structural type lost. Document or fix.

---

## semantics/types/runtime_type_checker.rs

**L~60–100 `fn_call_types` heuristic: "first call site wins."** A polymorphic fn called first with `int` and later with `string` produces wrong LLVM types on the second call. Should emit a warning or be gated on a flag. Silently wrong is worse than loudly broken.

**L~232: lenient unification silently retries with last arg stripped.** Masks real arity bugs. Should at least track that the fallback fired and warn.

**L~155–160 `Sub`/`Mult`/`Div`: non-int operands return a fresh type var.** Comment says "dispatched to user-defined impl" but no such dispatch exists. Unresolved type vars silently coerce to `i64` in codegen. **This is a bug.** Either enforce `int` or implement actual operator dispatch.

**L~213–217 `SliceRange` on string: both `match` arms return `t`.** The match is a no-op. Delete it.

---

## semantics/cps/cps_transform.rs

**`transform_while_loop`: callee names excluded from capture analysis.** If a ctl op were ever a local closure variable (`f(x)` where `f` is a lambda), `f` would not be captured. Fine under current globals-only assumption; document it.

**`transform_while_loop`: unused `__` param in suffix lambda.** `|__| suffix` — dead param, dead env slot in LLVM IR. Not a bug, but messy.

**`collect_refs_stmt`: `ForEach` and `Match` not handled.** Same gap as in codegen. Variables inside `for` bodies not captured in loop-to-recursion transforms.

---

## semantics/types/enum_registry.rs

**`EnumRegistry::build`: duplicate `EnumDecl` for same name silently overwrites.** Could happen after monomorphization. Detect and error.

**`resolve_type_name`: unknown type name becomes `Type::Enum(other)` silently.** A typo in a field type annotation (`int` → `imt`) produces `Type::Enum("imt")` with no diagnostic. Return `Result` or emit a warning.

---

## runtime/interpreter.rs

**L~510 `free()` builtin: no type guard.** `free` is registered in the type environment as a builtin. Calling `free(42)` in interpreted mode silently returns `Unit`. Acceptable for now but should be noted.

---

## Tests

**Milestones 7–11 have no `.ll` regression files.** M0–M6 all have `.ll` snapshots. Either add them for M7–M11 or document why they are intentionally excluded (e.g. effects-heavy IR is volatile across LLVM versions).

---

## Priority summary

| Severity | Finding |
|----------|---------|
| Bug | `collect_refs_stmt` missing `ForEach`/`Match` → silent wrong captures in lambdas and loop transforms |
| Bug | `Sub`/`Mult`/`Div` on non-int operands → unresolved type vars coerce silently to `i64` in codegen |
| Risk | `ptrtoint`/`inttoptr` env encoding breaks LLVM alias analysis |
| Risk | "first call site wins" type heuristic silently wrong for polymorphic fns |
| Risk | Lenient unification fallback masks arity bugs |
| Risk | `EnumRegistry` duplicate name silently overwrites |
| Nit | 1684-line `compile()` — extract passes |
| Nit | Copy-paste `emit_fn_body` / `emit_lambda_body` — extract `bind_params()` |
| Nit | `SliceRange` match is a no-op — delete |
| Nit | Missing `.ll` snapshots for M7–M11 |
