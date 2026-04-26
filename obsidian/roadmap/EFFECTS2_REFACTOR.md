# Effects Syntax Refactor

**Status:** Complete  
**Last Updated:** 2026-04-24  
**Owner:** Brendan

---

## Summary

Replaced the effects1 syntax (`handle {} with {}`, `with fn`, `with ctl`) with a cleaner syntax that is more explicit, supports named reusable handlers, and enables cooperative scheduling via lambda-captured continuations.

All effects1 tests and source files have been removed. The `tests/effects2/` directory has been renamed to `tests/effects/`.

---

## Syntax

### Run-handle block

```cx
run { body } handle effect_name {
    fn op(params) { ... }
    ctl op(params) { ... resume; ... }
}
```

Multiple effects chained:

```cx
run { body }
    handle logger { fn log(msg) { print(msg); } }
    handle counter { ctl tick() { print("[TICK]"); resume; } }
```

### Named handler definition

```cx
handle name {
    ctl op(params) { ... }
}
```

### Run with named handler

```cx
run { body } with handler_name
```

### Lambda-captured resume

`resume` inside a lambda closes over the handler's continuation at creation time. When called later — even outside the handler — it resumes the suspended computation.

```cx
ctl tick() {
    queue.push { resume; };   // thunk closes over continuation
    dequeue();
}
```

---

## Milestones (all complete)

- [x] M0 — Prerequisites (test data, bug fixes)
- [x] M1 — `run {} handle eff {}` with fn ops (`effects/log`, `effects/ask`)
- [x] M2 — ctl ops in RunHandle, no-resume + single-resume (`effects/exception`, `effects/recover`)
- [x] M3 — multi-resume (`effects/flip`, `effects/logic`)
- [x] M4 — named handlers (`effects/handler`, `effects/stream`)
- [x] M5 — lambda-captured resume, cooperative async scheduling (`effects/async`)
- [x] M6 — cleanup: remove effects1, rename effects2 → effects, multi-handle test

---

## Removed (effects1)

| What | Why |
|------|-----|
| `with fn op() {}` statement form | Replaced by `fn op(params) {}` inside `run {} handle eff {}` |
| `with ctl op() {}` statement form | Replaced by `ctl op(params) {}` inside handler blocks |
| `handle { body } with { ops }` expression | Replaced by `run { body } handle eff {}` |
| `MetaExpr::Handle` AST node | Superseded by `MetaExpr::RunHandle` |
| `StagedExpr::Handle` AST node | Superseded by `StagedExpr::RunHandle` |
| `tests/effects/` directory (old) | All effects1 source files removed |
| `mod effects { ... }` in test runners | Replaced by `mod effects { ... }` using new paths |
| `tests/compile/m8–m12/` | Effects1 compile tests removed |

## Still Present (effects infrastructure)

`MetaStmt::WithFn` and `MetaStmt::WithCtl` remain — they are the op node types inside handler blocks, now only appearing nested within `RunHandle` blocks, not as standalone top-level statements.

---

## TODO (future work)

- Port `tests/effects/unhandled_*` (unhandled effect error cases) as interpreter error tests once the error test infrastructure supports them cleanly
