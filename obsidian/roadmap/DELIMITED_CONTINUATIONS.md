# Delimited Continuations — Implementation Roadmap

**Status:** Phase 2 complete — selective CPS transform implemented  
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

The test `effects::assert_fn` now passes after the selective CPS transform was implemented.

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

### Phase 1 — Mark ctl-performing functions ✅

Identify which functions call `ctl` ops (directly or transitively). Implemented in `src/semantics/cps/effect_marker.rs`.

- [x] Phase 1: collect ctl op names from `EffectDecl` nodes
- [x] Phase 2: detect functions with sequential top-level ctl calls (excluding loops)
- [x] Phase 3: transitive closure — functions that call CPS functions are also CPS

### Phase 2 — CPS Transform ✅

Transform every CPS-candidate function at the AST level before interpretation. Implemented in `src/semantics/cps/cps_transform.rs`, wired in `main.rs` and `tests/script_integration.rs`.

#### 2.1 — Continuation representation ✅

Continuations are `RuntimeExpr::Lambda` nodes (new AST variant) converted to `Value::Function` at runtime.

#### 2.2 — Transform function signatures ✅

`__k` parameter appended to each CPS-candidate function. At call sites, a lambda wrapping the remaining statements is passed as the final argument.

#### 2.3 — Transform ctl op calls ✅

Each sequential ctl op call in a CPS function body is lifted into a nested lambda:
```
choose(list1, fn(choice1) {
    // ... rest of body ...
})
```

#### 2.4 — CPS handler dispatch ✅

Handlers detect CPS-mode by argument count (`args.len() == params.len() + 1`). When in CPS mode, the extra arg is pushed onto `cps_continuations`. `resume x` calls that continuation with `x`.

#### 2.5 — Transform call sites of CPS functions ✅

Top-level calls to CPS functions also get a continuation lambda wrapping the remaining statements.

#### 2.6 — `return` rewriting ✅

`return x` inside a CPS function body becomes `__k(x)`. Fall-through appends `__k(unit)`.

### Phase 3 — Interpreter changes (hybrid complete)

The interpreter uses a **hybrid approach**: CPS-transformed functions use the `cps_continuations` stack; top-level ctl calls and ctl calls inside loops still use the replay-stack. Both coexist.

- [x] `cps_continuations: Vec<Value>` stack in `EvalCtx`
- [x] CPS handler dispatch (arg-count detection)
- [x] `resume x` in CPS mode calls `call_value(cont, x)`
- [x] `call_value` helper for invoking `Value::Function` closures
- [ ] **Future**: remove replay-stack once all ctl paths go through CPS (Phase 4)

### Phase 4 — Remove replay-stack code (future)

After all ctl uses are CPS-transformed (including loops):

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
| `assert_fn.cx` ✅ | Two `choose` ops inside a function, pruned by `assert` | `3\n5` |
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
