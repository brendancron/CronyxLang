# 04 — Migrating stdlib and fixtures to the CPS Migration syntax

Scope: `internal-docs/CPS Migration.md` only, as recorded in `scratch/ctl-as-function.md`
("no compatibility sugar": `effect`, `ctl`, `final ctl`, `resume x;`, `handler n : E`,
`with name` are all rewritten in this one change). Counts come from a comment- and
string-aware scan (brace matched) over `stdlib/`, `tests/`, `cx/test/`, `benchmarks/benches/`,
`examples/`. `examples/` has none. `docs/` is not tested (only `deploy-docs.yml` builds it).

## 0. Assumptions this plan makes (each needs a yes before the script runs)

| # | Assumption | Why it matters |
|---|---|---|
| A1 | `run<R>` may omit `<R>`. Omitted, R is the body's value type, and unit for a run used as a statement (the parser already drops a statement run's value, `parser.ml` `run_stmt`). The design writes `run { greet("ada"); } handle<Console>` with no `<R>`. | 243 of 251 runs are statements. Only the 8 runs in value position get `<R>` written, by hand. |
| A2 | The rewrite names the continuation `resume`, since the name is free. | `resume x;` becomes `resume(x);`, the smallest possible diff. No file uses `resume` as an identifier, because it is a keyword today. `k` would collide: `stdlib/async/Task.cx:309` already binds a lambda param `k` inside the `suspend` arm. |
| A3 | A `final ctl op(...)` with **no** written result becomes `@ctl fn op<T>(...): T`. One with a written result keeps it. | `final ctl`'s fresh result type per call site (`Algebraic Effects.md` ~117-130) is relied on at **66 `return throw(…)` sites in 17 files** (13 stdlib: Error, File, Net, Process, Cli, Udp, Json, Toml, Codec, Base64, Hex; plus `tests/core/builtins/conversions.cx` `return invalid(…)`, `tests/effects/final/{abort,in_loop,errors/resumes}.cx`, `tests/core/defer/defer_effect.cx`). With `<T>` they still check. A statement call `throw(e);` leaves T unsettled, so this needs the defaulting that `tests/effects/generic/unconstrained_at_call` already relies on. The handler method becomes `fn throw<T>(err: X, resume: (T) -> R): R`. It cannot call `resume`, because it has no T to pass, which is what `final ctl` promised. |
| A4 | `handle<E>` for a generic effect settles E's arguments from the body's row, as the arms settle them today. The alternative is to write `handle<Throw<IoError>>` by hand. | There are **50 handle sites in 30 files** on a generic effect (Throw 34, Yield 14 incl. local same-name, Fallible 4, Feed 3, Store 1). Without A4 every one of them, including all 13 in WebSocket.cx and Http.cx, is a hand edit, and `declof(Throw)` with no arguments is an error. |
| A5 | In a `handle<E>` block, and in an `impl` of a trait, an untyped method parameter takes the trait's type. It is not an implicit static param. Neither are the op's own static params (`suspend<T>`). | The design's own examples write `fn log(msg)` and `fn choose(options, k)`. All 247 inline arms leave their types unwritten, except 5 (`arm_param_annot`). |
| A6 | The `return (x) { … }` clause on `run` is deleted. Its body is folded into the run's tail. | The design has no return clause. It is used by 4 fixtures (§2.6). `ExprKind.Run`'s `Option<ReturnClause>`, `Ast.ret_clause`, `rc_*` and the `run_expr` look-ahead all go. |
| A7 | A named handler is `type X {}` plus `impl E for X` (all `fn` ops), or `impl EffectHandler<E, unit> for X` (some `@ctl` op). It uses the two-declaration form, because the design's `type X impl …` shorthand is a TODO. | The design makes `@ctl` named handlers generic in R, but `logic_handler.choose` and `print_stream.yield` fall off without a value, so they cannot return a generic R. Every named handler runs under a statement run, so `unit` is exact. |
| A8 | Effect names are kept as written, lowercase ones included (`log` ×15, `logger` ×5, `stream`, `logic`, `async` ×4 …). | Renaming changes `.txt` and `.err` text (`<mixed>`, `'logger'`). A trait `log` with a method `log` must still resolve. That is a compiler check, not a rewrite. |

## 1. Inventory

**Totals:** 202 `.cx` files, which are 18 stdlib, 3 cx/test, 2 benchmarks and 179 under tests/.
The tests/ files are 171 fixtures (142 `.txt`, 29 `.err`, 0 `.rt`) and 8 imported helpers.

| Construct | Count | Files | stdlib / tests / cx / bench |
|---|---|---|---|
| `effect` declarations | 205 | 165 | 17 / 184 / 2 / 2 |
| … generic `effect N<P>` | 15 | 14 | Throw, Fallible, Yield / 11 tests / Feed (cx) |
| `ctl` op declarations | 114 | 98 | 8 / 104 / 1 / 1 |
| `final ctl` op declarations (no result: 19, with result: 8) | 27 | 26 | 3 / 23 / 1 / 0 |
| `fn` op declarations | 88 | 65 | 21 / 66 / 0 / 1 |
| ops with own static params (`suspend<T>`, `ask<T>`, `spawn<E>`) | 7 | 7 | Task.cx; 6 tests |
| `run` blocks | 251 | 170 | 25 / 222 / 1 / 3 |
| … in value position | 8 | 8 | tests only (§2.5) |
| … with `return (x) {}` clause | 4 | 4 | tests only |
| `handle E {}` clauses (inline) | 267 | 166 | 35 / 228 / 1 / 3 |
| … on a qualified name (`handle signal.Signal`) | 2 | 2 | handled_in_import/qualified, qualified_op/main |
| runs with >1 clause | 10 | 10 | prelude (9 + 3), wider_row(_nested), multi_handle, map_over_effects, row_extension, suspend_in_resume, fake_net, cli |
| `handler n : E {}` declarations | 7 | 7 | 0 / 5 / 2 / 0 |
| `with name` | 5 | 5 | handler/handler, logic/multi_guard, nested_decls/handler_in_block, stream/stream, errors/unknown_handler |
| arms: `ctl` / `final ctl` / `fn` | 133 / 65 / 114 | 93 / 43 / 64 | stdlib 10 / 19 / 27 |
| `resume x;` / `resume;` | 101 / 31 | 89 | stdlib 10 (prelude 6, Task 2, Timer 1, Yield 1) |
| `discontinue;` | 10 | 7 | Task, Timer, Yield; defer_in_run ×2, discontinue ×2, nested_after_outer, errors/discontinue_outside_ctl ×2 |

Arm kind always equals op kind (132 ctl/ctl, 60 final/final, 112 fn/fn, plus 5 against an
imported `Signal`). The one mismatch is `tests/effects/errors/handler_widens.cx` (a `ctl` arm
for a `fn` op), and the arm keyword therefore maps one-to-one from the op.

**stdlib (18 files):**
- Declarations only: `core/Assert.cx` (Assertion, final), `fs/File.cx` (Fs ctl, Dirs 5 fn),
  `io/Console.cx` (Console, Stdin), `log/Logger.cx`, `net/Net.cx` (4 ctl), `os/Args.cx`,
  `os/Env.cx` (4 fn), `os/Process.cx` (Exit final, Process ctl), `os/Time.cx` (3 fn).
- Declarations and handlers: `core/Error.cx` (Throw final, Fallible fn; `attempt`),
  `async/Task.cx` (async: `ctl suspend<T>` + 3 fn; 4 runs; `discontinue`; resume in lambdas),
  `iter/Yield.cx`, `random/Random.cx`.
- Handlers only: `async/Timer.cx` (2), `net/WebSocket.cx` (8 Throw), `net/Http.cx` (5 Throw),
  `test/Test.cx` (Assertion), `prelude.cx` (`__root`: 2 runs, 12 clauses, 6 resumes).
- Untouched, though they lean on A3: Json, Toml, Codec, Cli, Udp, Base64, Hex (`return throw(…)`).

**tests/ by directory (files):** effects/errors 19, effects/generic 14, effects/fn_values 11,
effects/rows 9, core/defer 7, core/traits 7, effects/run_value 6, stdlib/net 6, stdlib/os 5,
effects/nested_control 4, stdlib/async 4, stdlib/io 4, reflection/typeof_effect_* 4,
effects/final 3, effects/handled_in_import 3, effects/handler 3, effects/match 3, about 40 more
single-file dirs under effects/, and meta/syntax 2 and meta/moduleof 2.
**cx/test:** `library/Ops.cx` (Feed<T> plus `handler empty`), `packages/documented/app/src/ink.cx`
(Missing final plus `handler quiet`), `packages/logged/tests/logging.cx` (handle Logger).
**benchmarks:** `benches/effects.cx` (Ask fn, Yield ctl), `benches/calls.cx` (handle Throw).

## 2. Patterns: the mechanical rewrite, then the cases that are not mechanical

### 2.1 Effect declaration → trait (205 decls)
`effect N<P> {` → `trait N<P> {`; `fn op…;` is unchanged; `ctl op` → `@ctl fn op`; `final ctl op(..);` →
`@ctl fn op<T>(..): T;` (A3, 19 ops) or `@ctl fn op(..): R;` when written (8 ops). Doc comments
and attributes above an op stay above it, and `@ctl` goes last: `/** … */ @cheap @ctl fn next(): int;`
(`tests/core/syntax/doc_comment.cx:39`). From `stdlib/async/Task.cx:29`:
```cronyx
effect async {                                             trait async {
    ctl suspend<T>(register: ((T) -> unit) -> unit): T;  →     @ctl fn suspend<T>(register: ((T) -> unit) -> unit): T;
    fn waker(): (() -> unit) -> unit;                          fn waker(): (() -> unit) -> unit;
```
`stdlib/core/Error.cx:44`: `final ctl throw(err: X);` → `@ctl fn throw<T>(err: X): T;`. Check
for a T clash with the effect's own params: `Fallible<T>` has only a `fn` op, so none occurs.
Edge cases:
- 1 `ctl` op has no result type. Under traits a missing result is `unit`, which matches today.
- A `final ctl` op whose result is written as `unit` or `int` (`stop(): unit` ×3, `stop(): int`,
  `halt(): int`, `bail(): int`, `fail(): unit` ×2) keeps that result. Grep the call sites. Any
  that use it at another type (`return stop();` in a non-int fn) break. The scan found none.
- `tests/effects/errors/duplicate_operation.cx`: a duplicate op becomes a duplicate trait method.
  Its diagnostic moves to the trait checker's wording.

### 2.2 Inline handler → `handle<E>` (267 clauses)
`handle E {` → `handle<E> {`; `handle signal.Signal {` → `handle<signal.Signal> {`.
- `fn` arm: unchanged (`fn read_dir(path) { return __read_dir_on_disk(path); }`).
- `ctl op(ps) {` → `fn op(ps, resume) {`, or `fn op(resume) {` with no params.
- `final ctl op(ps) {` → `fn op(ps, resume) {`. `resume` goes unused, and A3 makes calling it
  ill-typed.
- `resume x;` → `resume(x);`, `resume;` → `resume(());`, `discontinue;` → `discontinue(resume);`.

From `stdlib/prelude.cx:62`:
```cronyx
} handle Fs {                                                   } handle<Fs> {
    ctl open(path, mode) { resume __open_on_disk(path, mode); } →   fn open(path, mode, resume) { resume(__open_on_disk(path, mode)); }
```
Under A1 (R = unit for a statement run) this is **exact for every arm of a statement run**. An
arm that falls off after `resume(x);` returns `()`, and `()` is the block's value. An arm that
falls off without resuming aborts with `()`. The scan sorts the 133 `ctl` arms like this:

| Shape | Arms / files | Action |
|---|---|---|
| ends in its only `resume` | 61 / 42 | mechanical |
| ends in `resume`, with other resumes before it (multi-shot) | 8 / 7 | mechanical; flip, multishot_closure, resume_through_run ×2, return_out_of_run, returned_closure, suspend_in_logical_nested, suspend_in_tuple_destructure |
| `resume` then more statements, no `return` | 25 / 23 | mechanical in statement runs; hand edit in `two_runs_one_expr.cx` (2 arms, value position) |
| `resume` only nested (loop, `if`, `match`, closure) | 27 / 22 | mechanical; see the closure list below |
| no `resume` | 12 / 8 | mechanical; 2 of them `return v` in a valued run (§2.5) |

Not mechanical, and to be checked by eye even though the script handles them:
- **`resume` inside a closure (15 sites, 14 files).** The continuation escapes the arm: `pending.push { resume; }`
  → `pending.push { resume(()); }` (`tests/effects/abort_after_resumption.cx:18`,
  `fn_values/{closure_in_arm,suspending_closure,through_index,spawn,nested_spawn}`, `deferred/deferred`,
  `discontinue/nested_after_outer`, `async/{async,interleaved}`, `errors/arm_settles_op_param`,
  `stdlib/iter/Yield.cx:58`, `stdlib/async/Task.cx:206,310`, `stdlib/async/Timer.cx:90`). Each
  stores the closure in a typed slot: `rest: Option<() -> <E> unit>` (Yield.cx), `List<() -> unit>`
  (fixtures), `here.stop: Option<() -> unit>` (Task). **Blocker: the design's `handled()` gives the
  continuation `TypeKind.Function([A], R, [])`, which has no row, but the continuation runs the rest of the
  body and performs whatever the body performs beyond E** (Yield.cx needs `<E>`). `effect_transform`/EffectHandler
  must give `resume` the run body's residual row, or Yield, Task and Timer stop checking.
- **`discontinue` (10 sites).** `abandon = Option.Some(() => { discontinue; });` (Yield.cx:59) →
  `() => { discontinue(resume); }`. `tests/core/defer/defer_in_run.cx:20` reads `ctl ask() { discontinue; print("discontinued"); }`.
  Here the arm runs on after `discontinue(resume)`, so the call returns, which is unchanged. The
  intrinsic's type has to be `((A) -> R) -> unit`, or `-> R` for the arm to return it. Decide which.
- **Multi-shot loops (7 sites, 5 files).** `for (x in options) { resume x; }` → `{ resume(x); }`
  (`core/defer/defer_multishot{,_abort}`, `logic/{multi_guard,simple_guard}`, `multishot_sequel` ×3).
  The results are discarded, R = unit.
- **`resume` with a performing argument.** `tests/effects/suspend_in_resume.cx:21`:
  `resume counted() * 2;` → `resume(counted() * 2);`. The argument performs `Tick`, which an outer
  run handles. The handler method's own row must allow that.
- **An arm that forwards to an outer handler under the same name.** `Task.cx` reads `fn waker() { return waker(); }`
  and has the same for `after` and `when_ready` (and Timer.cx likewise). Inside the method, a bare `waker()`
  must resolve to the op, which the outer handler answers. It must not resolve to the method.
- **The defer and abort semantics of an arm are unchanged textually, but now rest on the transform.**
  `return_past_arm_defer.cx` reads `defer {…} resume 1; print("UNREACHABLE");`, and the body's `return`
  leaves `f`, so the code after `resume(1)` must not run. The fixtures are the spec, so the
  expectation stands.
- **Param annotations on arms (5)** (`handler/handler.cx`, `log/log.cx`, `rows/builtin_in_effectful_fn.cx`)
  are kept. The parser drops them today, and they become real types that must match the trait.

### 2.3 `final ctl` result typing (A3)
`stdlib/core/Error.cx` after the rewrite:
```cronyx
trait Throw<X> { @ctl fn throw<T>(err: X): T; }
fn attempt<X, T, E>(f: () -> <Throw<X>, E> T): <E> Result<T, X> {
    var outcome: Option<Result<T, X>> = Option.None;
    run { outcome = Option.Some(Result.Ok(f())); } handle<Throw> {
        fn throw(e, resume) { outcome = Option.Some(Result.Err(e)); }
    }
```
`rethrow`'s `return throw(e.to());` and the 65 other `return throw(...)` sites need T settled
from the expected type. That is the design's "Expected Types": the return type is passed down.
`tests/core/defer/errors/defer_cannot_fail` asserts "'Throw<string>' never resumes". Nothing
declares that any more, so the check needs a new criterion (any `@ctl` op whose handler never
calls `resume`? any `@ctl` op?). That is an open question, so the fixture's `.err` is reworded
or the fixture is deleted.

### 2.4 Named handlers (7) and `with` (5): hand edits
`tests/effects/handler/handler.cx`:
```cronyx
handler basic_log_handler : log {                       type BasicLogHandler {}
    fn log(msg: string) { print("From handler…" + msg); } →  impl log for BasicLogHandler {
}                                                           fn log(msg: string): unit { print("From handler…" + msg); }
run { greet("Brendan"); } with basic_log_handler;       }
                                                         run { greet("Brendan"); } with BasicLogHandler;
```
`@ctl` effects (`logic/multi_guard.cx` `logic_handler`, `stream/stream.cx` `print_stream`,
`cx/test/library/Ops.cx` `empty : Feed`, `core/syntax/doc_comment.cx` `steady : Feed`):
`impl EffectHandler<logic, unit> for LogicHandler { fn choose(options: Array<int>, resume: (int) -> unit): unit { for (x in options) { resume(x); } } … }`.
`Ops.cx`'s `Feed<T>` is generic, so it is `impl<T> EffectHandler<Feed<T>, unit> for Empty`. Check that
impl generics parse that way. `documented/ink.cx` `quiet : Missing` (final) needs `fn absent<T>(what: string, resume: (T) -> unit): unit`.
`nested_decls/handler_in_block.cx` declares its handler inside `fn main`, so local `type` and
`impl` declarations must be allowed there. If they are not, the fixture moves the handler to the
top level and loses its point, which is a question. `errors/unknown_handler.cx` `with nope` becomes
an unknown type.

### 2.5 `run` in value position (8): hand edits
`tests/effects/run_value/{value,statements_then_value,two_in_one_expr,unit_body,return_clause,arm_answers}.cx`,
`multi_handle/differing_arms.cx`, `two_runs_one_expr.cx`. Write `run<int>`. An arm that resumes and keeps the
value becomes `return resume(x);`. One with statements after it becomes `var r = resume(5); print("a done"); return r;`
(`two_runs_one_expr.cx:7-8`). Expected output is unchanged.

### 2.6 Return clauses (4): hand edits (A6)
`run_value/return_clause.cx`:
```cronyx
var total = run { doubled() } handle Ask {            var total = run<int> { var x = doubled(); x + 1 } handle<Ask> {
    ctl ask() { resume 21; }                       →      fn ask(resume) { return resume(21); }
} return (x) { x + 1 };                               };
```
`run_value/arm_answers.cx` and `multi_handle/differing_arms.cx`: `run<int> { each(); 0 } handle<Yield> { fn yield(v, resume) { return v; } }`.
`run_value/unit_body.cx`: `run<int> { note("first"); note("second"); 7 } … fn note(msg, resume) { print(msg); return resume(()); }`.
In Koka the clause runs outside the handler, and folding it in runs it inside. None of the 4 clause
bodies performs an effect, so the output is the same.

### 2.7 Quoted syntax and reflection (hand edits)
- `tests/meta/syntax/printer.cx:28` quotes `code effect Log { fn log(s: string): unit; ctl ask<T>(): T; }`.
  It becomes `code trait Log { fn log(s: string): unit; @ctl fn ask<T>(): T; }`, and `printer.txt:34-36` changes.
- `tests/meta/syntax/round_trip.cx:11,52-56` (`code effect Log`, and a run/handle in a quoted fn).
- `tests/meta/moduleof/{main,helpers}.cx`: `DeclarationKind.Effect`/`.Handler` arms go.
  `main.txt:6` `effect Log --` becomes `trait Log --`.
- `bootstrap/test/test_bootstrap.ml` `run_round_trip` reprints **every** `cases` fixture through
  `Source.program` and reparses it, so `bootstrap/lib/source.ml` must print `run<R>`, `handle<E>`,
  `@ctl fn` and `resume(x)` before the suite can be green.

### 2.8 Comments and doc examples (hand)
- Fixture comments: 36 lines name old constructs, and 5 files say `ctl`/`resume`/`discontinue`
  (`return_past_arm_defer.cx:1-3`, `final/in_loop.cx:1-2`, `two_runs_one_expr.cx:1-2`, …).
  Per CLAUDE.md, delete them rather than reword them.
- Five print strings name the old words (`abandon_through_run.txt` "stopped through a ctl block", "…final
  ctl block"; `dyn/effect_resumes.txt` "after the resume"). They are cosmetic, so leave them or change
  the `.cx` and `.txt` together.
- stdlib doc comments: `iter/Yield.cx:12` (already stale: `handle Yield<int> {…} with {…}`),
  `io/Console.cx:16-18`, `core/Assert.cx:17-21` ("which is what `final ctl` says"), and
  `core/Error.cx:137` ("an `fn` operation rather than a `ctl` one"). `cx doc` renders these.

## 3. Expected outputs that change

**`.txt` (stdout):**
- `tests/meta/syntax/printer.txt` (Printer.cx output for the trait), `tests/meta/moduleof/main.txt`.
- `cx/test/library/expected.json:608-890` and `cx/test/packages/documented/app/expected.json`. The
  `"kind": "effect"` entries with `"ops"`/`"kind": "ctl"` become `"kind": "trait"` with `@ctl` in
  `attrs`, and `"kind": "handler"` becomes a type plus an impl. They come from `cx/lib/docs.ml:607-680`.
- Everything else in §2 is written to keep its `.txt` byte for byte. That is the check on the
  script: a `.txt` that changes outside this list is a rewrite bug or a semantic change to raise.
- The design's non-effect rules hit these (out of the effect rewrite, but in the same change):
  - "A parameter with no type written is an implicit static param." 42 `fn` definitions in 33
    fixtures have untyped params. Of these, `reflection/typeof_fn.txt` and `typeof_generic.txt`
    (`('a) -> 'a`) print the type of an un-keyed generic, which is now "key not settled" or needs
    an expected type. `types/inference/numeric_defaulting.cx`, `polymorphism.cx` and
    `core/static_params/type_params/main.cx` change meaning. The error fixtures
    `core/traits/errors/{ambiguous_receiver,unknown_method}`, `core/tuples/errors/unknown_arity` and
    `types/errors/arity` become per-instance errors, so their messages move.
  - "Recursion": `tests/core/functions/fib.cx` (`fn fib(n)`, no return type, self-recursive),
    `tests/meta/04_functions/dyn_fib.cx` and `tests/meta/05_order/04_recursion.cx`
    (`fn sum(a: int)`) now fail. Write `: int`, or move them to `.err` and add a passing twin.
  - "Generic function used as a value": `tests/core/functions/shadowed_generic.cx:15`
    `var passed = describe;`, and `reflection/typeof_generic.cx:13-14` / `typeof_pack.cx:23-24`
    (`typeof(pick)`).
  - "Impls only emitted when referenced": `meta/05_order/08_static_invoke` and `09_dyn_invoke`
    print from `meta` blocks inside impl methods. Cow is never used, and its line is already absent.
    Re-verify the order.

**`.err`: 30 fixtures contain effect syntax.** All of them move position, because `[line:col]` shifts
when `ctl` → `@ctl fn` or `handle E` → `handle<E>`. Regenerate the positions, then judge the wording:

| Disposition | Fixtures |
|---|---|
| **Obsolete** (the construct is gone) | `effects/final/errors/resumes` (the "final ctl cannot resume" rule; it is now an ordinary type error, so keep the fixture with new wording or delete it); `effects/errors/discontinue_outside_ctl` (both diagnostics: there is no `final ctl`, and with no `resume` in scope it is an unbound name); `effects/errors/handler_widens` (a `ctl` arm for a `fn` op is now an impl arity mismatch, so keep it reworded); `run_value/return_clause` (now a `.txt`) |
| **New wording** (now a trait or impl rule) | `errors/duplicate_operation` ("Effect 'A' already declares an operation" → the trait duplicate-method message); `errors/non_exhaustive` ("Handler for 'two' is missing operation 'b'" → "'two' for '<handler>' is missing method 'b'", where the inline handler type needs a printable name); `errors/no_such_operation`; `errors/unknown_effect` ("Unknown effect" → "Unknown trait 'nope'"); `errors/unknown_handler` (→ unknown type); `generic/errors/written_row_arity` ("Effect 'Yield' takes…" → the "Trait 'Pair' takes N type argument(s)" form); `errors/effect_param_in_row`; `errors/across_modules/main` and `errors/unimported_effect` ("is not an effect in scope" → a trait, imported by name) |
| **Semantics to re-decide** (monomorphized handler methods check per instance, so "handled once for every type" may no longer hold) | `errors/arm_ties_op_param`, `errors/arm_settles_op_param`, `errors/arm_settles_op_row`, which may become passing programs or instance errors. Also `core/defer/errors/defer_cannot_fail` (§2.3) |
| **Position only** (the row machinery is unchanged) | `errors/{leaked_effect,unhandled,purity_violated,pure_parameter,row_argument_kind,closed_row_argument}`, `handler/errors/arm_without_outer`, `generic/errors/{two_instantiations,written_row_mismatch,one_type}`, `core/traits/errors/impl_row_{narrower,wider}`, known_unsound `impl_row_inferred`, `core/control/errors/break_outside_loop` (it still says "a 'run' block") |

The typecheck strings that go: `typecheck.ml:4101-4103` ("A 'final ctl' handler cannot resume…",
"'resume' outside of a 'ctl' handler"), `cps.ml:1215` and `parser.ml` ("Expected 'fn', 'ctl' or 'final ctl'.",
"Expected ';' after resume.", "Expected 'handle' or 'with' after a run block.").

**New error fixtures the design implies.** Write them first, in `expected_failing` with
`Waiting "CPS migration"`:
1. `effects/errors/two_handlers_one_effect`: `run {…} handle<Log> {…} with BasicLog;`.
2. `effects/errors/handler_not_a_trait`: `run {…} handle<int> {…}`, which fails with "int is not a trait, so it has no operations to handle".
3. `effects/errors/handler_missing_continuation`: `fn ask() {…}` for an `@ctl fn ask(): int`, an arity mismatch.
4. `effects/errors/continuation_wrong_type`: `resume("x")` for an `int` op.
5. `effects/errors/run_answer_mismatch`: `run<string> { 1 }`, or an arm returning an int.
6. `effects/errors/final_style_resume`: `resume(0)` in a handler for `@ctl fn throw<T>(..): T` (the replacement for final/errors/resumes).
7. `meta/errors/key_not_settled`: `fn helper<T>(t: T): T {…} var f = helper;`.
8. `meta/errors/recursion_needs_return_type`: the design's `is_even`/`is_odd`.
9. `meta/errors/splice_misfit`: `var x = meta { gen code { var y = 1; }; };` (a statement where an expression stands).
10. `meta/errors/declof_generic_without_args`: `declof(Throw)` from a static param left unapplied.
11. `types/errors/lambda_monomorphic`: `var f = (x) => x; f(1); f("a");`.

Passing fixtures to add alongside them:
- `EffectHandler<Effect, String>` printed through `decl_source(declof(...))`.
- A named handler generic in R (`Picker<R>`) used under both a statement run and a valued run.
- A tail-resumptive named handler under any run.
- One `with H` binding two effects.
- A handler capturing a local by reference. Many fixtures already do this, e.g. `logged/tests/logging.cx`.
- `fn id(x)` instanced at two types.
- `var g: (int) -> int = helper; var h = helper<int>;`.
- Expected types: `Set<int>` literals, and `takes_any([1, 2])`.
- A meta block in a generic fn printing `str(T)` per instance.
- Recursion with a written return type.
- `effect_transform` invoked directly from a `meta` block.

## 4. Other surfaces

**Compiler front end (this rewrite needs these):**
- `bootstrap/lib/scanner.ml:49-79`: drop `ctl`, `final`, `effect`, `handler`, `resume` and `discontinue`
  as keywords (they become identifiers; `discontinue` becomes an intrinsic). Keep `run`, `handle` and `with`.
- `bootstrap/lib/token.ml:55-83,143-171`: the same tokens.
- `bootstrap/lib/parser.ml`: drop `effect_decl` and `op_kind` (1199-1245), `handler_decl`, the `handler` arm
  loop and `handler_clauses` (1519-1555), the return clause in `run_expr` (1590-1617), `resume_stmt`, and the
  `Discontinue` statement (1091-1097). Add `run<R>` and `handle<E>` (static args), and `with` + a type. `@ctl`
  rides on the existing trait-method `attributes`.
- `bootstrap/lib/ast.ml:119-165,431-498,1020-1046`: `op_kind`, `op_decl`, `arm`, `handler`, `Effect_decl`,
  `Handler_decl`, `Resume`, `Discontinue` and `ret_clause` go. Every match on them goes too: typecheck.ml 43,
  metaprocess.ml 25, cps.ml 25, parser.ml 23, syntax.ml 18, source.ml 14, loader.ml 10, resolve.ml 9,
  printer.ml 9, scanner.ml 6, desugar.ml 5, type_mono.ml 3. (The backend side of this is the other plans'
  scope. It is listed here because the AST change and the rewrite land together.)
- `bootstrap/lib/source.ml:190-199,250,349-354,562-612` (round-trip printer),
  `bootstrap/lib/printer.ml:131,249,267,519` (`--dump-ast`/`--dump-types`), and
  `bootstrap/lib/syntax.ml:50,176,209-216,251-253,319-321,475-476,624,704-706,777-791` (the Cronyx AST
  bridge both ways).
- `bootstrap/lib/metaprocess.ml:2540-2541` (`DeclarationKind` Effect/Handler).
- `bootstrap/test/test_bootstrap.ml`: drop the obsolete error fixtures from `error_cases`. Move
  `run_value/return_clause` if it becomes `.txt`. Add the new fixtures. The comment at :682 ("nothing
  exports one") is now false for traits, so reword it or delete it along with its premise. The
  `renderings` entry "Unhandled effect(s): Log." stays.

**stdlib compiler model:**
- `stdlib/compiler/Ast.cx`: `ExprKind.Run(ValuedBlock, List<HandlerClause>, Option<ReturnClause>)` →
  `Run(Option<TypeExpr>, ValuedBlock, List<HandlerClause>)`. `StmtKind.Run` likewise, and
  `StmtKind.Resume` and `StmtKind.Discontinue` go. `DeclKind.Effect`/`Handler`, `EffectDecl`,
  `OpKind`, `OpDecl`, `Handler`, `Arm` and `ReturnClause` go.
  `HandlerClause = Inline(TypeExpr /*E*/, List<MethodDef>) | Named(TypeExpr)`.
  The design's EffectHandler meta needs `MethodSig.attrs`, `Signature.static_params`,
  `TypeKind.Function` and `Param.implicit`, which all exist already.
- `stdlib/compiler/Printer.cx:22,232-238,341-346,423-468,585-600`: `__op_kind`, the effect and handler
  decl printers, and `__handlers`. Print `run<R>`, `handle<E>` and `with T`.
- `stdlib/meta/Reflect.cx:187-188`: `DeclarationKind.Effect` and `Handler` go.
- New stdlib code: `EffectHandler<E, R>` and `effect_transform` (the design's library code). It belongs
  in a module the prelude imports, so it is a new `global import` in `stdlib/prelude.cx`.

**cx package manager:**
- `cx/lib/docs.ml:607-680`: the `Effect_decl` and `Handler_decl` doc entries go, and traits carry `@ctl`
  in `attrs`.
- `cx/lib/site.ml:340,517-523,588-604,648-649`: the "Effects" and "Handlers" sections and the `kw "effect"`
  and `kw "handler"` headers. Decide whether effects stay as their own section (a trait with an `@ctl`
  method, or one used in a row?) or fold into Traits.
- `cx/test/test_cx.ml` lists are unchanged; the two `expected.json` files change (§3).
- `scripts/cx-parity.sh` is generic over fixtures and needs no change. Run it last; it also runs all
  `--dump-*` flags, so `printer.ml` must not crash on the new nodes.
- `cx/lib/test.ml` is the `Assertion` runner through `stdlib/test/Test.cx`, so only Test.cx's
  handler changes.

**Editors and highlighting** (no tree-sitter grammar exists; Prism is the docs default with no Cronyx grammar):
- `editors/vscode/syntaxes/cronyx.tmLanguage.json:78`: keywords `effect|ctl|final|handle|handler|resume|discontinue|run|with`
  → `handle|run|with`. Line 127 is `(fn|ctl)\s+name` → `fn\s+name`.
- `editors/nvim/syntax/cronyx.vim:9`: `cronyxEffect effect ctl final handle handler resume discontinue run` → `handle run`
  (and add `with`).
- The Obsidian plugin (`editors/obsidian/` on branch `obsidian-plugin`, worktree
  `.claude/worktrees/cronyx-obsidian-plugin`) is `main.js`/`manifest.json`/`styles.css`. It only runs
  code and has no highlighting, so it needs no change.

**User docs (`docs/docs/`, untested):** every page in `language-effects/` (why-effects 21 hits, first-effect 29,
resumable-effects 41, multiple-resumption 29, composing-handlers 45, effect-polymorphism 14,
error-handling 44, generators 51, async 35) needs rewriting. So do the single mentions in
`language-basics/{control-flow,enums,functions,traits}.mdx` and `language-metaprogramming/reflection.mdx`,
plus `README.md` (5). resumable-effects and multiple-resumption explain `resume` as a statement,
and error-handling explains `final ctl`. Those are prose rewrites, not syntax swaps.

**internal-docs (list only; not part of this plan's edits):**
- They describe the old system as current: `Algebraic Effects.md` (48 hits, including the decisions table
  where `resume` is a statement, :117-130 on `final ctl`, and :217 on the stale answer type), `Async.md` 14,
  `Continuations and Tasks.md` 8, `Net.md` 6, `Errors.md` 4, `Native Readiness.md` 4, `IO.md` 3,
  `Testing.md` 3, `TODO.md` 10, `Attributes and Test Frameworks.md` 2, `Stdlib Plan.md` 1, `README.md` 1
  and `Package Manager Plan.md` 1.
- The uncommitted drafts use old syntax in examples: `Async Strategies.md` 16, `Algebriac Effects During
  Metaprocessing.md` 12, `CPS in Metaprocessing.md` 6, `Delimited CPS Example.md` 7.
- `CPS Migration.md` itself keeps its "Working Examples" old-syntax block as the before.
- **`CLAUDE.md`'s "CPS is selective" paragraph** ("a `ctl` operation means continuations, and only `fn`
  and `final ctl` operations mean evidence") becomes false, and so does the Architecture
  pipeline line (Desugar/Resolve/CPS). Ask before editing CLAUDE.md.

**Benchmarks:** `benchmarks/benches/{effects,calls}.cx`. `resumed_handler` asserts `@memory("constant")`,
and the closure-based transform must keep that. Check it with `cx bench` by hand, because CI does not run it.

## 5. Ordering inside the one change

1. **Fixtures first** (CLAUDE.md). Add the §3 new fixtures in the new syntax, all `expected_failing`
   `Waiting "CPS migration"`.
2. **Rewrite tool**, `scratch/migrate/rewrite.py`, run on a copy of the tree. It reuses the
   comment- and string-aware brace matcher from this inventory and edits raw text, so comments and
   layout survive. Rules:
   - R1: `effect N` → `trait N`.
   - R2: in a trait that came from an effect, `ctl` → `@ctl fn` (placed after any attributes on
     their own lines).
   - R3: `final ctl op(...)`, with no result → `@ctl fn op<T>(...): T`, picking a param name that
     is free; with a result → `@ctl fn op(...): R`.
   - R4: `handle X {` → `handle<X> {`.
   - R5: an arm `ctl`/`final ctl op(ps) {` → `fn op(ps, resume) {`.
   - R6: `resume e;` → `resume(e);`, `resume;` → `resume(());`.
   - R7: `discontinue;` → `discontinue(resume);`.
   - R8: report, and do not touch, every value-position run, return clause, `handler`/`with`, quoted
     `code effect`, and `.err` fixture.

   The tool is idempotent and prints a per-file report. It is not committed (`scratch/` is ignored).
3. **Front end** (§4 compiler list), and also `source.ml`, `printer.ml` and `syntax.ml`. Do Ast.cx,
   Printer.cx and Reflect.cx in the same step: `syntax.ml` reads and writes Ast.cx by constructor
   name, so the OCaml and Cronyx shapes must match in one commit.
4. **Optional bridge, recommended.** Lower the new surface onto the *existing* backend in Desugar: a
   trait named in a row becomes an effect with op kinds read from `@ctl`, and `handle<E>` arms whose
   last param is `resume` become old arms with `resume` bound to the reified continuation
   (`cps.ml:1164` already makes one). The old backend needs resume-as-expression for this, which
   `ctl-as-function.md` already schedules. Then run R1–R7 over stdlib and all fixtures, do the hand
   edits (§2.4–2.8), and require **every `.txt` outside the §3 list to be unchanged**. That separates
   "the rewrite is faithful" from "the new backend is correct". Without the bridge, steps 5 and 6
   merge and a failing fixture cannot say which one is wrong.
5. **Hand edits.**
   - 8 value runs (7 files) and 4 return clauses.
   - 7 named handlers and 5 `with`.
   - `stdlib/async/{Task,Timer}.cx` and `stdlib/iter/Yield.cx` (stored continuations, `discontinue`,
     forwarding arms, and the row of `resume`).
   - `stdlib/prelude.cx` (12 clauses: R4–R6 apply, then check by eye).
   - stdlib doc comments (4).
   - `tests/meta/syntax/{printer,round_trip}.cx`, `tests/meta/moduleof/*`.
   - cx/test `Ops.cx` and `ink.cx`, and both `expected.json`.
   - The 30 `.err` fixtures, positions now and wording after step 6.
6. **Backend.** Add EffectHandler and effect_transform in stdlib, and remove the bridge and the old
   CPS/handler paths per the design. The step is done when the 133 `tests/effects` fixtures and the
   stdlib suites (async, net, io, os, test) pass on unchanged `.txt` files, and the step-1 fixtures
   leave `expected_failing`.
7. **The non-effect rules from the same design** (implicit static params, the recursion rule, generic
   functions as values, impl pruning, and meta blocks in generics). Fix the 42 untyped-param
   definitions and 3 recursive functions where the fixture is not *about* inference. Rebaseline
   `typeof_fn`, `typeof_generic` and `typeof_pack`, and the 4 error fixtures in §3.
8. **Error wording.** Regenerate the `.err` files and review each against the §3 table. Delete the
   obsolete ones from `error_cases` and the tree.
9. **Green:** `dune test --force` (bootstrap), `dune test cx`, `./scripts/cx-parity.sh`, and
   `cx bench` on benchmarks/ by hand.
10. **Docs:** `docs/docs/language-effects/*`, the editors, and the stdlib doc comments if they were
    not already done in step 5. internal-docs and CLAUDE.md wait for the user.

Hand edits, as opposed to script edits:
- About 25 fixtures: the value runs, return clauses, handlers and `with`, quoted code, moduleof,
  and doc_comment.
- 30 `.err` files.
- 5 stdlib files (Task, Timer, Yield, prelude by eye, and the doc comments in Assert, Console, Error
  and Yield).
- 2 cx packages and their 2 JSON files.

The script covers the remaining ~150 fixtures and 13 stdlib files.

## 6. Risks found while inventorying (raise when they bite)
- **The continuation's row (§2.2).** EffectHandler's generated `resume` type has an empty row, and
  Yield, Task, Timer and the `fn_values/` fixtures store continuations that perform effects.
- **Trait objects calling `@ctl` ops.** `tests/core/traits/dyn/effect_resumes.cx` calls `get()` (a
  `ctl` op) inside `Speaker` impls reached through `List<Speaker>`. A static transform reaches the
  callee by `declof`, so a table method that performs a `@ctl` op needs its instance under the
  run's key.
- **The answer type of a handler under a generic run.** `__root<T, X, E>` runs its body as a
  statement (R = unit), which is fine. `attempt`, `seeded` and `timeout` also use statement runs and
  stash the value in an `Option`, so no stdlib run needs `<R>` at all.
- **A trait whose methods take no `self`** is "an associated function" today (`'area' is an
  associated function of 'Circle', so it is reached as 'Circle.area'`). It also cannot be a type
  (`'Maker' cannot be used as a type`). Effect ops are called bare, so that call path is new checker
  work. Every effect now hits that rule if it is ever written as a type.
