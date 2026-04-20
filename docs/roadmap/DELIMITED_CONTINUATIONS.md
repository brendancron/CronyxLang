# Delimited Continuations — Implementation Roadmap

**Status:** Not started  
**Last Updated:** 2026-04-20  
**Owner:** Brendan  
**Depends on:** EFFECTS_ROADMAP Phase 2 (Selective CPS Transform)

---

## Problem

The current `ctl` handler implementation uses a **replay-stack** approach. When a `ctl` op is called, the interpreter:

1. Runs the handler body in "collection mode" to gather all `resume` values
2. Returns `Err(CtlSuspend { op_name, resume_values })` to bubble up
3. `eval_stmts` catches the error and replays `stmts[i..]` once per resume value
4. On each replay the op call hits `replay_stack` and returns the pre-decided value

This works when ctl ops appear at **separate statement positions** in a linear sequence. It breaks when multiple ctl ops of the same name are called within a single expression or function call.

### Failing Example

```
fn find_matching(list1, list2) {
    var choice1 = choose(list1);   // ctl op #1
    var choice2 = choose(list2);   // ctl op #2
    assert(choice1 == choice2);
}

var result = find_matching([1,2,3,4,5], [3,5,7]);
print(result);
```

Both `choose` calls are inside `find_matching`. When `choose(list1)` fires, the `CtlSuspend` bubbles all the way to the top-level `eval_stmts`. The inner replay (for `choose(list2)`) then re-runs `find_matching(...)` from the beginning, where `choose(list1)` consumes the replay value meant for `choose(list2)`.

Expected output (correct delimited continuations): two surviving branches — `choice1=3,choice2=3` and `choice1=5,choice2=5`.

Actual output: no output (all branches pruned due to wrong value routing).

The test `effects::assert_fn` is `#[ignore]`-d until this is fixed.

---

## What True Delimited Continuations Require

The continuation captured at a `ctl` call site must include **everything that comes after that call**, not just the remaining top-level statements. In `find_matching`, the continuation at `choose(list1)` is:

```
[bind result to choose(list1) value]
→ var choice2 = choose(list2)
→ assert(choice1 == choice2)
→ [return from find_matching]
→ var result = <return value>
→ print(result)
```

This is precisely what a **CPS transform** produces. After CPS, `choose(list1)` passes the rest of `find_matching`'s body (plus the call site suffix) as a continuation closure to the handler. The handler calls that closure for each resume value, giving full backtracking.

---

## Implementation Plan

### Phase 1 — Mark ctl-performing functions

Identify which functions call `ctl` ops (directly or transitively). This is the effect inference step already planned in EFFECTS_ROADMAP Phase 1.

- [ ] **`effect_set: HashSet<String>`** per function in `TypeEnv`
- [ ] Walk call graph to propagate effects transitively
- [ ] Functions with `ctl` effects in their effect set are **CPS candidates**

### Phase 2 — CPS Transform

Transform every CPS-candidate function at the AST level before interpretation.

#### 2.1 — Continuation representation

A continuation is a `Value::Closure` that takes one argument (the resumed value) and runs the remaining computation.

```rust
Value::Closure {
    params: vec!["__resume_val".into()],
    body: ...,  // stmt id of the remaining body
    env: captured_env,
}
```

#### 2.2 — Transform function signatures

Add an implicit `__k: Continuation` parameter to each CPS-candidate function:

```
fn find_matching(list1, list2)
// becomes:
fn find_matching(list1, list2, __k)
```

`__k` is the continuation that receives the function's return value.

#### 2.3 — Transform ctl op calls

A call `var choice1 = choose(list1)` inside a CPS function becomes:

```
choose(list1, fn(__resume_val) {
    var choice1 = __resume_val;
    // ... rest of the function body ...
})
```

The second argument is a continuation closure. The handler receives it and calls it once per `resume` value.

#### 2.4 — Transform `resume` in handlers

Inside a `with ctl choose` handler, `resume x` becomes `__cont(x)` — calling the continuation with value `x`. Multi-resume = calling `__cont` multiple times.

#### 2.5 — Transform call sites of CPS functions

When calling a transformed function, pass the current continuation:

```
var result = find_matching(list1, list2)
// becomes:
find_matching(list1, list2, fn(result) {
    print(result)
})
```

#### 2.6 — Transform control flow within CPS functions

- **`if`/`else`** — both branches receive the same continuation
- **`for` loops** — the loop body's continuation is the "next iteration" plus the post-loop code; simplest to convert loops to recursive functions
- **`return`** — becomes a tail call to `__k`
- **`block`** — thread continuation through each statement sequentially

### Phase 3 — Interpreter changes

The interpreter mostly stays the same. Handlers now receive an explicit continuation argument instead of using the implicit resume mechanism.

- [ ] **Remove `collecting_resumes` / `CtlSuspend` / `replay_stack`** from `EvalCtx` — these are no longer needed
- [ ] **`eval_stmt(Resume { value })` in handler** → call the `__cont` closure from the handler's env with `value`
- [ ] **`eval_stmt(WithCtl)` setup** → install handler into env (same as `WithFn` today)
- [ ] **Multi-resume** → handler body can call `__cont` multiple times naturally

### Phase 4 — Remove replay-stack code

After CPS is working:

- [ ] Remove `CtlSuspend` error variant
- [ ] Remove `MultiResumed` error variant  
- [ ] Remove `replay_stack`, `collecting_resumes`, `collected_resumes` from `EvalCtx`
- [ ] Simplify `eval_stmts` (no more special `CtlSuspend` catch arm)

---

## Key Invariants After CPS

- A `ctl` op call **never propagates as an error**. It calls the handler directly, passing a closure.
- `resume x` inside a handler calls the closure with `x`. Multi-resume = multiple closure calls.
- Functions with no `ctl` effects are unchanged (no CPS overhead).
- Continuations compose: nesting two multi-resume handlers (like `choose` + `assert`) works because each is just a function call with a closure.

---

## Test Cases to Validate

| Test | Description | Expected output |
|---|---|---|
| `assert_fn.cx` | Two `choose` ops inside a function, pruned by `assert` | `""` (two unit prints, both branches) |
| `yield_nested_fn.cx` | Already passes — regression test for CPS |  |
| `flip.cx` | Multi-resume, already passes — regression test | `Heads!\nTails!` |
| Future: deeply nested `ctl` calls | Effects across 3+ function levels | TBD |

---

## Risks

| Risk | Mitigation |
|---|---|
| CPS transform correctness for loops | Convert `for` loops to recursive functions first; optimize later |
| Closure capture of mutable env | CPS closures must capture env snapshot, not reference — verify by test |
| Regression on existing ctl tests | Keep replay-stack path as fallback during transition; run full suite |
| Performance — every CPS call allocates a closure | Accept for correctness first; optimize with stack allocation later |
