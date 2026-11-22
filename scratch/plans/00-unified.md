# Unified plan: implementing CPS Migration.md

Scope: `internal-docs/CPS Migration.md` only. Sources: `01-metaprocess-core.md`,
`02-reflection-splice.md`, `03-effects-transform.md`, `04-migration.md` (all in this
directory, all against `main` at d418029). This file decides the order and settles where
those plans disagree. The detail stays in each source plan, and every step below names the
source step it comes from.

Delivery: one branch, one big change (memory: one big PR while 0.0.x). Every step ends with
`dune build` passing. `dune test --force` is green except for fixtures that are deliberately
in `expected_failing` and name the step they wait on (CLAUDE.md).

## Where the plans disagree, and the resolution

| Topic | Plans | Resolution |
|---|---|---|
| Order of reflection work | 02 steps 1-8 build on today's walk; 01 S4 replaces that walk | Core first (01 S1-S9), then 02 rebased onto the fused walk. Building 02 on the old walk would mean writing it twice. 02 step 1 (syntax only) can go early, because it touches no walk code. |
| The `return (x) { … }` clause on `run` | 03 D3 keeps it as the terminal continuation; 04 A6 deletes it | **Delete** (04 A6). CPS Migration.md has no return clause, and the scope is that document. The 4 fixtures that use it fold the clause into the run's tail. |
| The old effects backend during core work | 01: CPS stays in `Compile.back` until the transform exists | Keep it. `cps.ml` and the old effect syntax run unchanged through Phase A, so every effect fixture stays green while the core changes underneath. |
| Dual-mode parser (03 S3) vs bridge (04 step 4) | Both put the new syntax onto the old backend for a while, to check the rewrite | **One mechanism: 03 S3-S6 dual mode is the bridge.** It lives only in this branch's history, and no shipped commit has both syntaxes, so it is not the compatibility sugar the user ruled out. It lets the mechanical rewrite be checked against unchanged `.txt` files before the backend is replaced. |
| Naming the continuation in migrated code | 04 A2: `resume`; 03 S9 script: `k` | **`resume`** (04 A2). `k` collides at `stdlib/async/Task.cx:309`, and `resume x;` → `resume(x);` is the smallest diff. |
| `final ctl` | 03 D9 and 04 A3 | Agree: `@ctl fn op<T>(…): T`. This keeps the fresh result type at each call site, but loses the cheap unwind. 03 S11 measures the cost, and over ~3x compile time is a stop. |
| "hooks" in plan 01 §2.3 | — | This is an OCaml callback record between `Typecheck` and `Metaprocess`, inside the compiler. It is **not** the compiler calling library code on a condition (memory: no-hooks). Rename it `walk` / `Walk_ops` in code so the word doesn't appear. |
| `str(E)` in the doc's EffectHandler block | 02 T7: does not check, because a type param is not a value in a meta block | DONE (review after): the doc example now reads `fail("not a trait, so it has no operations to handle")`. |
| Named handlers for `@ctl` effects | Design: generic in R; 04 A7: `impl EffectHandler<E, unit>` | Use the design (generic in R) where it works. Use A7's `unit` for the 2 named handlers whose arms fall off their end without a value. |

## Questions that change the base (asked one at a time; defaults below if not asked)

- **U1 (03 Q1) REPLACED 2026-11-22 by (b), the Koka model:** a function whose type has a
  `@ctl` effect takes the handler and its continuation as parameters, wherever it is written
  (a built-in rule), so higher-order callees are processed once and lists of tasks work.
  Specializing at the key is the fast path where a run sees the code and the handler. See
  review-later R1. The text below is the superseded decision.
- **U1 (03 Q1) was:** (a). A function argument whose row holds an effect the callee binds
  in a run is part of the key: its code is static and its captures are a value, mirroring the
  handler rule. This covers `__root`, `attempt`, `iterator`, `block_on` and `spawn`. (c) is
  **deferred**: lists of tasks (`Task.all`, `race`, `scope.start`) go in `expected_failing`
  waiting on "dynamic capture for stored tasks", to be decided after the base is green, as (c)
  versus a redesign around static arguments.
- **U2 (03 Q2) DECIDED:** honest rows, `resume: (A) -> <ρ> R`. Stored continuations write
  their row. `abort_after_resumption` is rewritten to drain inside the Error run (the doc is
  updated to match).
- **U3 (02 Q1) DECIDED:** (a). `gen f(x)` evaluates the call when f's declared return type is
  a syntax type (Expr, Stmt, Decl, MethodSig, TypeExpr, or a List of one), and emits that value.
  Otherwise it emits the call as written, as today.
- **U4 (01 Q1) DECIDED (review after):** (a). A static param that appears only inside an
  effect label's arguments defaults to `unit` when nothing settles it. Anywhere else, an
  unsettled param is an error.

Defaults taken without asking (80% rule):
- A key is settled at the call, strictly (01 Q2 a).
- Plain generic types stay parametric; functions and methods are instances (01 Q3 / D1).
- A trait instance may keep a param open, `EffectHandler<Effect, _>` (02 Q2 a).
- `run<R>` may omit `<R>`, which is inferred, or `unit` for a statement run (04 A1, 03 D8).
- `handle<E>` on a generic effect settles E's arguments from the body's row (04 A4).
- Untyped params of a handler or impl method take the trait's types (04 A5).
- Lowercase effect names are kept (04 A8).
- A trait-object method that performs a bound `@ctl` effect is rejected for now
  (`methods/suspending_receiver`, `core/traits/dyn/effect_resumes` → `expected_failing`) (03 D6).
- Discontinue insertion is syntactic: an arm that never names its continuation gets
  `discontinue(k)` (03 D7).
- Display/Debug impls stay rooted for every type the program constructs, until Display is static (01 D6).

## Phase A: Metaprocess core (plan 01)

Old effects run through `cps.ml` throughout. The target is green at the end of each step.

1. **A1 = 01 S1** Session split; `Typecheck.nested`; keep `Types.counter` monotonic (01 T1).
2. **A2 = 01 S2** C-style `for` lowered in the Parser (`lower.ml`). Round-trip temp names (01 T8).
3. **A3 = 01 S3** Typecheck over surface syntax; desugar.ml deleted.
4. **A4 = 02 step 1** Syntax only for `Declof`, `Meta_expr`, `Trait_members`, `@ctl` on trait
   methods, `run<R>`, `handle<E>`, `with T`, `discontinue(k)`, and call-style `resume(x)`. New
   nodes are rejected at their span until their step lands. The round-trip fixture is extended.
   (This merges 02 step 1 and the parse half of 03 S3.)
5. **A5 = 01 S4** The fused walk: `Key`, `Decl`, instance and cache; the call branch for calls,
   static calls and methods; implicit static params (D4); strict-at-call keys; the recursion
   rule. **Before it lands:** run the 01 T9 probe for recursion with no written return type, fix
   those fixtures (04 step 7 list), and remove the 3 non-terminating fixtures
   (`polymorphic_recursion`, `unspecializable_*`), which would hang the watchdog.
6. **A6 = 01 S5** Expected types. New fixtures `tests/types/expected/*`, taken from the doc's
   examples.
7. **A7 = 01 S6** Resolve folded into the call branch (operators, index, compound, literals,
   trait-object tables); resolve.ml deleted.
8. **A8 = 01 S7** Type_mono, `lift_comptime` lifting and the separate comptime path deleted.
9. **A9 = 01 S8** Prune by reference; plain impls no longer always included; D6.
10. **A10 = 01 S9** Meta blocks processed in the walk; `Typecheck.nested` and `meta_program`
    deleted. U4's default goes in here at the latest.

## Phase B: Reflection and Splice (plan 02, rebased on the fused walk)

11. **B1 = 02 step 2** `splice.ml`: generated code collected as fragments, one `fit` function
    placing them by context; `gen code(…)` fixed.
12. **B2 = 02 step 3** `meta` as an expression: exactly one expression fits, and misfits are
    errors at Splice.
13. **B3 = 02 step 4** `gen` of a value (per U3) and of a `MethodSig`.
14. **B4 = 02 step 5** Meta blocks in trait bodies, per instance, with open params.
15. **B5 = 02 steps 6-7** `declof(f<key>)` through the decl cache (a use that doesn't count
    toward Prune), `declof` of a static param, and `declof` by `Name` from inside a meta block.
16. **B6 = 02 steps 8-9** `EffectHandler` end to end on direct calls; `typeof` as a value,
    spliced; reflect.ml deleted, so no reflection node survives into the processed tree.

## Phase C: Effects and the transform (plan 03), with the migration (plan 04)

17. **C1 = 03 S0** New-syntax fixtures in `tests/effects/v2/`, `expected_failing`.
18. **C2 = 03 S1-S2** Built-ins: tail calls for every closure, and the discontinue signal.
19. **C3 = 03 S4-S5** Traits as effects (receiverless op calls, rows of trait labels, `final ctl`
    → `<T>`), `handle<E>` as an anonymous type, `with`, the two-handlers error, and captured
    state as a value.
20. **C4 = 03 S6** Unmarked ops bound through the key (`H.op(hv, …)`), with no rewrite.
21. **C5 = 03 S7** `effect_transform` core in `stdlib/effects/Transform.cx`, one fixture family
    at a time.
22. **C6 = 03 S8** Composition and control: honest rows (U2), arms transformed by outer runs,
    discontinue insertion, defers, returns that cross a run, in-region function values.
23. **C7 = 03 S9 + 04 steps 2-5** Function values from outside the run (U1). Then the
    migration: `scratch/migrate/rewrite.py` (rules R1-R8, run with `resume` as the
    continuation name), the hand edits (about 25 fixtures, 30 `.err` files, Task, Timer, Yield,
    the prelude, the cx packages), and the bridge check that `.txt` files are unchanged.
24. **C8 = 03 S10 + 04 steps 6-8** cps.ml, the old effect AST, the old keywords and parser paths,
    and the interpreter's scopes deleted. `v2/` moved into place. Error wording regenerated and
    reviewed.
25. **C9 = 03 S11 + 04 step 9** Measure compile time (stop if over ~3x). Full green:
    `dune test --force`, `dune test cx`, `./scripts/cx-parity.sh`.
26. **C10 = 04 step 10** `docs/` user pages and the editor keyword lists. The internal-docs
    rewrites (Algebraic Effects.md, Continuations and Tasks.md, Async.md, Architecture.md,
    Metaprocessing.md, Type System.md) and CLAUDE.md's "CPS is selective" paragraph are listed
    for the user, not edited unasked.

## Biggest risks (from all four plans)
- 01 T2/T3/T4: block-exit scoping wiping registered declarations, local types shared across
  instances, and zonk timing. These are the bugs most likely to cost hours in A5.
- 01 T5 / 03 M2: rows used as keys must close their tail by unification, or callee and caller
  disagree about evidence.
- 03 Q1/U1: every program runs through a function value. Until U1 lands, `__root` keeps the old
  path. Phase C cannot finish without it.
- 03 §10: an interpreted transform runs on every throwing function, which is a compile-time risk.
- 02 T3: `emit_into`'s collector is re-entered by every new `run_meta` caller.
