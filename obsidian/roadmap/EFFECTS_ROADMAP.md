# Cronyx Algebraic Effects — Implementation Roadmap

**Status:** Complete through interpreter integration. Effect row type inference is the next major milestone.  
**Last Updated:** 2026-04-24  
**Owner:** Brendan  
**Target:** Koka-style effects with row polymorphism + selective CPS

---

## What Is Implemented

Algebraic effects are fully working in the interpreter via selective CPS transform:

- **Effect declarations** — `effect name { fn op(params): ret; ctl op(params): ret; }`
- **Run-handle blocks** — `run { body } handle effect_name { fn op(params) { ... } ctl op(params) { ... resume; ... } }`
- **Named handlers** — `handle name { ops }` + `run { body } with name`
- **fn effects** — transparent function replacement; no CPS, no effect row entry
- **ctl effects** — CPS transform, continuation passed to handler; `resume` resumes computation
- **Multi-resume** — handler can call `resume` multiple times (backtracking)
- **Lambda-captured resume** — `resume` inside a closure captures the continuation lexically, enabling deferred execution and cooperative scheduling
- **Multi-handle** — `run {} handle eff1 {} handle eff2 {}` — multiple simultaneous effects
- **Effect inference** — `typeof(f)` shows `(params) -> ret <yield>` for functions performing `ctl` ops
- **Unhandled effect detection** — calling a `ctl` op with no active handler is a compile error

See `tests/effects/` for working examples:
- `log`, `ask` — fn effects
- `exception`, `recover` — ctl with no/single resume
- `flip`, `logic` — multi-resume backtracking
- `handler`, `stream` — named handlers
- `async` — cooperative scheduler via lambda-captured resume
- `multi_handle` — two simultaneous effects

---

## What Is Not Yet Implemented

### Effect Row Type Inference

Function types should include an effect row: `(int, int) -> unit <yield>`. The type checker infers `<yield>` from function bodies and propagates it transitively. This is separate from the interpreter's effect tracking — it's a compile-time check.

`typeof(f)` already shows effect rows for functions that directly or transitively call `ctl` ops. Full enforcement (rejecting unhandled ctl effects at the call site) is still ahead.

See `docs/Effect Typing.md` for the full design.

### Row Polymorphism

Higher-order functions that take effectful callbacks should propagate the effect row:

```cx
fn map(f: (a) -> b <E>, xs: [a]): [b] <E>
```

`E` is a row variable. Full row polymorphism requires extending the type unification algorithm.

See `docs/EFFECTS_WITH_ROW_POLYMORPHISM.md` for the design.

### Effect Annotations in Function Signatures

```cx
fn range(low: int, high: int): unit <yield> { ... }
```

Effect row annotations on function declarations are parsed but not yet enforced. The `<yield>` postfix is currently syntax sugar; the type checker does not validate that the declared row matches the inferred row.

---

## Next Steps

1. **Effect row unification** — extend `type_subst.rs` to unify effect rows alongside type variables
2. **Annotation enforcement** — validate declared rows against inferred rows in `runtime_type_checker.rs`
3. **Row variables** — add `EffectVar` to `EffectRow` for polymorphic propagation through HOFs
4. **LLVM codegen** — effects in compiled targets (complex; requires CPS in codegen)
