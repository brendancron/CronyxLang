# Fix Plan: llvm-compilation branch

Remediation for all findings in `docs/llvm-compilation-branch-review.md`.
Organized by priority group; execute in the order shown in the summary table at the bottom.

---

## Group A — Bugs (must fix first)

### A1. `collect_refs_stmt` missing arms → silent wrong closure captures

**Files:** `codegen/mod.rs`, `cps_transform.rs`

Both files have independent `collect_refs_stmt` / `collect_stmt_refs` functions with identical missing arms. Fix both in the same commit.

**Add these arms before the catch-all `_ => {}`:**

- `RuntimeStmt::ForEach { var, iterable, body }` — recurse into `iterable` via `collect_refs_expr`; build a new `bound` set with `var` added; recurse into `body` with the augmented bound.
- `RuntimeStmt::Match { scrutinee, arms }` — recurse into `scrutinee`; for each arm extend `bound` with the binding names from `arm.pattern` (`VariantBindings::Tuple(names)` / `VariantBindings::Struct(names)`), then recurse into `arm.body`.
- `RuntimeStmt::Resume(Some(expr))` — recurse into `expr` via `collect_refs_expr`.
- `RuntimeStmt::Assign { name, expr }` — insert `name` into `refs` if not in `bound`; recurse into `expr`. (Check `cps_transform.rs` — `Assign` may already be present there.)

**Watch out for:**
- `ForEach` arm must use a *new inner* `BTreeSet` for the body recursion, not mutate the caller's `bound`.
- `VariantBindings::Unit` — no names to bind.
- Scope this PR to these four stmt variants; `collect_refs_expr` gaps (missing `List`, `EnumConstructor`, `StructLiteral`, etc.) are a follow-up nit.

**Tests required:** Lambda inside a `for` loop body that captures an outer variable — verify compiled binary produces correct output. Same for a lambda inside a `match` arm.

---

### A2. `Sub`/`Mult`/`Div` return fresh type var for non-int operands → silent i64 coerce

**File:** `semantics/types/runtime_type_checker.rs` (~line 155)

**What to change:**

1. Remove the `Struct` branch that returns `Type::Var(env.fresh())` for non-int operands. No operator dispatch exists in the language; letting a fresh var escape causes it to silently become `i64` in codegen. Restore the unconditional `unify(&ta, int_type())` + `unify(&tb, int_type())` behavior, or convert it to a `TypeError` if both operands resolve to a non-int type after `apply(subst)`.

2. After the final substitution, scan all `RuntimeExpr::Sub / Mult / Div` expr_ids in `ast.exprs` against `resolved`. If any entry is still `Type::Var(_)`, emit a `TypeError` (or structured warning) rather than silently leaving it unresolved.

**Watch out for:** Struct operator dispatch (if ever added) will need a dedicated pre-pass that resolves it before Phase 2 runs — don't encode that assumption in the arithmetic inference rule.

**Tests required:** A Phase 2 test applying `-` between two `string` variables — assert `TypeError`. Regression test that arithmetic on `int` still passes.

---

## Group B — Risks (fix before stabilizing)

### B1. "First call site wins" for polymorphic functions

**File:** `semantics/types/runtime_type_checker.rs` (~lines 61–121)

Replace the `if fn_call_types.contains_key { continue }` skip with a check that collects *all* call sites per function. If multiple distinct arg-type vectors exist for the same function name:

- **Preferred:** Emit a structured warning to stderr naming the function and conflicting call sites; keep the first concrete entry for codegen.
- **Stronger:** Return `TypeError::PolymorphicAmbiguity` blocking codegen.

The warning path is non-breaking. The error path is safer for production.

Also document the existing arity guard at ~line 97 (`arg_types.len() < existing_param_count → continue`) with a comment referencing this issue.

**Tests required:** A test calling the same generic function with two different concrete types — assert a warning or error is produced. Verify existing polymorphic tests still pass.

---

### B2. Lenient unification silently swallows arity errors

**File:** `semantics/types/runtime_type_checker.rs` (~line 232)

Change `let _ = unify(&callee_ty, &trimmed, subst)` to a propagating call:

```rust
unify(&callee_ty, &trimmed, subst)?;
```

This surfaces genuine arity errors instead of swallowing them. The fallback (strip last arg) is only valid for CPS-added continuation args. Gate it: check whether the extra arg's inferred type is `Type::Func` (continuations are always closures). If not `Func`, propagate the error immediately rather than trying the trimmed path.

This avoids threading `CpsInfo` into `infer_expr` (a larger API change).

**Tests required:** Function of 1 param called with 3 args → assert `TypeError`. Existing CPS tests (`m7–m11`) must still pass.

---

### B3. `EnumRegistry::build` silently overwrites duplicate enum names

**File:** `semantics/types/enum_registry.rs` (~line 44)

Before inserting, check for an existing entry:
- If existing entry equals the new one (same tags, same payloads): skip silently. This handles the module re-import case where two files declare the same enum identically.
- If they differ: `debug_assert_eq!` in debug mode; emit a warning in release. Or return `Result<Self, EnumRegistryError>` from `build` and propagate to callers.

**Tests required:** Unit test with two identical `EnumDecl` nodes — assert no panic. Unit test with two conflicting `EnumDecl` nodes — assert error/warning.

---

### B4. Replace `ptrtoint`/`inttoptr` env encoding with typed `ptr` slots

**File:** `codegen/mod.rs` (~lines 670, 2707–2730, 2911–2938, 1854–1876)

**Must land after A1** — A1 fixes capture lists; B4 changes how those lists are encoded.

Three coordinated changes:

1. **Env struct representation:** Replace the flat `i64 * N * 8` malloc with a dynamically-typed LLVM struct: `{ptr, i64, ptr, ...}` matching the `captures` order. Each `LocalKind::Int` capture → `i64` field; all other captures → `ptr` field.

2. **Env write (closure creation):** For `Int` captures store the `i64` directly. For pointer captures store the `ptr` directly — remove `build_ptr_to_int`.

3. **Env read (`emit_lambda_body`):** GEP into the typed struct at the correct field index. For `i64` fields: `build_load(i64_ty, ...)`. For `ptr` fields: `build_load(ptr_ty, ...)`. Remove `build_int_to_ptr`.

**Watch out for:**
- Use `lambda_actual_captures` as the source of truth for field order at both write and read sites.
- Null-env lambdas (HOF closure wrappers) are unaffected — keep the `null` path.
- Batch C4 (multi-binding LocalKind fix) into this PR since both use the same array encoding pattern.

**Tests required:** New test: lambda inside a `for` loop capturing a struct-typed variable — verify correct pointer value in compiled output.

---

## Group C — Cleanup (can be batched or done in parallel)

### C1. Delete `SliceRange` no-op match arm

**File:** `runtime_type_checker.rs` (~lines 213–217)

Both arms of `match obj_ty.apply(subst) { t @ String => t, t => t }` return `t`. Replace with a direct return of `obj_ty.apply(subst)`. Optionally add a check that rejects `SliceRange` on non-slice non-string types.

---

### C2. Fix `param_type_from_annot` erasing typed fn params

**File:** `codegen/mod.rs` (~line 4124)

`"fn"` arm returns `Func { params: vec![], ... }`. Change to a single `Int` placeholder param as a minimal fix: `Func { params: vec![int_type()], ... }`. Document that multi-param `fn(T, U)` annotations are not yet parsed. Add a test for a `with fn` handler that receives a function parameter and passes it an argument.

---

### C3. Fix `ForEach` loop var `LocalKind` hardcoded to `Int`

**File:** `runtime_type_checker.rs` (~line 509)

In the `ForEach` arm: after inferring `iter_ty`, if it is still `Type::Var`, unify it with `Type::Slice(Box::new(Type::Var(env.fresh())))` before extracting `elem_ty`. This propagates element type information to codegen for generic iterables.

Run the full compile_all test suite after — this may turn previously-unconstrained vars into Slice vars.

**Tests required:** `for x in list_of_strings` — assert `x` inferred as `string` and uses `LocalKind::Str` in emitted IR.

---

### C4. Fix `Match` only extracting `names[0]` from tuple variant bindings

**File:** `codegen/mod.rs` (~lines 2520–2543)

**Batch with B4.** For multi-binding variants, look up `ResolvedPayload::Tuple(types)` in `self.enum_registry` and use those types to determine `LocalKind` per binding — same logic as `emit_fn_body` param kind table. Store pointer-typed bindings in `ptr` slots (consistent with B4's encoding).

---

### C5. Fix `indirect_fn_ty` inferred from value types instead of `type_map`

**File:** `codegen/mod.rs` (~line 1978 `emit_closure_call`)

Look up `self.type_map.get(&arg_id)` for each arg to determine the LLVM type, falling back to the emitted value type only when absent. The `args: &[usize]` expr_ids are available in `emit_closure_call` — use them. Also apply to the `Resume` indirect call (~line 2645) which hardcodes `i64` for the resume value.

---

### C6. Extract `bind_params()` from `emit_fn_body` / `emit_lambda_body`

**File:** `codegen/mod.rs` (~lines 1776–1805, 1880–1909)

**Do after B4.** Extract the shared param-binding logic into:

```rust
fn bind_param(
    &self,
    name: &str,
    param_val: BasicValueEnum<'ctx>,
    opt_ty: Option<&Type>,
) -> Result<Local<'ctx>, CodegenError>
```

Pure refactor — no behavior change.

---

### C7. Add `.ll` regression snapshots for milestones 7–11

**Do last** — after all other fixes land so snapshots reflect corrected IR.

Generate by running existing compile tests and capturing emitted IR from `/tmp/`. Strip the `target triple` line before committing. Files needed:
- `tests/compile/m7/safe_div.ll`
- `tests/compile/m8/log.ll`
- `tests/compile/m9/say.ll`
- `tests/compile/m10/emit_pair.ll`
- `tests/compile/m11/yield.ll`

---

### C8. Extract passes from `compile()` mega-function

**Do last** — after all other changes to avoid merge conflicts.

Suggested split following existing pass comments:

| Pass | Responsibility |
|------|---------------|
| `collect_declarations` | Scan EnumDecl, StructDecl, string literals, lambda forward-decls |
| `forward_declare_functions` | `user_fns`, `fn_arg_types`, handler decls |
| `emit_function_bodies` | `emit_fn_body` calls for user fns, lambdas, handlers |
| `emit_main_body` | Root stmt sequence |

The `Cg` struct remains as shared state holder for builder/context. Each pass takes `&RuntimeAst`, `&HashMap<usize, Type>`, and `&Module`.

---

## Execution Order

| Step | Items | Dependency |
|------|-------|------------|
| 1 | **A1** collect_refs missing arms | None — do first |
| 2 | **A2** Sub/Mult/Div type var leak | None — independent |
| 3 | **B4 + C4** ptr-slot env encoding + multi-binding fix | After A1 |
| 4 | **B1** first-call-site warning | Independent |
| 5 | **B2** lenient unification propagate | Independent |
| 6 | **B3** EnumRegistry duplicate check | Independent |
| 7 | **C1, C2, C3, C5** small cleanups | Independent |
| 8 | **C6** bind_params extraction | After B4 |
| 9 | **C7** .ll snapshots | After all fixes |
| 10 | **C8** mega-function split | After all fixes |

A1 and A2 each deserve their own PR with test coverage. B4+C4 is one PR. B1/B2/B3 can be combined in a single "risk mitigations" PR. C1–C6 can be one cleanup PR.
