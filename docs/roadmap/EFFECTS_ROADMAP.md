# Cronyx Algebraic Effects — Implementation Roadmap

**Status:** Phase 3 Complete — Phase 4 Designed  
**Last Updated:** 2026-04-19  
**Owner:** Brendan  
**Target:** Koka-style effects with row polymorphism + selective CPS

---

## Overview

Implementing algebraic effects in Cronyx using:
- **Row-polymorphic function types** — functions declare their effect capability
- **Effect inference** — propagate effects through call chains
- **Selective CPS transform** — only transform functions that perform `ctl` effects
- **Continuation as values** — handlers receive continuations as regular parameters

See `/docs/EFFECTS_DESIGN.md` for semantics and `/docs/EFFECTS_WITH_ROW_POLYMORPHISM.md` for detailed design.

---

## Test Cases (Expected Behavior)

### log.cx — `fn` Effects
```
effect log { fn log(msg: string): unit; }

with fn log(msg: string): unit {
    print(msg);
}
log("Hello, World!");

with fn log(msg: string): unit {
    print("Log: " + msg);
}
log("Hello, World!");
```
Expected: `Hello, World!\nLog: Hello, World!`

### yield.cx — Single-Resume Generator Pattern
```
effect yield { ctl yield(i : int): unit; }

fn range(low: int, high: int, step: int) {
    for(i = low; i < high; i += step) {
        yield(i);
    }
}

with ctl yield(i: int): unit {
    print(i);
    resume
}

range(0, 5, 1);
```
Expected: `0\n1\n2\n3\n4`

### flip.cx — Multi-Resume Backtracking
```
effect flip { ctl flip(): bool; }

with ctl flip(): bool {
    resume true;
    resume false;
}

if(flip()) {
    print("Heads!");
} else {
    print("Tails!");
}
```
Expected: `Heads!\nTails!`

---

## Phase 0: Type System Foundations

**Duration:** 1-2 weeks  
**Goal:** Support effect row annotations in function signatures. No inference yet, no transforms.

### 0.1 — Design Effect Row Representation

- [ ] **Design `EffectRow` struct**
  - `pub struct EffectRow { pub effects: BTreeSet<String> }`
  - Or: `pub struct EffectRow { pub effects: Vec<String> }`? (choose based on performance)
  - Operations: union, intersection, subsumption check
  - Display format: `<yield, log>`, `<>` (empty)

- [ ] **Design handler value representation**
  - What does a handler carry? Op name, params, body stmt id, continuation?
  - Should be a `Value` variant? Or something else?

### 0.2 — Extend Type System

- [ ] **Modify `Type` enum** (`semantics/types/types.rs`)
  - Change `Func { params, ret }` to `Func { params, ret, effects: EffectRow }`
  - Update display/debug impl
  - Update unification logic (effects are part of type equality)

- [ ] **Modify `TypeScheme`** (for polymorphic functions)
  - Support row-polymorphic effect variables (like `E` in `fn map(f: (int) with E -> int): list with E`)
  - Representation: `EffectVar { id }` variant in `EffectRow`?

- [ ] **Test:** Type construction and display
  ```rust
  Type::Func {
      params: vec![int_type()],
      ret: Box::new(unit_type()),
      effects: EffectRow::from_vec(vec!["yield".to_string()]),
  }
  ```

### 0.3 — Parser Changes

- [ ] **Extend `Token` and `TokenType`** (`frontend/token.rs`)
  - Add `TokenType::With`, `Effect`, `Ctl`, `Resume` if not present
  - Check if already added (from initial tests exploration)

- [ ] **Extend `MetaAst`** (`frontend/meta_ast.rs`)
  - Add to `MetaStmt`:
    - `EffectDecl { name: String, ops: Vec<EffectOp> }`
    - `WithFn { op_name: String, params: Vec<Param>, body: usize }`
    - `WithCtl { op_name: String, params: Vec<Param>, body: usize }`
    - `Resume`
  - Add struct `EffectOp { kind: EffectOpKind, name: String, params: Vec<Param>, ret_ty: Option<String> }`
  - Add enum `EffectOpKind { Fn, Ctl }`
  - Update `convert_stmt` for AST display

- [ ] **Extend `FnDecl` in MetaAst**
  - Add `effect_row: Option<EffectRow>` field
  - Or `effect_row: EffectRow` (default empty)?
  - Parser: recognize `with <yield, log>` syntax after return type

- [ ] **Implement parser arms** (`frontend/parser.rs`)
  - `parse_effect_decl()` — parse `effect name { fn|ctl op(...): ret; }`
  - `parse_with_fn()` — parse `with fn op(...): ret { body }`
  - `parse_with_ctl()` — parse `with ctl op(...): ret { body }`
  - `parse_resume()` — parse bare `resume` or `resume expr`
  - Update `parse_fn_decl()` to parse optional `with <...>` effect row
  - Test parsing all four statement types, effect annotations

- [ ] **Test:** Parser round-trips on all test files
  ```bash
  cargo test --lib frontend::parser
  ```

### 0.4 — Type Checker (Minimal)

- [ ] **Update type checker** (`semantics/types/type_checker.rs`)
  - Update `infer_expr` for `Call` to return types with effect rows
  - `infer_stmt` for `EffectDecl` → no-op or store declaration
  - `infer_stmt` for `WithFn`, `WithCtl`, `Resume` → no-op for now (will add effect tracking in Phase 1)
  - Built-in functions: assign empty effect row `<>`

- [ ] **Test:** Type checking doesn't break on new AST nodes
  ```bash
  cargo test --lib semantics::types::type_checker
  ```

### 0.5 — Pipeline Plumbing

- [ ] **Extend `StagedAst`** (`semantics/meta/staged_ast.rs`)
  - Mirror the 4 new statement types from MetaAst

- [ ] **Extend `meta_stager.rs`** (`semantics/meta/meta_stager.rs`)
  - Add pass-through arms for 4 new statement types

- [ ] **Extend `RuntimeAst`** (`semantics/meta/runtime_ast.rs`)
  - Mirror the 4 new statement types
  - Update `compact()` method

- [ ] **Extend `conversion.rs`** (`semantics/meta/conversion.rs`)
  - Add conversion arms for 4 new statement types

- [ ] **Test:** Full pipeline (lexer → token → parser → type check → stage → runtime) compiles
  ```bash
  cargo test --lib
  ```

### 0.6 — Interpreter (No-Op)

- [ ] **Update interpreter** (`runtime/interpreter.rs`)
  - Add `ctl_handlers: Vec<CtlHandlerEntry>` to `EvalCtx`
  - `eval_stmt` for `EffectDecl` → return `Continue` (no-op)
  - `eval_stmt` for `WithFn` → no-op for now (will implement in Phase 4)
  - `eval_stmt` for `WithCtl` → no-op for now (will implement in Phase 3)
  - `eval_stmt` for `Resume` → error (not in handler context)

- [ ] **Test:** Existing tests still pass, new tests don't crash
  ```bash
  cargo test --lib runtime::interpreter
  cargo test  # integration tests
  ```

### 0.7 — Integration Test Setup

- [ ] **Add test infrastructure** (`rust_comp/tests/` or wherever integration tests live)
  - Wire up `effect_log`, `effect_yield`, `effect_flip` tests
  - Create expected output files: `tests/effects/{log,yield,flip}/{input.cx, output.txt}`
  - Tests will fail (Phase 0 is no-op), but infrastructure is ready

- [ ] **Test:** All three test files parse and type-check (no output yet)
  ```bash
  cd rust_comp
  cargo test --test script_integration effect_  # should fail on output
  ```

---

## Phase 1: Effect Inference

**Duration:** 1 week  
**Goal:** Compiler infers which effects each function performs.

### 1.1 — Effect Inference Algorithm

- [ ] **Create `semantics/meta/effect_inference.rs`**
  - `fn infer_effects(ast: &RuntimeAst, type_env: &TypeEnv) -> Map<String, EffectRow>`
  - Algorithm:
    1. Scan each function body for `ctl` op calls
    2. Collect called functions' effects from type env
    3. Infer function's effect row from body
    4. Type check: inferred row ⊆ declared row (if declared), or report error
    5. Propagate up call chain (iterate until fixed point)

- [ ] **Implement helper functions**
  - `fn scan_stmt_for_effects(stmt: &RuntimeStmt, ...) -> EffectRow`
  - `fn scan_expr_for_effects(expr: &RuntimeExpr, ...) -> EffectRow`
  - `fn is_ctl_op(name: &str, effect_decls: &Map) -> bool`

- [ ] **Test on simple cases**
  ```
  fn foo() { yield(1); }  // infers <yield>
  fn bar() { foo(); }      // infers <yield> (from foo)
  fn baz() { print(1); }  // infers <> (no effects)
  ```

### 1.2 — Integrate into Type Checker

- [ ] **Call effect inference after type checking**
  - In `type_check()` or in interpreter setup
  - Update function types with inferred effect rows
  - Type check errors: inferred effects not in declared row → error

- [ ] **Handle polymorphic effects**
  - If function has effect variable `E`, infer at call sites
  - Example: `fn map(f: (int) with E -> int): list with E`
  - At call: `map(range)` where `range: (int) with <yield> -> ...`
  - Infer: `E = <yield>`

- [ ] **Test:** Effect inference on yield.cx
  ```rust
  assert_eq!(infer_effects(program)["range"], EffectRow::from_vec(vec!["yield"]));
  ```

### 1.3 — Error Messages

- [ ] **Effect mismatch errors**
  - If function declares `with <log>` but body calls `yield` → error
  - Good error message with location

- [ ] **Unhandled effect errors**
  - If function body calls effect that isn't active → error (later phase)

---

## Phase 2: Selective CPS Transform

**Duration:** 2 weeks  
**Goal:** Transform functions with `ctl` effects into CPS form.

### 2.1 — CPS Transform Design

- [ ] **Design transformed code shape**
  - Original: `fn range(low: int, high: int): unit { ... yield(i) ... }`
  - Transformed: `fn range(low: int, high: int, __k): unit { ... __k_yield(i) ... }`
  - What is `__k`? Structure? One handler per effect or unified handler stack?
  - Decide: pass individual handlers or handler stack?

- [ ] **Design handler value**
  - `pub struct HandlerValue { op_name: String, body: fn(...) -> (...), ... }`
  - Or just use function values?

- [ ] **Design resume semantics in transformed code**
  - Original: `resume expr` inside handler
  - Transformed: `__k_cont(expr)` where `__k_cont` is the captured continuation

### 2.2 — Implement CPS Transform Pass

- [ ] **Create `semantics/meta/cps_transform.rs`**
  - `fn transform_cps(ast: &mut RuntimeAst, effects: &Map<String, EffectRow>)`
  - For each function with `ctl` effects:
    - Transform function signature (add handler params)
    - Transform body (see 2.3-2.5)
    - Find callers and mark them for transformation too

- [ ] **Transform function signatures**
  - Add one parameter per effect: `__k_yield`, `__k_log`, ...
  - Or: add `__handlers: HandlerStack` (one param, cleaner)
  - Update `FnDecl` in AST

- [ ] **Transform function bodies** (hard part, see below)

- [ ] **Transform call sites**
  - When calling a function that was transformed, pass handlers as extra params
  - Insert handler lookup: which handlers are currently active?

### 2.3 — Transform Statements

- [ ] **Transform all statement types that contain sub-stmts**
  - `Block(stmts)` → transform each stmt
  - `If { cond, body, else_branch }` → transform body and else_branch recursively
  - `WhileLoop { cond, body }` → transform body
  - `ForEach { ... body }` → transform body
  - `FnDecl { ... body }` → recursive (inner functions may use effects too)

- [ ] **Special: transform return statements**
  - Original: `return expr`
  - Transformed: `__k_cont(expr)` (continue with the next step)
  - Actually, depends on context (inside a loop vs inside a function)
  - Need to thread "what's the current continuation?" through transform

### 2.4 — Transform Expressions & Effect Operations

- [ ] **Transform effect operation calls**
  - Original: `yield(i)` (call to undefined operation)
  - Transformed: `__k_yield(i, __k_cont)` where `__k_yield` is the handler
  - `__k_cont` is a closure: "what to do after yield returns"

- [ ] **Build continuations**
  - This is the hard part! The continuation must capture:
    - The remaining statements after the operation call
    - The current environment/bindings
    - The next operation to perform
  - Representation: as a `Value::Closure`? Or as a transformed lambda?

- [ ] **Transform regular function calls**
  - If calling a transformed function, pass handler params
  - Otherwise, no change

### 2.5 — Handle Loops (Key Case for yield.cx)

- [ ] **ForEach loop with yield inside**
  - The continuation after `yield(i)` is: "continue loop to next iteration"
  - How to represent this in transformed code?
  - Option A: transform into recursive function call
  - Option B: transform into explicit continuation lambda
  - Option C: keep loop structure, embed continuation inside

### 2.6 — Test CPS Transform

- [ ] **Unit tests on simple functions**
  ```
  fn foo(x: int): int with <yield> { yield(x); return x * 2; }
  // Transform and verify structure
  ```

- [ ] **Integration test: transform yield.cx**
  - Compile to transformed AST
  - Inspect transformed code (print it out)
  - Verify it's syntactically valid Cronyx AST

- [ ] **Do NOT run interpreter yet** (Phase 3)

---

## Phase 3: Interpreter Integration

**Duration:** 1 week  
**Goal:** Interpreter executes CPS-transformed code correctly.

### 3.1 — Handler Value Type

- [ ] **Add `Value::Handler` variant** (`runtime/value.rs`)
  - `Handler { op_name: String, body: fn(args, cont) -> Result }`
  - Or: handler is a regular function that takes continuation as last param?
  - Decide representation

- [ ] **Add handler construction in interpreter**
  - When `WithCtl` is evaluated, construct a handler value
  - Push onto handler stack (or store in environment?)

### 3.2 — Run Transformed Code

- [ ] **Verify interpreter can execute transformed code**
  - CPS-transformed code is syntactically valid Cronyx
  - So interpreter should just work
  - Add some debug logging to trace execution

- [ ] **Test: yield.cx produces correct output**
  ```bash
  cd rust_comp
  cargo test effect_yield
  ```

### 3.3 — Test: flip.cx

- [ ] **Test: flip.cx produces both branches**
  ```bash
  cargo test effect_flip
  ```

### 3.4 — Error Handling

- [ ] **Unhandled operation error**
  - If code calls `yield` but no `with ctl yield` is active → error

- [ ] **Resume outside handler error**
  - If `resume` appears outside handler body → error (should catch in Phase 1 type checker)

---

## Phase 4: `fn` Effects

**Duration:** 1 week  
**Goal:** Simple handler replacement for `fn` effects.

### 4.1 — Implement `fn` Handlers

- [ ] **Implement `WithFn` in interpreter** (`runtime/interpreter.rs`)
  - `eval_stmt(WithFn { op_name, params, body })`:
    - Create a `Function` value wrapping the handler body
    - Install it in current environment under `op_name`
    - When `op_name(...)` is called later, normal function lookup finds it

- [ ] **Scope management**
  - Second `with fn log` shadows the first (natural, via `env.define()`)
  - When scope exits, old binding is still shadowed (until scope pops)

### 4.2 — Test log.cx

- [ ] **Test: log.cx produces correct output**
  ```bash
  cargo test effect_log
  ```
  Expected: `Hello, World!\nLog: Hello, World!`

---

## Post-Implementation (Future)

- [ ] **Effect masking** — `with yield { ... } where flip is masked`
- [ ] **Handler composition** — multiple handlers for same operation
- [ ] **Performance optimization** — reduce CPS overhead
- [ ] **Better error messages** — map transformed code back to source
- [ ] **Effect benchmarks** — measure overhead of effects system

---

## Dependencies & Critical Path

```
Phase 0 (Type System)
    ↓
Phase 1 (Effect Inference) [depends on Phase 0]
    ↓
Phase 2 (CPS Transform) [depends on Phase 1]
    ↓
Phase 3 (Interpreter) [depends on Phase 2]
    ↓
Phase 4 (fn Effects) [depends on Phase 0, independent of 1-3]
```

**Critical path:** Phase 0 → 1 → 2 → 3

Phase 4 can start after Phase 0 completes (parallel work if needed).

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| CPS transform correctness | Extensive unit tests on each statement type; verify AST structure before running |
| Effect row polymorphism complexity | Start with monomorphic effects (no E variables) in Phase 1; add polymorphism later |
| Debugging transformed code | Keep source-to-transformed mapping; add debug output; test incrementally |
| Performance regression | Benchmark overhead of CPS calls; optimize hot paths later |
| Type system stability | Run full test suite after each Phase 0 change |

---

## Done Checklist (Update as Progress)

- [x] Design semantics (EFFECTS_DESIGN.md)
- [x] Design row polymorphism approach (EFFECTS_WITH_ROW_POLYMORPHISM.md)
- [x] Create this roadmap
- [x] **Phase 0** — type system foundations (parsing, AST, pipeline plumbing)
- [ ] **Phase 1** — effect inference
- [ ] **Phase 2** — selective CPS transform
- [x] **Phase 3** — interpreter integration (single-resume `ctl` effects working)
- [x] **Phase 4** — `fn` effects + single-flip multi-resume
- [x] log.cx, yield.cx, flip.cx, multi_resume_accumulate.cx all passing
- [x] Delimited continuations via call-site suffix replay (`CtlSuspend` + `stmts[i..]`)
