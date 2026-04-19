# Cronyx Algebraic Effects — Design, Analysis & Implementation Plan

## Overview

Implementing Koka-style algebraic effects in Cronyx. Three test cases define the requirements:

1. `log.cx` — `fn` effects (simple function replacement)
2. `yield.cx` — `ctl` effects with single resume (generator pattern)
3. `flip.cx` — `ctl` effects with multiple resumes (backtracking/choice)

---

## Koka Comparison & Lessons Learned

### How Koka Does It

Koka's implementation evolved through two major phases:

**Original (2012-2017): Full CPS Translation**
Every effectful function was transformed so its continuation was passed explicitly. This caused massive code-size blowup and defeated standard optimizations — every function call became a closure allocation.

**Current (2020+): Evidence-Passing Translation**
Instead of reifying continuations at every call, Koka passes an *evidence vector* — a runtime value mapping each effect label to its handler's stack marker. Operations compile as ordinary function calls. Only when a `ctl` operation actually suspends does Koka capture a continuation (via `setjmp`/`longjmp`-style stack copying on C backend). Tail-resumptive operations (`fn` ops) compile to direct calls with zero overhead.

### Key Insight for Cronyx

**The planned "selective CPS transform" is over-engineered for a tree-walking interpreter.** CPS transforms are a *compiler* technique — they rewrite the AST into continuation-passing form before execution. In a tree-walking interpreter, we already have an implicit continuation: *the Rust call stack itself*.

| Aspect | Full CPS (planned) | Handler Stack (recommended) |
|---|---|---|
| Default cost per call | Closure allocation | Zero (direct call) |
| `fn` effects | Unnecessary transform | `env.define()` — done |
| `ctl` effects (single) | Closure chain | One-shot continuation capture |
| `ctl` effects (multi) | Multiple closure invocations | Clone continuation |
| New code needed | ~1000+ lines + new pass | ~200-300 lines in existing files |
| Complexity | Very high (new compiler pass) | Medium (extend interpreter) |

### What Koka Gets Right (And We Should Copy)

1. **Effect rows in types** — functions declare which effects they perform
2. **`fn` vs `ctl` distinction** — tail-resumptive ops have zero overhead
3. **Handler scoping** — handlers are lexically scoped, stack-managed
4. **Deep handlers** — handler stays active across resumes

### What We Should Skip (For Now)

1. **Evidence-passing translation** — only matters for compiled backends
2. **Full CPS transform pass** — wrong tool for interpreter
3. **Row polymorphism with effect variables** — start monomorphic
4. **Effect inference fixed-point algorithm** — start with explicit annotations

---

## Handler Semantics: Deep Handlers

**Key insight:** Koka handlers are **deep** — a single handler can execute `resume` multiple times, each re-entering the suspended computation with a different value.

### flip.cx Example

```
effect flip {
    ctl flip(): bool;
}

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

Execution:
1. `flip()` suspends execution, capturing the continuation: "run the `if` statement"
2. Handler runs `resume true` → re-enters if-stmt with `flip()` returning `true` → prints "Heads!"
3. Control returns to handler (not to caller)
4. Handler runs `resume false` → re-enters if-stmt with `flip()` returning `false` → prints "Tails!"
5. Handler finishes, program ends

**This is not sequential execution — it's a branching search tree where each `resume` explores one branch.**

### yield.cx Example (Single Resume)

```
with ctl yield(i: int): unit {
    print(i);
    resume
}

range(0, 5, 1);  // calls yield(0), yield(1), ..., yield(4)
```

Each `yield(i)` suspends, handler prints `i`, then `resume` re-enters range body to continue loop.

---

## Two Kinds of Effects

### `fn` Effects (Simple Dispatch)

```
effect log {
    fn log(msg: string): unit;
}

with fn log(msg: string): unit {
    print("LOG: " + msg);
}

log("hello");     // calls the installed handler
```

**Semantics:** Replace the operation with a normal function. No suspension/resumption.
**Implementation:** `env.define(op_name, function)` — done. This is trivial.

### `ctl` Effects (Delimited Continuations)

```
effect yield {
    ctl yield(i: int): unit;
}

with ctl yield(i: int): unit {
    print(i);
    resume
}

fn range(low: int, high: int) {
    for(i = low; i < high; i = i + 1) {
        yield(i);
    }
}

range(0, 5);
```

**Semantics:** Calling `yield(i)` suspends the entire computation. Handler runs, and `resume` re-enters at the exact call site.

The continuation is a **first-class value**:
- Call `resume` once (like `yield.cx`)
- Call `resume` multiple times (like `flip.cx`)
- Not call `resume` at all (abort continuation)
- Call `resume` with different values each time

---

## Design Decisions

### 1. `resume` Takes an Optional Argument

- Bare `resume` is sugar for `resume ()` (returns unit)
- `resume expr` passes result of `expr` back to operation call site
- **Type rule:** If `ctl op(...): T`, then `resume` must pass value of type `T`

### 2. Handlers Are Deep (Multiple Resumes Allowed)

- Each `resume` re-enters the continuation from scratch
- The continuation must be replayable (cloneable)

### 3. Open Scope for Handlers

```
with ctl yield(i: int): unit {
    print(i);
    resume
}

range(0, 5);      // yield is active here
other_stuff();    // yield is still active here
// yield is no longer active here (scope ended)
```

### 4. Multiple Handlers Active Simultaneously

Handler stack, last-installed-wins lookup by operation name.

### 5. `resume` Only Inside Handler Bodies

Parser/type checker enforces this.

### 6. Effect Declarations Are Structural

`effect yield { ctl yield(i: int): unit; }` is documentation + signature check. Runtime doesn't enforce — type checker validates handler matches declaration.

---

## Revised Implementation Architecture

### Strategy: Handler Stack + Continuation Capture (NOT CPS Transform)

Instead of a CPS transform compiler pass, we extend the interpreter directly:

```
Lexer → Token → Parser → MetaAst → TypeChecker → StagedAst →
MetaStager → RuntimeAst → Conversion → Interpreter (with handler stack)
```

### Core Runtime Changes

```rust
// New in result.rs
pub enum ExecResult {
    Continue,
    Return(Value),
    Suspend {
        op_name: String,
        args: Vec<Value>,
        continuation: Continuation,
    },
}

// New in value.rs
pub struct Continuation {
    /// Remaining statement IDs to execute after resume point
    pub remaining_stmts: Vec<usize>,
    /// Snapshot of the environment at suspension point
    pub env_snapshot: EnvRef,
    /// Handler stack depth at suspension point
    pub handler_depth: usize,
}

// New in interpreter.rs
pub struct CtlHandler {
    pub op_name: String,
    pub params: Vec<String>,
    pub ret_type: String,
    pub body: usize,
    pub env: EnvRef,
}

pub struct EvalCtx<'a, W> {
    pub out: W,
    pub env: &'a mut EnvHandler,
    pub ast: &'a RuntimeAst,
    pub gen_collector: Option<&'a mut GeneratedCollector>,
    pub source_dir: Option<std::path::PathBuf>,
    pub ctl_handlers: Vec<CtlHandler>,   // NEW: handler stack
}
```

### Execution Model for `ctl` Operations

When `eval_expr(Call { callee: "yield", args: [...] })`:

1. Check if `yield` is in `ctl_handlers` stack (reverse search — last installed wins)
2. If found:
   - Evaluate args → `arg_vals`
   - Capture continuation: remaining stmts + env snapshot
   - Create handler scope, bind params to `arg_vals`
   - Evaluate handler body
   - When `resume expr` is hit: evaluate `expr`, re-enter continuation with that value
   - When handler body completes without resume: continuation is discarded
3. If no handler: check env for normal function; if not found, error

### Continuation Capture Strategy

For the tree-walking interpreter, continuations are represented as:
- **Statement-ID lists** — the remaining `usize` IDs to execute after the suspend point
- **Environment snapshots** — `Rc::clone()` of the current `EnvRef` (cheap due to Rc)
- **Cloneable** — for multi-resume, clone the remaining stmts + env

This fits Cronyx's existing `usize`-ID architecture. No need for Rust closures or threads.

For multi-resume (`flip`), each `resume` gets its own clone of the continuation. The handler body calls resume sequentially — first resume runs to completion, then second resume runs.

---

## Codebase Impact Analysis

### Files That Need Changes

| File | Change | LOC (est.) | Effort |
|---|---|---|---|
| `frontend/token.rs` | Add `With`, `Effect`, `Ctl`, `Resume` to `TokenType` | ~8 | Trivial |
| `frontend/lexer.rs` | Add `"with"`, `"effect"`, `"ctl"`, `"resume"` keyword mappings | ~8 | Trivial |
| `frontend/meta_ast.rs` | Add `EffectDecl`, `WithFn`, `WithCtl`, `Resume` to `MetaStmt`; add `EffectOp` struct | ~40 | Low |
| `frontend/parser.rs` | Add `parse_effect_decl()`, `parse_with_handler()`, `parse_resume()`; extend `parse_stmt()` | ~120 | Medium |
| `semantics/meta/staged_ast.rs` | Mirror 4 new stmt variants in `StagedStmt` | ~20 | Trivial |
| `semantics/meta/meta_stager.rs` | Pass-through arms for 4 new variants | ~20 | Trivial |
| `semantics/meta/runtime_ast.rs` | Mirror 4 variants in `RuntimeStmt`; update `compact()` | ~60 | Low |
| `semantics/meta/conversion.rs` | Convert 4 new variants StagedStmt → RuntimeStmt | ~20 | Trivial |
| `semantics/types/type_checker.rs` | Type-check effect decls and handler signatures (initially no-op) | ~30 | Low |
| `runtime/result.rs` | Add `Suspend` variant to `ExecResult` | ~10 | Trivial |
| `runtime/value.rs` | Add `Continuation` struct | ~15 | Low |
| `runtime/interpreter.rs` | Handler stack, `ctl` dispatch, `resume` handling, continuation capture | ~150 | **High** |
| `runtime/environment.rs` | Add env snapshot/clone support (may already work via Rc) | ~5 | Trivial |
| **Total** | | **~500** | |

### What Stays Untouched

- `config.rs`, `args.rs`, `main.rs` — no changes
- `debug_sink.rs` — no changes
- `module_loader.rs`, `source_discovery.rs` — no changes
- `semantics/meta/gen_collector.rs`, `symbol_collector.rs` — no changes
- `semantics/meta/monomorphize.rs` — no changes
- All existing tests — must continue passing

---

## Implementation Phases (Revised)

### Phase 1: Lexer + Token + AST Pipeline (1-2 days)

**Goal:** All new syntax parses without crashing. No runtime behavior.

- [ ] Add 4 tokens to `TokenType`: `With`, `Effect`, `Ctl`, `Resume`
- [ ] Add keyword mappings in lexer: `"with"` → `With`, `"effect"` → `Effect`, `"ctl"` → `Ctl`, `"resume"` → `Resume`
- [ ] Add AST nodes to `MetaStmt`:
  ```rust
  EffectDecl { name: String, ops: Vec<EffectOp> }
  WithFn { op_name: String, params: Vec<Param>, ret_type: Option<String>, body: usize }
  WithCtl { op_name: String, params: Vec<Param>, ret_type: Option<String>, body: usize }
  Resume(Option<usize>)  // optional expr to pass back
  ```
- [ ] Add `EffectOp` struct: `{ kind: EffectOpKind, name: String, params: Vec<Param>, ret_ty: Option<String> }`
- [ ] Implement parser arms: `parse_effect_decl()`, `parse_with_handler()`, `parse_resume()`
- [ ] Mirror variants through StagedAst, RuntimeAst, conversion
- [ ] Update `compact()` in RuntimeAst
- [ ] All existing tests still pass

**Verification:** `cargo test` passes. Effect test files parse but produce no output.

### Phase 2: `fn` Effects (1 day)

**Goal:** `log.cx` passes.

- [ ] In interpreter `eval_stmt` for `WithFn`:
  - Create `Value::Function` from handler params + body
  - `env.define(op_name, function)` — installs handler as normal function
- [ ] `EffectDecl` → no-op (just store for type checking later)
- [ ] `Resume` inside `fn` handler → error (not valid for `fn` effects)

**Verification:** `cargo test effect_log` passes.

### Phase 3: `ctl` Effects — Single Resume (3-5 days)

**Goal:** `yield.cx` passes. This is the hard phase.

- [ ] Add `ctl_handlers: Vec<CtlHandler>` to `EvalCtx`
- [ ] Add `Suspend` variant to `ExecResult`
- [ ] In `eval_expr` for `Call`: check `ctl_handlers` before env lookup
  - If found, return `Err` or `Suspend` variant that propagates up
- [ ] In `eval_stmts`: intercept `Suspend` result, find matching handler
  - Capture remaining stmts as continuation
  - Run handler body with params bound to args
  - When `Resume(expr)` is hit: evaluate expr, re-enter continuation
- [ ] Propagate `Suspend` through all `eval_stmt` arms:
  - `Block` — capture remaining siblings
  - `WhileLoop` — capture loop re-entry
  - `ForEach` — capture iteration re-entry
  - `If` — capture branch completion
  - `FnDecl` body — propagate up through call boundary
- [ ] `WithCtl` → push handler onto stack, eval remaining stmts, pop handler

**Key challenge:** Getting `Suspend` propagation right through nested eval calls. Every `eval_stmt` arm that contains sub-statements must handle the `Suspend` case.

**Verification:** `cargo test effect_yield` passes.

### Phase 4: `ctl` Effects — Multi Resume (2-3 days)

**Goal:** `flip.cx` passes.

- [ ] Make continuations cloneable (they're just stmt IDs + Rc env — already cheap)
- [ ] When handler body has multiple `Resume` calls:
  - Each `resume` gets its own clone of the continuation
  - First resume runs to completion
  - Second resume runs its clone to completion
  - Handler body completes after all resumes finish
- [ ] Test with `flip.cx` — should print both "Heads!" and "Tails!"
- [ ] Test with nested effects (yield inside flip, etc.)

**Verification:** `cargo test effect_flip` passes.

### Phase 5: Type System Integration (3-5 days, can be parallel with Phase 3)

**Goal:** Effect rows in types, basic validation.

- [ ] Add `EffectRow` to `Type::Func`: `Func { params, ret, effects: EffectRow }`
- [ ] Type check: handler signatures match effect declarations
- [ ] Type check: `resume` value type matches operation return type
- [ ] Error messages for unhandled effects
- [ ] Error messages for `resume` outside handler

**Verification:** Type checker catches mismatched handler signatures.

### Phase 6: Polish & Edge Cases (2-3 days)

- [ ] Nested handlers (yield inside yield with different handlers)
- [ ] Handler shadowing (second `with ctl yield` replaces first)
- [ ] Effects crossing function boundaries (yield inside fn called from handler scope)
- [ ] Error: `resume` outside handler context
- [ ] Error: calling `ctl` op with no handler installed
- [ ] Good error messages with line numbers

---

## Effort Summary

| Phase | Duration | Dependencies |
|---|---|---|
| Phase 1: Pipeline plumbing | 1-2 days | None |
| Phase 2: `fn` effects | 1 day | Phase 1 |
| Phase 3: `ctl` single resume | 3-5 days | Phase 1 |
| Phase 4: `ctl` multi resume | 2-3 days | Phase 3 |
| Phase 5: Type system | 3-5 days | Phase 1 (parallel with 3-4) |
| Phase 6: Polish | 2-3 days | Phase 4 |
| **Total** | **~12-19 days** | |

### Critical Path

```
Phase 1 (Pipeline) → Phase 3 (ctl single) → Phase 4 (ctl multi) → Phase 6 (Polish)
                    → Phase 2 (fn effects) [parallel, easy]
                    → Phase 5 (Type system) [parallel, independent]
```

Phase 2 is trivially parallelizable. Phase 5 can happen alongside Phase 3-4.

**Realistic calendar time: 3-4 weeks** with single developer, testing included.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `Suspend` propagation through all eval arms | High — must handle every statement type | Systematic: enumerate all `eval_stmt` arms, add `Suspend` handling to each |
| Multi-resume environment corruption | High — resumes share mutable state | Clone env snapshot per resume; verify with flip.cx |
| `Rc<RefCell>` borrow conflicts during resume | Medium — nested borrows could panic | Careful borrow scoping; test with deep call stacks |
| Existing tests break | Medium — new stmt variants need handling everywhere | Run full test suite after each change |
| Performance regression from handler stack checks | Low — only affects function calls | Only check handler stack for unresolved names |

---

## Test Cases

See `tests/effects/` directory. Tests are organized by phase:

### Existing (3 core tests)
- `tests/effects/log/log.cx` — Phase 2
- `tests/effects/yield/yield.cx` — Phase 3
- `tests/effects/flip/flip.cx` — Phase 4

### Additional TDD Tests (in `tests/effects/`)
- `effect_decl_parse` — Phase 1: effect declaration parses
- `with_fn_parse` — Phase 1: with fn handler parses
- `with_ctl_parse` — Phase 1: with ctl handler parses
- `fn_shadow` — Phase 2: second with fn shadows first
- `fn_scoped` — Phase 2: handler only active in scope
- `yield_nested_fn` — Phase 3: yield from inside called function
- `yield_in_while` — Phase 3: yield inside while loop
- `ctl_no_resume` — Phase 3: handler that doesn't resume (aborts continuation)
- `resume_with_value` — Phase 3: resume passes value back to call site
- `nested_effects` — Phase 4: multiple different effects active
- `multi_resume_accumulate` — Phase 4: collect results from multiple resumes
- `effect_across_functions` — Phase 3: effect crosses function call boundary
- `handler_override` — Phase 3: inner handler shadows outer for same op

---

## Three Core Test Cases Explained

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

### yield.cx — Generator Pattern

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

### flip.cx — Backtracking

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
