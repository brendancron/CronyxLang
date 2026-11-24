# Decisions to review after the base works

Each item was taken on a recommendation so implementation could start. All of them are to be
reviewed in depth once the CPS Migration work runs. Plan references are to
`scratch/plans/00-unified.md` and its sources `01`-`04`. The design is
`internal-docs/CPS Migration.md`.

Status key: **taken**, built as described; **deferred**, left in `expected_failing` until
reviewed.

**After this review: go through the TODOs (user, 2026-11-22).**

## Asked and answered with the recommendation

### R1. Function values from outside the run (U1, 03 Q1): REPLACED 2026-11-22 (user decision)
**Now (the Koka model, 03 Q1 option b):** handlers are dynamic in meaning and static where the
handler is visible. A function whose type has a `@ctl` effect in its row takes the CPS form: the
handler and its continuation are parameters. `twice` is processed once, not per lambda:
```cronyx
fn twice(f: () -> <Ask> int): <Ask> int { return f() + f(); }
// processed
fn twice<R>(f: (H, (int) -> R) -> R, h: H, resume: (int) -> R): R {
    return f(h, (a) => { return f(h, (b) => { return resume(a + b); }); });
}
// and the lambda, wherever it is written, inside a run or not
() => { return ask(); }   →   (h, resume) => { return h.ask(resume); }
```
- That is a compiler rule triggered by a type, a built-in; the user accepted it.
- Lists of tasks (`Task.all`, `race`, `scope.start`) work, because every such value has one form.
- Where a run sees both the code and the handler (steps 1–3), specializing at the key stays as
  the fast path; it is an optimization, not the semantics.
- A function value created under one run and called under another that handles the same effect
  is answered by the run where it is called, as in Koka.

**Superseded:** U1 (a), "a function argument is part of the key", built in C7a as I156–I159
(lifting into `lifted#n`, the captures record of getters and setters, `lifted_by`,
`lifting_calls`, the "cannot be stored where no run reaches it" errors). These come out or get
reworked when the new rule is built.

Review: what `H` is at run time (I105's record of closures, or an evidence vector by effect as in
Koka); where the specialization fast path applies; the cost of passing `h` through every call in
CPS form.

### R28. Rewritten code keeps false rows (raised by the user 2026-11-22): built for runs in S3 (I204), the call-site display left (I204)
Processed `helper` from `twice`/step 2 (`--dump-code`):
```
(fn helper#1 (hv#Ask k)
  (return (call (field hv#Ask:{ ask: ((int) -> <Ask> int) -> int } ask) (fn (n: int) ...):(int) -> <Ask> int)))
```
The continuation is typed `(int) -> <Ask> int`, but nothing in it performs `Ask`: the transform
routed `ask()` through the handler. The row is not dead information, it is **false**, and it
contradicts U2 (`resume`'s row is what the run passes outward, which cannot hold the effect this
run handles). Likely cause: types carried over from the code before the transform (the handler
record's type and the continuation's annotation) instead of recomputed.

Rule to adopt: **rewritten code is type checked from scratch and keeps no types from the code it
replaced** (Splice → Typecheck already says so). Truth to add to `CPS Migration.md` after review:
processed code is typed by what it actually does, so under a run no type holds a handled effect.
Not erasing rows: they stay, and stay accurate.

### R29. The prelude and the whole stdlib get reworked (user, 2026-11-22)
The user expects `prelude.cx` (`__root`) and the full stdlib to need a rework after these changes,
not a mechanical syntax migration. C7b is therefore a redesign pass over the stdlib against the
new model (R1's CPS form for function values, R28's accurate rows), not `rewrite.py` plus hand
edits.

### R30. Case convention (user, 2026-11-22): decided, convention only; built in S5a (I226–I230)
All types are uppercase, identifiers stay lowercase: `Int`, `String`, `Bool`, `Float`, `Byte`,
`Char`, `Unit`, and every user type, trait and effect (`Async`, `Log`, `Sched`, `Logic`, `Stream`,
`Ask`). Type params stay `T`/`R`/`E`; values (variables, functions, fields, value static params
`<n: Int>`) stay lowercase; variants stay as they are. **Convention only:** the compiler does not
check it and case never carries meaning. The built-in names are renamed in the compiler, and the
stdlib and fixtures follow (about 4,000 uses of the built-in names, 76 lowercase declarations),
as part of the stdlib rework. Built in S5a (I226–I230); review after: the runtime's own kind names, the CLI help's
case, and the two `cx docs` JSON fixtures (I226, I228, I230).

### R31. `type X impl A, B { … }` (user, 2026-11-22): decided, defaults to review; built in S4 (I214)
The doc's TODO is now the section "Implementing Traits in the Type": a type names the traits it
implements in its declaration, Java/C# style. Defaults taken: several traits separated by commas;
the body holds fields, then the methods of every named trait; each method goes to the trait that
declares it; a method no named trait declares belongs to the type; a method name two named traits
both declare is an error (write separate `impl`s); static params work (`type Picker<R> impl
EffectHandler<Choose, R>`). Supersedes the "impl as a type-body member" alternative. To build.

### R2. The continuation's row (U2, 03 Q2): taken, CONFIRMED by the user 2026-11-22 (A: the type says so)
`resume: (A) -> <ρ> R`, typed honestly as in Koka. Stored continuations write their row
(`List<() -> <Error> unit>`), and calling one outside its handlers is an unhandled effect.
`abort_after_resumption` is rewritten to drain inside the `Error` run. Review: whether the
written rows are a burden in Task.cx and Yield.cx.

### R3. `gen f(x)`: call or value (U3, 02 Q1): CONFIRMED as built by the user 2026-11-22
An operand already in code form (its type is a syntax type: Expr, Stmt, Decl, MethodSig,
TypeExpr, or a List of one) is not wrapped: its value goes to Splice, so the call runs to produce
it (`gen sig_named(…)`). Anything else is wrapped in code and spliced a layer above
(`gen print("hi")` emits the call). Code that does not fit where it lands is an error at Splice
(a `TypeExpr` where a statement goes). I76 and I80 answered with no change.

### R4. An unsettled param in an effect's arguments (U4, 01 Q1): taken, CONFIRMED by the user 2026-11-22 (keep the rule)
`__root<T, X, E>` leaves `X` open in a statement that never throws. It defaults to `unit` when
the param appears only inside an effect label's arguments, and is an error anywhere else.
Review: redesigning `__root` so no default is needed.

### R5. The `str(E)` fix in the doc: taken, REVIEWED 2026-11-22: user chose A (a static param is a value inside a meta block: a type param is a `Type`, so `str(E)` works); to build, then restore the doc's `str(E)` message. Built in S4 (I213); the message is restored
A type param is not a value inside a meta block, so the EffectHandler example's fallback arm
now reads `fail("not a trait, so it has no operations to handle")`. Review: whether a meta
block should be able to name a static param as a value (`str(E)`).

## Defaults taken without asking (80% rule)

| # | Decision | Source | Review question |
|---|---|---|---|
| R6 | A key is settled strictly at the call, after its arguments. CONFIRMED by the user 2026-11-22 (strict) | 01 Q2 | Should a later statement be allowed to settle it (a queue at the end of the statement)? |
| R7 | Plain generic types (`type Box<T>`) stay parametric; only functions and methods are instances. REVERSED by the user 2026-11-22: types are monomorphized exactly like functions (`Box$int`, `Box$string`); a use of a type reaches Check decl cache → Metaprocess decl (diagram diamond now "call, operator, method, type"). To build; not built in S4 (I218). Built in S4b for the program the walk finishes (I220–I223); a meta block's program, local generic types and per-copy impls are left (I224) | 01 Q3/D1 | Literal "every declaration at a key": would `Box$int` records be worth it? |
| R8 | A trait instance may keep a param open (`EffectHandler<Effect, _>`), so `Picker<R>` works. CONFIRMED by the user 2026-11-22 (`Picker<R>`, R settled by the run) | 02 Q2 | Fine as it is, or generic handlers another way? |
| R9 | `run<R>` may omit `<R>`, which is inferred, or `unit` for a statement run. REVERSED by the user 2026-11-22: `<R>` is required on every run for now (`run<unit>` for a statement); inferred static params come later, once designed properly. Built in S4 (I209) | 04 A1, 03 D8 | Should `<R>` be required? |
| R10 | `handle<E>` on a generic effect (`Throw<X>`) settles E's arguments from the body's row. REVERSED by the user 2026-11-22: written, `handle<Throw<IoError>>`; leaving them out is an error, until inferred static params are designed. Built in S4 (I210) | 04 A4 | Should they be written, as in `handle<Throw<IoError>>`? |
| R11 | Untyped params of a handler or impl method take the trait's types (not implicit static params). CONFIRMED by the user 2026-11-22 (an expected type, not inference) | 04 A5 | Consistent with "an unannotated param is an implicit static param"? |
| R12 | Lowercase effect names (`log`, `async`) are kept. REVERSED by the user 2026-11-22: renamed trait style (`Async`, `Log`, …), see R30; built in S5a (I227) | 04 A8 | Rename to trait-style names? |
| R13 | Migrated code names the continuation `resume`. CONFIRMED by the user 2026-11-22 | 04 A2 | Fine, or `k`? |
| R14 | `final ctl op` → `@ctl fn op<T>(…): T` (keeps the fresh result type at each call site, loses the cheap unwind). REVISED by the user 2026-11-22: add `@abort` (users may skip it). Defaults taken, to review: `@abort fn throw<T>(err: X): T` keeps the fresh `T`; EffectHandler gives an `@abort` arm no continuation param and it returns the run's `R`; the transform compiles the call as an early exit to the run, building no continuation; stdlib `throw`, `exit`, `failed` use it. Built in S4 (I215); review after: the call still builds its continuation, which the arm discontinues | 03 D9, 04 A3 | Measure compile time (stop if over ~3x); is a cheap abort worth a mechanism? |
| R15 | The `return (x) { … }` clause on `run` is deleted and folded into the run's tail (4 fixtures). CONFIRMED by the user 2026-11-22 (left out; may return later as an EffectHandler method) | 04 A6 vs 03 D3 | Was it worth keeping? |
| R16 | A trait-object method that performs a bound `@ctl` effect is rejected (`methods/suspending_receiver`, `core/traits/dyn/effect_resumes` deferred). REVERSED by the user 2026-11-22: rejection dropped; trait-object methods take handler + continuation under the R1 function-value rule. To build | 03 D6 | How should dynamic dispatch meet the transform? |
| R17 | Discontinue insertion is syntactic: an arm that never names its continuation gets `discontinue(k)`. CONFIRMED by the user 2026-11-22 (A: stored-then-dropped continuations are the programmer's to discontinue) | 03 D7 | Is syntactic enough, and what about an arm that stores `k` and drops it later? |
| R18 | One intrinsic, `discontinue(k)`, plus tail calls as an interpreter guarantee. CONFIRMED by the user 2026-11-22: the full list is discontinue, tail calls, the R1 function-value rule, and `@abort` (library first if it can express an exit to the run); no Cont/Frame/Abort | decision log | Is anything else of Cont/Frame/Abort needed? |
| R19 | Display/Debug impls stay rooted for every type the program constructs. REVISED by the user 2026-11-22: make Display static in the stdlib rework (`str<T: Display>` an ordinary generic call, real impls for built-in types, `List<T>` calling `T`'s; a type without an impl decided when built), then delete this Prune exception. To build. Built in S5b (I235–I240); a type without an impl is an error, review after (I236). REPLACED by the user 2026-11-22: every type prints through `str`'s meta block, an impl only overriding; built (I242–I250) | 01 D6 | Goes away once Display is static (Stdlib Plan). |
| R20 | An effect is a trait whose methods take no `self`; a trait mixing both is not an effect. CONFIRMED by the user 2026-11-22 | 03 D4 | Right boundary? |
| R21 | Named `@ctl` handlers are generic in R, except the 2 whose arms fall off their end (`unit`). REVISED by the user 2026-11-22: rewrite those 2 generic (`return resume(())`) in the rework; no special rule, falling off the end is `Unit` as for any function. To build | 04 A7 | Should a handler's arm be allowed to fall off its end? |
| R22 | `self` stays recognized by name. CONFIRMED by the user 2026-11-22 | conversation | Positional like the continuation? |
| R23 | Recursion with no written return type now fails, and fixtures that rely on it get `: T` written. CONFIRMED by the user 2026-11-22 (group inference waits for the inference work) | doc Recursion, 01 D2 | Count after the T9 probe, then judge whether group inference is worth it. |
| R24 | 3 fixtures that never terminate under the design are removed (`polymorphic_recursion`, `unspecializable_*`). CONFIRMED by the user 2026-11-22 | 01 S4 | Confirm they should go, not change. |

## Plan-level resolutions (00-unified.md)

| # | Decision | Review question |
|---|---|---|
| R25 | Core before reflection, so the reflection work isn't written twice | — |
| R26 | A dual-mode parser inside the branch acts as the bridge to check the migration (never shipped). DECIDED by the user 2026-11-22: remove the old syntax now; everything goes 100% through the new system. Old syntax, `cps.ml` and the old keywords are deleted at the start of the rework, not the end, so fixtures and stdlib in old syntax fail until rewritten | Did it pay for itself? |
| R27 | The OCaml callback record between Typecheck and Metaprocess is renamed `Walk_ops` (not a hook) | — |

## Implementation decisions

I1. `Typecheck.nested` keeps each table's contents for `f` (snapshot, restore after) instead of
clearing it. `Session.start` already clears what a session fills; the rest (`Types.declarations`
holding the built-in `Type` fields, `dynamic_rows`, `ctx_row_params`, `Desugar.decl_attrs`) hold
what precedes any check, and clearing them broke 26 reflection fixtures. Refs start at their
initial values.

I2. Resolve's five tables reach `nested` through `Typecheck.later_passes`, which Resolve fills at
module initialization: Resolve depends on Typecheck, so Typecheck cannot name them. The name
counters (`Lower`, `Resolve`, `Cps`) are left monotonic, not restored.

I3. `Types.reset` no longer zeroes `Types.counter`. `Session.start` zeroes it only at nesting
depth 0, so a nested check never mints an id the outer one holds (T1).

I4. The C-style `for` flag is the constant `__for_first`. It scans, so the round trip works, and
it is the same in every loop, so the reparse is stable. A nested loop shadows it in its own
block. Rejected: copying the step in front of each `continue` (no name needed), because a
`defer` in the body would then run after the step instead of before it. Cost: a program that
names `__for_first` in a loop's init, cond or step collides with it.

I5. `Lower`'s builders are open in the node type (polymorphic variants), so the parser's
`Ast.stmt` and the checker's `desugared_stmt` share them until A3. `Desugar.bound` (unused) and
`bound_desugared` merged into `Lower.bound`.

I6. `Syntax` reading a `For` value from `std/compiler/Ast` lowers it with `Lower.c_for`. The
Cronyx-side `StmtKind.For` constructor and its `Printer.cx` arm stay, but quoting never produces
it now. `Ast.loops`/`map_loops` are deleted: only `For_in` was left.

I7. Named handlers and variadic arities are gathered once per check, over the whole program
(`Typecheck.gather`, from `Session.declare`), not in `hoist`. Both tables are keyed by bare name
and read from anywhere, so a handler or variadic declared inside a block must be known before any
block is checked; `hoist` runs per block, when the check reaches it. `Session.start` clears both.

I8. `Attributed` is unwrapped where a statement list enters the checker (`infer_block`,
`Session.declare`/`infer`, via `Typecheck.unattributed`, which records a type's attributes in
`Typecheck.decl_attrs`). `infer_stmt_impl` has an arm for one in a single-statement position.
Rejected: teaching every declaration pass (`hoist`, `declare_*`, `dependency_order`) to see
through the wrapper.

I9. "'code' is only allowed inside a meta block", "'moduleof' is only allowed inside a meta
block" and "Unknown handler" raise `Typecheck.Rejected`, which ends the whole check with that one
error, as Desugar's first-error stop did. Under the partial policy (Precheck) it ends the check
with no errors, as Precheck did when Desugar failed: a meta block may still be what removes it
(`tests/meta/moduleof/helper_fn` holds `moduleof` in an ordinary function reached only from a
meta block). Rejected: an ordinary per-statement error, which cascaded ("Undefined variable 'c'"
after the `code` error in `tests/meta/code/errors/outside_meta`) and made Precheck report
`helper_fn`. Cost, unchanged from before: a program holding one of these gets no precheck.

I10. Those three diagnostics are now stage Type (rendered "Type error:" rather than "Desugar
error:"). No `.err` file shows the stage, and the exit code is 65 either way. Type is right:
"Unknown effect" was already a Type error, and these are the checker's findings now.

I11. `run<R>` is the first component of `Run_expr` (`type_expr option`), in the type every
stage shares, so the typed stages carry it too. Typecheck rejects `Some` for now and builds the
typed node with `None`. Rejected: a surface-only tag. At C8 the typed run is deleted and the
surface one keeps R, so a second tag would have to be merged back in. The statement `Run`
has no R, because the parser never produces one: a statement run is `Expr (Run_expr …)`.

I12. `with T` adds no node. A bare `with X` parses as `Named X`, as before, because the old
form and the new are the same text. Deciding whether X is a `handler` value or a type is the
checker's job at C3. Until C8, `Named` means either one, and after C8 it means only a type.
`with Picker<int>` does not parse, since the design writes `with Picker` and infers R.

I13. `handle<E> { … }` is `Handle of type_expr * ('s, unit) method_def list` in `handler_clause`.
Its methods use the impl's method parser (`Parser.method_def`, factored out of `impl_decl`), so
they take attributes, static params and untyped params. The `<` after `handle` is what tells
it from the old `handle E {`. Ast.cx: `HandlerClause.Handle(TypeExpr, List<MethodDef>)`.

I14. `resume` is a keyword only at the start of a statement inside an old arm (`handle E { ctl
… }` or `handler n : E { … }`). The parser tracks this with `state.in_arm`, which
`handle<E>` methods reset. Everywhere else `resume` is a name in expression position and may name a
parameter, so `fn ask(resume) { resume(5); }` parses. `discontinue;` stays the keyword
everywhere, which keeps `effects/errors/discontinue_outside_ctl`. `discontinue(` is a call to
`Var "discontinue"`, which C2's built-in will answer. Cost: a stray `resume x;` outside an arm
is now a parse error, or "Undefined variable 'resume'", instead of "'resume' outside of a 'ctl'
handler." No fixture had one. Both are still keyword tokens, so only a parameter (and an
expression) can be called `resume`. `var resume = …` does not parse.

I15. `ctl` is a keyword token, so `Parser.attributes` accepts it as an attribute name, which
makes `@ctl` parse. Trait methods already carried `ms_attrs`.

I16. Where the new nodes are rejected until their step:
- The walk raises a Meta error at the node's span for `Declof` and `Meta_expr`. Both
  `runtime_hooks` and `run_meta`'s hooks use the new `declof`/`meta_expr` hook fields, set to
  `Metaprocess.unsupported`, and `quiet` defaults both to the identity.
- The walk raises for `Trait_members` in `collect`/`register` (`reject_trait_members`).
- Precheck turns `Declof`/`Meta_expr` into unknown and drops a top-level `Trait_members`
  (plan 02 T6).
- Typecheck raises `Rejected` for `run<…>` and `handle<…>`, and, as a guard, for `Declof`,
  `Meta_expr` and `Trait_members`. `'declof' is only allowed inside a meta block`, like `code`.
- `promote` and `lower` pass `Declof`/`Meta_expr` through untouched. `substitution` visits
  their children (operand and static args, like a static call's, and the meta body).

I17. `Syntax.kind_of` has no `Sig_node` yet. `literal_of` fails on every kind except an
expression, so recognising a MethodSig value would turn one promoted into run-time code from a
record literal into an error. `read_method_sig` and `to_method_sig` exist. `Sig_node` comes with
B3 (`gen` of a MethodSig), and that step has to decide how `literal_of` treats one.

I18. `Source` and `Printer.cx` now print a trait method's static params (`fn fail<T>(…): T;`).
Both used to drop them, which broke the round trip of `@ctl fn op<T>` (the `final ctl` form,
R14).

I19. The operand of `declof` parses as a name or a dotted path (a `Var`/`Field` chain, which the
loader resolves like any qualified name). It does not take an arbitrary expression.
`static_arguments ~operand:true` also accepts `)` after the `>`. A `meta` member of a trait is
read with `declaration` before the member's attributes, so `@a meta {…}` in a trait body is
"Expected a method signature." `Trait_members` is `attachable`, so a documented trait may hold
meta blocks.

I20. The walk is Typecheck in walk mode (`Typecheck.walk_ops` set, the record `walk_ops` that
`Metaprocess` fills). `hoist` registers every function and impl method as a `walk_decl`, bound in
the env by its written scheme as before. A name is the declaration only where `lookup` finds that
very scheme (`decl_of`), so a local shadowing it is not. Rejected: a `Scheme | Decl` variant in
the env, which would touch every `lookup` for the same effect; whole-mode code keeps reading the
scheme. `Typecheck.check_instance` checks a body at a key; `Metaprocess.instance` owns the cache
(keyed by declaration id and `Key.show`) and the instance records.

I21. A use instantiates the written signature with every variable fresh (static parameters, and
the unwritten return and row), and reads the key once its arguments are unified (R6). Unsettled:
"The static params of 'f' are not settled here: {T = ?}." An implicit parameter shows as `_`. A
generic function named as a value is a placeholder node, settled at the end of the innermost
call or statement around it: "'f' is generic and its static params are not settled here; write
them or give it a type: {T = ?}." `var g: (int) -> int = helper;` settles through the
annotation.

I22. Naming (D5): key `{}` keeps the declaration's name, others are `name#n` per declaration. The
first instance of a `Display`/`Debug` method keeps the declaration's name too, since the printer
finds it by name, and at the end of the walk every such method nothing instantiated is made at
its own parameters defaulted to `unit` (D6, as "always rooted" for now).

I23. A call into a `Walking` instance with no written return is the error (D2, the T9 rule). One
with no written row is tied to its caller's row (`unify_row`) rather than contained, so mutually
recursive functions share one row and a label one gains after the call still reaches the other.

I24. Rows: an instance's row tail is closed at the end of the root statement that reached it,
when it is zonked (T4), not when the instance completes. Before a key is read, the call's row is
contained in the caller's, so a label the caller already carries settles the callee's argument
to it (`Throw<IoError>` in `net/WebSocket.cx`).

I25. **REVISED by the user 2026-11-22:** a param that defaults because nothing performs its effect makes the call contribute no such effect to the caller's row (the call never throws, so its type says so); replaces keeping the use open. Built in S3 (I206). Was: U4 as built: a parameter standing only in effect labels defaults to `unit` in the key, but
the use keeps its own copy open and only the instance's return is unified back into the use. So
`Throw<unit>` never enters the caller's row, where a later `Throw<IoError>` could not join it
(`net/Http.cx` calling `timeout` with a task that never throws). A variable left open inside a
label argument is allowed in a key. Review together with R4.

I26. Parametric keys: a key argument holding variables declared generic (an operation's own
type parameters inside a handler arm, a GADT existential) collapses to one generic argument, and
that instance is checked once, generically. Each use instantiates the instance's own generic
variables fresh, as a scheme. Needed by `__once` in `Task.cx`'s `suspend` arm and by
`types/gadt/pair`, which without the collapse never terminates (each existential nests one level
deeper). The interpreter is dynamic, so this holds as long as nothing in such a body is
type-directed on the parameter.

I27. GADT (T12): an arm the concrete scrutinee cannot reach is dropped from the instance, not
reported. Existentials are declared so I26 applies.

I28. Expected types, the part S5 needs first, pulled in as an interim: `expected_result` is set
by a parent just before a child is checked and read by the child first thing, like
`expected_lambda`. Sources: `var` annotations and `return` (through `check_against`), call and
method arguments (the parameter types), record fields, variant payloads. A call meets it before
its arguments, only if it unifies (a retracted trial), and a lambda's unwritten return takes the
parameter's. This settles `var slot: Promise<T> = promise();` in `Task.cx` and most of the
encoding stack. A6 replaces it with `?expected`.

I29. Inside an instance, the traits bounding its static parameters (and their supertraits) are
in scope for method calls, and a bound's targets pick among several impls. A generic body reached
`T.zero()` through `T: Num` without importing `Zero`, and `value.to()` through `T: To<bool>`; at
a key the receiver is concrete and only the bound still says which.

I30. Meta blocks run where the checker meets them (`walk_stmt` calls `meta`), with the current
instance's value arguments bound. Type arguments that have a name are written into meta blocks
only: writing them into the whole body let a parameter capture them (`T = E` against `__root`'s
own row parameter `E`, in `meta/02_gen/reify_enum_*`). Each instance records what each meta block
generated and keeps the spliced body as its surface. A meta program is the types, every impl
whose methods run no meta block (a trait impl whole or not at all), and the functions the block
reaches: as written when they run no meta block, otherwise the `{}` instance's surface. A static
call with written value arguments becomes the instance at them. A generic function holding a meta
block reached from a meta block without its arguments is "'f' runs a meta block and is generic,
so a meta block reaches it only through a call that writes its static arguments." No fixture
meets it.

I31. Names a meta block generates later: an undefined name or method is noted with its span and
reported as usual; `register` then fails with "'x' is used before the meta block that generates
it", which ends the walk (a Meta error), as before.

I32. Errors (D8): per root statement. An instance that fails is marked failed, reported once, and
typed from its written signature afterwards. A root statement reading a `var` whose own statement
failed is skipped. A function whose signature does not read is bound as unknown. A key left
unknown by an error already reported collapses to generic instead of reporting again. `Rejected`
ends the whole walk (I9). A meta error ends the walk with that error alone.

I33. `Pipeline.merged` drops a Precheck error wherever the walk reports at the same span (was:
same span and message). The walk checks at a key, so its account knows the types
(`unknown_method` now reads "Type 'Circle' has no method 'perimeter'.").

I34. Resolve runs per root statement on what the walk zonked, through `Resolve.instance_of`
(every `fn_ref`, and each trait-object slot). Its tables only grow (`Resolve.start` once per
walk), and `record` of a `Fn` records its row too. An instance Resolve makes is zonked and
recorded at once and resolved in the same pass.

I35. Local functions: a block holds the instances of its own local functions, in front, since the
interpreter defines a block's functions before running it. `scoped_declarations` runs only for a
block declaring types of its own (T2). A local type is renamed after each instance whose name is
not the declaration's (T3).

I36. A `meta` a root-level meta block generates goes back through the driver, so it runs rather
than being checked at the top level's own row.

I37. `Metaprocess.program` returns the typed program and the resolved one. `on_code` (and
`--dump-code`) print the typed program with `Printer.string_of_typed_program`; `Pipeline.front`
returns it; `run_prelude_walk` looks for `(type std#List#List)` and the `FromArray` instance a
list literal reaches, and still not for `std#Assert#assert`.

I38. D4 names implicit parameters `implicit#n` (`Ast.implicit_param`) on functions and inherent
impl methods; a trait impl's methods are left as written (R11). The walk keeps value parameters
out of the signature it hoists (`split_static`).

I39. A zero-parameter associated function is hoisted in walk mode: whole mode bound it only when
it generalized the impl.

I40. A static call collects variadic arguments, in whole mode too (`count<int>("none")`). Since
A3 only the `Call` arm did.

I41. What a meta program reaches is read with the function's own parameters in scope: a stdlib
parameter named `start` pulled the program's own `start` into one.

I42. Expected types are an `?expected` argument of `infer_expr` (and `argument`); the globals
`expected_result`/`expecting`/`expected_lambda`, `called_use`, `meet_expected`, `check_against`
and `mentions_trait` are gone. Sources: a `var` annotation (and through `under_root`'s `?ret`, the
root lambda's `return`), `return`, call arguments (`Call`, `Static_call` by name and dotted, method
arguments, constructor `New_call` arguments), `New` fields, variant payloads, `=`, field and index
assignment, and a match arm's value. A node rewritten into another (`Option.Some(x)` into a variant,
`Array<int>(3, 0)` into a constructor) passes it on. Index assignment now reads the element type
before the value, so an index mismatch is reported before one in the value.

I43. Where a node consumes the expected type early (a call's result before its arguments, a
generic `Var`, `New`, a variant), it is unified only if that holds (`meet`, a retracted trial):
the parent unifies anyway and reports a mismatch at the span it always did. Rejected: a strict
unify at the node. It moved `records/errors/nominal_mismatch` and
`traits/errors/impl_signature_mismatch` from the call to the argument, and preempted `not_pure`'s
message in `effects/errors/pure_parameter`, while a literal argument (which consumes nothing)
would still be reported at the call. Lambda parameters and an unwritten return take the expected
function type's by try-unify, as before; the return is now hinted outside the walk too.

I44. A trait expected of a value is a coercion, in `infer_expr` itself (`coerced` around the
unhinted node), except a match, whose arms are each coerced. Coercion therefore also reaches
static call and constructor arguments, variant payloads (`var o: Option<Shape> =
Option.Some(rect)` now checks), index assignment and lambda returns. `coerce_params` in the
method path is kept: an associated function's arguments get no expected type there.

I45. A collection literal with an expected head picks its container there: `Array` gives its
element, any other head with a registry `FromArray` entry gives `Registry.container_element`.
Otherwise (no expected type, a variable, a head with no container) it keeps the `Collection`
kind variable, defaulting to `Array`. Elements are checked with the element type expected on
both paths, so a later element sees what the first settled. `Resolve` still lowers the literal
from its annotation.

I46. `root_argument` is an `?at_root` argument from the `Call` arm through `argument` to the
`Lambda` arm, not a global. It still has the same job: the root's lambda row stands in for the
top level's while the statement is checked.

I47. A generic `Var` meets the expected type and enters its instance at once when that settles
every static parameter; otherwise it is a placeholder settled at the end of the call or
statement, as before (I21).

I48. `helper<int>` as a value is a new surface node, `` `Static_ref (callee, static_args) `` in
`Ast.static_call` (`ExprKind.StaticRef` in `std/compiler/Ast`). It parses when the `>` is followed
by `;`, `,`, `)`, `]` or `}`, where no comparison can end. Typecheck writes the arguments with
`write_static` (shared with `Static_call`) and then treats it as a `Var`; whole mode instantiates
the scheme at the written types (`written_instance`, shared too). Metaprocess substitutes into it,
walks it, and counts it among a meta program's dependencies. It is never made a static instance
the way a `Static_call` with value arguments is (`statically_called`), so `f<3>` as a value inside
a meta block is untested. Printed by `Source`, `Printer` and `Printer.cx`; the round trip covers it.

I49. A5-Q1 is left as it is. Expected types do not reach `var xs = []; xs.push(1);`: nothing is
written. The principled change, `under_root` declaring the var and the root's lambda assigning
it, needs a var whose type stays open across root statements, which conflicts with zonking each
root statement at its end (T4, I24): `xs`'s element would be open when the first statement is
zonked. The annotations A5 added stay.

I50. The walk's arms build what Resolve built: an operator (with `__is_less` and its family
around an ordering, `Not` around `==` for `!=`), unary minus and `~`, an index and an index
assignment, a collection literal (`Array_lit` or the `from_array` instance), a trait-object
coercion (`Object`, each slot the instance of the impl's method at the value's type, `equal` the
`Eq` instance; `__upcast` for a supertrait), a call through a bound (`Call` of the instance, or
`Dyn_call`), `New` (`Record_lit`) and `New_variant` (`Variant`). One function,
`Typecheck.lowered`, makes each choice. The arm calls it once the types the choice reads hold no
variable (`Types.concrete`). Anything still open is lowered by the same function when its root
statement is processed (`Typecheck.processed_*`, which replaces the zonk and the per-root
Resolve). A probe over every fixture found 153 nodes lowered at the end. All of them were
literals with no expected type, which keep the `Collection` kind variable until then (I45), or
indexes into one. An instance made at the end is closed at once (`closed_if`), as
`Resolve.instance_of` closed one before the call read its row.

I51. Hoisting goes through `ctx.hoisted`. A compound assignment is expanded in its arm, and the
temporaries `once` declares are pushed there while the arm is checked. A `run` or `match` in
expression position, a right side of `&&`/`||` that holds one, the operand spills that keep
evaluation order (`in_order`), and the two copies of a loop condition are taken apart per
statement, right after it is checked (`statement`, `hoist_stmt`), and not in the
`Run_expr`/`Match_expr` arms. The reason: spilling an earlier operand needs to know whether a
later one hoists, and an arm checking left to right does not know that yet. Every place that
checks a statement goes through `statement` or `one_statement`: `walk_stmt`, both `if` branches,
a `while` body, `defer`, `for`'s sequence variable, a handler arm's body, and the root statement.
So the pass never descends into a nested statement list. Cost: a `once` temporary under a
`match` value is declared ahead of the whole statement, not inside that arm. It is only a
declaration, and its name is unique.

I52. Whole mode is unchanged, so `resolve.ml` stays, as the back end of `Compile.program` for meta
programs only. That mode is Precheck and the meta programs `Metaprocess.run` compiles under
`Typecheck.nested`. A meta program's generic functions are checked once, generically, and
`Type_mono` copies them afterwards, so what an operator or a bound reaches is known only per
copy, after the check. For the same reason `bound_calls`, `coercions`, `dp_instance` (which
`Type_mono` sets) and `Resolve.synthesized` (which `meta_program` adds, since that pass calls them)
stay too. All of them go when meta programs are processed by the walk (A10, plan 01 S9). Resolve
lost `instance_of`, `start`, `statements`, its trait tables, and `is_trait`/`methods_of`. Its two
remaining tables are reset by every `Resolve.program`, and nothing outside it reads them, so
`Typecheck.later_passes` is gone (I2).

I53. `Typecheck.is_trait`/`methods_of` read `ctx_traits` and `trait_closure`. Verify runs while
the session that checked the program is still current: after the walk, or inside `nested` for a
meta program. So the tables hold that program's traits.

I54. `Metaprocess.program` returns the processed program alone (`Ast.resolved_stmt list`).
`--dump-code`, `--dump-types`, `Pipeline.front` and `run_prelude_walk` print it with
`Printer.string_of_processed_program`, which coerces it to the typed tree. To allow that,
`typed_expr_kind` gained `variant_lit` and the new `Ast.object_lit` (split out of `objects`), and
`Type_mono`, Resolve and the typed printer pass them through. `checked_expr_kind` gained both as
well. `run_prelude_walk`'s expectations are unchanged: the binop branch's own call reaches the
`from_array` instance as Resolve's did.

I55. What Resolve reported ("Cannot index …", "… cannot be built from a literal.", "… has no type
to dispatch on.", "the receiver's type is not known here", "A spread takes a tuple, not …") is now
a Type diagnostic from the checker, raised where the node is lowered. The exit code is 65 either
way, and no `.err` file shows the stage.

I56. `coerce_params` is gone (A6 hand-off). An associated function's arguments are given its
parameters as expected types, as a method's already were, so a trait-typed argument is coerced in
`infer_expr` like every other argument. Nothing covered that path; the new fixture
`types/expected/associated_argument` does.

I57. A meta block is checked by the walk as a root statement of its own: `__root(() => { bindings;
lowered body })` (`Typecheck.Walk.meta`), in a meta env that copies the top-level env less the
program's top-level `var`s, with its own `ctx` and row (`Walk.isolated`). The interrupted check's
`open_defer`, `walk_locals`, `bound_traits` and loop state are set aside. An effect left in the row
after `__root` is "Unhandled effect" at the meta statement. A function a meta block declares is a
local of that lambda, so its instances live in the block (§2.6). `gen`/`code` are lowered first, as
before, so quoted syntax is never checked.

I58. What a meta block runs is: every type-level statement processed so far, the closure of the
instances it reaches, and every finished `Display`/`Debug` instance (the printer finds them by
name). The closure is read from `instance.deps`, which `Metaprocess.instance` fills on every
reference, hit or miss, for the current instance or, inside a meta block, for its frame. The
default `Display`/`Debug` instances (`printed`) are now made before each meta block as well as at
the walk's end. The instances a block reaches are zonked when it runs, not at the end of the root
statement around it. T4 does not apply, because the block cannot see a run-time variable. A
`Walking` instance in the closure gives "'f' is still being metaprocessed, so a meta block cannot
call it yet." If an instance fails while the block is checked, the block fails with the first error
recorded, as a Meta error that ends the walk.

I59. Inside a meta block (`Typecheck.in_meta`), an instance's body is lowered before it is
checked. One whose lowering captured a `gen` or a `code` is `quoting`: it is not emitted into the
program, and a call from outside a meta block that finds it in the cache fails with "'f' quotes
code or runs a gen, so only a meta block can call it." The "performs Gen" check is skipped in meta
context. A non-quoting instance made from a meta block is shared with run-time callers. The
reverse order (a run-time call first) still gets the old errors.

I60. A meta block nested in one being checked still runs first. What it generates is lowered with
the outer block's names in scope (`runtime_names` at that point), so `gen gen …` works. The outer
block's static names travel in the frame (`outer`), for "'n' is a value of the enclosing meta block
and does not cross into a nested one."

I61. A top-level `var` read in a meta block now gives "'x' is a run-time value and does not cross
into a meta block." It used to give "Undefined variable 'x'." The hidden names are added to
`explain`'s run-time set.

I62. `check_static` and the static `==` probe are checked in the walk (`Walk.probe`, in the meta
env), not by a nested whole check. `Typecheck.nested` and its savers are deleted. `Session.start`
always zeroes `Types.counter`: Precheck's session ends before the walk's starts, and the walk is the
only session after it (T1 no longer arises). `Compile.program` is deleted. `run` takes the processed
program to `Compile.back`.

I63. The check that a static call inside a meta block reads no meta value ("cannot be instantiated
from inside a meta block") stays a syntactic pre-pass over the block. `declof` and a meta
expression inside a meta block are still "not supported yet" (the same pre-pass, `unsupported`).

I64. `type_mono.ml` and `resolve.ml` are deleted, along with the `Type_mono`/`Resolve` diagnostic
stages, `dp_instance` (`Registry.dispatched` loses its first case) and `Resolve.synthesized`.
`bound_calls` and `coercions` leave `Ast`. They are now checker-private node families in
`typecheck.ml` (`'e bound_calls`, `'e coercions`, over `infer_ty` dispatch). The checker still
builds them while a receiver or a coercion's value is not concrete (and always in whole mode, for
Precheck). `lowered` turns them into `Call`/`Object`, so no stage type holds one.

I65. The `typed_*` stage is deleted, together with `Typecheck.resolve_expr`/`resolve_stmt` and
`Session.finish`. `Typecheck.check` returns the error list, which is all Precheck reads. The
printer's dump prints `Ast.resolved_*` directly (`string_of_processed_*`), without the arms for
nodes the processed tree cannot hold. `Ast.map_match_expr`, `map_method_defs` and `map_method_def`
went with their last users. Four definitions that were already unused before this work are left:
`Ast.map_declof`, `Ast.type_head`, `Registry.exact_index` and `Registry.register_constructor`.

I66. `lift_comptime` is now `rename_local_types`. Function lifting is gone. A local function taking
a static value is a local declaration whose instances are emitted in place (`repeat#0` inside
`main` in `core/static_params/nested/comptime_in_function`). Local types are still renamed after
their owner, and then after each instance (`renamed_locals`, T3).

I67. A comptime type (one with a value parameter or meta members) is copied through the cache.
`comptime_type` takes an id from the walk's declaration counter. The cache holds `Function of
instance | Copy of string`, keyed by declaration and `Key.show`: `Key.Value` for a value parameter,
and `Key.Type` of the resolved annotation for a type parameter. The copy's name and what is written
into its body still use the written spelling (`Buf<4>`), so diagnostics are unchanged. Two
spellings of one type now share a copy, and an unknown type argument is now a type error.

I68. **REVIEWED 2026-11-22: delete the "named by the author" (handler leaves an effect param open) exemption when written `handle<Throw<X>>` is built; keep the others. Built in S4 (I211).** Unsettled at the processed stage. `processed_expr` fails with "This is not settled when its
statement ends: its type is T, and nothing fixes it. Write the type." when a node's type holds a
free variable outside every effect label that is none of these:
- collection-kinded (it defaults to an array);
- declared (I26: a parametric instance's parameters, GADT existentials, an operation's own
  parameters in an arm);
- named by the author (`Types.param_names`: an effect parameter a handler leaves open, such as `X`
  in `block_on`'s `handle Throw`);
- unknown (`unknowns`: an error or a meta block left it);
- unobservable (the new `Typecheck.unobservable`): the result of a call to an effect operation, or
  to a function whose scheme returns a quantified variable that no parameter mentions
  (`compile_error`, a `final ctl` op), and every variable of a failed instance's signature.

`settled_at_end` answers `None` for such a type. Verify refuses a `Generic` outside rows on the
same terms. Before the exemptions, 663 fixtures had open variables at this point: all of them were
`throw(…);` results, label-only `X`s (U4/I25), the arm's `X`, or cascades after an error. The cx
suite added `compile_error` (`std/test/Test.cx`, `Bench.cx`). The message does not say "static
params": keys are already strict at the call (`key_of_use`), so what is left is local inference. An
unused lambda (`var ignore = (x) => 1;`) and a bare `Option.None` are the cases it catches. Review:
the naming exemption relies on an instance's own parameters always being bound by its key, and it
may be broader than it needs to be.

I69. `lower`'s and `promote`'s `refs` are gone. Only `meta_program` read them.

I70. Prune (A9) marks from the root statements. `referenced` records a name in `w.rooted` when no
instance and no meta frame is current, which is exactly a root statement, its end-of-statement
lowering, and a root-level meta block's generated statements. Marking follows `instance.deps`
transitively, through local instances too (their deps count, but they are emitted inside their
owner, not at the top). The output is `type_level`, then the marked instances in the order they were
processed (`w.emitted` now holds instances, not statements), then the roots. A quoting instance is
never emitted, as before. Type-level statements, including comptime type copies, are all kept (D1).

I71. D6 as built: a `Display`/`Debug` instance that keeps the declaration's name (the one
`Builtins.written` looks up) is kept when its impl's type is built by a marked body or a root. "Built"
means a `Record_lit` or `Variant` node whose type is that nominal type, which is the only way the
interpreter makes a named value (`Interp.nominal`). A `typeof` counts as building the reflection
records (`TypeShape`, `TypeField`, `TypeVariant`, `Attr`, `AttrArg`, `TypeRef`), since Reflect makes
them after the walk. A kept printer's body is scanned in turn. `printed` still makes every default
printer, but no longer roots it (it restores `w.rooted`). Rejected: keeping every printer made, which
emits `Circle`'s `fmt` in a program that never builds a `Circle`. Risk: a native that returns a named
value would need its type listed here. None does today (only `syntax.ml`, for meta values).

I72. There is no `--dump-code` fixture kind (`renderings` is the diagnostic renderer's table), so
"absent from `--dump-code`" is checked by a new probe list in `test_bootstrap.ml`, `pruned`: each
entry is a fixture that is also in `cases`, with needles that must be absent from and present in
`Printer.string_of_processed_program` of its `Pipeline.front` output, as `run_prelude_walk` does.
Checked against the pre-Prune emission: both entries fail there (`doubled`, and `Circle`'s
`Display.fmt`).

I73. Nothing in the suite relied on "every made instance is emitted": no existing fixture changed,
and `run_prelude_walk`'s three expectations hold (the `from_array` instance is reached by the
literal's own call). Before A9 the difference was smaller than the plan expected, since the walk
already made only what something reached: what Prune drops is what only a meta block reached, and
the default printers of types nothing builds.

I74. `splice.ml` (B1): a `gen` collects `Splice.fragment`s (`Stmt`, `Expr`, `Sig`, `Type`) into
`context.current`, and one `Splice.fit : 'a context -> span -> fragment list -> 'a` places them. The
context is a GADT, so each says what it yields: `Top`, `Module`, `Body`, `Meta_program` and
`Type_body` give statements, `Expression` one expression, `Trait_body` signatures. `meta_stmt` and
`run_meta` return fragments and each of the six callers fits them. `Top` is everything outside a
function, a block inside a root statement included, because only a function body rejected a
generated impl before (`Body` is chosen when `w.current` is set). `Module` drops what is not a
declaration, as `wake` did. Every fit error is at the meta block's span. "A type's meta block can
generate only its methods." moved there from the generated statement's span. No fixture had it.
`Trait_body` has no caller until B4. `error`/`Failed`/`fail` and `is_visible_to_meta` moved into
`Splice`, and `Metaprocess` re-exports the first three. `literal_of` is now `Splice.reify`,
unchanged: the `Name` case of plan 02 §3.1 comes with its first user (B6), and substitution must
never reach it (T1).

I75. `gen code(e)`, `gen code { … }` and `gen code fn …` emit what was quoted, with the meta names
substituted. Before, they emitted a statement holding the quote, which the check then rejected as
"'code' is only allowed inside a meta block". The quote is classified before substitution
(`Metaprocess.fragments`, as in 02 §3.1). A bare meta name holding a `MethodSig` or a `TypeExpr` is
a `Sig` or `Type` fragment. Any other bare name keeps the substitution path: an `Expr` value
becomes an expression statement, which `Expression` accepts as well.

I76. **ANSWERED 2026-11-22: as built, the Splice error is right (R3).** A `Type` fragment fits nowhere: "A type cannot be generated on its own; it stands only inside
other code.", at the block. Before, `gen t;` with a `TypeExpr` was a reify error at the `gen` ("This
is a type, which cannot stand where an expression does."). U3 lists `TypeExpr`, so a call returning
one is evaluated, but no context takes a type yet. No fixture. Review: drop `TypeExpr` from the U3
list, or give it a context.

I77. Meta as an expression (B2): `Typecheck.walk_ops.meta_expr` takes the run-time names and the
node and returns the fitted expression. The checker's `Meta_expr` arm then checks it with the same
`?expected`, so `var xs: Set<int> = meta { gen code([1, 2, 2]); };` is a `Set`. No variant of
`Walk.meta` was needed. The block is still statements and is checked as any meta block is, and only
what it generates is checked, in place and in the enclosing env. When it is nested in a meta block,
the expression is lowered with the outer block's run-time names, as a nested statement block's
output is (I60). No new frame either: `run_meta` already pushes one while the block is checked, and
the generated expression lands where the block stood, so at a root statement it is rooted as code
written there would be. `run_meta`'s pre-pass refuses only `declof` now. Precheck already made a
meta expression unknown.

I78. `survey` counts a meta expression as running a meta block, so a type member holding one makes
the type comptime. An instance's named type arguments (I30) and a type copy's value bindings are
written into meta expressions as into meta statements (`Metaprocess.meta_bodies`).

I79. U3 as built (B3). In `lower`, `gen e;` lowers to `meta#emit_value(e)` when `e` is either of:
- a `Call` or `Static_call` of a `Var`, or
- a `Method_call` through its `as_function`,

and that declaration's written return type is a syntax type (`Splice.is_syntax_type`: `Expr`,
`Stmt`, `Decl`, `MethodSig`, `TypeExpr`, or a `List` of one, by their `std#Ast` names). Where the
declaration is looked up: first the meta block's own local functions (per block, an inner one
shadowing), then `w.fns`. A name the meta scope binds (a local, a parameter) is never evaluated,
since its type is not written, and neither is an associated function (`T.make()`). The native
classifies the value with `Splice.of_value`. A list record is checked first, so an empty list gives
no fragments (T9). A value that is not code is "This is not code, so gen cannot emit it.", which an
honest declared type never reaches. `meta#emit_value` is typed `(fresh) -> unit` in `Builtins`.

I80. **ANSWERED 2026-11-22: as built (R3).** Since the call is evaluated, `gen f<a - 1>()` with `f` returning syntax and `a` a meta value is
now an instantiation from inside the meta program. It fails with "This argument to 'f' is not known
at compile time; only literals, constructors and the static parameters of the enclosing function
are.", at `a`. A non-syntax `f` is unchanged: emitted as `f<2>()` (`05_order/19_gen_static_arg`).
Review: whether that message should say "'a' is a value of the meta block", and whether a syntax
call should be allowed meta values in its key, which would need the key settled at run time of the
block.

I81. I17 settled: `Syntax.kind_of` knows `Sig_node` ("a method signature"). So `Splice.reify` now
refuses a `MethodSig` value written into run-time code ("This is a method signature, which cannot
stand where an expression does.", at the `gen`), as it already refused a `Stmt`, `Decl` or
`TypeExpr`. Before, it built a `MethodSig` record literal at run time. Nothing in the suite or the
stdlib did that.

I82. Comptime traits (B4). A top-level `Trait_members` is a comptime trait (`w.comptime_traits`,
`note_trait`). It is taken out of the program before collection, and the trait itself is never
declared: only its instances are. An impl naming one is held back from `collect` and from the first
`Walk.declare`. It is registered once the session has started, after the type-level statements are
checked and before the first root statement, because the trait's meta blocks need the session. So
D7's "collect order" is those impls' source order, and all of them come ahead of every root
statement's output. `register` rewrites an impl's head (`trait_instance`), so a generated impl of a
comptime trait works too, and it accepts a generated `Trait_members`. `reject_trait_members` is gone.
The checker's guard now reads "A trait whose body runs a meta block is declared only at the top
level." It is reached only by a local trait.

I83. A trait instance's name is `Getter<int>`. With open slots it is `EffectHandler<Effect, _>`, and
a trait with no parameters keeps its own name. It is keyed by the resolved types, `_` for an open
slot, in `w.cache` under the trait's own id as a `Copy`, and entered before its blocks run. A bound
parameter whose argument is a simple name is written into the meta blocks as a `Value.Name`. A
compound argument (`List<int>`) is not, since a type is not a value there; it goes only into the
signatures. After the blocks run, the written and generated signatures and the supertrait arguments
are substituted with the whole argument as a `TypeExpr` value (T13). This goes through
`substitute_sig` and `substitute_type`, over the new fourth component of `substitution`. The
instance's own params are the trait's names at the open slots, and the impl passes its own
parameter as the argument, so T12 holds by construction.

I84. The duplicate check is the caller's, as handed off. It covers written against generated and
generated against generated, at the block that generated the second: "Trait 'Getter' already has a
method 'get'." A missing generated method is the checker's existing "'Getter<int>' for 'Box' is
missing method 'get'." (T14: the instance name is shown inside the quotes).

I85. A method from a trait instance is in scope wherever the trait's written name is.
`Typecheck.written_trait` strips the `<…>` in the method-reach check. Not supported yet: a bound that
names a comptime trait (`<H: Getter<int>>`). The checker's `ctx_traits` holds only the instances, so
its `is_value_param` would read the bound as a value parameter (T2 on the checker's side; the walk's
`w.traits` does know it). No fixture meets this. `handle<E>` in Phase C needs `trait_instance` (I5)
from that path.

I86. `declof` (B5) is `Typecheck.walk_ops.declof span target name static_args`. The checker's arm (in
walk mode, inside a meta block) resolves the operand. A walk declaration takes its key from the
written static arguments. It goes through `write_static ~implicit:true`, so a function whose only
static params are implicit takes them positionally (D3). A function with no static params takes
`{}`, and one with static params given none is the unkeyed error. The op makes or reuses the instance
with `made ~use:false`, which is `instance` without `referenced`. The surface is then spliced as
`meta#code_decl(k)`, with the declaration in `context.codes`, so each evaluation builds a fresh
`Decl` (T8). Since it is not a use, an instance made only for `declof` is never marked by Prune (the
`declof/pruned` probe). Its meta blocks still run, once, and a later call reuses the instance.

I87. **CONFIRMED 2026-11-22: keeps the declaration's own name.** What `declof` returns of a function instance is built from:
- the body the checker was given (`instance.source`), after value binding and named type arguments
  and before lowering;
- each meta block in it replaced by what it generated (`instance.generated`), keyed physically by the
  block's statement list and recorded by the walk's `meta`/`meta_expr` ops while an instance is
  current;
- the parameters and the return at the key, with a key type written back by `Splice.type_expr_of`;
- no static params, and a value param left as the `var n: int = 3;` that `bind_values` puts first.

It carries the declaration's own name (`id`), not the instance's (`id#0`, which `str` shows as `0`).
Review: plan 02 said the instance's name, but the design renames before generating again either way.
Only a simple type name is written into the body, where a parameter may also stand as a value
(`T.zero()`).

I88. `declof` of a type, trait or effect gives it as `w.types` holds it. A comptime type or trait at
written arguments gives the copy or instance, so `declof(EffectHandler<Effect, string>)` shows the
generated signatures. A bare comptime trait comes back with its meta blocks, as a `Trait_members`.
Other cases are errors:
- a local, a parameter, a builtin, or a meta value not of type `Name`: "'n' is not a declaration."
- a `Walking` instance: "'f' is still being metaprocessed, so declof cannot see it yet."

An effect is not a static type argument ("Unknown type 'Bark'"), so `declof/static_param` uses a type
and a trait.

I89. A dynamic `declof` (02 step 7) is `declof(n)` with `n` a meta value of type `Name`. The checker
lowers it to the native `meta#declof(n)` (`(Name) -> Decl` in `Builtins`), which runs
`declared_by_name` while the block runs, re-entering the walk as `moduleof` does. It takes key `{}`
only. A function with static params is the unkeyed error, raised while the block runs, and
`declof(n<…>)` is "not a declaration". The instance is made outside the block's check (`in_meta` is
false by then), so it is an ordinary instance that run-time callers share. Errors are the block's,
Meta stage, at the `declof`.

I90. **REVIEWED 2026-11-22: B, a static param only in the return type, at a call whose value is discarded, defaults to `Unit` (unobservable, like R4); `effect`→removed with old syntax; `String` per R30. Built in S4 (I212).** `traits/effect_handler` departs from the doc's code in three places:
- `effect` is still a keyword, so the binding `DeclKind.Trait(effect)` is `eff` until C8 drops the old
  effect syntax.
- `fail` comes from `std/core/Error` and is written `fail<unit>(…)`. Its `T` stands only in its return
  type, and a key is settled strictly at the call (01 Q2), so `fail(…)` as a statement is "The static
  params of 'fail' are not settled here: {T = ?}." Review: whether a static param standing only in a
  return type should default the way U4's does in labels. That would make the doc's line check as
  written.
- `String` is `string`.

`Collector<R>`, an impl of `EffectHandler<Effect, R>` with R open, is declared and checked but not
called: an associated function of a generic type has no call syntax (`Collector<int>.log` does not
parse). That is the doc's `type Picker<R>`, reached through a run in Phase C. The generated
signatures keep the op's `@ctl` attribute, since `handled` copies `op.attrs`.

I91. `typeof` is spliced (B6). The checker's arms, `typeof(e)` and `typeof(e).name|shape|attrs|doc`,
type the operand through `reflected_type`. That restores the statement's hoisted list and runs under
`walk_ops.unused`, which restores `w.rooted`, the current instance's deps and the frame's reached,
so the operand is not a use (T4). The arm then splices `Splice.reflected`, which is reflect.ml's
builders retargeted to `Value.value` and written back by `Splice.reify_with ~names:true` (the `Name`
case). Substitution keeps `reify` without that case (T1). The arm checks the result against the
answer's type (`string`, `TypeShape`, `Array<Attr>` or `Type`), and a projection builds only that
field. Whole mode (Precheck) types `typeof` without splicing.

Deleted: `reflect.ml`, the `reflected_*` stage (`Cps` takes `resolved`), `Diagnostic.Reflect`,
`reflect` in the checked and processed kinds, the built-in `Type` (`Types.reflection_name`,
`ireflected` and its `declare_fields`), the now-unused `Types.shape_name` family, and Prune's
`Typeof` list in `constructed` (the splice gives ordinary `Record_lit`/`Variant` nodes). `Type` is now
a record in `std/meta/Reflect` with `impl Display` writing `name`, global-imported by the prelude.

I92. A meta block sees the type of a run-time name (02 §3.3, T5). Before a meta block runs, as a
statement or an expression, each `typeof` whose operand reads a run-time name the block does not
shadow is spliced (`Metaprocess.typed_body`). The splice uses `type_in`, a closure the checker passes
to the `meta`/`meta_expr` ops that types the operand in the enclosing env (`reflected_type`). This is
the full version for any operand, not plan 02's interim for a parameter or an annotated local only.
`meta print(d)` is still `dynamic_in_meta`.

I93. A Precheck bug, found while writing `params/typeof_param`. A generic function holding a meta
block failed at its second key ("Expected int, got string"). Precheck appended `return <unknown>` to
every function that ran a meta block, and an unknown is never quantified, so the first call fixed
the parameter. Now the tail is the unknown only when neither the signature nor the body's own
`return` says what is returned. Otherwise it is `compile_error(__span_generated(), "")`
(`Precheck.anything`), which takes whatever type it is returned as and is quantified with the
function. Reproduced on a B3 build, so it predates B4.

I94. Tail calls for every closure (C2, B1). A closure whose body the CPS pass did not cut (no
`Cont`, `Frame`, `Scope`, `Abort` or `On_unwind` among its statements, found once per body) and
that re-enters no scope now hands back the call it ends in: `return f(x)`, or a final bare
`f(x);`, with no `defer` pending, through `if`, `match` and block tails. A bare `f(x);` leaves unit
whatever the chain gives back, so the pending call carries `discards` to the end of the bounce.
Two traps found on the way:
- A builtin that applies a closure directly (`Display`/`Debug` through `written`, an `Eq` impl,
  `discontinue`) is followed by no bounce, so a closure checks that `call` (or `bounce`) is the one
  entering it (`entering`, by identity) and otherwise makes the handed-back call itself.
- A bounce that put back a frame's scopes returned whatever its inner bounce left pending, which
  "the bounce outside" used to pick up because a non-tail call frame sat between them. Flattened,
  nothing did (every program deadlocked in `block_on`). The outer bounce now goes on looping. A
  call handed back by an ordinary closure inside a bounce that installed scopes is made in a nested
  bounce with none, which is where `call` made it before.
`tests/core/functions/tail_call_deep` (1e6 calls through lambdas, mutual and self) went from 29 s
to 0.7 s; OCaml 5's growable stack had let it pass slowly before.

I95. The discontinue signal (C2, B2): `__discontinued<T>(): T`, `__is_discontinued<T>(x: T): bool`
and `discontinue<A, R>(k: (A) -> <ρ> R): <ρ> unit` are natives in `Builtins` (the new `effectful`
list, typed whole so that `discontinue`'s row is its continuation's). `Interp` reads the signal
value from `Builtins.discontinued`. Under the old backend two things do not work, and
`tests/effects/discontinue/signal` avoids both: a continuation that performs an effect cannot be
handed to `discontinue` (evidence passing adds an argument the native does not pass), and the
signal cannot be a top-level statement's value (an old continuation tests every value it is
resumed with). None of the three has a doc string, so `cx docs` does not list them yet.

I96. An effect is a trait with at least one method, none taking `self` and none naming `Self`
(`Ast.is_effect`; D4 refined). The `Self` clause keeps `Zero`, `One`, `FromArray`, `Decode`,
`Cli`, `TryFrom` and the fixtures' `Make`/`Defaulted` out: their methods build a `Self`, which a
bare call has nothing to stand for. It is not "a trait used in a row": the Working Example writes
`Ask` in no row.

I97. The loader resolves a bare operation of an effect trait to `Ast.operation_name trait m`
(`Ask#op#ask`, which no program can spell and whose last part `shown_name` shows). Reachable bare:
the file's own effect traits and those imported by name, locally or by a global import. Two
candidates is a Load error at the call, "Ambiguous operation 'log': Log.log or Journal.log.".
`Log.log(…)` names one. The file's own names and names imported by name still win (T1, value
first), and an effect trait's operation wins over the old "is an operation of 'Throw', which this
file does not import" error, so a file's own `trait Fail { @ctl fn throw<T>… }` is reached. A
dependency compiled to an artifact records its operations as names only, so its effect traits'
operations are not reachable bare from another package yet.

I98. The checker registers an effect trait as an effect as well as a trait (`declare_effects` for
its parameters, then `declare_operations`, factored out of the `Effect_decl` arm, from the trait's
`Trait_decl`). Each method becomes an `op_decl` (`operations_of`): unmarked is `Op_fn`, `@ctl` is
`Op_ctl`, and `@ctl` whose result is its own static parameter, standing in no argument, is
`Op_final`. That kind is what gives the fresh result at each call site (D9) and keeps the
"A deferred statement cannot fail" check. A method with no result written returns unit.

I99. `check_run` keeps the old path, unchanged, for a run whose clauses are all old. Any
`handle<E>` or `with T` (T not a `handler`) goes to `check_bindings`, which also takes old clauses
in the same run:
- `handle<E>`: E must be an effect trait ("'int' is not a trait, so it has no operations to
  handle.", "'X' is not an effect, …"). Its arguments are written or fresh, settled by the body's
  row (A4).
- `with T`: T must be a type ("Unknown handler 'T'.", as before). It binds each effect T
  implements, as `impl E for T` or `impl EffectHandler<E, R> for T`, that the body's row holds.
  In the walk the impl names a trait instance, read back through the new
  `Typecheck.trait_instances` (filled by `instantiate_trait`); in Precheck it names the comptime
  trait itself with its written arguments. An impl whose R is bound unifies it with the run's
  answer. None bound: "'T' handles nothing this run performs.", at the run.
- One effect bound by two clauses: "'Log' is handled twice in this run.", at the run.
- What is left of the body's row after the bindings is the run's row, unified into the
  enclosing one, and is ρ in each continuation's type, `(A) -> <ρ> R` (U2).
- A method of `handle<E>` is checked in place, so what it reads from around the run is captured
  as a lambda captures it. Its parameters take the operation's types (A5); a written one must
  agree. A `@ctl` method has the continuation last and returns R; an unmarked one has the
  operation's own signature. Falling off the end unifies the return with unit. The operation's
  own static parameters stay the handler's to leave alone (`own_params_unsettled`, shared with
  the old arms). Errors: "This handler for 'Two' is missing method 'b'.", "Trait 'One' has no
  method 'c'.", "'ask' takes 1 parameter(s) in this handler, but 0 are written.".
Precheck types all of this with the same code (M5), so unreached runs are checked and functions
keep their rows.

I100. `run<R>` is accepted. A new-syntax run with no `<R>` meets the expected type, then the
body's value (unit for a statement run). An old-syntax run is checked exactly as before.

I101. In the walk, `handle<E>` for an effect with a `@ctl` operation and no parameters reads its
methods' shapes from `EffectHandler<E, _>`, made through `instantiate_trait` (the walk op
`effect_handler`, open slot `handler#answer`), so the library's meta block is what decides them
there. The continuation's row in the instance is empty, since `TypeKind.Function`'s row cannot
hold a variable (R7), and the checker puts ρ in its place. Precheck, an effect with no `@ctl`
operation, and a generic effect use the same rule written in OCaml: a generic effect's instance
would need `declof` of a compound argument, which I83 does not write into the meta block.

I102. Not made yet: the anonymous handler type and its impl. A method captures locals, so an impl
at the top level can only be checked once the handler value is threaded (C4), and the interim
record of closures needs its fields' types written, ρ included (R7). The checked run keeps each
`handle<E>` clause as an `Ast.handler` whose arms are its methods, continuation last, and a `with
T` binding as an arm-less one. Nothing consumes them: `cps.ml` refuses any run that handles a
trait, "A 'run' that handles the trait 'Ask' is not supported yet." (CPS stage), where every
`Run` is converted.

I103. `EffectHandler<E, R>` is `stdlib/core/EffectHandler.cx` (core holds the language's traits),
global-imported by the prelude and listed in `internal-docs/stdlib.txt`, the layout `cx`'s
`library layout` test reads. It is the doc's code with I90's three departures (`eff`,
`fail<unit>`, `string`) and the pure continuation of I101. `Core.effect_handler` names it.

I104. **REVISED by the user 2026-11-22: B, handlers come out of the key; the key holds the row, the handler is always passed as a value (follows R1); one processing per key, no probe, meta blocks run once; specializing for a visible handler is a later optimization. To build.** `Key.Handler h` is a key entry `(label, Handler h)`: the effect `label` is bound to the
handler type `h`. Entries follow the static parameters, sorted by label, and show as `{Log =
handler#1}`. Which entries a call's key gets (`bound_handlers`): each binding in scope whose label
the instance at the plain key performs. That instance is made first under `unused`, as a probe,
and only its row is read. A rows-free rule would have to extend every instance a run body reaches
(`print`, `str`, the stdlib), each with the hv parameter threaded through it. **Cost:** a function
that performs a bound effect is made twice, at the plain key (pruned, I70) and at the bound one,
so a meta block in it runs twice. A walking probe (recursion through a run) offers only the row it
has so far. Review: whether to make the plain instance cheaper or skip it.

I105. **CONFIRMED 2026-11-22: record of closures for now; inline handlers become anonymous types when references exist.** A handler's value, interim (03 §3.5): `handle<E>` is the OCaml-side handler `handler#n`, one
per clause per check, and its value is a record of closures, one field per method that takes no
control, of the structural type `{ log: (string) -> unit }`. It is built at the run site as `var
hv#n = { log: (msg) => { … } }`, so the closures capture by reference as lambdas do. No Cronyx
`type __Handler#n` or `impl` is declared: fields captured by reference need references, which
Cronyx does not have yet (memory: references design), and a method body reading `hv.x` would need
them. An instance at a key binding a valued handler takes the value as its leading parameter
`hv#<label>`, before `self`. `Typecheck.visible_type` strips them from the instance's type, so
callers unify against what was written. **Departure from the doc:** an inline handler with a method
always has a value, its closures, even if it captures nothing, so "the parameter disappears" holds
only for a named handler (`with T`) and for an inline one whose methods all take control.

I106. In a run with no old clause, the methods that take no control are checked before the body
(Precheck too, since it is the same code). The body reaches them through the value, whose type
they give. The methods that take control are checked after, as before, since they need ρ. Each
such method is checked in a row of its own, which is then contained in the run's surroundings
(`row_within`), as it was before. Its field's row is empty, since what it performs was settled
where it was written: the old backend's evidence for a `fn` effect (`print`'s Console) is captured
lexically by the closure. A method that performs an old effect that takes control is rejected,
"A handler's 'log' that performs 'Stop', which takes control, is not supported yet." Otherwise
the old backend would run it without a continuation, which happened silently: it resumed where it
should have aborted.

I107. The call branch (`bound_operation`): an unmarked operation whose label is bound becomes
`hv.log(args)`, which is `Call(Field(Var hv, "log"), args)`, for an inline handler. Here `hv` is the
run's `hv#n` or the instance's `hv#Log`. For `with T` it becomes a call to T's impl method instance,
entered with the bindings from outside the run (`bd_outer`), so an operation it performs reaches
the enclosing handler, as an inline method's does. The operation is still typed as an operation
call, so its label enters the row and the run discharges it as before. Rows are unchanged from
Precheck. A call to an instance whose key binds valued handlers passes them first (`reached`
returns them). Not supported yet, as errors: a function named as a value at such a key ("'greet'
performs 'Log', whose handler here has a value, which a function named rather than called is not
handed yet."), and a registry-built call (operator, `Display`, bound method) reaching one.

I108. **Interim, replaced by C5:** the transform for a run whose handlers have no `@ctl` operation
is the identity on processed code, implemented in the compiler (`check_bindings`), because the
library `effect_transform` does not exist yet. Such a run (new clauses only, walk mode) keeps no
clause: it becomes `Run(hv declarations @ body, [])`, which `processed_stmt` emits as a `Block`.
Nothing calls library code. A run with a `@ctl` operation already binds its unmarked operations
and builds its value, but keeps its clauses, and CPS still refuses it ("A 'run' that handles the
trait 'Ask' is not supported yet."). So does a run that mixes old and new clauses, which binds
nothing.

I109. The loader reads a bare name as the operation when an effect trait is named like its own
operation, as in `trait log { fn log(…) }`. The trait name is not a value, and without this rule the
file's own name won and `log(…)` was "Undefined variable". This applies only to that case, and is
needed by the migrated `v2/log` and `v2/handler` (R12 keeps lowercase names).

I110. `with Picker` for `impl<R> EffectHandler<Effect, R> for Picker<R>` does not bind `log` yet:
the impl method's R is not tied to the run's answer at the call, so its key is unsettled ("The
static params of 'log' are not settled here: {R = ?}"). `v2/named_handler_generic` stays in
`expected_failing` (C5), now failing there rather than at CPS.

I111. **C5a: the run's fixed meaning, in place of I108 for runs that take control.** In the walk, a
run with no old clause and an inline `handle<E>` for an effect with a `@ctl` operation checks every
method of its handlers first, then checks, in the body's place and under the run's bindings,
`meta { gen std#Transform#effect_transform(code { stmts }, Option<code(value)>, [labels]) }`
(`Typecheck.transformed`). The run keeps no clause, so it is a `Block` after the walk and `cps.ml`
never sees it. I108's identity stays for runs whose handlers take no control. The library is
`stdlib/core/Transform.cx` (next to `EffectHandler`, as asked; the plan said `effects/`), imported
by the prelude, and `Core.effect_transform` names it. The interface is
`effect_transform(body: List<Stmt>, value: Option<Expr>, bound: List<Name>): Expr`: the labels the
run binds whose operations take control, not `<R, ...H>` and handler values (D1). The library never
names a handler, because the core binds operations (I112). R is not passed: every continuation's
answer is inferred from the handler method it is handed to.

I112. **REVISED by the user 2026-11-22: B, delete the handed form; the transform emits `h.op(args, k)` itself (handler is a value, I104); hand-written `ask(k)` is an arity error; `with T` for `@ctl` effects then works. Answers N2. To build.** **A `@ctl` operation handed its continuation is bound by the core.** An operation that takes
control, called with one argument more than it declares (`ask(k)`, `choose(options, k)`), is typed as
that operation handed the rest of its caller: its parameters, then `(A) -> <ρ> α`, answering α
(`Typecheck.handed`, `infer_handed`). Under a binding with a value it becomes `hv.op(args, k)`, the
same way `bound_operation` binds an unmarked call. The method's type is copied per call with the
operation's own parameters fresh (`per_call`), so `throw<T>` is handed an `int` continuation in one
copy and a `string` one in another (`v2/throw_fresh_result`). The value is annotated there as a
one-field record holding that copy, since Verify takes a `Var` at its word and checks the field
against it. Unbound (a probe at the plain key), the call performs its label, so the probe of a
copied function sees what to bind. Bound through `with T`: "A run that binds 'E', which takes control,
through a named handler is not supported yet." This follows plan §2 ("binding is the core's job;
splitting is the transform's"). It is what lets a copy reach its handler as `hv#E` through the key
(C4), with that value's type still live. Rejected: the copy taking the handler value as an implicit
parameter. Its type then enters the copy's key, and a key closes rows, so the continuation row in the
value's type was closed at the first copy ("Expected a function performing , got one performing
<Console>"). Review: the handed form is writable by a program too (`ask(k)` under a run). Is that
acceptable, or should it be a node only generated code can hold?

I113. **Continuation rows, interim (refines U2 until C6).** A method that takes control is checked
apart (`handle_block ~apart:true`): in a declared row of its own, contained in the surroundings, and
calling its continuation through a declared row `resumes`, which is contained, not tied. The generated
code hands each continuation one typed with `given`. Once the body is checked, `resumes` is unified
with `given` less the run's bindings, and contained in the surroundings. So a continuation's type
says what the rest of the body performs, not everything around the run. Why: tying ρ to the
surroundings put the root's `async`/`Throw` in every continuation's type. The old backend then
converted every arm and continuation: `cps.ml` lost a `var` bound from a continuation call
(`working_example`: "Undefined variable 'res'"), and calling a method whose row was the surroundings'
tied the body's row to the run's ("This effect row is recursive"). **Limitation:** every continuation
handed to one operation in one run shares `given`, and a copy's key closes it. So those continuations
must perform the same effects, or the second one reports "Expected a function performing …".
Review in C6 with honest rows, outer runs and R7.

I114. A handler's value now holds every method, the ones that take control included, as plan §3.5's
interim says. The record literal is annotated with the methods' own types (continuations through
`resumes`, the row of each one taking control its own). The body sees the same record with `given`
in each continuation (`handler_values`). Verify checks a record literal against its fields, which is
why the two differ.

I115. **R1, `processed`.** `processed(body: ValuedBlock): ValuedBlock` and
`processed_fn(d: Decl): Decl` are in `std/compiler/Ast` (natives `__processed`, `__processed_fn`).
They work in every meta block that stands in checked code, not only the transform's:
`Typecheck.meta_scope` is set by the walk's `Meta` and `Meta_expr` arms (`in_scope`). The code is
checked in a child of the block's env, in a scratch ctx (a fresh row, its own hoisted list), under
`unused`, and under whatever bindings are in force. A type error there is a Meta error at the code's
span. `processed_fn` checks a body in the top env, with its parameters at their written types. A
top-level meta block has no scope: "Only a meta block inside checked code can ask for processed
code." **Cost:** a run body is checked twice, once by `processed` and once as the transform's output.
So a meta block in a run body runs twice, and nested runs would be transformed 2^depth times (C6).

I116. **R2, `Expr.ty: Option<TypeExpr>`.** It is `None` in a quote. `processed` fills it from a table
`located` records while `Typecheck.recording` is set, keyed by physical identity and resolved
afterwards. A type still holding a variable answers `None`. A callee the call branch resolves is
never `located` on its own, so it is recorded from the resolved call, without the handler values
passed first (their record type holds an operation's own `T`). `Syntax` writes `ty` through
`Syntax.typer` and ignores it when reading. The `Expr` literals in `std/test/Test.cx` and
`std/test/Bench.cx` gained `ty: Option.None`.

I117. **R4.** `fresh(prefix): Name` hands out `cx<n>#<prefix>`, which is unwritable and shown as the
prefix. **Not built: the resolved-reference `ExprKind`.** Straight-line output names only fresh names,
operations as processed code names them, and copies. Copies are top-level declarations whose bodies
were resolved where they were written, so nothing generated can be captured by a local. It is needed
once the transform names a library function itself (`discontinue`, `__is_discontinued`, C6).

I118. **R5.** `Operation { label, name, takes_control }` and `operation_of(callee): Option<Operation>`,
read from the checker's operation tables (`Typecheck.operation_of`). The field is `label`, not
`effect`, because `effect` is still a keyword (C8).

I119. **Callees (4.5).** `declare(d: Decl)` (native `__declare`, through `register`) declares at the
top level from any meta block, because a meta block standing as an expression splices exactly one
expression and cannot `gen` a declaration. A copy is `fn <fresh f>(params…, k)`. `k` is an implicit
parameter, so the continuation's type is part of the copy's key. Its return and row are unwritten.
There is one copy per call site: there is no cache (R6 not built), so recursion does not terminate
yet. A callee is found with `declof(name)`, which takes key `{}` only, so a generic callee (implicit
parameters, `exception/exception`'s `divide(n, d)`) fails at the `declof`. A plain statement in a copy
has each `return` (outside function values) hand its value to `k`, and the copy ends `return k(())`.

I120. **R8 and R7 are not built.** A tail with statements before its value is spliced as
`(() => { …; return v; })()` (D2). That is a closure per run, and it is correct while no `return`
crosses a run (C6 decides). R7 is not needed: copies write no function type, and a row parameter
written by name in a `TypeKind.Function` row already reads back as `<E>`.

I121. **RESOLVED 2026-11-22: C6b's fixes; `hello` now ~79 ms, under the pre-library 92 ms. Answers N1.** **Cost of loading the library.** `Transform.cx` is loaded with every program (prelude import),
which adds about 35 ms to every compile (`hello` 92 → 127 ms, the whole bootstrap suite about 80 →
117 s). Once `Throw` takes control (C7), every program needs the library anyway. Review: load it only
for a program holding a `handle<E>` until then, or make Precheck of an unchanged stdlib cheaper.

I123. **Compile time (plan §10), C5a.** Each run below is the median of 7, compile and run together,
with the library loaded in both columns. Old-syntax original → `v2` copy: `flip` 127 → 141 ms
(1.11x), `recover` 127 → 145 (1.14x), `delim` 127 → 142 (1.12x), `nested_return` 128 → 147
(1.15x), `two_runs_one_expr` 127 → 145 (1.14x), `run_value/value` 132 → 148 (1.12x),
`multi_handle` 127 → 149 (1.17x), `suspend_in_record` 127 → 147 (1.16x), `ask` (no control)
126 → 126. Against the build before C5a (no library loaded, about 92 ms for a small program), a
one-run program is about 1.6x. Per run the cost grows: 40 copies of the Working Example take 297 ms,
against 156 ms for the old syntax. That is about 3.9 ms per run against 0.8 ms, or 2.5x the
pre-C5a old-syntax total, under the 3x stop. The likely cost per run is the meta block's
`Compile.back` of everything it reaches (the whole transform) on every block, plus checking the
body twice (I115). Not profiled.

I122. **What C5a refuses**, each a Meta error at the construct, "… is not supported by the transform
yet.": a call that takes control inside a loop, an `if`, a `match` (statement or expression), a
block, a `defer`, a nested `run`, a local declaration, a tuple `var`, a function value, `&&`/`||`; a
`return` out of the function a run stands in; and a named handler for an effect that takes control
(I112).

I124. **C5b: control flow in the transform** (plan §4.3, §4.4, §4.7). A `Tail` now ends in
`Option<Expr>`, `None` when every path through its statements returns.
- A branching statement holding a split (`if`, `match`, a block) declares what follows it first,
  as `var join = (u: unit) => { rest }`, and each branch ends `return join(());`. A lambda, not a
  local function, so no type is written. A `match` statement is followed by `return join(())` too,
  for an arm that falls through. A statement every path of which leaves (`return`, `break`,
  `continue`, an `if` whose two branches leave, a `match` whose arms all leave: `__tx_leaves`) gets
  no join. Without that rule a copy of a function ending in such an `if` ends `k(())`, which does
  not check against an `int` continuation.
- A loop holding a split is `var after = (u: unit) => { rest }` and a local
  `fn loop(u: unit): R { if (c') { body'; return loop(()); } else { return after(()); } }`, then
  `return loop(())`. It is a local function because it calls itself, so its return type is
  written (T9): `Cx.answer` is the type of the run body's value (unit for a statement run) or the
  copy's `R` (I126). The condition is evaluated inside `loop`, so a split in it is performed on
  every iteration. `break` and `continue` become `return after(())` and `return loop(())`, at the
  statement level and inside plain statements (`__tx_exiting`, which stops rewriting them at a
  nested plain loop, where they are that loop's). The loop relies on the interpreter's tail calls
  (I94).
- `for (x in xs)` over a `List` or an `Array` is lowered by the transform into the indexed loop the
  checker uses: the sequence and the index are evaluated once, and the step comes before the body,
  so `continue` needs nothing more. Over anything else (a string, an iterator) it is "A loop over
  this sequence holding a call that takes control is not supported by the transform yet.". C-style
  `for` arrives already lowered by the parser (A2).
- `a && b` or `a || b` with a split on the right becomes a branch: `var join = (v: bool) => {
  rest(v) }`, then `if (a') { b' handed to join } else { return join(false); }` (the other way
  round for `||`). A split only on the left stays an operator.
- A `match` expression holding a split hands each arm's value to a join, typed with the
  expression's `ty`.
- More ANF: a tuple `var`, a `match` scrutinee, `match` expressions, a variant's named payload,
  `NewGeneric`, and the compound assignments, keeping the order (I116's rule: earlier operands held
  in temporaries).

I125. **What C5b still refuses**, each "… is not supported by the transform yet." at the construct
(C6):
- A `defer` anywhere but the run body's top level after its last split: "A 'defer' in code split at
  a call that takes control …". At the top level after the last split, the defer still runs last,
  so it is left alone, as in C5a.
- A `return`, `break` or `continue` that the transform makes a call, from inside a scope with a
  pending `defer`, since the defer would run after the call: "Leaving a 'defer' in code split at a
  call that takes control …".
- A split inside a function value, a nested `run`, or a local declaration. The message names the
  innermost such construct, which is found by descending (`__tx_culprit`), not the outer statement.
  An inner run reaches the outer one already transformed, so a nested run's leftovers show as
  "inside a function value" (`v2/generic/nested`).
- A `return` out of the function a run stands in (unchanged).
- **Not caught:** a method whose body takes control, called in the region (`c.bump()` where `bump`
  calls `tick()`). The transform cannot see the method's row, because `processed` records only a
  method call's result type. So the call is left whole, and the method's `tick()` runs unbound:
  "Runtime error: Undefined variable 'tick'". A checker-side net (an unhanded `@ctl` call in an
  instance whose key binds its effect) does not work: the instances `processed` makes at bound keys
  hold exactly such calls before the transform splits them, and they are cached. C6 needs
  `processed` to give a method call its callee (the resolved method instance and its type), and
  then a copy taking `self` first.

I126. **Copies (§4.5).** A copy is `fn copy<R, E>(params…, k: (T) -> <E> R): R`, where `T` is the
call's `ty`. Its return type is written, so a copy that calls itself checks (T9), and it is generic
in what the continuation answers and performs, so one declaration serves every run: each call's key
settles `R` and `E`, and its handlers. `R` and `E` are `fresh` names, so they cannot capture a type
the copied body writes. When the call has no `ty` (a type variable left in it), the copy falls back
to C5a's untyped `k`, which cannot recurse. The cache is a native memo kept for the whole program
in the walk's world (`remembered(key)`, `remember(key, name)` in `std/compiler/Ast`, R6). It is
keyed by `[instance_of(callee)] + bound labels`, and the name is reserved before the body is made,
so recursion and mutual recursion terminate. It is shared across runs, because a copy's body depends
only on the instance and on which labels split. 15 copies of `loop_exits`' first run went from
0.82 s to 0.38 s. The trap C5a hit (an implicit-param callee nested in its own lambda argument) does
not arise with a written `k`.

I127. **Generic callees.** `declof_call(callee)` and `instance_of(callee)` (natives `__declof_call`,
`__instance_of`) replace `declof(name)` in the transform. `Typecheck.instance_at` takes a fresh use
of the callee's signature, unifies its parameters and result with the callee's recorded `ty`
(rows are left out: what an instance performs is no part of its plain key), and reads the key with
`key_of_use`. `declof_call` is then `declared_instance` at that key, so `exception`'s
`divide(n, d)` is copied at `{n = int, d = int}`. `instance_of` is the declaration's name followed by
`Key.show` of the key, used only as a cache key.

I128. **Generic effects.** Their handed form binds as written. The gap was earlier: an inline
handler's methods are checked before the body (I111), so `fn yield(x, k) { print(x); … }` met
`print` with `T` unsettled. When an inline handler's effect arguments are still variables, the
walk now checks the surface body once with the run's bindings not pushed, under `unused`, in a row
of its own (`ctx.hoisted` restored), and unifies each handled label's arguments with what that row
holds. **Cost:** a third check of such a body, and of the meta blocks in it, only for a generic
effect whose arguments are not written. Open for C6: `__tx_binds` compares labels only, so an inner
`Yield<int>` run and an outer `Yield<string>` run look like the same effect to the outer transform.

I129. **Named handlers for effects that take control** (`with T`, I110, I112). `v2/named_handler_generic` flipped.
- A run takes its fixed meaning when a named handler implements an effect with a `@ctl`
  operation, as an inline one already did. Those labels are handed to `effect_transform` too.
- `bound_operation`'s named path takes the handed form, `op(args, k)`. It becomes a call to `T`'s
  impl method instance, entered with the bindings from outside the run, as an unmarked one is
  (I107).
- `open_continuation`: in the walk, an impl method of `EffectHandler<E, _>` whose operation takes
  control, and whose last parameter is a function type written with no row, is read as having a row
  parameter of its own there, `resumes#<method>`: `(A) -> <ρ> R`, settled at each call, as an inline
  method gets ρ (I101). Without it, a written `(unit) -> unit` is pure (R7). Verify then rejected
  every continuation that performs anything ("An argument should be (unit) -> unit but is
  annotated (unit) -> <stream> unit").
- A handed call through a named handler keeps its label in the caller's row, which is how `with`
  sees what it binds. `performed` also reads the rows of the inline methods' continuations (`given`,
  I113), so a `with T` in a run that also has an inline controlling handler binds an effect
  performed only after a split (`v2/two_controlling_effects`).
- An impl parameter that the method's signature never names, such as `Picker<R>`'s `R` in `log`, is
  settled to unit at the call (I110). Nothing the call passes could settle it, and the method's type
  does not depend on it. Rejected: tying it to the run's answer through the binding. That works at
  the run body, but a copy rebuilds its bindings from its key, which holds no answer
  (`v2/named_handler_in_copy`).
- A probe's unbound handed call also performs its continuation's row. Otherwise a copy whose
  continuation is the only thing performing an effect (an inner `pick` after a `tick`) was keyed
  without that effect's handler, and the operation was left unbound at run time.
- Migration: `handler h : E { … }` + `with h` → `type H {}` + `impl EffectHandler<E, unit> for H {
  … }` + `with H` for the two whose arms fall off their end (R21: `logic/multi_guard`,
  `stream/stream`). `Picker<R>` stays generic.

I130. **Performance (plan §10).**
- `Transform.cx` is loaded only for a program whose units' tokens hold `handle <` or `with`
  (`Loader.binds_by_trait`, walked after `Core.modules`). The prelude no longer imports it. This
  decides what is loaded, not what runs, so it is not a hook. The check is syntactic, so an
  old-syntax `with h` loads the library too (old `stream` 84 → 137 ms). Once `Throw` takes control
  (C7) every program loads it anyway. A dependency compiled to an artifact whose own code holds a
  run, linked into a program with none, would miss the library. No fixture has one.
- `__tx_splits` and `__tx_reaches` no longer re-scan a call's arguments at each level. That scan was
  exponential in how deeply calls nest.
- Copies are shared across runs (I126).
- Precheck, which is every program's largest cost (hello: 67 of 94 ms), spent 41 ms in `env_free`.
  Every generalization walked every top-level binding. The env now keeps `open_names`, the bindings
  whose schemes may leave a variable free. `bind` files a scheme by `closed_scheme`, and a walk drops
  any it finds closed. A scheme whose every variable is quantified stays so. The three free-variable
  kinds are read in one walk (`env_free_all`). Precheck of hello is 67 → 56 ms. Rejected: skipping
  the hoisted, unchecked functions' schemes as well. `pending_calls` shows a checked function can
  share a row variable with one.
- **Not done:** caching `Compile.back` across meta blocks. It is about 2.3 ms per block (CPS 1.7,
  Verify 0.6), mostly converting `__root`'s async runtime, which every meta block runs under. That
  is cps.ml's whole-program `collect`, and cps.ml goes in C8. Measured and rejected as a special
  case: running the transform's own meta block without `__root` saves about 1.2 ms per run. **Not
  done:** removing the double check (I115). `processed` returns the surface body with types, so the
  transform's output still holds whatever the body held, and it is checked again in full. Checking
  it once would need `processed` to return checked code that can be checked again (R7/R8), which is
  C6's nested-run work.
- Numbers (median of 7, compile and run, ms): `hello` 83 (C5a: 127; before C5a: 92). Old-syntax
  original → `v2` copy: `nested_return` 84 → 158, `two_runs_one_expr` 83 → 158, `run_value/value`
  88 → 163, `multi_handle` 84 → 159, `suspend_in_record` 84 → 159, `logic/simple_guard` 85 → 157,
  `generic/generic` 85 → 155, `match/return_in_match` 83 → 159, `suspend_in_logical_nested`
  83 → 156, `exception` 84 → 159, `return_in_converted_loop` 84 → 164, `multi_handle/differing_arms`
  89 → 168, `suspend_in_while_condition` 87 → 164, `stream` 137 → 167. One run costs about
  1.9x the old syntax. Of the extra ~75 ms, about 50 is loading and Prechecking `Transform.cx` and
  about 13 is the walk checking the library's instances the first time. 40 copies of the Working
  Example: 340 ms against 106 for the old syntax (3.2x). That is about 4.6 ms per run against 0.6:
  Compile.back 2.3, the transform's own interpretation about 1.1 (working example), and the
  checks. A many-run program is over the 3x signal until cps.ml goes (C8). After that, back is
  Verify's 0.6 ms. The bootstrap suite: 1508 tests in 121 s before C5b, now 1562 in 90 s.

I131. `Source` printed a run expression's `with T` with a `;` after it, so `var r = run<int> { … }
with Picker;` printed as `… with Picker;;`, which does not parse (round trip of
`v2/named_handler_generic`). The statement form, which prints its own `;`, is unchanged.

I132. **REVISED by the user 2026-11-22: drop the first check of arms; errors and processed types come from checking the record (R28 rule); keep error spans on the arm as written. Built in S3 (I203).** **C6: a run is lowered to a bound run** (`HandlerClause.Bound(label, handler, Option<Stmt>)`, OCaml
`Ast.Bound`). In the walk, every run with no old clause becomes `run { body } bound E = h { var hv = {…}; }`:
the effect, the handler it is bound to, and the declaration of the handler's value. An inline handler's
value is built from its method defs as a record of lambdas (`handler_record`); a parameter takes the
type its operation writes unless that names an effect or own parameter, and the continuation's is left
to the calls. A run whose handlers take control hands the library the shell (the bound run with an
empty body) as a fourth argument and gets it back with the transformed body; one whose handlers take
no control is lowered by the core as written. `check_bindings` checks the lowered pieces itself: the
values first, outside the run's bindings (arms are outside their run), then the body under them. A
bound run met anywhere else, which is an outer transform's output, goes to `check_bound`, which does the
same without a transform. The checked prelude of C4 (I105, I108) is gone for walk runs. Arms are now
checked twice, once by `handle_block` (errors, the types the processed view uses) and once as the
record. Review: whether the first check can go.

I133. **A handler value is checked against the types its methods were first checked at**
(`bound_value`): `handler_built` (each method's own type, the continuation through `resumes`) is the
expected type, with each method's own row left fresh, and the record is then annotated with those types
again, because the old backend gives an unmarked method's evidence to it lexically and a closure typed as
performing it would be handed it twice ("fn expects 2 argument(s)"). Record literals now pass an expected
record type to their fields. A value an outer transform rewrote is marked by the annotation `open_type`
(`__tx_rewritten_value`, which compares by `__tx_rewrites_stmt`): it is checked as written, a method with
more parameters than first checked gets fresh types for the continuation and what follows it, the free
variables left are declared parameters (so `per_call` copies them per handed call, as an operation's own
`T`), and `handler_values` takes the new type.

I134. **Nested runs, inside out, each transformed once.** `processed` shows each inner run as what it was
lowered to (`Typecheck.expansions`, read by `Syntax.expansion`), so an outer transform sees a bound run,
and the outer's output holds bound runs, which are never transformed again. Counted: one transform per run
at depths 1 to 10 (I115's 2^depth is gone). The double check of I115 stays: each body is checked by
`processed` and again as output. Time over depth (compile and run of `run { … run { print(a0() + … ) } … }`):
3: 347 ms, 4: 394, 5: 483, 6: 595, 7: 782, 8: 961, 10: 1536. That needed `Cx.direct`: a rewritten function
value's `return f(x)` that splits hands its own continuation on rather than wrapping it, or every level
doubles the continuations (depth 6 was 2.2 s, 8 over 20 s).

I135. **An outer transform in an inner run's region.** `Cx.bound` is `List<Applied>`: each effect with the
arguments its clause binds it at (`bound_arguments(handler, label)`, from `Typecheck.bound_arguments`).
Inside a bound run, an effect it binds at the same arguments is masked (`__tx_inside_run`); `Cx.inner` holds
the labels inner runs bind, since the core binds an operation by its label alone, innermost; `Cx.held` holds,
per inner handler with a value, the methods the outer splits at (arm lambdas that take a continuation). A
call to such a method is still the handed call, with one more argument: `handed` accepts any extra past the
first for an operation that takes control and one for one that does not, and `infer_handed` types the
continuation argument by the lambda's arity. An already handed call (more arguments than `Operation.arity`,
new) splits by its callee's type. Rows compare with arguments (`__tx_row_binds`), operations by label
(`__tx_binds`), which is what settles I128's `Yield<int>`/`Yield<string>` (`v2/generic/nested_relay`).

I136. **Function values in the region** (03 §4.6). `__tx_values` rewrites each lambda whose type performs a
bound effect, or whose body splits where its type still holds an open variable, into `(params…, k) =>
body'`, `k` typed `(T) -> <ρ, open> R`: R the run's answer, ρ `__tx_continuation_row` (what the processed
body performs, less the effects bound through a handler with a value, since a handed call through one does
not keep its label, plus what the run's methods that take control perform, `Typecheck.arm_rows`). A type
written in the region that names such a function is rewritten (`__tx_rewritten_type`) or left to inference.
A function named as a value whose type splits becomes `(a…, k) => copy(a…, k)`. A local function that
splits becomes a local generic function taking `k`. Two unwritable names make this writable: `Ast.open_row`
(a row label `row_of_labels` reads as a fresh tail) and `Ast.open_type` (what processed code shows where a
type inside a function's type is still open; `Splice.type_expr_of ~opened`, and the library keeps it out of
what it writes, `__tx_known`). `processed` now keeps a function type that holds an open variable, since its
row is what the transform needs.

I137. **A function named as a value at a key binding a valued handler** (`handed_value`): a closure passing
the handler values first, `(a…) => f#inst(hv…, a…)`. It closes C4's I107 gap. An unsettled generic named
that way is still the error.

I138. **Defers across splits** (03 §4.8, without the flags). The cleanups in scope (`Cx.cleanups`, innermost
first; `Cx.looped` for a loop's base) are emitted at each way out: a scope's end, `return` (the value held
first), `break` and `continue`, and each continuation's discontinue branch. No flag is needed: every pass
through a continuation runs its exits once, so multi-shot runs each pass's cleanup. A cleanup that itself
splits is transformed where it is emitted (`defer_performs_effect`). A `defer` at the run's top after its
last split stays a real `defer`. A `return`, `break` or `continue` inside a plain statement that has a real
`defer` of its own is still the "Leaving a 'defer' …" error.

I139. **Discontinue** (03 D7). Every continuation starts `if (__is_discontinued(x)) { cleanups; return
<ret>(__discontinued()); }` (at the run's top, `return __discontinued()`). The insertion is in the library,
over the run's own bound record (`__tx_discontinuing`): a method that takes control (`operation_in`, new)
and never names its last parameter gets `discontinue(k)` before each `return` (its value held first) and at
its end. A named handler's methods are not in the library's view, so `with T` gets no insertion. The
`discontinue` native passes on the arguments after the continuation, which is the old backend's evidence
(I95's restriction is gone). An outer transform rewrites `discontinue(k)` of a rewritten `k` as
`k(__discontinued(), kont)`.

I140. **A `return` that crosses a run** (03 §4.7). The flag is a bound clause of its own, with a fresh label
no operation has, declaring `var left: T = __discontinued();` before the run's handlers, so the arms can see
it. A crossing `return v` is `left = v;`, the run's cleanups, then `return __discontinued()`. Each of the
run's own methods that take control tests the flag after each statement naming its continuation
(`__tx_stopping`). The run's body becomes `var answer = <transformed>; if (!__is_discontinued(left)) { return
left; } answer`: a bound run's body is a block, so that `return` is the enclosing function's, and an outer run
around it sees a crossing `return` of its own. The discontinue signal stands for "not set", so generated code
names no `Option`. An arm's own `defer`s run because the arm returns normally (`return_past_arm_defer`).

I141. **Method callees.** In processed code a method call through an owner's impl is shown as the function
it is, `Call(Var(decl), receiver :: args)`, with the callee's type recorded, so the transform copies it as it
copies any function (`v2/method_takes_control`). `declof` of an instance writes back each parameter written
with no type (`self` among them) from the instance's settled type, and a row parameter at its key into rows
(`Key.Row`, which it skipped). A trait-object method is unchanged (D6).

I142. **Copies.** A parameter whose written function type splits or names effects is left untyped, and one
with no type takes the callee's parameter type (`__tx_typed_param`). `typed_fn` reads an annotation it cannot
read as fresh (a copy of a copy names the first copy's row parameter). A copy remembers what its original
performed (`remember([copy, label], label)`), and an outer run splits a call to a copy whose original
performed its effect, because the continuations the copy makes perform what followed (`abort_under_conversion`,
`defer_multishot_abort`). A copy no longer hands its own `k` straight to a split call in tail position: it
passes `(x) => k(x)`, since `k`'s row is closed by the copy's key, and a handler's continuation row is shared by
every call of the operation in the run. That was I113's limitation ("those continuations must perform the same
effects"), now `v2/continuations_differ`.

I143. **REVISED by the user 2026-11-22: B, EffectHandler generates each `@ctl` method generic in the row: `fn choose<ρ>(options: Array<Int>, k: (Int) -> <ρ> R): <ρ> R`; each run settles ρ when it binds the handler; named handlers write nothing extra; the core's per-op row becomes this per-run ρ. Also covers the `async.suspend` waker. Built in S3 for inline handlers and the trait (I201, I202); named handlers not tied to one ρ yet.** **U2 as built.** Continuation types are honest: what a continuation performs is in its type, stored
continuations write it (`List<() -> <Console> unit>`, `List<() -> <Error, Console> unit>`), and calling one
outside its runs is an unhandled effect. The core still types an operation's continuations through one row
per operation per run (`given`/`resumes`, I113), which no longer limits anything a fixture does. Not built:
ρ as a row parameter of `EffectHandler` that named handlers write. Review: whether the per-operation row should
become the per-run ρ in the core.

I144. **What C6 still refuses or does not do.** A copy whose effect's handler an outer run rewrote, called
inside the inner run (the copy of the copy is checked under the outer's bindings, so its handed calls bind to
the wrong handler: `nested_relay` with a function, "Expected string, got int"). A continuation a copy makes,
stored by an inner arm and called under an outer run (`abort_after_resumption`, expected_failing). Function
values from outside the run (C7). Trait-object methods (D6). A `for` over anything but a list or an array. A
named handler's discontinue insertion. A `return`/`break` leaving a real `defer` inside a plain statement.

I145. `Source` printed a statement run whose body holds a value (a run filling the braces of another run)
as an expression, with a `;`, so each round of printing moved the boundary one run inward. It is printed as
the statement it is now (`v2/nested_deep`'s round trip).

I146. **RESOLVED 2026-11-22 by C6b (one run 1.0–1.3x the old syntax; `hello` ~79 ms).** **Compile time** (median of 7, compile and run, ms). Old syntax → `v2`: `resume_through_run` 90 → 321,
`abort_under_conversion` 88 → 294, `defer_multishot` 87 → 268, `fn_values/in_list` 88 → 279,
`return_past_arm_defer` 88 → 318, `multishot_sequel` 90 → 292, `nested_return` 88 → 267 (C5b: 158);
`v2/working_example` 268, `v2/loop_exits` 382, `v2/nested_deep` 496; `hello` 87. A `v2` program whose runs take no
control (`v2/log`, only loading the library) is 224: loading and prechecking `Transform.cx` (now about 2500
lines, C5b 1053) is about 135 of it. One run is about 3.0-3.6x the old syntax, at or over the 3x signal, and
nearly all of the difference is the library's size. Review: precheck the library once (cache it with the
stdlib's artifact), or split it so a program loads only what its runs reach.

I147. **C6b: where the compile time went** (profiled with temporary phase timers and a SIGPROF stack sampler
in the compiler, both removed). Before, `v2/log` 222 ms: load 23 (scan + parse 14), Precheck 178 (hello: 73),
walk 19. `Transform.cx` alone was about 105 ms of Precheck: 68 in inference of its 132 functions, the rest in
`generalize_listed` and `env_free`. `w40` (40 copies of the Working Example) 680 ms: Precheck 183, walk 461 =
the meta programs' `Compile.back` 177 (CPS 130, Verify 47: 4.4 ms for each run's 448-declaration program, of
which 233 are `__root`'s runtime) + their interpretation 209 + the checks 75. Of the interpretation, about 90%
of the samples were in one cache in `Interp` (below), not in the transform. Neither loading, parsing nor the
transform's own interpretation was the cause.

I148. **`Interp`'s `holds_frames` cache was quadratic.** An `Ephemeron` table keyed by a body with
`Hashtbl.hash`, which reads only a few words of a statement list, mostly its spans' shared `File` record, so
every body of one file landed in one bucket and each closure call scanned it. Now each closure computes
`framed` once, lazily, when first called. `w40`'s meta interpretation 209 → 17 ms; it is a cost of every
program, not only `v2` (it was introduced on this branch).

I149. **Precheck leaves out the transform's declarations unless some unit imports it.** Precheck exists to
report errors in code the walk may never reach. `Transform.cx` is library code the walk runs on the program:
no unit imports it, so nothing the program writes can name one of its declarations, and checking it found
nothing about the program. The Loader marks each declaration of such a unit with `Ast.walk_only_attr` (a
generated name, so no program can write it, riding the attribute channel the doc comment uses), and Precheck
filters them out. A unit that imports `std/core/Transform` (new fixture `stdlib/effects/transform_imported`) gets
it unmarked and prechecked in full, which is also what keeps the library's unreached code checked by the
suite. The walk still checks every instance of it a run reaches. Rejected: caching a precheck of the stdlib
on disk (a new artifact and invalidation for a result that is "no errors" by construction); splitting
`Transform.cx` (most of it is reached by any run that takes control).

I150. **N1: `Transform.cx` is loaded with every program**, after `Core.modules`, and `binds_by_trait` (the token
sniffing for `handle <` / `with`) is gone. An artifact or a `gen` can bring a run with it, and what a unit's
tokens hold says nothing about either. With I149 and I151 the cost to a program with no run is its scan and
parse, about 6 ms, and its hoisting in the walk, about 1 ms; `hello` is 79 ms against 85 before C6b.

I151. **`env_free` was quadratic in the free variables it collects.** Each id was checked against the list so far
with `List.mem`; with the transform's 132 hoisted functions in scope (rows open until checked) every
generalization and every arm (`own_params_unsettled`) walked about 500 ids against each other. Now deduplicated
through a table. Precheck of hello 73 → 58 ms; the walk of hello with the transform loaded 17 → 10 ms.

I152. **A meta block reuses the last block's converted declarations** (`Compile.back_sharing`,
`Cps.program_sharing`). A meta program is `type_level @ reached` (the declarations the block reaches, which
the next block mostly reaches too: the transform and `__root`'s runtime) followed by the block's own statements.
CPS converts each top-level statement from itself, what `collect` found in the whole program, and the counter it
starts at, so the shared part is converted again only when its statements differ by identity or `collect`'s
tables (owners, operations, delimited, operation types, function types) differ from last time; on a hit the
counter resumes where that conversion left it, so the output is the one a whole conversion gives. Verify is per
statement, so the shared part is verified once per conversion. One entry, held in `Cps` and `Compile`; a miss
converts everything as before. `w40`'s meta `back` 177 → 19 ms. This is a measure until cps.ml goes (C8), not a
design: afterwards back is Verify alone. Rejected: running the transform's meta block without `__root` (a special
case, I130).

I153. **Numbers after C6b** (median of 7, compile and run, ms; old syntax → `v2`, same binary): `hello` 79;
`v2/log` 80 → 80 (1.00x; before 88 → 222); `v2/working_example` 80 → 103 (1.29x; before 92 → 266);
`v2/nested_return` 79 → 102 (1.29x; before 88 → 267); 40 runs (`w40` against the old-syntax `o40`) 93 → 159 (1.71x;
before 110 → 680). Also `resume_through_run` 80 → 119, `abort_under_conversion` 79 → 111, `multishot_sequel` 80 →
107, `return_past_arm_defer` 79 → 113, `v2/loop_exits` 116 (382), `v2/nested_deep` 148 (496). Against the
pre-C6b old-syntax numbers the ratios are lower still (working example 103 / 92). The bootstrap suite: 1648 tests
in 79 s (1643 in about 110 s before). What is left per run in `w40` is about 1.6 ms: the conversion of the block's
own statements, `collect` over the whole meta program, its interpretation, and the double check of I115.

I154. **REVISED by the user 2026-11-22: delete `call_handlers` (the by-name table) and the copy cache's handler part when handlers-as-values (I104) is built; the handler is an argument at the call. Answers I126 too.** **Copies of copies are checked under the bindings their call reached** (C6 hand-off 1, I144). In processed
code each call records, by the callee's declaration name, the handler entries of the key it reached
(`Typecheck.call_handlers`, filled only while processed code is being read). `typed_fn` (`processed_fn`) pushes
those bindings in front of the run's own, binding each valued handler's parameter (`hv#label`) at the type
`handler_values` holds, the way an instance at that key is checked. So a copy an inner transform made, called
inside the inner run, hands its operations to the inner handler when the outer transform reads it, rather than to
whichever outer handler binds the same label (`nested_relay` through a function: "Expected string, got int"). It
is by name, latest call wins: a function called in one region under two different bindings would be read under
the last. The outer transform's copy cache has the same blind spot already (I126: keyed by instance and bound
labels, not by what binds them at the call). Review both together if a fixture ever needs it.

I155. **A handed call's rewritten continuation performs into the probe.** An operation called with a continuation
that an outer transform rewrote (a lambda taking a continuation of its own, or one of several extra arguments)
was given a fresh row, so when the call was unbound (a probe at the plain key) what the continuation performed
never reached the caller's row. The copy of a copy in `abort_after_resumption` was then keyed without `Error`
(its `throw` sits inside the continuation it hands `op`), its `throw` stayed unbound, and its row did not close
against the inner handler's ("Expected a function performing <Console>, got one performing <Console, Error|_>").
That continuation's row is now `resumes`, as the one-argument form's already was, so `row_within resumes ctx.row`
covers it. `abort_after_resumption` passes with its U2 rewrite unchanged.

I156. **SUPERSEDED by R1 (2026-11-22). C7a: U1 as built, a lifted function argument.** A parameter is *controlled* when its written type is a
function type whose row names an effect that a `handle<E>` or a new-syntax `with T` in the body binds (runs inside
lambdas and local functions count), or when the body hands it, by bare name, to a controlled parameter of a
callee (`rethrow` → `attempt`, `spawn` → `run_one`). Old clauses never make one, so the old stdlib, the old
`__root` and every old fixture are untouched. Computed syntactically per declaration and memoized
(`Metaprocess.controlled`, walk op `controlled`). At a call, the argument at a controlled position must be a
lambda written there or a function's name (eta-expanded into a lambda). The lambda is **lifted** into a top-level
declaration `lifted#n(captured#record, params…)` with the lambda's own signature, registered like a copy, once per
(span, source, instance it stands in) (`Metaprocess.lift`). The key gets `(param, Key.Fn (lifted#n, captures
type))` (new `Key.arg`, shown as the lifted name), and the argument the call passes is the **captures record**.
The instance binds that parameter at the record's type, and its body is rewritten before it is checked
(`with_lifted`): `p(a…)` → `lifted#n(p, a…)`, any other `p` → `(a…) => lifted#n(p, a…)`. So inside the run the
argument is a call to a named function, which the transform copies like any callee, and one instance per call
site follows. The caller still checks the lambda in place, for its type only (it settles `T`, `X`, `E`), under
`unused`, so the instances it reaches are not emitted.

I157. **Captures are by reference, through closures.** The record holds, for each name the lambda reads or
assigns that the enclosing function binds (not a top-level name), a getter `x: () => x`, and for each it assigns a
setter `set#x: (v) => { x = v; }`. The lifted body reads `captured#record.x()` and writes
`captured#record.set#x(v)` (a compound assignment reads then writes). Both sides share the variable, as the
handler-value closures of §3.5 do (`v2/fn_values/captures_assigned`: a loop's `total += …` and `last = w` inside
`attempt`). No captures: the record is `()`. Rejected: copying values into the record (loses writes either
way); a run-time primitive rebinding a closure's code onto its environment (a built-in the native backend would
owe). Review: getter calls per read cost a call each; a name never assigned anywhere could be passed by value.

I158. **Calls through outer transforms.** Processed code shows a lifting call with its lambda as written, so a
re-check lifts again. Two library rules keep that true: `lifted_by(callee)` (native `__lifted_by`) gives the
lifted positions, and the transform leaves those arguments as written instead of rewriting a lambda whose type
performs a bound effect (`__tx_kept_lifted`; without it the outer run of `nested_after_outer` made the inner
lambda take a continuation, "Expected a function of 0 argument(s), got one of 1"). When an outer run splits a
call to a lifting instance (`rethrow` inside `attempt`), its copy takes the captures record, so the transform
passes `lifted_captures(callee, i, arg)` (native `__lifted_captures`), the record the core built at that call.
The key such a call reached is recorded while processed code is read (`Typecheck.lifting_calls`, by the call's
location and callee), and `instance_at` uses it, since a callee's type says nothing of the code its key holds;
`declof_call` and `instance_of` now pass the callee's span for that lookup (`~at`; errors keep the meta block's
span). `declof` of such an instance writes the parameter at the captures type. Review: the table is by location
and name, like `call_handlers`; a lambda generated twice at one span in one instance would share an entry.

I159. **SUPERSEDED by R1 (2026-11-22). Deferred: stored tasks.** A function value from anywhere else at a controlled position (a list
element, a variable, an operation's argument, a parameter of a lambda) is "A function performing 'sched'
cannot be stored where no run reaches it: 'run_one' handles it for 'task', so the function it is given is written
at the call or named." (`v2/errors/stored_task`). A lambda that captures such a value and calls it inside the
run is caught by the transform: "… cannot be stored where no run reaches it: this one is captured from outside
the run, so nothing made it taking its continuation." (`__tx_is_captured`, reading `captured#record` through the
new native `captured_record()`). Naming a controlled function as a value is "'run_one' handles 'sched' for
'task', so it is called with that function written or named, not named as a value itself."
(`v2/errors/handling_function_as_value`). `nested_spawn` as written passes `child` through an operation
`spawn(t)` whose arm calls `run_one(t)`: `t` is a value the arm receives at run time, so it is a stored task by
nature (`v2/stored_tasks/through_operation`). The passing `v2/fn_values/nested_spawn` starts the child through
a function that forwards to `run_one`, with the original `.txt`.

I160. **Pre-existing gaps fixed on the way.** (1) The transform held a method call's receiver in a temporary
when an argument split, and `Option.Some(f())` reaches it as a method call on the type name: `var t = Option`,
"Undefined variable 'Option'". A receiver that is a `Var` with no `ty` (a type) is not held (`__tx_names_type`).
(2) `handle<E>` for a trait imported into a module other than the entry was "'Throw' is not an effect": an
effect trait's operations were declared only when its statement was checked, and dependency order can check the
handler's function first. `Session.declare` now declares them after the type passes, before hoisting. Both are
needed by the stdlib migration (`Option.Some(main())` is the shape of `__root`; `Task.cx` handles an imported
`Throw`).

I161. **Compile time** (median of 7, compile and run, ms). `hello` 78. `spawn` with 1 call: old 83 → v2 106; with
20 calls: old 87 → v2 144 (cap20, each lambda capturing two locals, one assigned: 152). So each further call site
costs about 2 ms: an instance of `spawn`, one lifted function, one transform. A root-shaped program (`v2/root`'s
`root`, three runs of which two take control, one call per statement): 1 statement 112, 20 statements 270, 100
statements 999, against 78 / 83 / 94 for the same prints at the top level. The same 100 statements inside one
`root` call: 139.

I162. **`__root` once the prelude is migrated (plan for C7b).** `__root`'s `main` is controlled (its row names
`Console`, `Fs`, … which the runs bind), so the mechanism already covers it: `v2/root/root_shaped` and
`root_failure` run `var`s, assignments to top-level `var`s, locals and a failure through a local `__root`-shaped
`root` with a `block_on`-shaped scheduler inside it. Top-level names are globals, not captures, so a statement's
lifted function has an empty record. **But one call per statement is too slow** (I161: about 9 ms per statement
for three runs; the real `__root` has the `Fs`/`Process`/`Net` run, `Exit` and `block_on`'s `async` and `Throw`, so
more). Plan: `Compile.under_root` hands the whole top level to **one** `__root` call. Each top-level `var` stays a
declaration at the top level (a global, so functions still read it), without its initializer, which becomes an
assignment in place inside the one lambda; every other statement goes in as written, in order. Consequences to
settle in C7b: (a) a statement is no longer checked apart, so a later statement may settle an earlier `var`'s type
(A5-Q1's annotations become unneeded; error spans still name the statement); (b) one row for the whole top level,
so one `Throw<X>`: two statements throwing different types no longer check. Options for (b): wrap each statement
in a per-statement `Throw<X_i>` catcher inside the one lambda (an instance and a transform per throwing statement
only), or make the root's failure handler one that never resumes and so takes no control. Recommend the wrapper,
applied only to statements whose row holds `Throw`. (c) U4's `X` default stays for a program that never throws.
(d) `block_on` then runs the whole top level as its one main task, which is today's sequencing.

I163. **ANSWERED 2026-11-22: Iter close row → stdlib rework; suspend waker → I143 (row-generic @ctl methods); task lists → R1.** **What C7a leaves for C7b, found on the way.** `std/core/Iter`'s `close: () -> unit` is pure, but under
honest rows closing a producer runs its cleanups, which perform `E`: it becomes `() -> <E> unit`
(`tests/stdlib/v2/Yield.cx` returns a local `Pulled<T, E>` for that reason). `async.suspend<T>(register: ((T) -> unit)
-> unit): T` hands out a waker whose call runs the rest of the task, so under honest rows its type needs the
task's row, and the trait has no parameter to carry it: `Task.cx` needs a design (a row parameter on `async`, or
the scheduler owning the queue so the waker is `() -> unit` over a stored continuation of a known row);
`tests/stdlib/v2/Task.cx` uses a `pause` operation instead. Lists of tasks (`all`, `race`, `interleaved`, `both`,
`scope`'s `start`) wait on "dynamic capture for stored tasks".

I164. **S1: what the minimal prelude holds.** `__root<T, X, Rest>(main: () -> <Throw<X>, Console, Logger, Args, Env,
Time, Random, Rest> T): <Rest> T`, one `run` binding all seven, per-statement wrapping unchanged. Dropped, because
their modules import `std/async/Task` (old syntax, unloadable) directly or through `std/io/Io`: `async`/`block_on`,
`Stdin`, `Fs`, `Dirs`, `Process`, `Net`, and `Exit` (it lives in `os/Process.cx`, which imports `async`). The
prelude's global import of `Stdin, read_line` is gone. Recommend in the stdlib step: `Exit` and `Dirs` in modules
of their own, so the root can bind them before `async` is designed.

I165. **S1: `Stdin` moved out of `io/Console.cx`.** `Stdin`, `read_line`, `__line`, `TerminalInput` and
`__stdin_of_process` moved verbatim (old syntax) to a new `stdlib/io/Stdin.cx`, unloadable until the stdlib step;
`io/Console.cx` keeps `Stream`, `Console` and `flush` and imports nothing.

I166. **S1: old declarations rewritten as traits.** `effect` → `trait` for `Console`, `Logger`, `Args`, `Env`, `Time`,
`Random`, `Fallible<T>`; `final ctl throw(err: X)` → `@ctl fn throw<T>(err: X): T`, `final ctl failed(msg)` →
`@ctl fn failed<T>(msg: string): T`. `attempt`'s arm is `fn throw(e, resume) { … }`, `seeded` uses
`handle<Random>`. Docs that named `final ctl`/`fn` operations reworded.

I167. **S1: a failure nothing catches.** The root's `Throw` arm is `fn throw(e, resume) { panic("uncaught failure: " +
str(e)); }`, `block_on`'s message, so the program stops with a runtime error naming the value (exit 70).

I168. **S1: the root's row parameter is `Rest`, not `E`.** Named `E`, it collided with a fixture's own `trait E`: a
transform copying the user's function substituted the root's `E` into it ("Expected a function performing <E,
Console>, got one performing <Console>", `return_in_inner_run` and six others). A name-hygiene bug in the copy;
`T`/`X`/`Rest` still collide with a user trait of that name. To fix in the transform/key, not by renaming.

I169. **S1: a meta block the root's own body reaches runs without the root.** `Metaprocess` wraps every meta block
in a `__root` call. With the root's runs on the new path, checking `__root` reaches the transform's meta call and
the `EffectHandler<Throw, …>` instance's meta block; wrapped in `__root` they need `__root` finished, and
metaprocessing never ends. So a meta block reached while `w.current` is a `__root` instance is a plain block. Those
blocks perform nothing today.

I170. **S1: `EffectHandler`'s meta block uses `panic`, not `fail`.** Under I169 nothing handles `Throw` there; the
import of `std/core/Error` is gone with it.

I171. **S1: a meta block's top level is global to its root lambda.** `Typecheck.is_local` counted every name in a
meta block's env (a parentless copy of the top level) as local, so the root lambda a meta block is wrapped in
captured `panic`, `emit_value` and the block's functions into a record whose type was never settled ("This is not
settled when its statement ends"). A parentless env now holds globals.

I172. **S1: the interpreter runs the resolved tree.** `cps.ml` and the `cps_*` types are deleted; `Interp` and `Verify`
take `Ast.resolved_stmt`, which still holds `Type_decl` (a no-op in both). `Compile.back` is `Verify` alone, and
`back_sharing` verifies `shared` again only when it is not, statement by statement, the list verified last.
`Diagnostic.Cps` is gone.

I173. **S1: tail calls without scopes.** With `Scope`/`Abort`/`On_unwind`/`Cont`/`Frame` gone, every closure's body is
in tail position and hands back the call it ends in; `pending` holds the function, the arguments and whether the
result is discarded. The builtin `discontinue(k)` applies `k` to the signal alone (no evidence follows it).

I174. **S1: a checked run holds no clauses.** The checked tree has `` `Run_block of valued_block `` in place of
`Run_expr`, hoisted to a temporary and a `Block`. `check_run` returns the body and the handler values' declarations;
outside the walk (Precheck) the methods that take control are still checked by `handle_block`, and the result is
dropped. A checked method is the typecheck-local `checked_arm`.

I175. **S1: deleted from the AST.** `Effect_decl`, `Run` (statement), `Resume`, `Discontinue` (statement),
`Handler_decl`, `handler`/`arm`, `Inline` clauses, `ret_clause` (`return (x) { … }` after a run), `aborts`
(`Scope`, `Abort`, `On_unwind`), `Cont`, `Frame`, the `cps_*` types, `discontinue_name`/`discontinued_name`,
`map_effects`/`map_handler`/`map_arm`; likewise `ReturnClause`, `OpKind`, `OpDecl`, `EffectDecl`, `Handler`, `Arm`,
`HandlerClause.Inline`, `StmtKind.Run/Resume/Discontinue`, `DeclKind.Effect/Handler` in `std/compiler/Ast` (and
`Printer.cx`, `Transform.cx` follow), and `DeclarationKind.Effect/Handler` in `std/meta/Reflect`. Kept:
`op_decl`/`op_kind`, as the checker's reading of an effect trait's methods (`Op_final` is an `@ctl` method whose
result is its own parameter).

I176. **S1: keywords.** `effect`, `ctl`, `final`, `handler`, `resume`, `discontinue` are identifiers now (`@ctl` is an
ordinary attribute name, `discontinue` the builtin); `run`, `handle`, `with` stay. The parser's arm state and the
`return (x) { … }` lookahead are gone.

I177. **S1: what else only the old path used.** `Loader`'s operation tables (`operations`, `effects_of`, the "is an
operation of '…', which this file does not import" error) and `Artifact.operations`; `dependency_order` moving
effect declarations first; `bound_value` forcing a method's first-checked rows, which only the old backend's
lexical evidence needed (no fixture changed); the "handler's method performs an effect that takes control" check;
`cx doc`'s `effect`/`handler` kinds.

I178. **S1: regressions in `v2`, gaps the old `Console` hid.** (a) A named handler (`with H`) whose methods perform an
outer unmarked effect: the impl method, and the functions reaching it, are not keyed by the outer binding, so
`print` inside is the unbound instance and `write` is undefined at run time (`v2/handler`,
`v2/named_handler_in_copy`, `v2/stream/stream`). (b) A root lambda whose effects show only in code a transform puts
in a continuation gets a key without them (`v2/multishot_sequel`'s second run, `stdlib/v2/iterator`), same symptom.
(c) `v2/fn_values/nested_spawn` calls stored closures performing `sched`/`Console` from the top level (R1's stored
tasks). (d) `v2/errors/handler_method_takes_control` tested the deleted I177 check and is in old syntax.

I179. **S1: meta blocks run more than once.** A meta block is the body of a lambda handed to `__root`, which is
controlled, so the lambda is checked as an argument and again as the lifted copy, and an instance whose key holds the
root's per-statement handler binding is made again for every statement: `meta/01_basic/nested` prints `C` three
times, `05_order/01_basic` prints `f<1>()` per statement. 13 `tests/meta` fixtures differ this way. One root for the
whole top level (I162) removes the per-statement part; the double check of a controlled argument needs its own fix.

I180. **S2: how handlers are passed (R1, I104 B, I154).** Two mechanisms, both arguments at the call. (a) **Evidence, for
every effect.** A function whose type's row has labels takes one more parameter, `ev#h`, **last**, after any
continuation: a record holding, by label name, the handler of each label it performs. The checker adds it once the
statement ends, from the bindings in scope where the call was checked: a run's value for what that run binds, the
calling function's own evidence for the rest; evidence handed in whole is passed on as it is (the usual case),
otherwise a record is built at the call. An unmarked operation reads its method from it
(`ev#h.Console.write(…)`). Keys hold rows only (`Key.Handler` and the probe are gone), so one instance per key and a
meta block runs once. (b) **Handlers of `@ctl` effects, explicit**, as R1's example writes them: a function or value
taking control takes one handler parameter `hv#<label>` per effect it takes control of, sorted by label name, after
its own parameters and before its continuation: `f(args…, hv#A, hv#B, k, ev#h)`. A copy takes those of the effects
its run splits at. Order relative to `self`: `self` is the first parameter as ever; handlers come after all
parameters. Why evidence last: a closure the transform makes for itself takes none (I182), and the interpreter drops
arguments past a closure's arity, so a call through any value passes evidence by its type alone. **Cost to review:**
that tolerance in `Interp` (a native backend owes the same, or exact arities); one evidence record per call that
mixes a run's handler with handed ones.

I181. **S2: the answer type `R` of a function value's CPS form is no part of its type.** A value keeps its written
type (`() -> <Ask> int`); the calling convention follows from the type (a handler for each `@ctl` effect in its
row, then the continuation, then evidence), and the checker types a call in that form with the answer fresh at each
call (`cps_call`), and a lambda in that form with its answer a rigid parameter of its own, which it can only pass on
(`cps_lambda`). So lambdas stay monomorphic in their type and the answer is polymorphic only in the convention.
**Conflict flagged:** "processed code is type checked" holds loosely for the plumbing: handler arguments are not
constrained by the callee, and `Verify` accepts a call or lambda of the surface arity plus the convention's. Copies
keep their written `<R, E>` (I126).

I182. **S2: functions the transform makes for itself are plain.** A static parameter `plain#made` marks
continuations, joins and loop functions, and the arms the core builds from handler clauses (I105 records): they bind
what they perform where they are written (no frame of their own, no evidence) and their effects count as the
enclosing function's. A static parameter `cps#made` marks a function value made taking control; its written row
names the effects whose handlers it takes. Neither is writable by a program (`#`).

I183. **S2: function values take control wherever written (R1).** When the checker reaches a lambda whose type takes
control and whose body splits, it hands the lambda to `effect_lambda` (`Transform.cx`) and checks what comes back in
its place; one whose type takes control but whose body never splits is wrapped once the statement ends
(`k(body)`). A function named as a value whose type takes control is eta-expanded into such a lambda. A run's
transform leaves the lambdas a program wrote as written; it still rewrites its own plain continuations layer by
layer, in the convention.

I184. **S2: trait objects (R16).** A table's slot for a method whose trait row takes control is an eta lambda made
taking control, so it calls the impl method's copy; `obj.m(args)` in a region is split into
`obj.m(args, hv…, k)`, which the checker types like `cps_call`. The rejection is gone. New `v2` copies:
`core/traits/dyn/v2/effect_resumes`, `effects/methods/v2/suspending_receiver`.

I185. **S2: named handlers have values (I105).** `with T` binds each effect `T` implements through a value made at
the run: a record of plain closures calling `T`'s impl methods (through the old static path), one record per effect,
checked after the body because the impl may be generic in what the run answers. `@ctl` effects work through it, so
the "not supported yet" error is gone. Default taken: every effect `T` implements is bound, and claiming one twice
(inline and named, or two named) is an error checked before anything else; a `@ctl` effect counts as bound by
`with` whenever the run was transformed. A statement `run { … } with T` whose impl is generic in the answer needs
`run<unit>` (R9 makes it required anyway).

I186. **DECIDED by the orchestrator 2026-11-22 (review after): (a), it follows the user's Koka-model choice (R1); built in step 2b.** **S2 limitation, the main open question: a function value whose `@ctl` effects are handled by different nested
runs.** One CPS form cannot serve runs that are split layer by layer: the inner run's continuation is made taking
the outer's continuation too, which a value made once does not. Reported as "A function taking control of 'X' is
called here among effects another run handles, which is not supported yet." This is the shape of the root and of
`block_on` (`main` performs `Wait` and `Fails`/`Throw`), so `root/root_shaped`, `stdlib/v2/block_on`, `nested_deep`
and `discontinue/nested_after_outer` go from pass to fail. Options: (a) drop layering: every function and value in
one CPS form for all its `@ctl` effects, a run delivering its answer through a "current answer continuation" its
handler value holds, saved and restored by the outer handlers it wraps at entry (Koka's prompts, as values);
(b) values carrying one form per order of their runs. Recommend (a).

I187. **S2: lifting removed (I156–I159).** `Key.Fn`, `controlled`, `lift`, the captures records, the natives
`__lifted_by`/`__lifted_captures`/`__captured_record`, and both "cannot be stored" errors. `v2/errors/stored_task` and
`v2/errors/handling_function_as_value` are now valid programs, merged into `v2/fn_values/stored_task`;
`v2/stored_tasks/*` pass, so they move out of `expected_failing`. `stored_tasks/scope_start` wrote its `start` function pure though
it performs `Console`; its type now says so.

I188. **S2: the handed form is gone (I112).** `ask(k)` is an arity error; `infer_handed` is deleted. One internal
exception: a named handler's record calls its impl's method for a `@ctl` operation with the continuation it is
handed (`named_method_call`), which only the core writes.

I189. **S2: rows the change touched.** An unmarked operation bound to a run's value no longer adds its label to the
caller's row (a named handler's still does, so `with` sees what it binds); a call in the convention does not add the
effects it takes control of. A handler method called through a value is shown answering what it performs where its
run stands (`answered`), so it is handed no evidence. A copy's handler parameter is read as the effect's handler
type in its body but is any value at the call, so a run's continuation row is not tied to the copy's. These are
patches over R28, not the fix.

I190. **S2: compile time** (median of 5, ms): `hello` 60 → 60, `working_example` 69 → 60. A table keyed by checked
node hashed spans, which hash the whole file text; `Source_map.Span.offsets` gives it a cheap key.

I191. **S2: other pass → fail** (besides I186): `v2/generic/nested_relay`, `nested_relay_fn`,
`abort_after_resumption`, `handler/arm_reaches_outer`, `suspend_in_resume`, `core/defer/v2/defer_multishot_abort`,
`abort_under_conversion`: nested runs where the outer transform rewrites the inner's continuations and arms in the
convention, and the inner continuation's type or a copy-of-copy's handler type no longer lines up (the layering
I186 would remove). `stdlib/v2/rethrow`, `stdlib/throw/rethrow`: `rethrow`'s copy is read from `declof` with its
function parameter's type left open, so `attempt(f)` inside it has no key. `stdlib/encoding/generic`: "Undefined
variable 'T'" in a meta block, not traced.

I192. **S2b: one CPS form (I186 a), as built.** Every function value and every copy takes the handler of each
`@ctl` effect its type takes control of, sorted by label, then its continuation, whichever runs handle them. A copy is
keyed by its instance and those labels (`__tx_copy_of`), so one copy serves every run. A run whose code takes control
of an effect an outer run handles is a **prompt** (`__tx_prompt`); `__tx_outward` finds those effects: a `@ctl`
label in `processed_row()` the run does not bind, and any `@ctl` label in the row of its methods (`arms_row()`), its
own included, since a method stands outside its run (`handler/arm_reaches_outer`: an inner `Ask` arm's `ask()` goes
to the outer `Ask`). The transform returns the bound run with the body `LAM()`, `LAM` a function value made taking the
handlers of those effects and `k` (static params `cps#made`, `plain#made`; written row the outward labels, open), so
whatever splits the code around it splits at it as at any call. Inside `LAM`:
```
var answer = k;                        // where the run's answer goes
var hv#O' = { op: (a…, k1) => { var at = answer; return hv#O.op(a…, (x) => { answer = at; return k1(x); }); } };
var hv#M' = { op: (a…, k0) => {        // each of the run's own methods that take control
    var entered = answer;
    var resume = (x, hv#O…, then) => { answer = then; return k0(x); };   // a value taking control of O
    …the method's body, split for O through the outer handlers unwrapped; `return v` is `entered(v)`…
} };
…the body, split at every call taking control (its own effects through hv#M', the outer ones through hv#O'), ending
in answer(v)…
```
A method's continuation is a function value taking control outward, so it is stored, handed and called like any
(`root/scheduler_throws_outward`: the stored `{ resume(()); }` is called from `block_on`'s converted loop). Each outer
handler is wrapped because a method of the run may move `answer` before an outer continuation is resumed
(`outer_resumes_inner_twice`). The clause's own value keeps only the methods that take no control (no value when none
is left), which evidence still reaches. An outer transform reads a prompt where it stands (`__tx_run_cx`) and leaves
its clauses alone; nothing rewrites an inner run's continuations or methods any more. A run whose code takes control of
nothing outward is unchanged: it delimits natively, as before. Library: all of the above. Built-in: nothing new; two
read-only natives, `operations(label)` (the wrapper's methods) and `arms_row()`. Removed: `__tx_note_performs` and
`__tx_copy_performs` (an outer run splitting at a call to an inner run's copy); the "called here among effects another
run handles" error is now "no handler of it is in scope here".

I193. **Where the current answer continuation lives.** The design says the handler value holds it; as built it is a
local `answer` of the prompt, which the run's methods and continuations close over by reference. A record is a value
and a field captured by reference needs references (I105), so the record cannot hold a cell. Review with I105.

I194. **Typing the plumbing** (R28 still open; these keep processed code checkable). (a) A function value made taking
control that is also `plain#made` answers what the function value taking control around it answers
(`ctx.cps_answer`), so `answer = then` and `var entered = answer` check; any other keeps its own rigid answer (I181).
`ctx.cps_answer` is set by `cps_lambda`, kept through plain lambdas, cleared by every other function body. (b) `var x:
open = …` in any statement is checked as its initializer, and what nothing settles in it is left open: the wrappers
are read at each call's own type. (c) A lambda checked against an expected function type that takes control takes the
handlers of the expected type's `@ctl` labels as well as its body's (`effect_lambda(lambda, taken)`): before,
`root(() => { twice("a"); })` took `Wait` alone while `root` handed `Fails` and `Wait`. (d) Whether a trailing lambda
takes `it` is decided after the arguments before it settle, as `push(xs) { … }`, the call processed code shows of
`xs.push { … }`, needs.

I195. **A loop whose answer has no name.** A loop holding a split where what continuations answer is not written (a
prompt's body, a function value made taking control) becomes `var loop = (u) => { return after(u); }; loop = (u) => {
…step… };` rather than a local `fn` with a written return type. Both used to stop with "needs the type the run
answers"; `loop_taking_control_outward` and loops in function values now run.

I196. **A copy is made from its function at the call's types (`__tx_called_at`).** Before `processed_fn`, each
parameter takes the type the call settled for it: a static parameter written only in a row (`rethrow`'s `X` in `f: ()
-> <Throw<X>, E> T`) is no part of the key, so the instance still names it and `attempt(f)` inside had no key. Fixes
`stdlib/v2/rethrow` and `stdlib/throw/rethrow`. The copy's own parameters follow the same order (a written type naming
a static parameter is dropped, then retyped from the call).

I197. **What a prompt refuses** (the crossing `return` built in S4, I216; the named handler in S4b, I219) ("… is not supported yet."): a `return` that crosses it, since the flag (I140) has to
be answered by the continuation of the function the run stands in, which only the transform around the prompt holds;
and a named handler (`with T`) of a `@ctl` effect, whose impl method is a function of its own and is not made taking
control outward. Known gap: when a prompt's methods perform its own effect outward, `LAM`'s handler parameter for the
outer one shadows the run's binding of that label for the body's operations that take no control.

I198. **Native answers through an inner run.** A bound run split in place (one whose handlers take no control) now
hands on its value as the native answer (`__tx_bound_run` ends in the run, not after it), as every other split does.
No fixture changed.

I199. **Cost and compile time.** Per prompt: one wrapper record per outward effect, one closure per resumption, and
every outward operation goes through one wrapper per prompt between it and its handler (four in `nested_deep`).
Compile time (median of 5, compile and run, ms): `hello` 60 → 59, `working_example` 60 → 63; `root_shaped` 74,
`stdlib/v2/block_on` 75.

I200. **`stdlib/encoding/generic`, diagnosed, not fixed (types are monomorphized in a later step). FIXED in S4b by (a) (I222).** `from_json<T:
Decode>` performs `Throw`, so since S2 the top-level statement's function value splits at it and copies it. The copy
comes from `declof_call`, whose `surface` substitutes a type parameter only where the key binds it to a plain name;
here `T = Page<Item>`, so `T.decode(…)` keeps `T`: "Undefined variable 'T'". Options: (a) monomorphize types, the
planned step; (b) a copy keeps the type parameters its body names and its call writes them (`copy<Page<Item>>(…)`);
(c) substitute an applied type where it is a receiver, which needs an expression for `Page<Item>.decode`. Recommend
(a).

I201. **S3: `EffectHandler` makes each `@ctl` method generic in the row (I143), as built.** `handled` in
`stdlib/core/EffectHandler.cx` adds a static parameter to the operation's own and writes it on the continuation and
on the method: `EffectHandler<Fail, int>` is `@ctl fn throw<T, Rho>(msg: string, resume: (T) -> <Rho> int): <Rho>
int`. **Review after:** the name. `as_name` takes identifiers only, so `ρ` cannot be written, and `E` and `R` are
the trait's own; `Rho` is writable by a program and would collide with an operation's own parameter of that name. A
native returning a `#` name, as `open_row()` does, is the alternative. Named handlers write nothing extra:
conformance binds the trait's `Rho` to the impl's written row, and `open_continuation` still gives the impl's
continuation a row of its own, so a named handler's method is not yet tied to one ρ per run (it still performs
what it is written to). **Doc change proposed, not made:** the EffectHandler section's `handled` and the
`EffectHandler<Effect, String>` expansion would read `@ctl fn choose<ρ>(options: Array<int>, resume: (int) -> <ρ>
String): <ρ> String;`, and `Picker<R>`'s `choose` would say that the run settles ρ.

I202. **S3: one row per handler per run (I143 in the core), as built.** `handler_signature` gives an inline
handler's value its type from the effect's operations (or the `EffectHandler` instance's methods, with `R` the run's
answer and `Rho` the handler's row ρ): a method that takes control is `(…, (A) -> <ρ> R) -> <ρ> R`, one ρ for every
such method of the handler, an unmarked one keeps its operation's type with a row of its own, and an operation's own
parameters are declared, so each call takes its own copy (`per_call`). ρ is declared and contained in the run's
surroundings (`row_within`), not tied to them, so a continuation does not perform everything around the run. Gone:
`given`, `resumes` and `seen_by_body` (the body's view of a continuation and the method's differed in their rows),
`handler_built`, `handle_block ~apart`, and the arm types `handle_block` returned. `handler_type` (a handler a
function taking control is handed) uses one ρ per method too.

I203. **S3: arms are checked as the record (I132), as built.** In the walk `handle_block` no longer runs: each
inline handler's value, the record `handler_record` builds from its methods, is checked by `run_value` against its
signature, rows included, and is what the body's calls through it are typed by. An error in an arm's body is
reported at the arm's own statement (`v2/errors/arm_body_error`, `arm_resumes_wrong_type`, `arm_unmarked_error`, new);
a missing method, a wrong count of parameters, a written type the operation contradicts, or an operation's own
parameter the arm settles is reported at the run, as before (`final/errors/resumes` unchanged). With a transform
the record as written is checked before the transform, because the transform reads what the methods perform
(`arms_row()`) and `processed` reads the value's type; the record the transform returns (discontinue inserted, stop
flags, a prompt's unmarked rest) is then checked from scratch as the rewritten code it is (R28), and nothing of the
first check is kept. Without a transform the record is checked once. `handle_block` survives for Precheck, where
nothing is lowered. `check_bound` (a bound run an outer transform or a prompt made) reads a run's own value through
`run_value` too, and contains its ρ. **Review after:** checking arms once with a transform means the transform
taking what the methods perform from somewhere other than a check of them.

I204. **S3: rewritten code keeps no type from the code it replaced (R28), as built for runs.** Two causes, both
fixed. (a) Discharging a run's bindings used `rewrite_row`, which on an open row adds the label it was asked to
remove: that is how `Ask` reached the continuation's row in R28's dump. `discharged` removes a label where the row
has it and leaves an open row alone. (b) `handler_call` typed `hv.op(…)` through the body's view of the handler
(`handler_values` with `given` rows) rather than the value's own type; it reads the target's type now. `--dump-code`
of `v2/working_example`, before: `(field hv#8:{ ask: ((int) -> <Ask, Console> string) -> string } ask)` and the
continuation `(fn (n: int) …):(int) -> <Ask, Console> string`; after: `((int) -> <Console> string) -> string` and
`(int) -> <Console> string`, matching the declaration `{ ask: ((int) -> <Console> string) -> <Console> string }`.
**Still false, to review:** a call through a handler's value shows the target as a record of that one field with the
method's row emptied (`answered`), because the backend hands evidence to any callee whose type has a row and a
handler's methods are plain closures that take none (I133). The declaration keeps the honest row; the call site
does not. Making it honest needs a calling convention that does not read evidence from the row.

I205. **S3: `with` sees what it binds without a false row (I189's named-handler patch removed).** In the walk an
operation answered through a named handler's value no longer keeps its label in the caller's row; `used_handlers`
records the handler, and `with H` binds an effect the body's row shows, one answered through `H`, or one that takes
control under a transform. Outside the walk (no values) the label still stays in the row, as before.

I206. **S3: a defaulted effect parameter contributes nothing (I25), as built.** A key defaults a parameter standing
only in labels to `type#absent` (`Ast.absent_type`), not `unit`, and the use's copy is unified with it. A label
holding it is no label: `Types.repr_row` skips it, so every reading of a row sees the call perform nothing of it,
and the instance's signature drops it (`guarded<X, T>(f: () -> <Throw<X>> T)` at a lambda that never throws is
`guarded#0(f: () -> int)`). For the key to be read before the label reaches the caller, `reached` settles the
callee's labels from those the caller already carries and adds the rest after the key; a call with a use does the
same settling before its arguments are read, so a function value among them is made taking the handlers it will be
handed. A lambda takes the handler of a label its expected type names only if the label's arguments are settled or
its body performs it (otherwise the key may find it absent). Precheck has no keys: `undefaulted` leaves out of what
a call admits each label only an unsettled parameter of the callee names that the caller does not carry. A handler
of an effect nothing in its run's body performs has nothing to settle its arguments with, and is a handler at `unit`
(the pre-read in `check_bindings`); `root/root_shaped` and `stdlib/v2/block_on` needed it, because `block_on`'s
`Fails<X>` is absent under a root whose statement never fails. Consequence: a top-level statement that never throws
takes no `Throw` handler from `__root` (`(fn (ev#h) …):() -> <Args, Console, Env, Logger, Random, Time> string`;
before, `(fn (hv#Throw k#wrapped ev#h) …)` at `Throw<X>`). New: `v2/defaulted/never_throws` (a call in a `<>`
function to a function generic in `Throw<X>` with a lambda that never throws; before: "This code does not handle the
effect 'Throw'"), `v2/defaulted/joins_later_throw` (passed before too; kept as the I25 case of a later
`Throw<IoError>` in the same caller). **Review after:** R4 says the parameter defaults to `unit`; the key now holds
`absent`, and a body naming such a parameter outside a label would meet a type no program declares (none does
today). A key shows it as `type#absent`. Revisit with R4 and A5-Q1 (one `__root`).

I207. **S3: the plumbing a call in the convention hands is checked (I181, I194).** `cps_call` checks each handler
argument against `handler_type` of the label the callee takes control of at that position, its operation's own
parameters and its answer taken afresh for the call (`per_call`); before, handler arguments were checked against
nothing. **Still loose, to review:** `Verify` accepts a call or lambda of the surface arity plus the convention's
without checking what the extra arguments are, and a handler's answer is not tied to the continuation's.

I208. **S3: what stays.** A5-Q2 (rows as keys are closed, a function written `<E>` writes its own effects) is
unchanged. Compile time (median of 5, compile and run, ms, S2b → S3, this machine): `hello` 160 → 163,
`working_example` 172 → 175, `nested_deep` 211 → 218, `root_shaped` 198 → 198.

I209. **S4: `run<R>` is required (R9), as built.** The parser reports "Expected '<' after 'run': a run writes the type it
answers, as in 'run<unit> { … }'." at the token after `run`, records it and parses on, so one missing `<R>` is one
error (`v2/errors/run_without_answer`, new). `Run_expr` keeps `type_expr option`: a run the checker or a transform
builds (`shell`, `__tx_prompt_methods`, `Transform.cx`'s `ExprKind.Run(Option.None, …)`) still infers its answer;
only written code must say it. Every run in `tests/effects/v2`, `tests/stdlib/v2`, `tests/core/defer/v2`,
`tests/core/traits/dyn/v2`, `tests/effects/methods/v2`, `tests/meta/syntax/round_trip` and the stdlib the v2
fixtures use was annotated with the answer the checker had inferred for it (an instrumented build printed it per
run: 182 `unit`, 5 `int`), the rest of them (a statement run nothing reached) `run<unit>` by hand. The red old-syntax
stdlib (`net/`, `async/`, `iter/Yield.cx`, `test/Test.cx`) is left for step 5. **Doc change proposed, not made:**
the EffectHandler section's `run { greet("ada"); } handle<Console> { … }` should read `run<unit> { … }`.

I210. **S4: a generic effect's handler writes its arguments (R10), as built.** `handle<Yield>` for `trait Yield<T>`
is "Trait 'Yield' takes 1 type argument(s), which a handler writes: 'handle<Yield<…>>'." at the handled type
(`v2/errors/handle_unwritten_arguments`, new). With nothing left to infer, the body's pre-read in `check_bindings`
(read once unbound for its row, to settle the arguments; I206's "a handler at `unit`") is deleted. `__root` and
`attempt` write `handle<Throw<X>>`. A key that defaulted `X` to `type#absent` (I206) writes it into the instance's
`handle<Fails<X>>`, so `named_type` reads `type#absent` as the absent type rather than "Unknown type 'absent'"
(`root/root_shaped`, `stdlib/v2/block_on`). **Review after:** a handler at `absent` is checked and built though no
call reaches it; its arms see `e: type#absent`.

I211. **S4: the "named by the author" exemption is gone (I68), as built.** `unsettled` and `Verify.monomorphic` no
longer accept a variable because `Types.param_names` names it. It was covering two things, each now said directly:
(a) `per_call`'s copy of an operation's own parameter, left open where a call discards it (`throw("odd");` through a
handler's value, `throw<T>`'s `T`), is unobservable, as the result of a direct call to an operation already was;
(b) a copy's handler parameter is read in its body as a handler of the effect at fresh arguments (`handler_type
label []`), which only the name exempted: those arguments are now declared, the copy's own as a parametric
instance's parameters are (`stdlib/v2/rethrow`: `cx30#rethrow#0`'s `hv#Throw: { throw: (X, …) }`). No fixture
changed. **Review after:** (b) lets the body's view of a handed handler stay generic in its arguments however the
body uses it; tying it to the caller's (I207) would make it exact.

I212. **S4: a return-type-only parameter of a discarded call is `Unit` (I90), as built.** (Its found-not-fixed part is FIXED by I317.) `infer_stmt` marks the
call an `Expr` statement holds (`discarded`, by its offsets), and `key_of_use` settles a parameter still open there
that the scheme mentions only in its result (`only_returned`: not in a parameter, not in the row) to `unit`, keyed
`Key.Type Unit` (`types/expected/discarded_return_param`, new: `empty();` and `fn sizes() { empty(); … }`). Only a
call standing as the whole statement: `var _ = f();`, an argument, and a method call `x.f();` are not discarded
calls. **Found, not fixed:** in a meta block, any call to a function that performs an effect taking control (`fail`,
which throws) fails when the meta program runs ("Undefined variable 'fail'"; `fn g(): int { return fail("x"); }`
then `meta { if (false) { g(); } }` is "Undefined variable 'g'"), discarded or not; `fail<unit>(…)` does not. So
`meta/traits/effect_handler` keeps `fail<unit>(…)`, and the doc's `fail(…)` line checks but would not run.
Looks like the meta program not emitting the copies its split calls name; not chased, out of step 4.

I213. **S4: a type standing as a value in a meta block is its `Type` (R5), as built.** A static parameter is written
by name in its instance (`E` is `Effect` there), so the rule is on the name: inside a meta block, a `Var` no value
answers to that names a type, a trait, a static parameter or a primitive is checked as `typeof` of it, so `str(E)`
and `T.name` work (`meta/params/type_param_value`, new: a function's `str(T)` and a trait's `str(E)` at `Point`). A
type with no fields keeps its meaning as its one value. The doc's message is restored as `fail(str(E) + " is not a
trait, so it has no operations to handle")`; `stdlib/core/EffectHandler.cx` panics with the same message;
`meta/traits/effect_handler` uses `str(E)` (with `fail<unit>`, I212).

I214. **S4: `type X impl A, B { … }` (R31), as built.** The parser reads `impl` and a comma list of traits with their
arguments after the type's parameters, and stands each among the type's members as an `Impl_decl` with no methods.
`Metaprocess.implemented_in_types`, run first by both `Precheck.program` and `Metaprocess.program` over the loaded
program, hands each method to the named trait whose declaration lists it, the rest to the type's own impl
(`Type_members` as before), and emits one `impl` per named trait. A trait whose meta blocks generate its methods
(`Trait_members`: `EffectHandler`) declares nothing before an instance runs, so it takes every method no other named
trait declares; two such traits on one type are an error. A method two named traits declare is "'size' is declared by
both 'Area' and 'Volume'; write them as separate impls." at the method, and goes to the first (the second then
reports its missing method). Fixtures: `core/traits/in_type/in_type` (fields, `Area`, `Display`, an associated and a
`self` method of the type's own, a generic type), `core/traits/in_type/errors/declared_twice`, `v2/handler/in_type`
(the doc's `Five` and `Picker<R> impl EffectHandler<Choose, R>, Display` under `with`). The doc section gains that
sentence about generating traits. **Review after:** a generating trait named beside methods of the type's own takes
them too; a type with value parameters or meta members and an `impl` list is not tried; `Syntax` reflects the
markers as members. **Found, not fixed (R11):** a named handler's untyped parameters do not take the
`EffectHandler` instance's types, in a separate `impl` as in a type's body: the doc's `type Five impl
EffectHandler<Ask, String> { fn ask(resume) { var s = resume(5); print(s); … } }` is "The static params of 'print'
are not settled here", so the fixture writes the types.

I215. **S4: `@abort` (R14), as built.** `@abort fn throw<T>(err: X): T` is an operation that takes control and never
resumes (`Ast.aborts`; `Ast.takes_control` holds for it; its kind is `Op_final`, as an inferred never-resuming `@ctl`
one still is). `EffectHandler` gives it no continuation and answers `R`: `@abort fn stop<T, Rho>(why: string): <Rho>
int;` (`v2/abort/shape`, new). An inline arm is written without the continuation, and `aborting_arms` gives it one
it never names before anything reads the run, so R17's insertion discontinues it on the way out of the arm and the
`defer`s between the call and the run run (`v2/abort/abort`: cleanups in `parse` and in `total`'s loop run after the
arm, in order). A named handler's method (`v2/abort/named`) is given one by `aborting_impls` (before Precheck and the
walk), its body run as a lambda whose answer is handed back after `discontinue(k)`; conformance accepts the extra
parameter. Stdlib `Throw.throw` and `Assertion.failed` are `@abort`, and `__root`'s and `attempt`'s arms drop
`resume`; `exit` is not in the stdlib's current prelude, so nothing to change. **Departure from R14's default,
review after:** the call still builds its continuation and the arm discontinues it, rather than "an early exit to
the run building no continuation": the `defer`s in the frames between the call and the run unwind through their
continuations (I140's discontinue signal), and an exit that built none would skip them. The cheap unwind needs each
frame's cleanups reachable without a continuation. An arm written with the continuation anyway is accepted. Compile
and run, median of 5, ms: `hello` 162, `working_example` 179, `v2/abort/abort` 191, `v2/final/abort` 176 (S3:
163/175 on this machine; no change from `@abort` itself).

I216. **S4: a `return` crossing a prompt (I197, first refusal), as built.** A prompt now does what an ordinary run
does with I140's flag: `left` is declared by a bound clause before the run's handlers (and before its methods are
checked, so the stopping tests see it), the run's methods stop once their continuation comes back with the flag set
(`__tx_stopping`, before `__tx_prompt_methods`), and the run's body holds the prompt's call, then tests the flag
(`__tx_left_run`). Inside the prompt a crossing `return v` is `left = v;`, the run's cleanups, then the signal
answered through `answer`, the prompt's current answer continuation (`__tx_leaving` reads `cx.ret`; `__tx_return`
and `__tx_exiting` take `cx.leave` before `cx.ret`, which only a prompt has both of). The outer transform splits at
the prompt's call, so the flag test lands in a continuation, whose discontinue test would take the signal for a
discontinue: `__tx_continued` puts a flag test that starts the continuation before it (`__tx_is_flag_test`), and
`__tx_is_prompt` reads the held form as a prompt. `v2/prompt/return_crossing` (new): a return after the outer
effect resumed, one before any of the run's own operations, and one after two resumptions (the arm's code after
`resume` stops). **Review after:** the hoisted test is recognized by its shape (`!__is_discontinued(x)` first).

I217. **S4: a named handler of a `@ctl` effect in a prompt (I197, second refusal): NOT built, to build. BUILT in S4b as (a) (I219).** The
refusal stays. A prompt makes each of the run's methods taking control outward by rewriting its body
(`__tx_prompt_method`), but a named handler's method is its impl's, a function of its own: the record's lambda is
`return Ask#op#ask(arg0)`, resolved to the impl by the checker. Passing the prompt's continuation (a function value
taking control outward) to the impl method as written does not fit its `(int) -> R`, and instantiating `R` as the
outer answer is wrong for a method that returns without resuming. Options: (a) the record's lambda calls the impl's
entry directly, and the prompt inlines the instance's body (`declof_call`) as if it were an inline arm; (b) copy the
impl method made taking control outward, as a function copy is. Recommend (a). `v2/prompt/named_handler` is in
`expected_failing` (`Waiting`).

I218. **S4: types monomorphized like functions (R7): NOT built. Partly built in S4b (I220–I223; what is left, I224).** Left for its own step. What it touches: every
generic type use, inferred or written (`Box { v: 1 }`, `Option.None`, `List<T>`, annotations inside generic
functions), reaching Check decl cache with a key strict at the node (R6) — the `comptime_type` path (`Buf<4>`, I67)
already copies at written arguments (`New_generic`) and would become the only path; every generic impl of a type
copied per instance; values, patterns and `typeof` naming the copy (I67 spells a copy as written, `Box<int>`, so
output keeps its form); Prune and Verify on copies; the stdlib's `Option`, `List`, `Map` and `Result` at every key.
Done halfway it would regress the v2 and meta suites, which this step must not. The diagram's diamond already reads
"call, operator, method, type", so no doc change was needed. I200 (`stdlib/encoding/generic`) waits on it.

I219. **S4b: a named handler of a `@ctl` effect in a prompt (I217, recommendation (a)), as built.** A named
handler's record holds one lambda per operation whose body is `return ask(arg0)`, the checker reaching the impl
through it. `__tx_prompt_method` now recognizes that shape (`__tx_calls_operation`, the old `__tx_named_method`)
and takes the impl's method instead, through a new native `named_method(handler, method): Option<Decl>`
(`std/compiler/Ast.cx`; `Metaprocess.named_method`: `Typecheck.named_handlers` gives the impl type and effect of the
run's handler name, `Registry.method_entries` the impl's method), then makes it taking control outward exactly as it
does an inline arm. The method's parameters lose their written types and take the record field's, as an inline
arm's do, so I214's untyped-parameter gap does not arise here. The refusal "A named handler of … is not supported
yet." is gone; an impl with no such method is "The named handler of 'Ask' has no method 'ask' to make taking control
outward." `v2/prompt/named_handler` is out of `expected_failing`; `v2/prompt/named_handler_resumes` (new) resumes
twice, calls an unmarked method of the same handler, and performs the outer effect from each continuation.
**Review after:** the body is the method as its impl writes it, not its instance at a key, read outside the impl: a
type parameter of the impl named in the body (`fn ask(k: (int) -> R): R { var r: R = k(5); return r; }`) is
"Unknown type 'R'". Substituting the run's answer for the parameter the impl writes as `EffectHandler`'s `R` would
fix it. A meta block in such a method is not run there; none is tried.

I220. **S4b: a plain generic type is copied through the decl cache (R7), as built.** A type declared with type
parameters and neither a value parameter nor a meta block (`type Box<T> { v: T }`) is noted when its declaration is
checked (`note_generic`, which also fills `Types.generic_types`) and given a declaration id, as a comptime type is
(I67). `type_copy w base args` is its Check decl cache: keyed `(id, Key.show {T = int})` in the one `w.cache`
comptime types and functions use (`Copy of string`), it names the copy, records it in `Types.copies` (copy name →
generic name and arguments) and in `w.copies_made`. A copy is spelled as the use prints, `Types.string_of_ty
(Named (base, args))`: `Box<int>`, `std#Option#Option<int>`, `Job<int, <std#Console#Console>>`, which is I67's
spelling of a comptime copy and is also the key, so renaming changes no diagnostic and no `--dump-code` text. Its
declaration (`copy_decl`) is the generic one with each parameter written as its argument and every closed use of a
generic type in it naming that type's copy (`renamed_type`), which makes the copies it names. No stdlib type
changed: `Option`, `List`, `Map` and `Result` are copied at every key like any other.

I221. **S4b: where a use of a type reaches the cache.** Written arguments reach it at the node: `Box<int> { … }`
(`generic_new`), `declof(Box<int>)` (`declared_type`, which now answers a plain generic type at arguments rather
than "'Box' takes no static arguments here."), `typeof(Box<int>)` (new: `reflected_type` reads a `Static_ref` of a
type, which was "Undefined variable 'Box'"; `copies_of`, a new walk op), and a key binding a static parameter to a
closed applied type, wherever an instance writes the parameter into its meta blocks (`made`) or `declof` shows its
body (`surface`). Inferred uses (`Box { v: 1 }`, `Option.None`) reach it when the walk's program is finished, by
the pass of I223, when every type of every statement is settled. `Box<int> { v: "one" }` is now checked against
what is written (`core/types/errors/written_arguments`, new: "Expected int, got string."); before, the written
arguments were dropped and it built a `Box<string>`. **Review after (R6):** an inferred use is not read strictly at
its node. For a plain type nothing a copy holds feeds back into inference, so the copy made at the node and the one
made at the end are the same declaration; reading the key at the node would only reject what the end of the
statement settles (`var x = Option.None; x = Option.Some(1);`, about every `Option.None` and `[]` with no annotation).

I222. **S4b: inference never sees a copy, and a copy's name is the generic type at its arguments.** The checker
keeps `INamed ("Box", [int])`: a generic signature `fn unbox<T>(b: Box<T>)` has to unify with a use, which a separate
nominal type (as `Buf<4>` is) cannot. Where a copy's name reaches the checker, as a key writes it into a meta block
or a `declof` surface, `named_type` reads it as the generic type at its arguments, and a method call on it as a
receiver (`Page<Item>.decode(…)`) reaches the generic impl at those arguments. That fixes I200:
`stdlib/encoding/generic` passes (`T = Page<Item>`, `T.decode(…)` in `from_json`'s copy). It was already in a
passing list, so nothing in `test_bootstrap.ml` moved. **Consequence:** the comptime path and this one share the
cache and the spelling but not the representation; a comptime copy is a type of its own to the checker, a plain
copy never is.

I223. **S4b: the finished program names copies (`Metaprocess.monomorphized`).** After Prune, every annotation of
the processed program, a trait object call's type and a variant pattern's type name a copy wherever the type is
closed (`Types.copied`); a type still generic in a parametric instance's own parameters keeps its arguments. So a
value names its copy (the interpreter reads the declared name off the annotation), and so does `typeof` (it did
already, as printed). The type-level section holds, where each generic declaration stood, its copies the program
reaches, from code or from another emitted declaration's fields; the generic declaration itself is gone, and a copy
only a meta block's `declof` or `typeof` made is not emitted. Type-level declarations' own fields name copies too.
`Verify.program ~monomorphized:true` (only `Compile.back`, the finished program) rejects a closed use of a generic
type ("This is annotated List<string>, which names the generic type rather than its copy."; checked by disabling the
renaming), and reads a copy's fields as its generic type's at its arguments, renamed (`Types.named_fields`). The
printer finds `Display` and `Debug` by the declaration a value's copy was made from (`Types.declaration`).
**Review after:** written types inside processed code (a parameter's, a `var`'s, a lambda's signature) are left as
written: they print the same and nothing after the walk reads them. The printer's instance is still the one keyed
first under the declaration's name (`is_printer`), which `core/types/copies` shows as a `Box<unit>` copy no value
has; R19's static `Display` removes it.

I224. **S4b: what R7 still leaves (not built).** (a) A meta block's program is compiled as the walk leaves it: its
code is not renamed, its types are not copies, `Verify` checks it without `~monomorphized`. Renaming it needs the
readers of meta values that compare a declaration's name, `Core.list` in `Syntax.kind_of`, `Splice.of_value` and
`Metaprocess` (line 249), and `Splice.reify` writing `New (name, …)`, to go through `Types.declaration`, and a memo
per instance so the `shared` part is not renamed once per block. (b) A generic type declared in a function body is
not copied (local types are renamed after their owner and checked with its body, not by `check_type_level`). (c) No
per-copy impl: a generic impl's methods were already instances per key, and a static call on a copy's name reaches
the generic impl through I222; the registry holds no entry under a copy's name. (d) `internal-docs/Metaprocessing.md`
still says a function generic only over types is "checked once, generically, and `Type_mono` copies it", and
"Not built: … a value argument in a type annotation"; listed for the user, not edited (step 3 of the handoff).

I225. **S4b: cost.** Compile and run, median of 11, ms, this machine, S4 → S4b: `hello` 161 → 165,
`working_example` 179 → 181, `core/types/copies` 209 → 198; `stdlib/encoding/generic` 401 (failed before). The
renaming is one pass over the finished program; nothing runs per meta block.

I226. **S5a: the built-in type names are `Int`, `Float`, `String`, `Byte`, `Char`, `Bool`, `Unit` in the compiler (R30).**
The old names are gone, not aliased: `Typecheck.primitive` reads only the new spellings, and every printer of a type
(`Types.string_of_ty`, `string_of_infer_ty`, `type_name`, `infer_type_name`, `string_name`) writes them, so diagnostics,
`typeof(…).name`, `str(T)`, keys (`Box$Int`) and mangled method names follow. Also renamed: the owners in
`Builtins.methods` and their natives (`String.to_upper`, `Int.to_float`, …, which `Types.type_name` must agree with), the
derived `Eq`'s `Bool` and a static param's literal check in `Metaprocess`, an effect operation's default `Unit` return
in `Typecheck`, the parser's `run<Unit> { … }` hint, `cx docs`' names for the primitives (`cx/lib/docs.ml`), `cx new`'s
skeleton, the Cronyx in `test_bootstrap.ml`'s rendering and prelude-walk probes and `test_cx.ml`, and Cronyx examples in
backticks in OCaml comments. No other built-in type name was lowercase: `Type`, `Span`, `Array`, `List` already were.
**Kept, review after:** `Value.type_name`, the interpreter's runtime kinds in its own failures ("Expected a bool
condition, got int."), which sit beside `tuple`, `record`, `array`, `fn` and read as prose; the generated prefixes
`unit$meta` and `type$open` in `Ast` (a unit there is a compilation unit); English in messages ("A string literal",
"A string cannot be assigned into", "A char literal holds exactly one character").

I227. **S5a: how the sources were renamed.** A script over a Cronyx lexer that follows `scanner.ml` (strings, chars,
nested block comments), so nothing inside a literal or comment is matched by accident. An identifier token is renamed
unless it is preceded by `.`, `fn`, `var`, `ctl`, `@` or `handler`, or followed by `:`: those are methods (`input.int()`,
`fn int(self)` in `Codec`), variables, parameters and fields, which stay lowercase. A file that also binds the name as a
value (`var unit` in `Transform.cx`, the parameter `unit` in `Time.cx`) renames it there only in a plain type position.
A string literal whose whole text is a built-in name is renamed, because each one names a type the compiler now prints
(`__tx_named("unit")` in `Transform.cx`, `TypeKind.Named("unit")` in `EffectHandler.cx`, `Cli.cx`'s comparisons of a
field's written type, four meta fixtures); a literal that merely contains one is user text and is left. In comments,
only code in backticks and fences is renamed, never prose, and not after `a`/`an` or beside a `/` (`std/async/Timer`).
User types: the 75 lowercase declarations (25 `trait`, 50 old-syntax `effect`; R30's 76 was a rough count) are
renamed in their own file, CamelCase (`parse_error` → `ParseError`), only where the name stands as a type: an operation
of the same name (`fn log`, `log("x")`, `ask()`) stays. The stdlib's `effect async` is `Async` everywhere it is imported
(`import { Async } from "std/async/Task"`); the module path keeps its directory name. A `handler h : Log` keeps its
lowercase name, since a handler is a value. `benchmarks/` (5 `.cx`) was renamed as well, being Cronyx the toolchain
runs; `examples/` holds no `.cx`.

I228. **S5a: expected outputs.** For each fixture passing before and failing after, the expected file was rewritten
from the program's actual output only when the two agreed word for word up to case (97 files); the one other change is
`core/traits/errors/ambiguous_receiver`, whose list of declaring types is now `Array, String, List, Map, Set and
StringBuilder` (was `Array, List, Map, Set, StringBuilder and string`: the owners' order follows their names). The 24 red fixtures whose
expected output names a type were edited by hand: types in diagnostics, printed signatures and printed code renamed
(`meta/syntax/printer`, `round_trip`, `reflection/typeof_effect_*`, `effects/rows/inferred_rows`, the
`effects/errors/*` names of user effects such as `'Logger'`, `'One'`); text the program prints from its own strings
left (`not an int: nope`, `c after attempt async`). **Review after:** `stdlib/os/Cli`'s help now shows `--port <Int>`
and `--host <String>`, because it prints the field's written type; its prose (" takes an int, not '…'", "it takes a
bool, an int, a float or a string") and `Codec`'s messages ("expected an int, found a string") are user text and
stay lowercase, so the two now disagree in case. Say if the CLI help should print lowercase words instead.

I229. **S5a: left for after step 5 (docs, editors).** Not edited, per the handoff: `docs/docs` (27 pages: most uses in
`language-metaprogramming/static-params.mdx`, `language-basics/operators.mdx`, `traits.mdx`, `strings.mdx`,
`functions.mdx`, `language-metaprogramming/compile-time-functions.mdx`, `reflection.mdx`, and every page under
`language-effects/`), `docs/src/components/HomepageFeatures/index.tsx`, `README.md`, `CLAUDE.md` (one example), every
`internal-docs/*.md` but the code of `CPS Migration.md` (45 files with a built-in name, most in `Math.md`, `Generated
Documentation.md`, `Elaboration.md`, `Algebraic Effects.md`, `Inlining.md`, `Data Structures.md`, `Type System.md`,
`Static Params.md`, `GADT Refinement.md`, `Metaprocessing.md`), and the editor keyword lists:
`editors/nvim/syntax/cronyx.vim` (`syn keyword cronyxType int float bool string char byte unit never any`) and
`editors/vscode/syntaxes/cronyx.tmLanguage.json` (the same list as a regex). `legacy-bootstrap/` is untouched.
`CPS Migration.md`: 31 built-in names renamed inside code fences and backticks, no prose changed.

I230. **S5a: `cx` fixtures I could not check (review after).** `cx/test/library/expected.json` and
`cx/test/packages/documented/app/expected.json` were edited by hand (`"name": "Int"` for each primitive, and the
built-in methods' `"Byte.to_int"`, `"String.to_upper"`, …), because both cases are red on old syntax (`library/Ops.cx`,
`ink.cx`). If `cx docs` sorts entries by name, the built-in methods may now come in a different order. Trap found:
`dune test cx` deletes `cx/test/registry/app/cronyx.lock` (the registry case removes the lock first, and its build,
red for now, never writes it back); it was restored from `HEAD` after the run, and a later step should check
`git status` for it after running the suite.

I231. **S5b: one `__root` for the whole top level (A5-Q1, I162).** `Compile.root_call` hands every top-level
statement, in order, to the prelude's `__root<Rest>(main: () -> <Console, Logger, Args, Env, Time, Random, Rest> Unit)`
as one lambda; `Precheck` sees the same through `Compile.under_root`. Each top-level `var` stays a global, declared
without a value ahead of the call (`Compile.globals`), and its initializer is an assignment in place inside the body
(`Typecheck.root_stmt`); the name is bound at the top level only once its initializer is checked, so a function reached
before it reports it undefined (`core/top_level/errors/before_initializer`). `Typecheck.root_block` checks each statement
with a row of its own, so an error still names its statement and the next one is checked (`errors/each_statement`); a
statement reading a `var` whose initializer failed is skipped (`root_failed`). The consequences I162 listed: (a) a later
statement settles an earlier `var`'s type, so the A5-Q1 annotations came out (Fixture changes in S5b); (b) a statement
whose row holds `Throw` is checked again inside `__throwing<T, X: Display, Rest>`, so each catches its own failure and
two statements may throw different types (`core/top_level/one_root`); one statement throwing two types is an error, as
it is in a function body; (c) `__root` has no `X` any more, so U4's default is not needed there: a program that never
throws makes no `__throwing` instance; (d) `block_on` is not in the prelude (dropped in S1), so nothing runs the top
level as a task yet; when 5c brings `async` back, the one lambda is its one main task. Reviewed against A5-Q1 and I162:
it matches the decision except for I232, fixed.

I232. **S5b: a top-level meta block is a statement of the root's body.** As first built, each run of statements between
two top-level meta blocks was its own `__root` call, so the top level was one function only for a program without
one, and a `var` settled across a meta block failed (`var xs = []; meta { … } xs.push(1);` gave "Verify error: This is
annotated 'a, which is still generic."). Now the walk hands the whole top level, meta blocks included, to one root
call, and `root_block` runs a meta block where its check reaches it, through a new walk op `top_meta`: the block is
spliced at the top level, the declarations it generates are registered there as before, and its statements come back
to be checked in place; a generated `var` is a global too. The order is unchanged: a meta block runs after what the
statements above it reach. Fixture: `core/top_level/across_meta`.

I233. **S5b: a throwing top-level statement is checked twice (review after).** `root_block` learns that a statement
throws from its row, so a statement that does is checked once on its own and again inside `__throwing`. Instances are
memoized, so the cost is the second check; but a meta block written inside such a statement (a `meta` expression)
runs twice at compile time. Alternatives: check every statement inside `__throwing` and drop the wrapper when the row
holds no `Throw` (one `__throwing` instance and transform per statement otherwise, which I161 measured as the slow
path), or find `Throw` in a cheaper pre-pass over the statement's calls.

I234. **S5b: why `types/expected/written_key.txt` changed.** `var h = helper<Int>; print(h(5)); print(typeof(h).name);`
now prints `(Int) -> <Console> Int` where it printed `(Int) -> Int`. A top-level `var` is a variable of one function
body now, so its function type's open row is closed with the body's row rather than when its own statement ended,
exactly as for a local: the same three lines inside a function print `(Int) -> <Console> Int` too (checked, at HEAD as
well). It is the reading A5-Q1 chose (the top level is one function body), so the expected output was updated rather
than the checker. **Review after:** whether a function value's open row should close to the empty row when nothing it
holds performs, here and in a function body alike. Also from the one body: instances the top level makes are finished
(`finish_root`) once, at its end, rather than after each statement.

I235. **S5b: static `Display` (R19).** `str<T: Display>(value: T): String { return value.fmt(); }` and
`debug<T: Debug>` are library functions in `std/text/Format`, globally imported by the prelude with the traits;
`print` and `printerr` are `<T: Display>`. A call is an ordinary generic call, so each type printed is an instance
(`std#Format#str#0`, …) calling that type's impl directly. Impls: in `Format`, `Int`, `Float`, `Bool`, `Byte` (its
number), `Char` and `String` (quoted by `Debug`), `Unit` (`unit`, the value as before), `Name`, `Span`, `Array<T: Debug>`,
`Option<T: Debug>` (`Some(1)`, `None`), `Ordering`; `Result<T: Debug, X: Debug>` in `core/Error`; `AttrArg`, `Attr`,
`TypeRef`, `TypeField`, `TypeVariant`, `TypeShape` (their structure, as the old printer wrote them) and `Debug for
Type` in `meta/Reflect`. `List`, `Set` and `Map` already wrote each element with `debug`, which is now `T`'s impl. The
built-in types' impls call two natives, `__display` and `__debug`, that format only a built-in value. Deleted: the
interpreter's lookup of an impl by its method's name (`Builtins.written`'s `method_of`) and the `CX_PRINT_PROBE` code
beside it; `__written`; `Metaprocess.printed` (an instance of every `Display`/`Debug` method, made whether or not
called), the printers `reached` added to a meta block's program, Prune's exception (`constructed`, `build`: a printer
kept for every type a reached body builds), and `is_printer`'s first-key instance name (I223: the `Box<Unit>` copy in
`core/types/copies` is gone). The derivers generate each part's `debug` call (`Point { x: 1, label: "a" }`,
`Shape.Circle(1.5)`, as before) with every type parameter bounded by `Debug` (`Derive.with_bound`), rather than calling
`__written`. Kept: the rule that a `Display` or `Debug` impl performs no effect (`format/errors/effectful_display`),
since a part is written inside another value's impl; its comments no longer name a printer.

I236. **S5b: a type with no `Display` impl is an error where it is printed. REPLACED by the user's decision of 2026-11-22: every type prints, through metaprogramming (I242).** `print(Point { x: 1 })`
with no impl reports "Expected Display, got Point." (the message every unmet bound already gives), at the call; a
function value likewise (`format/errors/no_impl`). Taken because it is the static reading of R19 and the rule recorded
for the native backend (`str<T: Display>`, no structural fallback, 2026-10-26). Alternatives: (B) the Stdlib Plan's
fallback, the built-in structure for a type with no impl, which statically means the compiler deriving an impl for
every printed type that has none (a built-in derive, decided per type at the call); (C) a run-time structural form
that writes parts without their impls, which prints a part with its own impl wrongly. **Review after:** inside a
generic function written without the bound (`fn show<T>(v: T) { print(v); }`) the error is at the `print` in the
instance, and does not name the call that made the instance; and an impl's own parameter bound is checked only when
its method is (I240).

I237. **S5b: tuples and anonymous records have a built-in form.** Neither has a declaration to implement a trait on.
A tuple or a closed anonymous record meets `Display` and `Debug` when every part meets `Debug` (`Typecheck.admits`,
`structural_parts`), and `v.fmt()` or `v.debug()` on a variable of one is checked as its parts through `debug`
between the brackets (`structurally_written`): `(1, "a")`, `{ x: 1, y: "b" }`, `()` and `{}` when empty. Only a
variable is taken apart, which is how `str` and `debug` call it; on any other receiver the ordinary lookup fails.
**Review after:** an anonymous record's fields are written in label order (the order the checker keeps), where the old
printer wrote the value's order; a tuple of a function value is refused like the function value.

I238. **S5b: `absent` meets every bound.** I25 defaults an effect parameter nobody settles to `absent`, so an instance of
a handler arm that writes its failure (`str(e)` in `effects/v2/root/root_shaped`, `stdlib/v2/block_on`) reached
`str<T: Display>` at `T = absent`. No value has the type, so `admits` accepts it under any bound, and a method call on a
variable of that type is checked as `__unreachable()` (a new native whose type is free and which fails if it runs).

I239. **S5b: an uncaught failure is written through `Display`. REPLACED by I247: any failure is written through `str`.** `__throwing<T, X: Display, Rest>` writes the failure
with `str`, as before. So a top-level statement may only throw a type that implements `Display`, and one that does not
gets "This throws Bad, and nothing catches it, so the top level reports it through Display, which Bad does not
implement." (`Typecheck.reported_uncaught`, `core/top_level/errors/uncaught_without_display`) rather than a row
mismatch. `trait Failure: Display` now, so a `Failure` object can be written, and the library's failure types implement
`Display` as their message (`DecodeError`, `IoError`, `Utf8Error`, `CliError`). **Review after:** whether an uncaught
failure of a type without `Display` should be reported without its value instead of refused.

I240. **S5b: an impl's parameter bounds are not checked at the call (review after).** `satisfies` finds `impl Display for
List<T>` for `List<Point>` without checking `T: Debug`, so `str([Point { x: 2 }])` with no `Debug` for `Point` reports
"Expected Debug, got Point." at `value.fmt()` in `Format.cx`, inside the instance, not at the call. The fix is to check
the impl's own bounds in `satisfies`, as `worktree-compilation` did (`ctx_impl_bounds`).

I241. **S5b: cost.** Compile and run, median of 11, ms, this machine, HEAD (`fcc7db5`, built in a copy) → S5b: `hello`
41 → 51, `effects/v2/working_example` 61 → 73, `core/types/copies` 41 → 54. Not profiled. Likely the larger
`text/Format` (a deriver pair that generates code, and impls for twelve more types) checked by `Precheck` with every
program, and one `str`/`debug` instance per printed type. **Review after.**

I242. **S5b: every type prints, through metaprogramming (the user's decision of 2026-11-22, Zig `std.fmt` style), as
built.** `str<T>(value: T): String` and `debug<T>` in `text/Format` carry no bound; each body is one statement `meta`
block over `T`. If `implements(T, Display)` (`Debug` for `debug`), it generates `return value.fmt();` (`.debug()`);
otherwise it generates the body from `typeof(T).shape` through `__shaped`: a Product writes `Name` or `Name { x: …, y: … }`,
a Sum a `match` with one arm per variant writing `Name.V` or `Name.V(…)` (named payloads positionally, as the derivers
did), a Scalar the native (`__display`, or `__debug` for `debug`), and anything else `value.debug()`, which the checker
writes structurally (I246). Every part is `debug(value.x)`, so each part is an instance of its own and a written impl
on a nested type is used; a recursive type (`Tree.Node(Tree.Leaf, 1, …)`) is met by the instance's in-progress hit.
`print` and `printerr` are `<T>`. Deleted: `derive(shape) for Display` and `for Debug`, `Derive.with_bound` (Derive.cx
is as at HEAD), and the `T: Debug` bounds on the `Array`, `Option` and `Result` impls (I248). The output of every
formerly derived type is unchanged. No hook: this runs only because a program calls `str`, `debug` or `print`.

I243. **S5b: `implements(T, Trait): Bool` (review after).** A reflection query, alongside `typeof`, `moduleof` and
`declof`, allowed only inside a meta block ("'implements' is only allowed inside a meta block, with a type and a
trait." elsewhere, `meta/implements/errors/at_runtime`). The loader renames a call to it, in a module that declares no
`implements` of its own, to `__implements`, so a program's own `implements` does not capture the library's call
(`meta/implements/own_name`); the checker answers it (`Typecheck.implements`) and splices a `Bool` literal, as
`typeof` is spliced. The first argument is read as `typeof` reads its operand (a type, a static parameter, a value);
the second must name a trait, bare: a trait with arguments (`implements(T, Add<Int>)`) is not taken yet. It answers
for the impls declared when the block runs, so an impl a later meta block generates is not seen. A tuple, an
anonymous record and a function never implement anything (they have no declaration to implement on), `absent` (I238)
implements everything, a trait object its own trait and each supertrait. Fixture: `meta/implements/implements`.

I244. **S5b: `implements` checks a generic impl's own bounds (review after).** `impl Display for Box<T: Display>` answers
`implements(Box<Money>, Display)` true and `implements(Box<Point>, Display)` false when `Point` has no impl, so
`print(Box { held: Point { x: 2 } })` writes the structure, `Box { held: Point { x: 2 } }`, rather than failing inside the
impl. Each parameter bounded by a bare trait is checked, recursively, against the type's argument at its position
(`ctx_impl_params`, recorded beside `ctx_impls`); any other bound is taken as met. `satisfies` itself is unchanged, so
I240 stands for an ordinary bound.

I245. **S5b: `str` falls back to `Debug`. REVIEWED by the user 2026-11-22: built.** `str` tries a `Display` impl, then
a `Debug` impl, then the structure, as `internal-docs/Data Structures.md` (line 198) says: `print(Temp { c: 20 })` with
only `impl Debug for Temp` writes its `Debug` form. `debug` does not fall back to `Display`: a type with only `Display`
still writes its structure under `debug`, so `debug` always tells values apart. `stdlib/format/debug_fallback`.

I246. **S5b: a function value prints as `<fn>`; tuples and records meet a printing bound outright.** `v.fmt()` or
`v.debug()` on a variable holding a function is checked as the literal `"<fn>"`, beside I237's structural form, so
`debug` of a function type reaches it through `__shaped`'s last case (`{ act: <fn>, mark: 'c' }`). `admits` no longer
asks each part of a tuple or an anonymous record to meet `Debug` under a `Display` or `Debug` bound, since `debug`
takes any type now.

I247. **S5b: an uncaught failure is written through `str` (I239's question, simplest consistent option).**
`__throwing<T, X, Rest>` has no bound, and `Typecheck.reported_uncaught` and its error are deleted: `Bad.Oops` with no
impl is reported as `uncaught failure: Bad.Oops` (`core/top_level/uncaught_structure`, `.rt`, the former
`errors/uncaught_without_display`). Kept: `trait Failure: Display`, and the `Display` impls on `DecodeError`,
`IoError`, `Utf8Error` and `CliError` (their message), because a `Failure` object has no structure of its own: without
the supertrait it would print as the trait's name.

I248. **S5b: which impls stay.** Every `Display`/`Debug` impl in the stdlib writes something other than the shape form,
so none was deleted: the built-ins (natives), `Array`, `List`, `Set`, `Map`, `Option` (`Some(1)`, not
`Option.Some(1)`), `Result`, `Ordering` (`Less`), reflection's records (`Named(Int, [])`, no type name), `Type` (its
name), `Complex`, `Rational`, `BigInt`, `Duration`, `Timestamp`, `Measurement`, and the failure types (I247). The
`T: Debug` bounds came off `Array`, `Option` and `Result`: with them, `implements(Array<Point>, Debug)` would be false
by I244 and the array would fall to the shape form.

I249. **S5b: `__shaped` must not reach `str` or `debug` (trap).** Their meta blocks call it, so a call to either inside
it (directly, or through `numbered`, which builds its names with `str`) is met while `__shaped` is still being
metaprocessed: "'__shaped' is still being metaprocessed, so a meta block cannot call it yet." It uses `__display` for
names and builds the `__p0…` names in place. It takes `typeof(T)`, not `T`: a type with no fields standing as a value
is its one value (I213), so `__shaped(T, …)` of `Origin` is "Expected Type, got Origin". **Review after:** any helper
a printing meta block calls inherits the rule.

I250. **S5b: cost of I242.** Compile and run, median of 15, ms, this machine, before (the tree at the start of this
work, built in a copy) → after: `hello` 54 → 50, `effects/v2/working_example` 74 → 69, `core/types/copies` 57 → 52.
Faster, most likely because the two derivers are no longer prechecked with every program; a printed type now costs
one meta block run per instance of `str` or `debug`. Not profiled.

I251. **DEFERRED to the Async redesign (2026-11-23).** **S5c: `Async`'s shape (review after).** `trait Async { @ctl fn park(register: (() -> Unit) -> Unit): Unit; fn reactor():
Reactor; }`. `suspend<T>(register: ((T) -> Unit) -> Unit): <Async> T` is a library function over `park` (the woken value goes
through a captured slot); `after(delay, wake)` and `when_ready(socket, writing, wake)` are library functions reading
`reactor()`, a record of pure functions (`after`, `when_ready`, `on_cancel`) that set a wake-up and hand back its cancel.
`waker()` is gone. Why: (a) an operation with its own static parameter (`@ctl fn suspend<T>`) makes each handler's arm
generic per call, and a run no call reaches leaves the arm's type unsettled (`async/uncaught`: "This is not settled ...
{ suspend: ((('b) -> Unit) -> Unit, ...) }"); (b) an arm that forwards an unmarked operation of its own effect to the outer
handler (`fn after(d, w) { return after(d, w); }`) makes the run take control outward with the effect it binds, which the
transform types wrongly (I253). Alternatives: keep `suspend<T>` the operation once arms of generic operations settle when
unreached; keep `after`/`when_ready` operations once I253 is fixed.

I252. **S5c: a scope is a scheduler of its own (R1 lists of tasks; review after).** `__scope` runs each task under a run of its own
(`__launch`) whose `park` arm stores `() => { resume(()); }` in the scope's queue, typed `List<() -> <E> Unit>` (honest: what
the task's continuation performs is the scope's `E`), and a pure waker. When none of its tasks can run, the scope parks on the
scheduler around it, and a waker of one of its tasks wakes it. `block_on` is the same at the root, with timers and sockets in
place of parking. Wakers are pure, so they compose across scopes. **API change:** `scope`'s `start` is
`(() -> <Async, Throw<X>, E> Unit) -> Unit` and queues the task, which runs once the task that started it waits or finishes
(it was `-> <Async, E> Unit` and ran the task to its first wait at once); `all`, `race`, `both`, `interleaved` are unchanged.
Alternative: a started task runs at once, which makes `start` perform `E`.

I253. **DEFERRED to the Async redesign (user, 2026-11-23).** It only bites a handler that forwards an operation of its own effect outward (I251's `after` arm). **S5c: found, not fixed: a run binding an effect its own function performs outward.** `fn launch(...): <Async, Console> Unit
{ run<Unit> { task(); } handle<Async> { fn suspend(register, resume) { register((v) => { ready.push(() => { resume(v); }); });
} } }` inside a run handling `Async` fails "Expected a function performing <Async, Console>, got one performing ." (the prompt
path, `__tx_prompt`, when the run's outward row holds the effect it binds). I251's `reactor()` design avoids it in the library.

I254. **S5c: cancelling a waiting scope is cooperative (review after).** A failure or `stop` unwinds every parked task of a
scope by discontinuing its continuation; a task that is itself a scope waiting on this one registered a pure hook through
`Reactor.on_cancel` while it waits, and is woken instead: it stops its own tasks in ordinary code, then parks once more and is
discontinued. Why: the scope's own cleanup performs `E`, and a `defer` calling through `E` is "A deferred statement cannot fail"
(d_open). A task that waits inside a `defer` while it is unwound carries on (`unwinding`), as before
(`async/timeout_defers`); one that waits after its scope is cancelled is discontinued at once. Alternative: let a `defer`
call through a row parameter when what it calls only discontinues.

I255. **S5c: the scheduler stamps timers (review after).** `Reactor.after` performs nothing, so it cannot read `Time`; a timer
records its delay, and `block_on` sets `due = instant() + delay` before it next looks at its timers. A timer set while other
ready tasks run is due from the end of that batch rather than from when it was set. Alternative: `after` takes the instant
and `sleep` performs `Time`.

I256. **S5c: `block_on<E>(main: () -> <Async, E> Unit): <Time, E> Unit` (review after).** It no longer catches `Throw<X>`
and panics "uncaught failure": a failure passes outward like any other effect, and the top level's `__throwing` reports it.
`timeout(limit, task)` is `race` of the task and a `sleep`, so the task's `defer`s run when it runs out of time. The
deadlock and woken-twice panics are kept (`async/deadlock`, `async/woken_twice` give them).

I257. **S5c: `Iter`'s `close` row and the `for` loop (I163; review after).** `close: () -> <E> Unit`: closing a producer unwinds
it, which performs what pulling does. A `for` over an `Iter` closes it in a `defer`, which then calls through `E`; the
checker exempts that one generated `defer` (`close` on a `seq#` variable) from "A deferred statement cannot fail", since what
it runs is the producer's own `defer`s. `Adapters.take` calls its `shut` from `next` now that both perform `E`.
Alternative: a separate close row `Iter<T, E, C>`; or close explicitly on each exit of the loop.

I258. **S5c: the transform splits pulled loops and calls of a record's function (review after).** A `for` over an `Iter` whose
`next` takes control is lowered by the transform as the checker lowers it (`__tx_pulling`: `var seq; defer seq.close(); while
(more) { match seq.next() … }`) rather than refused. A method call naming a field that holds a function (`seq.next()`,
`s.reactor.after(…)`) reaches the transform as a method call with only its result's type; a new reflection query
`field_type(t, field)` (native `__field_type`, `Typecheck.field_type`) gives the field's type, and the call is split as a call
of the field. The pattern names `Option` as `next`'s type does.

I259. **S5c: Fs, Dirs, Process, Net, Stdin are unmarked; Exit is `@abort` (review after).** `fn open`, `fn start`, `fn connect`
… were `ctl` and resumed once; under honest rows they are tail-resumptive. `trait Exit { @abort fn exit<T>(status: Int): T; }`;
the root's arm records the status and the process ends once the root's run is left, so the `defer`s between `exit` and the
root run first (`os/exit`). Net's handler cannot wait (its arm would park on the scheduler, not the task's scope), so the
system's `connect` starts a non-blocking connection and the stream finishes it, trying the next address, where it is first
used (`OsStream.__connected`). **API change:** "connection refused" is thrown by the first `read`, `write` or `shutdown_write`,
not by `tcp_connect`, whose row stays `<Net, Throw<IoError>>`. Alternative: `tcp_connect` performs `Async` and waits.

I260. **S5c: the one `__root`, and `__meta_root`.** `__root<Rest>(main: () -> <Console, Stdin, Async, Fs, Dirs, Process, Net,
Exit, Logger, Args, Env, Time, Random, Rest> Unit)`: one run handling everything but `Async` around `block_on(main)`, so the
top level is the scheduler's main task. `Stdin` and `read_line` are globally imported again. A meta block's program used to run
under `__root`; it now runs under `__meta_root` (the S5b root: Console, Logger, Args, Env, Time, Random), because the program's
root reaches the I/O library, which calls `str`, and a `str` meta block then reached its own instance while it was walking
("'str' is still being metaprocessed"). `Ast.is_root` covers both; `Ast.is_program_root` finds the program's.

I261. **S5c: a top-level statement's row is contained in the root's, not unified with it.** `Typecheck.root_block` did
`unify_row row whole`; with `Async` and `Exit` in the root's row, a function value called at the top level took the whole row
and became a value taking control, while the top level, which splits nowhere, was only wrapped (`core/lambdas/basics`: "fn
expects 6 argument(s) but got 3"). `row_within` leaves its row to what it performs. `types/expected/written_key` still prints
`(Int) -> <Console> Int` (I234 unchanged).

I262. **S5c: the root is converted from the body `root_block` checked.** When the top level takes control, the transform used to
re-check the statements as written, without each `var`'s global or the `__throwing` catchers ("This takes control of 'Throw',
and no handler of it is in scope here."). `root_block` records the body it checked (`root_rewritten`: a `var` as an assignment
to its global, a throwing statement under its catcher) and the conversion is handed that.

I263. **S5c: compiler fixes the redesign needed.** In `Metaprocess.surface` (an instance as `declof_call` shows it): a row
parameter of the key is written back in the body too, as a row and as a type's argument (`Tasks<E>`); types inside row labels
are substituted (`Throw<X>`); a type no name spells (`(Int, String)`) is substituted into the body; a label at `absent` is
dropped; a static parameter the key leaves unsettled or generic stays the instance's own. The transform's copies keep those
static parameters; a copy whose function returns a value ends in `k(__unreachable())` where it falls off its end (a path that
`panic`s); a `panic` ends a branch for the join; `discontinue` of a continuation from outside the function hands it the
handlers its type takes. A lambda converted to take control gets the parameter types its context gave it (`written_type`, an
open or unsettled row written open). The checker orders the handlers a value takes by the effect's name as shown, as the
transform does (it sorted `std#Error#Throw` after `Wait`, the transform `Throw` before). A label whose arguments are unsettled
meeting a closed row that lacks it is at `absent` (`Types.unsettled_label`). `instance_at` falls back to the key the call
recorded at its span when the callee's written type no longer settles it.

I264. **FIXED (2026-11-23, user: "the local var should always shadow the normal decl").** The cause was in the checker,
not the transform: `admits_row` postponed a call's row to an unchecked top-level function's whenever the callee's *name* was
in `unchecked`, so `main()` on `block_on`'s parameter, with the program's `fn main` not yet checked, had its `<Async, E>` row
postponed and the run's outward row lost `Exit`. `unchecked` now holds the scheme each function was hoisted as, and
`calls_unchecked` postpones only when the name still resolves to that scheme. The renames (`__main`, `__task`,
`__producer`, `__f`, `__body`, `__session`, `__respond`, `__exchange`) and their comments are gone from `prelude.cx`,
`Task.cx`, `Yield.cx`, `Error.cx`, `Test.cx`, `WebSocket.cx`, `Http.cx`. New fixture
`core/modules/shadowing/own_function_param` (fails on the old checker with "This takes control of 'Stop'…"). The
transform's `Cx.locals` / `__tx_local` guard is kept; it may now be redundant. **S5c: found, not fixed: a program's function captures a library local called in a run body.** `block_on`'s `main()`
inside its run was taken for a program's `fn main` (`core/defer/defer_basic`: "This takes control of 'Exit'…"). The library
calls such values through `__main`, `__task`, `__producer`, `__f` and `__body` (`block_on`, `__launch`, `iterator`,
`attempt`, `run_tests`, the roots). A program with a parameter named like one of its own functions, called in a run's body,
still hits it. The transform now knows the names a split function binds (`Cx.locals`), which was not enough.

I265. **S5c: found (pre-existing at HEAD): a function value calling a named function that takes control twice. FIXED by I270.**
`run<Unit> { var g = () => { p(); p(); }; g(); } handle<Wait> {…}` with `fn p(): <Wait, Console> Unit` fails "This code does
not handle the effect 'Console'"; one call, or the same body in a named function, works. It is why two top-level statements
that throw, in a program whose top level takes control, fail, and why the new fixtures pass named functions to `attempt`.

I266. **FIXED by I303 (S5d batch 4).** **S5c: found, not fixed (pre-existing): a copy calling its module's private helper that takes control.** `Base64.decode`
and `Hex.decode` under a run copy their helpers' callers, and the copy names `__value` / `__digit`, which is not in scope
where copies are declared ("Undefined variable"; `encoding/toml`'s `peek` at baseline). `v2/encoding/digests` encodes only.

I267. **RESOLVED by I276 (S5d).** **S5c: found, not fixed: a named function with an inferred row passed as a value to a scope** (`both(user, count)` with
`fn user(): String { pause(); … }`): "Unknown type 'open'" (`async/both`). Writing the row works.

I268. **S5c: cost (review after).** Compile and run, median of 11, ms, this machine: `hello` 41 at HEAD (5a, built in a copy),
about 50 at the end of S5b (I250), 213 now; `effects/v2/working_example` 60 → 211. The main checkout's old root, which handled
the same effects, takes 110 for `hello`. Most of it is the root's I/O handlers, which make every program reach the io, fs, os
and net modules (about 150); `block_on` adds about 20. Not profiled. Alternatives: a smaller root with the I/O handlers in a
module only the programs that use them reach (which needs the root to be chosen, close to a hook), or cheaper Precheck.

I269. **S5c: the rest of the stdlib.** Rows written where the new model needs them (`send`, `recv`, `select`, `await`, `sleep`,
`resolve`). `Http`, `WebSocket` and `Test` had their runs written out (`run<Unit>`, `handle<Throw<IoError>>`,
`handle<Assertion>`). `Cli.from_args` writes `parse_args`'s type where it calls it (the trailing block left it unsettled).
Transitively loading now: `crypto/*`, `encoding/{Hex,Base64}`.

I270. **The continuation of a function value made taking control has a declared row (fixes I265).** `cps_lambda`
(`typecheck.ml`) bound the value's continuation `k` at `(R) -> <ρ> A` with ρ a plain fresh row. A call of a value whose row
is an undeclared variable unifies that row with the caller's (`admits_row`), so every continuation of the body that calls
`k` (each one's `__is_discontinued` branch does) shared one row. In `() => { p(); p(); }` the inner call's continuation is
among them, and its key closes the copy's continuation row (`close_row`): that closed the outer continuation's row too,
before the second `p` in it was checked, which performs `Console` ("This code does not handle the effect 'Console'"). A named
function's copy never hit it because its continuation is written `(R) -> <E> R'` with `E` a static parameter, so declared.
Fix: ρ is declared (`Types.declare_row`), as the copy's `E` is, so each call of `k` is contained in its caller's row rather
than tying the callers together. Old fixtures turned green: `stdlib/io/lines_to_end`; `stdlib/utf8/invalid` gets past the
same error and now fails on its expected output only (`Err(Invalid(4))` against `Err(Utf8Error.Invalid(4))`, and an
`IoError` printed as `Other("…")`), which is not this. I264 and I267 unchanged (`async/both` still "Unknown type 'open'").
Workarounds left as they are: `stdlib/v2/os/process` (`attempt(checks)`) and `stdlib/v2/net/loopback`
(`attempt(everything)`) pass named functions to `attempt`.

I271. **REVIEWED (2026-11-24): accepted; the `v2/` folders were then flattened (I337).** **S5d batch 1: an old `tests/effects` fixture with a `v2` copy is deleted (review after).** 71 fixtures under
`tests/effects/` (outside `errors/` and `v2/`) already had a copy in `tests/effects/v2/` (or `methods/v2/`) at the same
path or basename, made by C5a–S4 by the same mechanical rules, with the same expected output; diffing each pair shows only
the syntax rules and dropped comments. The originals are deleted with their `test_bootstrap.ml` entries, and the copies stay
where they are (a later batch may move `v2/` up a level). One pair differs in its expected output:
`final/errors/resumes` expected "A 'final ctl' handler cannot resume", a check of the deleted `final ctl`; its copy
`v2/final/errors/resumes` expects "This handler settles 'T' at Int, but 'throw' is handled once for every type its call
sites use", which is what the new model says of the same program. The list is in "Fixture changes in S5d".

I272. **REVIEWED (2026-11-24): accepted.** **S5d batch 1: the rest are rewritten in place (review after).** 30 fixtures (one parked, I275) and the 5 helper
modules they import (`handled_in_import/{qualified, selective, signal}`, `named_import/signal`, `qualified_op/signal`), by C5a's
rules: `effect` → `trait`, `ctl op` → `@ctl fn op`, `run {` → `run<Unit> {`, `handle E {` → `handle<E> {`, an arm `ctl
op(a) { … resume v; }` → `fn op(a, resume) { … resume(v); }`, `resume;` → `resume(());`. Beyond those: `final ctl
op(…)` that no arm resumes is `@abort fn op<T>(…): T` (R14), its arm written without the continuation (`signal`'s
`stop`, `generic/row_argument_generalized` and `generic/errors/unconstrained_at_call`'s `throw`); a generic effect's
handler writes its arguments (R10): `handle<Throw<X>>` inside a generic function, `handle<Yield<Int>>` in
`generic/errors/{two_instantiations, written_row_arity, written_row_mismatch}`; `nested_decls/handler_in_block`'s
`handler quiet : Log { … }` + `with quiet` is a local `type Quiet impl Log { … }` + `with Quiet` (I278). The comments in
`generic/errors/two_instantiations` and `generic/row_argument_generalized` are dropped (CLAUDE.md), so the first's `.err`
moves from `[8:5]` to `[7:5]`; the other expected outputs are unchanged except I273's.

I273. **REVIEWED (2026-11-24): changed — reported inside the arm (I338).** **S5d batch 1: `handler/errors/arm_without_outer` reports at the run (review after).** `run<Unit> { log("x"); }
handle<Log> { fn log(s) { log("again " + s); } }` at the top level: the error is the same ("Unhandled effect 'Log': no
handler encloses this."), and its position moves from the `log` call inside the arm (`[2:44]`) to the `run` (`[2:1]`). A
handler is a value (R1): the arm is a method checked inside it, its `Log` is that method's row, and it reaches the root's
row where the processed run calls the handler, a node the transform spans at the `run`. `effect_sites` records the first
node of the top row to carry a label, and nothing in the arm is one. Taken as the new model's answer; pointing inside the
arm would mean recording where a handler method's own row first gained the label.

I274. **REVIEWED (2026-11-24): accepted.** **S5d batch 1: `run_value/return_clause` is deleted (review after).** It tested `run { … } handle Ask { … } return
(x) { x + 1 }`, the clause R15 deleted. Folded into the tail it is `run<Int> { doubled() + 1 } handle<Ask> { … }`, which
`v2/run_value/value` already is but for the `+ 1`.

I275. **FIXED by I279 (S5d batch 2).** **S5d batch 1: found, not fixed (review after): a loop calling a copy that performs an outward effect (`async/async` in
`expected_failing`).** Reduced:

```cronyx
trait Ask { @ctl fn ask(): Int; }
fn inner(n: Int) { print("inner " + str(n)); print(ask()); }
fn outer() { for (i in [0, 1]) { inner(i); } }
run<Unit> { outer(); } handle<Ask> { fn ask(resume) { resume(1); } }
```

fails with "This code does not handle the effect 'Console'" (at `Transform.cx`'s `declare`). Unrolled (`inner(0);
inner(1);`) it runs, and so does the loop with `print(ask())` in its body. The loop becomes a local `fn loop<plain#made>`
whose row is inferred; its body calls `inner`'s copy with a continuation that calls `join`, which calls `loop`, so the
copy's continuation row `E` ends in `loop`'s own row variable, still open, and `key_of_use` closes it (`close_row`) before
`inner`'s `Console` reaches `loop`'s row. The same shape as I270, with the open row the loop function's rather than a
function value's continuation. `async/async` (a scheduler loop calling `counter` → `print_item` → `pause`) hits it;
`async/interleaved`, the same program with the work inline, passes.

I276. **REVIEWED (2026-11-24): accepted.** **S5d batch 1: a type processed code left open reads back as a fresh variable (fixes I267; review after).** Splice
writes a type still open where a meta block reads processed code as `Ast.open_type`, and `Typecheck.named_type` read that
name as an unknown type ("Unknown type 'open'"); it now reads it as a fresh variable, as the `var` annotations of a
transform's handler values already were. Seen where a function value is made taking control at an expected type the call
has not settled: `generic/errors/unconstrained_at_call` (`caught(pure)`, `X` unsettled) now gives its real error ("The
static params of 'caught' are not settled here"), `generic/errors/two_instantiations` loses a second, cascading error, and
`stdlib/async/both` (I267: a named function with an inferred row passed to a scope) passes unchanged. No program that
checked before reads differently, since every one that met the name failed.

I277. **REVIEWED (2026-11-24): accepted, with the ambiguity error added (I339).** **S5d batch 1: `module.op(…)` performs that module's operation (review after).** `signal.stop("no reason")`, with
`signal` imported whole, was read as the module's declaration `stop`, which does not exist: an operation is a method of
its effect trait, not a declaration. The loader's qualifier for a module bound whole (`Loader.resolve_unit`'s `bind`) now
names the operation when the module declares no export by that name and exactly one of its effect traits has a method of
it (`handled_in_import`, `qualified_op`). Two of its traits with the method fall back to the old reading, an undefined
name; an "ambiguous operation" error there is left for later.

I278. **REVIEWED (2026-11-24): accepted.** **S5d batch 1: a type with members in a function body (review after).** `type Quiet impl Log { fn log(…) { … } }`
inside `fn main` hit `assert false` in the checker: `implemented_in_types` and `types_of` split a type's members into a
declaration and impls only at the top level. Both now reach function bodies (`Metaprocess.in_bodies`, used by
`implemented_in_types` and the new `split_local_members`, which `types_of` and `Precheck.program` call); a local type
taking a value or holding a meta block is an error ("declared only at the top level"). Two more were needed for `with
Quiet` in that body: the substitution that renames a local type after its owner now renames a `with` clause's name too
(`Ast.Named`), and a named handler's method is looked up in the scope of the call (`bound_operation` takes `env`) rather
than the top level's, where a local type's impl methods are not.

I279. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: a continuation the transform made is contained in a call of a function still being checked (fixes
I275; review after).** The loop the transform makes (`fn loop<plain#made>`) is a local function in `unchecked`, so the
call of it inside the continuation handed to `inner`'s copy was a pending containment of `loop`'s row in the continuation's
row; that row is the copy's `E`, which `key_of_use` closes at the call, and `loop` gained `Console` only after, from the
copy's own row, which failed the pending containment. A named function calling itself after a copy call
(`fn outer(n: Int): Unit { if (n < 2) { inner(n); outer(n + 1); } }`) failed the same way through `walk_admits`, which
ties a walking instance's row to its caller's. Fix (`typecheck.ml`, `made_rows` and `is_made_row` near `admits_row`, used
by `admits_row` and `walk_admits`, filled where a `plain#made` lambda is checked): a call whose caller row is a lambda's
the transform made is contained at once (`row_within`), neither pending nor tied. What the callee gains later is its own and
reaches the function around the continuation through the callee; a made lambda takes no evidence (it performs through
what is around it), so a continuation row smaller than what it reaches costs nothing at run time. New fixtures:
`v2/loop_calling_copy` (I275's reproduction), `v2/recursion_calling_copy` (the named-recursion form). `async/async`
leaves `expected_failing` and passes.

I280. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: `tests/effects/errors/` rewritten (review after).** By I272's rules: `effect` → `trait`, `ctl` →
`@ctl fn`, `run` → `run<Unit>`, `handle E` → `handle<E>` (with its arguments, `handle<Spawn<E>>`), an arm's `resume x` →
`resume(x)` with the continuation a parameter, `final ctl stop(r)` → `@abort fn stop<T>(r: String): T` with an arm
written without the continuation; header and explanatory comments dropped (CLAUDE.md). Two beyond those:
`arm_settles_op_param`'s arm no longer resumes inside the `wake` callback, since the continuation now performs `Console`
and `register`'s parameter type is written pure, a second error the old fixture never meant (the arm still settles `T`
at `Int` with `value + 0`); `unimported_effect` binds `var n = ready();` instead of `print(ready())`, which drew a
cascading error from `str`'s instance at an unknown type (I289). Expected output changed, each the same mistake:
columns moved by `run<Unit>`/`handle<…>` (`pure_parameter` 25 → 31, `closed_row_argument` 11 → 17, `unimported_effect`
7 → 9); lines moved by dropped comments (`leaked_effect`, `purity_violated`, `unhandled`, `non_exhaustive`); the
trait vocabulary (`non_exhaustive`: "This handler for 'Two' is missing method 'b'."; `no_such_operation`: "Trait 'One'
has no method 'b'."); R30 case (`unknown_handler`: 'Nope'); `handler_widens`: an arm taking a continuation for an
unmarked operation is now "'yield' takes 0 parameter(s) in this handler, but 1 are written." (the arm's shape is the
mistake; `ctl` in an arm is gone); `duplicate_operation`: two effect traits may now share a method name (traits do), so
the mistake is reported where it bites, the bare call: "[5:23] Ambiguous operation 'get': A.get or B.get." (as
`v2/errors/ambiguous_operation`, kept because it is the `@ctl` form inside a run of one of them).

I281. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: `handle<Nope>` with no such name says "Unknown effect 'Nope'." (review after).** `check_bindings`'
`effect_named` said "'Nope' is not a trait, so it has no operations to handle." for any name not an effect; it now keeps
that message for a name that is a type (declared or built-in) and says "Unknown effect" for one that names nothing,
as the old fixture `unknown_effect` expected (its position moves to the name, `[3:10]`).

I282. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: an effect trait's error is reported once (review after).** `Typecheck.program` declares every effect
trait's operations up front (so a handler in another module can be checked first) and again at the trait's statement;
both ran the "an effect's parameter cannot stand in a row" check, so `effect_param_in_row` reported it twice. The
up-front pass now drops what it finds, and the statement reports it.

I283. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: a bare operation of a module imported whole says how to reach it (review after).**
`across_modules/lib.cx` imports `"signal"` whole and calls `stop(…)` bare; I277's `signal.stop(…)` resolves, but the
bare name was "Undefined variable 'stop'". The old loader message is back (`Loader.rewrite`'s `foreign`, filled by
`imported_whole` for a non-global import whole or under `as`): "'stop' is an operation of 'Signal', which this file
does not import by name. Write 'signal.stop', or import { Signal } from its module." It is tried only after every other
reading of the name (local, declared, imported by name, an operation in scope).

I284. **REVIEWED (2026-11-24): accepted; misplaced `discontinue` to become a compile error (I340).** **S5d batch 2: `discontinue_outside_ctl` is deleted (review after).** It tested `discontinue;` in a plain function
and in a `final ctl` arm. `discontinue(k)` is now a function of a continuation; there is no handler-only statement to
misplace, and an `@abort` arm has no continuation to pass (an unknown name, nothing particular to discontinuing).

I285. **REVIEWED (2026-11-24): changed — a permanent rule, caught in the walk again (I341).** **S5d batch 2: an unmarked operation's handler that takes control is rejected again (review after).**
`v2/errors/handler_method_takes_control` (rewritten: `trait Stop { @ctl fn stop(): Unit; }`, `handle<Stop>`) ran into a
run-time arity error: `log`'s arm performs `Stop`, so its method was made taking control while `greet` calls `log`
tail-resumptively. The arm check in `check_bindings` now fails when an unmarked operation's arm row holds a label that
takes control, with the message the fixture already expected ("A handler's 'log' that performs 'Stop', which takes
control, is not supported yet.", at the run). The doc's "an unmarked one is tail-resumptive, and returns exactly once
whatever handles it" suggests a permanent rule rather than "not supported yet"; the wording is left for review.

I286. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: a meta block run from a builtin in tail position (fixes `match moduleof(m) { … }`; review after).**
`match moduleof(helpers) { Module.File(…) => … }` as a meta block's last statement matched no case: `moduleof` wakes the
module and runs its meta block from inside the builtin, `Interp.run` ran that program's last statement in the caller's
tail position, its call was handed back through `pending`, and the outer `bounce` made it after the builtin returned,
in place of its value (`()`). `Interp.run` now starts with `tail` false and no `pending` call and restores both after.
Bound to a variable first, it already worked, which is why `helper_fn` was unaffected.

I287. **REVIEWED (2026-11-24): accepted, with the ambiguity error added (I342).** **S5d batch 2: a bare call of a generated trait's operation (review after).** `round_trip` generates `trait Log`
from a meta block and its generated `fn exercise` calls `log("hello")` in a `handle<Log>` run. The loader names an
operation after its trait (I277's machinery) but never sees a generated trait, so the bare name was undefined. In the
checker, a `Var` or a call's callee that nothing binds (`unbound`: no binding, no walk declaration) is now the operation
`Ast.operation_name owner name` when exactly one declared effect trait has that method (`bare_operation`, over
`ctx_op_owner`). Two or none fall through to the old error.

I288. **REVIEWED (2026-11-24): accepted.** **S5d batch 2: reflection and meta fixtures (review after).** `reflection/typeof_effect_{ctl, fn_vs_ctl, multi,
transitive}`: `effect` → `trait`, `ctl` → `@ctl fn`, header comments dropped; the row `typeof(f).name` prints is
unchanged, the effect being the trait's name. `meta/moduleof`: `DeclarationKind` has no `Effect` or `Handler` now (an
effect is a trait), so `helpers.cx`'s `effect Log` is a `trait Log`, `main.cx`'s two arms are gone, and `main.txt` lists
`trait Log`. `meta/syntax/printer`: the last quote is `code trait Log { fn log(…); @ctl fn ask<T>(): T; }`, printed as
such; `round_trip`: `code trait Log`, `handle<Log>`, and its `.txt`'s printed `run {` is now `run<Unit> {`, which the
printer writes for a statement run (the old expected output predates `run<R>`).

I289. **FIXED (2026-11-23, user chose "a key holding an unknown enters no instance").** `Typecheck` tells an unknown an
error left (`erroneous_ty`: a declaration whose signature failed, and what calling it returns) from one a meta block may still
declare. A use whose static params hold one is reached at no instance (`at_erroneous`, in `reached` and `value_of`), and
what it returns is made erroneous too; `processed_expr` does not report one as unsettled. `effects/errors/unimported_effect`
is back to `print(ready());` (`[5:7]`), with the same two errors. **S5d batch 2: found, not fixed (review after): `str` of a value an error left unknown cascades.** With `Async`
unimported, `fn ready(): <Async> Int` is declared as something unknown, and `print(ready())` reaches `str`'s instance
at `Generic 0` (`key_of_use` treats an unknown like a parametric type): its meta block takes the `Display` branch and the
generated `value.fmt()` fails ("Cannot call 'fmt': the receiver's type is not known here …", at `Format.cx:50`), a
second error for the one mistake. Before S5b `str` was a builtin. Fix idea: a key holding an unknown in the full check
enters no instance and answers unknown.

I290. **S5d batch 3: `tests/core` rewritten by I272's rules, and the `defer` originals deleted by I271's (review
after).** The six failing fixtures in `tests/core/defer/` (`defer_effect`, `defer_in_converted_fn`, `defer_in_run`,
`defer_multishot`, `defer_multishot_abort`, `defer_performs_effect`) each have a copy in `tests/core/defer/v2/` with the
same expected output; diffing each pair shows only the syntax rules and dropped header comments, so the originals and
their `test_bootstrap.ml` entries are deleted (`v2/` stays where it is). The rest are rewritten in place: `effect` →
`trait`, `ctl op(…): T` → `@ctl fn op(…): T`, `final ctl op(…)` that no arm resumes → `@abort fn op<T>(…): T` with its
arm written without the continuation (`builtins/conversions`, `traits/try_from`, `defer/errors/defer_cannot_fail`'s
`Stop`), `run {` → `run<Unit> {`, `handle E {` → `handle<E> {`, `resume x;` → `resume(x);` with the continuation a
parameter; `builtins/conversions`' header comment is dropped (CLAUDE.md). One expected output changed:
`control/errors/break_outside_loop.err`'s `[9:11]` → `[9:17]`, the `break` moved by `run<Unit>`.

I291. **REVIEWED (2026-11-24): accepted.** **S5d batch 3: an associated function that takes control is copied like any function (review after).** `Int.from("7")`,
with `fn from(source: String): <Fallible> Int` in an impl and `Fallible` `@abort` (or `@ctl`), failed at run time inside
the impl ("fn expects 2 argument(s) but got 1", at the operation): the checker's processed code shows a method call as a
`Call` of the function it reaches, receiver first, so the transform copies it, but only `when not associated`; an
associated call stayed a `MethodCall` on the type, which the transform never sees as taking control, so neither the call
nor the body was converted. `Typecheck` (the `Owner` branch of `Method_call`, the `lowered` table) now records an
associated call too, without a receiver. Fixes `traits/try_from` (through `T.from` in a generic function) and
`builtins/conversions` (`Int.from` directly); `stdlib/encoding/toml` turned green in the same run with no edit of its own.

I292. **REVIEWED (2026-11-24): accepted.** **S5d batch 3: `core.op` reaches an operation of an effect trait the prelude imports (review after).**
`core/modules/shadowing/own_var` declares `var write = 2;` and calls `core.write(Console.Stream.Out, …)`. `core.x` is the
prelude's `x` whatever the file shadows; at HEAD it reached a prelude trait's operations too (`brought`), which I277's
operation naming removed, so `core.write` fell back to the bare `write`, the program's `Int` ("Expected Int, got (Stream,
String) -> …"). `Loader.assemble` now puts each method of an effect trait the prelude imports by name into `core`, as
its operation (`Ast.operation_name`), whether the file shadows the trait or not. Expected output unchanged.

I293. **REVIEWED (2026-11-24): accepted; `core/syntax/doc_comment` is back to `/** … */ type Steady<R> impl EffectHandler<Feed, R> { … }` (the round-trip and its doc comments pass, output unchanged).** **S5d batch 3: attributes and a doc comment over a member of a type body (review after).** In `type Rect impl
Display { w: Int, /** Its area. */ fn area(self) … }` (or `@cheap fn …`), the field loop read the doc comment as the
next field's and then wanted a field name: only a bare `fn` or `meta` ended the fields. `Parser.type_decl` now looks past
doc comments and `@name(…)` attributes for `fn`/`meta` before reading a field (`member_ahead`). New fixture
`core/traits/in_type/documented`. Found, not fixed: a doc comment or attribute over `type X impl … { … }` itself is
"A doc comment belongs to a declaration.", since `attachable` leaves out `Type_members` and every pass reading one
matches it unwrapped; `syntax/doc_comment`'s `handler steady : Feed { ctl next() { resume 7; } }` became
`/** … */ type Steady<R>;` + `impl EffectHandler<Feed, R> for Steady<R> { /** … */ fn next(resume: (Int) -> R): R { … } }`
for that reason (the named form of a `@ctl` effect, as `v2/prompt/named_handler`). Its other expected output is unchanged.

I294. **REVIEWED (2026-11-24): changed — fixed (I343).** **S5d batch 3: `traits/errors/impl_row_inferred` stays in `known_unsound` (review after).** Rewritten (`trait Ask {
@ctl fn get(): Int; }`), it is still accepted: an impl method that writes no row is bound with a fresh row and
`conforming_method` compares written rows only, as at HEAD (b79ef7a). The tool counts it red ("accepted"); the suite's
`known_unsound` list expects exactly that. The four `core/modules/errors/*` fixtures (`imported_type_error`,
`module_var`, `module_var_assigned`, `module_var_shadowed`) were not failing: their `.err` carries a `[lib.cx 2:37]`
prefix the tool cannot read, as `effects/errors/across_modules` (left unedited, output matches).

I295. **REVIEWED (2026-11-24): accepted.** **S5d batch 3: `Source` writes `type X impl A, B { … }` back as written (fixes seven round trips; review after).**
The parser stands each trait of the header among the members as an impl with no methods (R31, I214), and `Source.type_decl`
printed those as `impl A for X {}` inside the type body, which does not parse: the suite's round trip failed for every
fixture using the form (`core/traits/in_type/in_type`, `effects/v2/handler/in_type`, `effects/v2/abort/named`,
`effects/v2/prompt/{named_handler, named_handler_resumes}`, `effects/nested_decls/handler_in_block`, and the new
`core/traits/in_type/documented`). It now writes each such member, an impl of the type with no methods, back into the
header as `impl A<…>, B`. Checked by printing each twice; the full suite run here predates this fix.

I296. **FIXED by I312 (S5d batch 5).** **S5d batch 3: found, not fixed (pre-existing): four generic-type fixtures fail when run after others in one process.**
The suite (one process) reports `meta/declof/generic_type` ("A record literal is annotated Box<Int> but its fields are
{ all: List<Int>, v: Int }"), `core/traits/generic_impl_two_methods/main`, `core/static_params/parameterized_sums/main`
and `core/types/copies` ("A record has no field 'v'"), each a verify error; each passes alone. Running the whole `cases`
list in order in one process reproduces it, with this batch's compiler changes and without them alike, so it predates
this batch: most likely a table of type copies (I220–I223) that outlives one compile. Not chased.

I297. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: `tests/stdlib` rewritten by I272's rules (review after).** `run {` → `run<Unit> {`, `handle E {` →
`handle<E> {`, `effect` → `trait`; `handle Throw { final ctl throw(e) … }` → `handle<Throw<X>> { fn throw(e) … }` with `X`
the type the body throws (`String`, `IoError`, `Failure`) and the `@abort` arm written without its continuation; an arm of an
operation I259 made unmarked (`Fs.open`, `Process.start`, `Net.connect`/`listen`/`bind`/`lookup`) loses `ctl` and returns
where it resumed; `handle Fallible` → `handle<Fallible<Int>>` (R10). Explanatory comments dropped (CLAUDE.md):
`log/logger` (two), `random/seeded` (two), `os/time` (two). Fixtures: `async/{cancel_defers, failure, fake_clock}`,
`fallible/fallible`, `format/written`, `io/{blank_line, fake_fs, fake_stdin, lines}`, `list/effectful`, `log/logger`,
`net/{cancelled_accept, fake_net, http_limits, http_wire, websocket, websocket_wire}`, `os/{args, env, fake_process, time}`,
`random/seeded`, `throw/failure`. Beyond the rules: I301, I304, I305, I306, I307.

I298. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: expected output changed by S5b's printing only (I242, I247; review after).** A value with no written
impl prints its structure with its type's name, and a failure type with a `Display` impl prints its message under `str`:
`utf8/invalid` (`Err(Utf8Error.Invalid(4))`; an uncaught `IoError` printed with `print(e)` is its message, not
`Other("…")`), `fs/directories` (`Metadata { kind: EntryKind.File, … }`, `EntryKind.Directory`, the `NotFound` message),
`io/files` and `os/process` (`caught no such file: …`), `io/using` (`Err(IoError.Other(…))`, `Err(LockError.Stuck(…))`),
`encoding/codec` (`Data.Map([Entry { … }])`, `Shape.Circle(2)`), `encoding/hex_base64` (`Err(DecodeError.Unexpected(1,
'g'))`), `format/written` (`debug(price)` of a type with only `Display`: `Money { pence: 1250 }`, I245), `net/websocket` and
`net/websocket_wire` (`Some(Message.Text(…))`). Each `.txt` taken from actual output after checking the diff is only that.

I299. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: three fixtures deleted, each covered by its `v2` copy (I271's rule; review after).** `async/scope`
(the same two programs and output lines as the middle of `v2/async/scopes`, with `attempt` for the `Throw` handler),
`os/cli` (`v2/os/cli` is it in the new syntax, same `.txt` byte for byte), `test/bench` (`v2/test/bench` likewise).

I300. **FIXED by I317 and I318 (S5d batch 5).** **S5d batch 4: `os/meta_environment` parked in `expected_failing` (review after).** Unchanged (it was already in the new
syntax): a meta block calling `write_text`, `read_text`, `remove_path`. Two things stand in the way: I212 (a meta block calling
a function that takes control: "Undefined variable 'write_text'", reproduced with `meta { var r = attempt(() => g()); }` too),
and `__meta_root` (I260) handles no `Fs`, `Dirs` or `Async`, so even once I212 is fixed a meta block has no file system,
against "meta blocks can do anything". Fix idea: emit the copies a meta program's split calls name, and give `__meta_root`
the system handlers and `block_on`, minding I260's `str` cycle.

I301. **S5d batch 4: a cancelled scope starts no queued task (fixes `async/cancel_defers`; review after).** `__scope`'s
loop launched every queued task in one pass, so in `all([() => { throw("early"); }, () => { … log("E start"); }])` the
second started after the first had cancelled the scope, against `all`'s doc ("one not yet started never starts") and the
old output. `stdlib/async/Task.cx:266` now stops launching once `s.cancelled`; the check after it drops the rest of the
queue, as it already did for tasks started later.

I302. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: a lambda made taking control carries the result its context typed (review after).** `var r: Result<P,
DecodeError> = attempt(() => decode_data(bad));` failed "The static params of 'decode_data' are not settled here: {T = ?}":
the result type reached the lambda's checked body through `use_toward`, but the transform checks the value on its own and
was handed only the parameter types (S5c's `written_type`), so the call in its body had nothing to key `T` from.
`typecheck.ml:5198` now writes the lambda's result too when its signature has none and the type is writable. Fixes
`encoding/{codec, json, round_trip}` (with I303); new fixture `effects/v2/result_settles_key`.

I303. **REVIEWED (2026-11-24): changed — local functions get distinct names per owner instance (I344, being built).** **S5d batch 4: a local function's instance is reached per instance of its owner (fixes I266; review after).** Not
a module's private helper as I266 guessed: `fn decode` with a `while` loop calling a helper that takes control, called under
two keys (once from a top-level statement, once inside `attempt`), made two copies of `decode`, each with a local
`fn loop` the transform names the same (`cx8#loop`), each calling its own instance of the helper's copy. `w.by_name` kept
one instance per name, so `pruned` followed only the second `loop`'s deps, and the first copy's helper instance was never
emitted ("Undefined variable '__digit'" at run time, spanned at `Transform.cx`'s `declare`). `by_name` is now added to, not
replaced (`metaprocess.ml:1995`), and `pruned` (`:3422`) and `reached` (`:2510`) visit every instance of a name; a
lookup still finds the newest. Fixes `encoding/{hex_base64, json, round_trip}` (`hex4`, `peek`: methods with loops) and
`Base64`/`Hex` `decode`; new fixture `effects/v2/loop_copy_two_keys`.

I304. **S5d batch 4: library parameters called in a run body get `__` names (I264; review after).** `net/websocket`'s own
`fn session` captured `WebSocket.__upgraded`'s parameter `session` called inside `run<Unit> { session(…); }` ("This takes
control of 'Async', and no handler of it is in scope here", in `WebSocket.cx`). As `block_on` does: `var __session =
session;` (`stdlib/net/WebSocket.cx:524`), and the same for `Http`'s `respond` (`Http.cx:323`) and `__closing`'s
`exchange` (`Http.cx:390`), the two other parameters called in a run body in `net/`. I264 itself stands.

I305. **DEFERRED to the Async redesign (2026-11-23).** The same shape with a user `@ctl` effect handled by a run, not the root, runs (`x`); it needs a `@ctl` effect the root handles at top level, which is only `Async`. **S5d batch 4: found, not fixed: a top-level throwing statement, then a run handling `Throw` around a function that also
takes control.** Reduced:

```cronyx
import { Throw } from "std/core/Error";
import { Async, pause } from "std/async/Task";
fn g(n: Int): <Async, Throw<String>> Int { pause(); if (n > 0) { return throw("x"); } return 1; }
g(0);
run<Unit> { g(1); } handle<Throw<String>> { fn throw(e) { print(e); } }
```

fails "This is not settled when its statement ends: its type is { throw: (String, (T) -> <Console> Unit) -> <Console> Unit
}" at the run: the `@abort` arm's `T` is left open. It needs the top level: inside a function it runs; the run first and
`g(0)` after runs; `print(g(0))` first runs (its row holds `Console`, so the two calls of `g` share one instance of its copy),
and `g(0);` or `var a = g(0);` fail. So it looks tied to a second instance of the copy made under a different continuation
row, against the root's converted body (I262). `net/http_wire`'s last part (a `get` at top level after others) hit it and
now uses `attempt` with a `match` on the error, which tests the same refusal.

I306. **RESOLVED (2026-11-24): superseded by I336 — `tcp_connect` waits, so a refused connection is thrown there.** **S5d batch 4: `net/fake_net`'s refused connection writes first (I259; review after).** `tcp_connect` to a closed port
no longer throws; the first `read`/`write` does. The run body is `tcp_connect("127.0.0.1", port).write("hi".bytes());`, so
`refused` is still printed and "connected" still is not. Output unchanged. `net/http_wire`'s `tcp_connect(…).close()` (a
connection opened and dropped) is unchanged and passes.

I307. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: `throw/failure`'s failure types implement `Display` (I239; review after).** `trait Failure: Display`,
so `impl Failure for IoError` without one is "missing the supertrait 'Display'". Each type gets `impl Display { fn fmt(self) {
return self.message(); } }`, as the library's failure types do (I247). Output unchanged.

I308. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: I265's workarounds written as lambdas (review after).** I270 fixed I265, so `v2/os/process`'s
`fn checks` + `attempt(checks)` is `attempt(() => { programs(); output(…); })` and `v2/net/loopback`'s `fn everything` +
`attempt(everything)` is `attempt(() => { tcp(); udp(); http(); faked(); })`. Both pass, output unchanged.

I309. **REVIEWED (2026-11-24): accepted, and the tool fixed: it passes `arguments_for`, writes another file's diagnostics as `[path l:c]`, and counts `expected_failing` as the suite does; it now agrees with the suite (935/935).** **S5d batch 4: two fixtures the tool counts red that the suite passes (review after).** `os/args` reads the arguments
the suite gives it (`arguments_for`: `one`, `two three`), which `scratch/tools/fixtures.py` does not pass (checked by hand
with `-- one "two three"`); `log/logger` writes one line to standard error by design, which the tool ignores, so it passes
there.

I310. **REVIEWED (2026-11-24): accepted.** **S5d batch 4: the two failing `.rt` fixtures under `tests/stdlib` (review after).** The tool reads no `.rt`, so these
showed only in the suite. `async/woken_twice` called `suspend { … }` unimported: it was an operation of `Async`, reached
through the imported trait, and is a library function since I251, so it is imported by name now; output unchanged.
`async/uncaught`'s `.rt` is `uncaught failure: LoadError.Missing("config.toml")` (I247 writes the failure through `str`, and
I242 names the type), where it was `Missing(…)`. `array/filled_arity` and `async/deadlock` already passed.

I311. **REVIEWED (2026-11-24): accepted; the probe's from_array check is back to "kept" only, since inlining is explicit (I333) and from_array is not `inline`.** **S5d batch 5: the prelude-walk probe reads a copy (review after).** `run_prelude_walk` in
`bootstrap/test/test_bootstrap.ml:1433` looked for `(type std#List#List)`, the generic declaration, which I223 replaced
in the finished program with the copies it reaches; it now looks for `(type std#List#List<Int>)`, the copy the probe's
`var xs: List<Int>` names. The other two expectations held (`from_array`'s instances are `…from_array#N`, still a match).

I312. **REVIEWED (2026-11-24): accepted.** **S5d batch 5: `Types.declarations` is reset with each check (fixes I296; review after).** The four fixtures failed
after `meta/05_order/10_box` in one process (found by running the `cases` list in order through a scratch driver, then
pairs). `Types.declarations` (each type's fields) and `Types.row_params` are keyed by name, and a copy's name is its
spelling (I220), so `10_box`'s `Box<Int> { item }` was still there when `declof/generic_type` declared `Box<Int> { v, all }`
elsewhere and `Verify` read the old fields ("A record literal is annotated Box<Int> but its fields are …"). Both are reset
in `Typecheck.Session.start` (`typecheck.ml:8731`), beside `Types.reset ()`; `Metaprocess` already reset `Types.copies`.
The whole `cases` list then passed in one process (694/694).

I313. **REVIEWED (2026-11-24): accepted.** **S5d batch 5: `effects/v2/root/root_failure` writes the handled trait's argument (R10; review after).**
`} handle<Fails> {` → `} handle<Fails<X>> {` inside `block_on<X, E>`, by I272's rule. Its `.rt` is unchanged.

I314. **REVIEWED (2026-11-24): accepted.** **S5d batch 5: `cx`'s link tells two impls of one trait apart by the trait's arguments (review after).** `Build.link`
keeps the first declaration of each name, and an impl by `impl <trait> <type> <file>` with the trait's name only
(`cx/lib/build.ml:389`), so `List.cx`'s `impl Index<Range> for List<T>` was dropped as a copy of `impl Index<Int>`. Every
package build failed once the one `__root` reached a slice (`Task.cx`'s `pending[1:]`, `Tcp.cx`, `Transform.cx`): "Expected
Int, got Range", 15 of `dune test cx`'s reds. The key now prints the trait with its arguments (`Index<Range>`).

I315. **Its found-not-fixed part FIXED (2026-11-23).** User: a local type is "coded globally but just cannot be referred to
outside of their local scope"; then, seeing that moving it out breaks `type Box { v: T }` in `wrap<T>` and a method reading a
local, "they shouldn't be moved", and chose placing the instance where its type lives. An instance whose key holds a type a
block still being walked declares (`Typecheck.home_of_key`, from `local_type_home` and `active_blocks`) is checked in that
block's scope (`check_instance ?home`) and emitted into that block (`local_instances`, collected by `walk_block`), not
the top level; it is `homed`, so `pruned` and `reached` leave it out. A value returned out of its body still reaches a
top-level instance and fails as before ("Nothing named 'L' …"). New fixture `core/traits/in_type/local_display` (plain,
a `fmt` reading a local, `Box` over `wrap`'s `T` through `shout`). **S5d batch 5: a doc comment or attribute over a type with members (review after).** `/** … */ type Quiet impl
EffectHandler<Missing, Unit> { fn absent(…) { … } }` was "A doc comment belongs to a declaration.": `Parser.attachable`
did not list `Type_members`. It does now, and `Metaprocess.attributed_first` puts the attributes on the first statement a
type with members is split into (its declaration) in `split_local_members`, `types_of` and `Precheck`; `in_bodies` leaves
an attributed type with members whole for them. A type taking a value or holding a meta block is made per argument list,
and the attributes over it are dropped (nothing reads them yet). New fixture `core/traits/in_type/documented_type` (top
level, `@cheap` over one, and one in a function body). Found, not fixed: a type in a function body implementing `Display`
is "Type 'L' has no method 'fmt'" when `str` reaches it (`fn f() { type L impl Display { fn fmt(self) … } print(L {}); }`),
with or without the doc comment.

I316. **REVIEWED (2026-11-24): accepted.** **S5d batch 5: `cx/test/` in the new syntax (review after).** By I272's rules: `library/Ops.cx`'s `effect Feed<T> { ctl
next(): T; }` is `trait Feed<T> { @ctl fn next(): T; }` and `handler empty : Feed { ctl next() { panic(…); } }` is `type
Empty<T, R> impl EffectHandler<Feed<T>, R> { fn next(k: (T) -> R): R { panic(…); } }`; `packages/documented/app/src/ink.cx`'s
`effect Missing { final ctl absent(what: String); }` is `@abort fn absent<T>(what: String): T` (R14) and `handler quiet` is
`type Quiet impl EffectHandler<Missing, Unit>`; `packages/logged/tests/logging.cx`'s run is `run<Unit> { … }
handle<Logger> { … }`. Both `expected.json` were taken from the actual index after reading the difference: R30's ids
(`builtin#Byte#to_int`, `Int#impl#std#Ops#Into<Float>`), `builtin#str` and `builtin#debug` gone (R19), `Feed` and `Missing`
are traits with an `@ctl`/`@abort` method, and each handler is a type and its impl (`Empty`, `Empty#impl`).

I317. **REVIEWED (2026-11-24): accepted.** **S5d batch 5: a meta block reads the top level as it is, not a copy of it (fixes I212; review after).**
`Typecheck.Walk.meta_env` copied the session's bindings when the block's check began, so a declaration the check itself
made at the top level was invisible to it: a run in a meta block calling a function that takes control is transformed, the
transform declares the function's copy (`cx2#g`) at the top level, and the block's check of the transformed run then found
no `cx2#g` ("Undefined variable 'g'"). The meta env is now a scope over the session's env (`parent`) that hides the
program's run-time variables (`hides`, read by `lookup` and by generalization), and `top_level` keeps it the top level for
`wd_local` and `runtime_names` (`typecheck.ml:863`, `9318`). `meta { var r = run<Int> { g() } handle<Ask> { … }; }` runs.

I318. **REVIEWED (2026-11-24): changed — every meta block may perform any system effect; one effect-driven meta root (I345).** **S5d batch 5: a meta block at the top level runs under `__meta_root_io` (fixes I300; review after).** `__meta_root`
handles the terminal, arguments, environment, clocks and entropy only, since a root reaching the I/O library reaches `str`,
whose own meta block may be what is running (I260). The new `__meta_root_io` (`stdlib/prelude.cx:151`) is `__meta_root`
around a run of `block_on` handling `Fs`, `Dirs`, `Process`, `Net` and `Stdin` as `__root` does (no `Exit`: a meta block
cannot end the compiler). The choice is by where the block is written (`meta_stmt ~io`): the entry's top level and a
module's top level take `__meta_root_io`, a block in a function, a type body or a trait body keeps `__meta_root`, so a
module's block does not change with who reaches it first. `Ast.is_root` covers it. Unparks `stdlib/os/meta_environment`
(into `cases`) and turns `cx`'s `package/reads_data` green. Cost: `meta/declof/generic_type` 248 → 252 ms, `hello`
210 → 213 (median of 5, with and without the root), within noise.

I319. **REVIEWED (2026-11-24): accepted; current figures: suite 1678/1678, cx 131/131, hello 35.7 · 0.0 · 35.8 ms (compile · run · total), known_unsound empty, expected_failing the nine compile/m*; parity to be re-run after I345.** **S5d batch 5: results and cost (review after).** `dune test --force` 1629/1629 (19 min, one process); `dune test cx`
131/131; `./scripts/cx-parity.sh` 1850/1850 (925 fixtures, both with and without the dump flags), run with a `dune` on
`PATH` that adds `--root .`, since the script's own `dune build` fails in a worktree. `hello` 213 ms compile and run (median
of 7), as at the end of S5c (I268); `effects/v2/working_example` 214. Only the deliberate entries are left: the nine
`tests/compile/m*` in `expected_failing` and `traits/errors/impl_row_inferred` in `known_unsound`.

### Fixture changes in S5d

**Batch 1: `tests/effects/` outside `errors/` and `v2/`.** Paths below are under `tests/effects/`.

- Deleted, each covered by its `v2` copy (I271), 71: `abandon_through_run`, `abort_after_resumption`, `abort_under_conversion`, `ask/ask`, `break_in_converted_loop`, `continue_in_converted_loop`, `deferred/deferred`, `delim/delim`, `discontinue/discontinue`, `discontinue/nested_after_outer`, `exception/exception`, `final/abort`, `final/errors/resumes`, `final/in_loop`, `flip/flip`, `fn_values/closure_in_arm`, `fn_values/in_list`, `fn_values/in_tuple`, `fn_values/multishot_closure`, `fn_values/named_as_value`, `fn_values/nested_spawn`, `fn_values/spawn`, `fn_values/suspending_closure`, `fn_values/through_index`, `fn_values/wider_row`, `fn_values/wider_row_nested`, `generic/generic`, `generic/nested`, `generic/shared_param`, `generic/written_row`, `handler/arm_reaches_outer`, `handler/handler`, `inner_run_suspends_outward`, `log/log`, `logic/multi_guard`, `logic/simple_guard`, `match/resume_in_match`, `match/return_in_match`, `match/suspend_in_scrutinee`, `methods/methods`, `multi_handle/differing_arms`, `multi_handle/multi_handle`, `multishot_sequel`, `nested_aborts`, `nested_return`, `recover/recover`, `resume_through_run`, `return_in_converted_loop`, `return_in_inner_ctl_run`, `return_in_inner_run`, `return_out_of_run`, `return_past_arm_defer`, `return_past_outer_ctl_run`, `run_value/arm_answers`, `run_value/statements_then_value`, `run_value/two_in_one_expr`, `run_value/unit_body`, `run_value/value`, `stream/stream`, `suspend_in_condition`, `suspend_in_field_assign`, `suspend_in_logical`, `suspend_in_logical_nested`, `suspend_in_logical_while`, `suspend_in_record`, `suspend_in_resume`, `suspend_in_tuple_destructure`, `suspend_in_variant`, `suspend_in_while_condition`, `two_runs_one_expr`, `methods/suspending_receiver`.
- Deleted, testing a construct the new model removed (I274): `run_value/return_clause`.
- Rewritten in place, passing (I272): `async/interleaved`, `generic/{nested_in_generic, row_argument_generalized,
  row_in_list_literal, row_in_type_argument, row_through_index}`, `generic/errors/{one_type, two_instantiations,
  unconstrained_at_call, written_row_arity, written_row_mismatch}`, `handled_in_import/main` (I277),
  `handler/errors/arm_without_outer` (I273), `named_import/main`, `nested_control/{op_only_in_match, run_in_if,
  run_in_match, run_in_while}`, `nested_decls/handler_in_block` (I278), `qualified_op/main` (I277), `rows/*` (9).
- Rewritten and parked in `expected_failing`: `async/async` (I275).
- Expected output changed: `generic/errors/two_instantiations.err` (a dropped comment moves the line, I272),
  `handler/errors/arm_without_outer.err` (`[2:44]` → `[2:1]`, I273).
- Left as they were, already passing: `callee_checked_across_statement`, `callee_checked_after_statement`,
  `discontinue/signal`, `forward_call_keeps_own_row`, `methods/v2/suspending_receiver`, `nested_decls/variadic_in_block`.
- Turned green with no edit of its own: `stdlib/async/both` (I276).

`scratch/tools/fixtures.py`: 786/989 → 816/917 overall; `tests/effects` outside `errors/` and `v2/` 6/108 → 35/36
(the one red is `async/async`, parked); `tests/effects/v2` 133/134 unchanged. No fixture went from passing to failing.

**Batch 2: `tests/effects/errors/`, `tests/reflection/typeof_effect_*`, `tests/meta/{moduleof, syntax}`, and I275.**

- Fixed and unparked: `effects/async/async` (I279), out of `expected_failing` and into the list beside `async/interleaved`.
- New: `effects/v2/loop_calling_copy`, `effects/v2/recursion_calling_copy` (I279).
- Rewritten in place, passing (I280): `effects/errors/{across_modules/main (and lib, signal; I283), arm_settles_op_param,
  arm_settles_op_row, arm_ties_op_param, closed_row_argument, duplicate_operation, effect_param_in_row (I282),
  handler_widens, leaked_effect, no_such_operation, non_exhaustive, pure_parameter, purity_violated, row_argument_kind,
  unhandled, unimported_effect (I289), unknown_effect (I281), unknown_handler}`; `effects/v2/errors/handler_method_takes_control`
  (I285); `reflection/typeof_effect_{ctl, fn_vs_ctl, multi, transitive}` (I288); `meta/moduleof/{main, helpers}` (I286,
  I288); `meta/syntax/{printer, round_trip}` (I287, I288).
- Deleted, its construct gone (I284): `effects/errors/discontinue_outside_ctl`.
- Expected output changed: `effects/errors/{closed_row_argument, duplicate_operation, handler_widens, leaked_effect,
  no_such_operation, non_exhaustive, pure_parameter, purity_violated, unhandled, unimported_effect, unknown_effect,
  unknown_handler}.err` (I280, I281); `meta/moduleof/main.txt` (`trait Log`), `meta/syntax/printer.txt` (the trait form),
  `meta/syntax/round_trip.txt` (`run<Unit> {`) (I288).
- Turned green with no edit of its own: `meta/moduleof/helper_fn` (its `helpers.cx` parses again).

`scratch/tools/fixtures.py`: 816/917 → 845/918 overall; `tests/effects/errors` 0/19 → 18/18 (the tool counts 17: it
cannot read `across_modules`'s `[lib.cx 4:12]` prefix, which the suite's comparison writes and the output matches);
`tests/reflection` 18/22 → 22/22; `tests/meta` 161/165 → 165/165; `tests/effects/v2` 133/134 → 136/136. No fixture went
from passing to failing. Every fixture is named by a list in `test_bootstrap.ml` (checked by script); the full
`dune test` did not finish inside ten minutes here and was not read.

**Batch 3: the failing fixtures under `tests/core/`.** Paths below are under `tests/core/`.

- Deleted, each covered by its `defer/v2` copy (I290), 6: `defer/{defer_effect, defer_in_converted_fn, defer_in_run,
  defer_multishot, defer_multishot_abort, defer_performs_effect}`.
- Rewritten in place, passing (I290): `builtins/conversions` (I291), `control/errors/break_outside_loop`,
  `defer/errors/defer_cannot_fail`, `enums/match_expr_effect`, `modules/local_binders/launch` (its `main` turned green),
  `print/captured`, `records/effectful_field`, `syntax/doc_comment` (I293), `traits/dyn/{effect, effect_resumes,
  meets_bound}`, `traits/errors/{impl_row_narrower, impl_row_wider}`, `traits/try_from/main` (I291).
- Rewritten, still in `known_unsound` as before: `traits/errors/impl_row_inferred` (I294).
- Turned green by a compiler fix with no edit of its own: `modules/shadowing/own_var` (I292), `stdlib/encoding/toml` (I291).
- New: `traits/in_type/documented` (I293).
- Left as they were, passing in the suite (the tool cannot read their `[lib.cx …]` prefix, I294):
  `modules/errors/{imported_type_error, module_var, module_var_assigned, module_var_shadowed}/main`.
- Expected output changed: `control/errors/break_outside_loop.err` (`[9:11]` → `[9:17]`, `run<Unit>`, I290).
- Round trips fixed by I295: `traits/in_type/in_type`, `effects/v2/handler/in_type`, `effects/v2/abort/named`,
  `effects/v2/prompt/{named_handler, named_handler_resumes}`, `effects/nested_decls/handler_in_block`.

`scratch/tools/fixtures.py`: 845/918 → 862/913 overall; `tests/core` 333/359 → 349/354 (the five red are I294's: four the
tool cannot read, one `known_unsound`); `tests/core/defer/v2` 6/6 unchanged; `tests/effects/v2` 136/136, `tests/meta`
165/165, `tests/stdlib/v2` 13/13 unchanged. No fixture went from passing to failing. The full suite ran to the end before
I295 (1552/1629); every red in it beyond the tool's list is old syntax, a `.rt` this batch did not touch, I296, the
prelude-walk probe, or a round trip I295 then fixed. Every fixture is named by a list in `test_bootstrap.ml` (checked by
script).

**Batch 4: the failing fixtures under `tests/stdlib/` outside `v2/`.** Paths below are under `tests/stdlib/`.

- Rewritten in place, passing (I297): `async/{cancel_defers (I301), failure, fake_clock}`, `fallible/fallible`,
  `format/written`, `io/{blank_line, fake_fs, fake_stdin, lines}`, `list/effectful`, `log/logger`, `net/{cancelled_accept,
  fake_net (I306), http_limits, http_wire (I305), websocket (I304), websocket_wire}`, `os/{args, env, fake_process, time}`,
  `random/seeded`, `throw/failure` (I307).
- Turned green by a compiler fix with no edit of the `.cx`: `encoding/{codec, json, round_trip}` (I302, I303),
  `encoding/hex_base64` (I303).
- Expected output only, the `.cx` unchanged (I298): `utf8/invalid`, `fs/directories`, `io/{files, using}`, `os/process`.
- Expected output changed (I298): those five, and `encoding/{codec, hex_base64}`, `format/written`,
  `net/{websocket, websocket_wire}`.
- Deleted, each covered by its `v2` copy (I299): `async/scope`, `os/cli`, `test/bench`.
- Parked in `expected_failing`: `os/meta_environment` (I300).
- Edited in `v2/`: `os/process`, `net/loopback` (I308), output unchanged.
- New: `effects/v2/loop_copy_two_keys` (I303), `effects/v2/result_settles_key` (I302).
- Stdlib fixes: `async/Task.cx` (I301), `net/WebSocket.cx`, `net/Http.cx` (I304).
- `.rt` (I310): `async/woken_twice` rewritten (imports `suspend`), `async/uncaught.rt` changed (I242, I247).

`scratch/tools/fixtures.py`: 862/913 → 895/912 overall; `tests/stdlib` outside `v2/` 66/102 → 97/99 (the two red are
`os/args`, which the suite passes (I309), and `os/meta_environment`, parked); `tests/stdlib/v2` 13/13 unchanged;
`tests/effects/v2` 136/136 → 138/138 (the two new); `tests/meta` 165/165 unchanged. No fixture went from passing to failing.
Every fixture under `tests/stdlib` is named by a list in `test_bootstrap.ml` (checked by script). The full suite (`dune
test --force`, round trips included) ran to the end: 1620/1626; the six red are the prelude-walk probe,
`effects/v2/root/root_failure` (a `.rt` in the old `handle<Fails>` form, outside this batch), and I296's four.

**Batch 5: the last reds.**

- Rewritten, passing: `effects/v2/root/root_failure` (I313); `cx/test/library/Ops.cx`,
  `cx/test/packages/documented/app/src/ink.cx`, `cx/test/packages/logged/tests/logging.cx` (I316).
- Expected output taken from actual (I316): `cx/test/library/expected.json`, `cx/test/packages/documented/app/expected.json`.
- New: `core/traits/in_type/documented_type` (I315).
- Unparked, out of `expected_failing` and into `cases`: `stdlib/os/meta_environment` (I317, I318).
- Turned green by a compiler fix with no edit of their own: `meta/declof/generic_type`,
  `core/traits/generic_impl_two_methods/main`, `core/static_params/parameterized_sums/main`, `core/types/copies` in the suite
  (I312); 15 `cx` packages (I314); `cx`'s `package/reads_data` (I317, I318).
- Probe changed: the prelude walk (I311).

`dune test --force` 1620/1626 → 1629/1629; `dune test cx` 116/131 → 131/131; `./scripts/cx-parity.sh` 1850/1850 (first run
since the migration began). No fixture went from passing to failing.

### Fixture changes in S5c

New, under `tests/stdlib/v2/`: `async/scopes` (`all`, `scope` with a task starting another, a failing task cancelling its
siblings and the body, `race`, `both`, `interleaved`), `async/waiting` (`sleep`, `timeout` both ways with a `defer`, a
`Promise`, a `Channel` iterated with `values()`, `select`), `iter/yield` (`iterator`, `close`, a `for` left by `break` and by
`return`, `map`/`take`/`collect`, `Yield` handled directly), `io/files` (files on disk under a scratch directory, `lines`,
`using`, `Buffer`, and `Fs` handled by a test), `os/process` (`output`, `spawn` with a pipe, programs inside `all`, `Exit`
handled by a test with its `defer` run, `Args` and `Env` handled), `os/cli` (the old `os/cli` in the new syntax, same output),
`net/loopback` (TCP echo, a refused connection, UDP, an HTTP server and client, `Net` handled by a test), `test/bench`
(`bench` under a test's `Time`), `encoding/digests` (SHA-256, SHA-1, Hex and Base64 encoding). No old fixture was edited.
No fixture went from passing to failing: `scratch/tools/fixtures.py` 743/978 → 783/987 (the nine new ones, and 31 old
fixtures that now pass unchanged: `async/{basic, channel, nested, nested_cancel, race, select, skipped_call, sleep, timeout,
timeout_defers, top_level_scope, trait_object_call}`, `buffer/in_memory`, `crypto/{sha1, sha256}`,
`effects/{for_iterator, iterator, iterator_suspends}`, `iter/{adapters, lazy_lines}`, `net/{echo, http, ping, silent_peer}`,
`os/{exit, pipe_wait}`, `core/defer/defer_suspends_on_unwind`, `core/modules/entry_var_shadowed/main`,
`effects/callee_checked_{across,after}_statement`, `types/inference/local_named_like_method`).

### Fixture changes in I270

New: `effects/v2/fn_values/calls_named_twice` (the I265 reproduction: a function value calling a named function that
takes control twice, under a run handling `Wait`) and `core/top_level/two_throwing_statements` (two top-level statements
that each call a function performing `Throw` and `Async`, so the top level takes control). `scratch/tools/fixtures.py`
783/987 → 786/989: the two new ones and `stdlib/io/lines_to_end`. No fixture went from passing to failing.

### Fixture changes in S5b

`stdlib/format/debug_fallback` (new): `str` of a type with only a `Debug` impl uses it (I245); with both, `str` takes `Display` and `debug` takes `Debug`.

One `__root` (I231): the A5-Q1 annotations came out of `core/lambdas/basics` (`var add = (a, b) => a + b`),
`core/operators/not_index` (`var visited = []`), `core/ufcs/with_lambda` and `stdlib/list/list` (`var nums = […]`,
`words`, `a`, `b` unannotated); `core/variadic/packs/erased` and `stdlib/os/pipe_wait` build their lists with `push`
after an empty literal; `core/collections/narrowing` moves its two lists from a function back to the top level.
`types/expected/written_key.txt` now ends `(Int) -> <Console> Int` (I234). New: `core/top_level/one_root`,
`core/top_level/uncaught` (`.rt`), `core/top_level/errors/each_statement`, `errors/before_initializer` (built
before this step), and `core/top_level/across_meta` (I232). `stdlib/encoding/generic` and `meta/traits/effect_handler`
throw a `DecodeError` and a `Failure` at the top level, which now need `Display` (I239); both pass unchanged.

Static `Display` (I235–I240): a fixture that printed a type with no impl was changed so it no longer does, since the
print was not what it tests: `core/traits/errors/impl_method_arity` prints `.radius`,
`impl_missing_trait_args` and `impl_trait_arg_arity` print `.n`, `core/records/errors/unknown_field_type` matches
its `S` rather than printing it, `meta/code/errors/quoting_at_runtime` prints `make().span` (expected diagnostics
unchanged in all five). `stdlib/throw/rethrow` and `stdlib/v2/rethrow` derive `Display` for their `IoError` and
`ParseError`, so they print `io: IoError.NotFound("missing.toml")` and `parse: ParseError.BadLine(1)` (was
`NotFound(…)`, `BadLine(1)`: the derived form names the type). New: `stdlib/format/static` (a hand impl inside a list,
an `Option` and a tuple, a generic type's impl at two keys, a derived record over a hand impl, a derived enum, an
anonymous record, `unit`, a generic function bounded by `Display`), `stdlib/format/errors/no_impl` (I236),
`core/top_level/errors/uncaught_without_display` (I239). No fixture went from passing to failing:
`scratch/tools/fixtures.py` 737/972 → 741/976 (the four new ones), the bootstrap suite run directly 1366/1745 →
1372/1751 with no case lost, `dune test cx` 116/131 (its four reds are old syntax: `ink.cx`, `fs/File.cx`, `cx docs std`).

Every type prints (I242–I250): the `derive Display`/`derive Debug` lines came out of `stdlib/encoding/generic`,
`stdlib/format/static`, `stdlib/throw/rethrow` and `stdlib/v2/rethrow`, with output unchanged. `stdlib/format/derived`
tested the derivers; it is now `stdlib/format/structure` with its derive lines removed and the same output, extended with
a recursive sum, a variant with named fields through `debug`, a generic type over an `Option` and a `String`, a function
value and an anonymous record holding one. `stdlib/format/errors/no_impl` is deleted (both of its prints now succeed,
and `structure` covers them). `core/top_level/errors/uncaught_without_display` became the runtime case
`core/top_level/uncaught_structure` (`uncaught failure: Bad.Oops`, I247). New: `meta/implements/implements`,
`meta/implements/own_name`, `meta/implements/errors/at_runtime` (I243). No fixture went from passing to failing:
`scratch/tools/fixtures.py` 741/976 → 742/977; the bootstrap suite run directly, against the starting tree built in a
copy, differs only by the renamed, deleted and new cases (1376/1755); `dune test cx` 116/131, as before.

### Fixture changes in S5a

Every fixture's source follows R30, red old-syntax fixtures included: 781 `.cx` under `tests/` (3,318 built-in
names, 285 uses of the lowercase user types and `Async`), 73 under `stdlib/` (1,791 and 138), 32 under `cx/test`
(78). Expected output: 97 files taken from the actual output plus `ambiguous_receiver`'s new order (I228), 24 red
fixtures' files edited by hand, the two
`cx docs` JSON files (I230). No fixture changed pass/fail state: `scratch/tools/fixtures.py` gives the same passing
set before and after (734/969); the bootstrap suite run directly (`test_bootstrap.exe`, round trips and probes
included) the same list, 1361/1740; and `dune test cx` the same list (102/131).

### Fixture changes in B1-B3

No existing fixture changed. `02_gen/promote` prints the same, because `twice` returns `int`.

Flipped: `meta/splice/meta_expr`, out of `expected_failing` and into `cases`.

New, passing:
- B1: `meta/splice/gen_code_expr`, `gen_code_stmts`, `gen_code_decl`
- B2: `meta/splice/meta_expr_value_param` (`fn doubled<n: int>` returning `meta { gen code(n * 2);
  }` at 3 and 5), `meta_expr_expected` (the `Set<int>` above), `meta_expr_nested` (a meta
  expression inside a meta block)
- B3: `meta/splice/gen_call_value` (a top-level `Expr` function, a static call `literal<7>()`, a
  meta block's local function, `List<Stmt>` at statement level, and `gen print(1)` as written)

New error fixtures:
- B2: `meta/splice/errors/expr_none`, `expr_two`, `expr_stmt`
- B3: `meta/splice/errors/sig_in_body` (a `MethodSig` generated at the top level)

### Fixture changes in B4-B6

Flipped: `reflection/errors/not_a_value` is now `reflection/typeof_value` (`.txt`: `int`), moved
from `error_cases` to `cases`. No other existing fixture changed. Every `tests/reflection/*` and
`tests/meta/03_derive/*` fixture prints the same.

New, passing:
- B4: `meta/traits/meta_in_trait` (a written and a generated method), `per_instance` (three impls,
  two instances, each block's `print` once), `open_param` (`Getter<_>` shared by `Picker<R>` and
  `Holder<Q>`; `Convert<int, _>` with one bound and one open slot)
- B5: `meta/declof/fn`, `keyed` (`id<int>`, implicit `first<string>`, value `times<3>`), `trait`,
  `processed` (the declof'd function's block prints once, and its output shows in the `Decl`),
  `pruned` (also in the `pruned` probe: `(fn lonely ` absent), `static_param` (a type and a trait
  through `T`), `qualified/main` (`declof(util.twice)`), `dynamic` (callees of a quoted body by
  `Name`)
- B6: `meta/traits/effect_handler` (I90), `meta/params/typeof_param` (the doc's `helper`, at `int`
  and `string`), `meta/params/typeof_compound` (`typeof(p.second)`, `typeof(xs[0])`,
  `typeof(p).shape` in meta blocks)

New error fixtures:
- B4: `meta/traits/errors/stmt_in_trait`, `missing_generated`, `duplicate_generated`
- B5: `meta/declof/errors/unkeyed`, `self`, `not_a_decl`, `outside_meta`, `dynamic_unknown`

### Fixture changes in C1-C3

No existing fixture changed.

New, in `expected_failing` (C1, 03 S0), each with the step it waits on: `effects/v2/working_example`,
`resume_returns_block_value`, `ctl_and_unmarked_in_one_effect`, `named_handler_generic` (`Picker<R>`
under a statement run and a valued run), `throw_fresh_result` (C5), and `with_binds_several`,
`handler_captures_by_reference` (C4). All of them now check, and stop at CPS (I102).

New, passing:
- C2: `core/functions/tail_call_deep` (I94), `effects/discontinue/signal` (I95)
- C3: `effects/v2/effect_handler_shape` (`declof(EffectHandler<Effect, string>)` and
  `EffectHandler<Fail, int>` from the stdlib)

New error fixtures (written in C1, passing from C3): `effects/v2/errors/handled_twice`,
`with_binds_nothing`, `ambiguous_operation`.

### Fixture changes in C4

No existing fixture changed, and the originals of the migrated ones are untouched.

Flipped, out of `expected_failing` and into `cases`: `effects/v2/with_binds_several`,
`effects/v2/handler_captures_by_reference`.

New, passing, migrated with the originals' `.txt` copied unchanged: `effects/v2/log`,
`effects/v2/handler`, `effects/v2/methods`. Changes in migration: `effect` → `trait`; `handle log` →
`handle<log>`; `handler basic_log_handler : log { … }` + `with basic_log_handler` → `type
BasicLogHandler {}` + `impl log for BasicLogHandler { … }` + `with BasicLogHandler`. The narrating
comments are dropped (CLAUDE.md: a fixture is read beside its `.txt`).

New, passing: `effects/v2/bound_through_the_key`, which covers a recursive callee at the bound key,
a run inside a function at `{Log = …}` whose `Ask` method logs through the function's `hv#Log`,
a valued `run<int>`, and an inline method relaying to an outer `with Outer`. Also
`effects/v2/generic_unmarked`, a generic `Emit<T>` settled from the body and written as
`Emit<string>`.

New error fixtures: `effects/v2/errors/valued_handler_function_value` (I107),
`effects/v2/errors/handler_method_takes_control` (I106).

### Fixture changes in C5a

No existing fixture changed, and no original of a migrated one was touched.

Flipped, out of `expected_failing` and into `cases`: `effects/v2/working_example`,
`resume_returns_block_value`, `ctl_and_unmarked_in_one_effect`, `throw_fresh_result`.
`effects/v2/named_handler_generic` stays, now waiting on "C5b: a named handler for an effect that
takes control" (I110, I112).

New, passing, migrated with the originals' `.txt` copied unchanged: `effects/v2/ask`, `delim`,
`flip`, `recover`, `nested_return`, `two_runs_one_expr`, `suspend_in_record`,
`suspend_in_field_assign`, `run_value/two_in_one_expr`, `run_value/value`, `run_value/unit_body`,
`run_value/arm_answers`, `multi_handle/multi_handle`, `generic/shared_param`. Changes in migration:
`effect` → `trait`, `ctl op(…)` → `@ctl fn op(…)`, `handle E { ctl op(a) { … } }` →
`handle<E> { fn op(a, resume) { … } }`, `resume v;` → `resume(v);`. Where the old arm fell off its
end after resuming in a valued run, the new arm returns what the resumption returned
(`return resume(21);`, `var r = resume(5); …; return r;`). The return clause is folded into the run's
tail (R15): `run<int> { each(); 0 }`, `run<int> { note(…); note(…); 7 }`.

New, passing: `effects/v2/straight_line` (a copy calling a copy, an unmarked operation inside a copy,
a split in a `var`'s initializer, under `+` and in the middle argument of a call, with the earlier
arguments evaluated first, and a multi-shot handler). Also `meta/processed/types` (R1, R2),
`meta/processed/operation` (R5) and `meta/processed/fresh_declare` (R4, `declare`).

New error fixtures: `effects/v2/errors/split_in_loop`, `effects/v2/errors/return_out_of_run` (I122).

Not migrated, needing C5b or C6: `exception` (a generic callee and a split in an `if`), `stream`,
`generic/*` that take control, `multi_handle/differing_arms`, `logic/*`, `match/*`,
`suspend_in_variant` (match scrutinee), `suspend_in_tuple_destructure`, `suspend_in_resume` (nested
runs), and `run_value/statements_then_value` (a match expression).

### Fixture changes in C5b

No existing fixture's `.txt` or `.err` changed, and no original of a migrated one was touched.

Flipped, out of `expected_failing` and into `cases`: `effects/v2/named_handler_generic` (I129).

Changed: `effects/v2/errors/split_in_loop` now loops over a string, the one loop the transform
still refuses (`[6:5] A loop over this sequence …`), since a loop over a list now splits.

New, passing, migrated with the originals' `.txt` copied unchanged: `effects/v2/match/resume_in_match`,
`match/return_in_match`, `match/suspend_in_scrutinee`, `logic/simple_guard`, `logic/multi_guard`,
`return_in_converted_loop`, `suspend_in_logical`, `suspend_in_logical_nested`,
`suspend_in_logical_while`, `suspend_in_while_condition`, `suspend_in_variant`,
`suspend_in_condition`, `suspend_in_tuple_destructure`, `exception/exception`, `generic/generic`,
`generic/written_row`, `run_value/statements_then_value`, `multi_handle/differing_arms`,
`stream/stream`. The changes are C5a's rules, plus: `resume;` → `resume(());`; the return clause
`return (nothing) { -1 }` folded into the tail (`run<int> { range(100, 103); -1 }`); `handler h : E
{ … }` + `with h` → `type H {}` + `impl EffectHandler<E, unit> for H { … }` + `with H` (I129). The
original's comment in `generic/written_row` is dropped.

New, in `expected_failing`, migrated the same way: `effects/v2/generic/nested` ("C6: nested runs"),
`break_in_converted_loop` and `continue_in_converted_loop` ("C6: a defer in a loop split at a call
that takes control"; each has one function with a `defer` in the loop).

New, passing:
- `effects/v2/loop_exits`: `break` out of a `match`, out of an inner loop and out of a plain
  loop inside a split one, `continue` in a C-style `for`, in nested loops and in a valued run, and
  a `return` from a `while (true)`. The first run's output agrees with the old syntax under the old
  backend.
- `effects/v2/recursive_copy`: a copy calling itself (`countdown`, and `sum` with a split under
  `+`) and two copies calling each other (`is_even`/`is_odd`).
- `effects/v2/expression_splits`: a split in `+=`, in a `match` expression's scrutinee and in an
  arm, in a record field after one evaluated first, in a list literal between two, and on the right
  of `&&` and `||`.
- `effects/v2/named_handler_in_copy`: `with Picker` reaching `log` and `choose` from inside a copy.
- `effects/v2/two_controlling_effects`: two inline handlers taking control in one run, and an
  inline one with a `with T` whose operation is performed only inside a copy's continuation.

New error fixtures: `effects/v2/errors/split_in_function_value`, `effects/v2/errors/defer_before_split`
(I125).

Not migrated, needing C6: `suspend_in_resume` and `generic/nested` (nested runs),
`break_in_converted_loop`/`continue_in_converted_loop` (in `expected_failing`, a `defer` in the
loop), and `fn_values/*`, `deferred/*`, `discontinue/*`, `return_*` crossing a run (out of scope).

### Fixture changes in C6

No existing fixture's `.txt` or `.err` changed, and no original of a migrated one was touched.

Flipped, out of `expected_failing` and into `cases`: `effects/v2/generic/nested`,
`break_in_converted_loop`, `continue_in_converted_loop`.

Error fixtures that now check and run, moved out of `errors/` into `cases` with a `.txt`:
`v2/errors/split_in_function_value` → `v2/split_in_function_value` (`1`), `v2/errors/defer_before_split` →
`v2/defer_before_split` (`left`, `1`), `v2/errors/return_out_of_run` → `v2/return_after_resume` (`1`),
`v2/errors/valued_handler_function_value` → `v2/valued_handler_function_value` (`hello ada`, I137).

New, passing, migrated with the originals' `.txt` copied unchanged: `effects/v2/resume_through_run`,
`inner_run_suspends_outward`, `handler/arm_reaches_outer`, `multishot_sequel`, `abandon_through_run`,
`abort_under_conversion`, `nested_aborts`, `suspend_in_resume`, `deferred/deferred`, `discontinue/discontinue`,
`final/abort`, `final/in_loop`, `return_out_of_run`, `return_in_inner_ctl_run`, `return_past_arm_defer`,
`return_past_outer_ctl_run`, `return_in_inner_run`, `fn_values/closure_in_arm`, `in_list`, `in_tuple`,
`multishot_closure`, `named_as_value`, `suspending_closure`, `through_index`, `wider_row`, `wider_row_nested`;
and `core/defer/v2/defer_effect`, `defer_in_converted_fn`, `defer_in_run`, `defer_multishot`,
`defer_multishot_abort`, `defer_performs_effect`. The rules are C5b's, plus: `final ctl f(…)` → `@ctl fn
f<T>(…): T` with the arm `fn f(…, resume)` falling off its end (discontinue insertion does the rest);
`discontinue;` → `discontinue(resume);`. Changed beyond the rules, as U2 asks: a stored continuation writes its
row (`deferred`, `discontinue`, `closure_in_arm`, `suspending_closure`: `List<() -> <Console> unit>`), and
`fn_values/through_index` declares `tasks` inside the run, since a function value stored where no run reaches is
C7's.

New, in `expected_failing`: `effects/v2/abort_after_resumption`, rewritten per U2 (the stored continuations
are drained inside the `Error` run, and `pending` is declared there, `List<() -> <Error, Console> unit>`; the
`.txt` is unchanged), waiting on "C7: a continuation a copy makes, stored by an inner arm, that an outer run
splits" (I144).

New, passing: `effects/v2/generic/nested_relay` (an inner `Yield<int>` run whose arm yields a string to an outer
`Yield<string>` run), `v2/method_takes_control` (a method that takes control, and one calling it twice),
`v2/continuations_differ` (two calls of one copy whose continuations perform different effects, I142),
`v2/nested_deep` (five runs nested, a multi-shot arm in the middle).

New error fixture: `effects/v2/final/errors/resumes` ("This handler settles 'T' at int, but 'throw' is handled
once for every type its call sites use.", the new form of `final/errors/resumes`, 03 §3.2).

Not migrated, waiting on C7: `discontinue/nested_after_outer`, `fn_values/spawn`, `fn_values/nested_spawn`
(function values from outside the run, and `std/core/Error`'s `Throw`), `core/defer/defer_handles_failure`,
`defer_suspends_on_unwind`, `errors/defer_cannot_fail` (the stdlib's `Throw`/`attempt`). `discontinue/signal`
uses no effect syntax and needs no copy.

Counted with a heuristic (an old `effect` declaration, `ctl`, `handle E` or `resume` in the file): 182 fixture
files outside `v2/` use the old syntax; 132 of them are under `tests/effects` and `tests/core/defer`, and 72
of those have a passing `v2` copy.

### Fixture changes in C6b

No existing fixture's `.txt` or `.err` changed.

Flipped, out of `expected_failing` and into `cases`: `effects/v2/abort_after_resumption` (I154, I155), with the U2
rewrite C6 made (it drains inside its `Error` run).

New, passing: `effects/v2/generic/nested_relay_fn`, `nested_relay` with the inner run's yields made by a function
`produce(): <Yield<int>> unit` (the copy of a copy, I154); its `.txt` is `nested_relay`'s. And
`stdlib/effects/transform_imported`, which imports `effect_transform` from `std/core/Transform` and prints
`checked`, so Precheck checks the whole transform in one fixture (I149).

### Fixture changes in C7a

No existing fixture's `.txt` or `.err` changed, and no original was touched.

New, passing, with the originals' `.txt` copied unchanged: `effects/v2/fn_values/spawn` (rows written honestly:
`List<() -> <Console> unit>`), `effects/v2/fn_values/nested_spawn` (the child started through a function that
forwards to `run_one`, not through an operation, I159), `effects/v2/discontinue/nested_after_outer` (with a local
`trait Throw<X> { @ctl fn throw<T>(err: X): T; }` and the stored continuations typed `<Console>`).

New, passing, stdlib-shaped, in `tests/stdlib/v2/` with test-local modules `Error.cx` (`Throw`, `Result`,
`attempt`, `rethrow`), `Yield.cx` (`Yield`, `iterator`, returning a local `Pulled<T, E>`, I163) and `Task.cx`
(`async` with `pause`, `block_on`): `attempt` and `rethrow` (the `stdlib/throw/` fixtures with the import changed,
`.txt` unchanged), `iterator` (`stdlib/effects/iterator`, `.txt` unchanged), and `block_on` (new).

New, passing: `effects/v2/fn_values/captures_assigned` (captures read and assigned inside `attempt` in a loop),
`effects/v2/root/root_shaped` and the runtime case `effects/v2/root/root_failure` (`.rt`: "uncaught failure:
boom"), the `__root` prototype (I162).

New error fixtures: `effects/v2/errors/stored_task`, `effects/v2/errors/handling_function_as_value` (I159).

New, in `expected_failing`, waiting on "dynamic capture for stored tasks", each with the `.txt` it should
produce: `effects/v2/stored_tasks/all` (a list of tasks run one by one), `race` (a lambda capturing a task from a
list), `scope_start` (`start` handed to the body), `through_operation` (`nested_spawn` as written).

Not migrated: `core/defer/defer_handles_failure`, `defer_suspends_on_unwind`, `errors/defer_cannot_fail` (they
use the stdlib's `Throw`/`attempt` and `async`, which C7b migrates).

### Questions found while building A5

A5-Q1 (plan gap). **DECIDED by the user 2026-11-22: one `__root` for the whole top level (I162): vars stay globals, initializers assigned in place inside the one main, so the top level is one function body and the annotations come out; per-statement Throw catchers only where a statement throws. To build. Built in S5b (I231–I234).** A top-level `var`'s initializer runs under `__root`, so the var's type is
`__root`'s `T` and part of its key. Strict R6 then rejects `var xs = []; xs.push(1);` at the top
level, and any top-level var a later statement settles (`var m = HashMap.new();`, `var add = (a,
b) => a + b;`). Plan 01 Q2 calls `var xs = []` "fine under both", which misses that the statement
is a call. Taken for now: those fixtures are annotated (list below). Options: keep it; make a
var's type not part of any key (for instance `under_root` declares the var and assigns it inside
the root's lambda); or a U4-style rule for `__root`'s `T`.

A5-Q2. **CONFIRMED by the user 2026-11-22.** Rows as keys are closed (T5), so a function written `<E>` that also performs an effect of
its own has to write it: `fn each<E>(…): <Console, E> unit`. The old check let `E` absorb the
function's own effects. Koka agrees with the new reading. Four fixtures and `stdlib/test/Test.cx`,
`stdlib/test/Bench.cx` now write `Console`.

A5-Q3. **ANSWERED 2026-11-22, see I25.** I25's treatment of U4 (the use keeps the defaulted copy open) is a refinement of R4 that
the design does not state.

### Fixture changes in A5

Removed (R24, never terminate under the design): `types/inference/polymorphic_recursion`,
`types/inference/errors/unspecializable_recursion`,
`types/inference/errors/unspecializable_names_the_caller`.

T9 probe (recursion through a `Walking` instance with no written return), return type written:
`core/functions/fib` (`: int`), `meta/04_functions/dyn_fib` (`: int`),
`meta/05_order/04_recursion` (`: int`), `meta/05_order/05_mutual_recursion` (`: unit` on both),
`effects/fn_values/nested_spawn` (`run_one: unit`), and `stdlib/encoding/Toml.cx`
`__write_table` (`: unit`). None of these is about inference. No fixture about that inference hit
the rule.

A generic function as a value with nothing to settle it: `core/functions/shadowed_generic` and
`core/builtins/print_value` annotate the `var`; `reflection/typeof_fn` writes its parameters'
types (the fixture is about reflecting a function value); `reflection/typeof_pack` drops its two
lines about generic functions; `reflection/typeof_generic` is now the error fixture
`reflection/errors/generic_value`.

Rows closed in the key (A5-Q2): `effects/generic/nested_in_generic`,
`effects/generic/row_argument_generalized`, `effects/discontinue/nested_after_outer` write
`<Console, E>`; `effects/async/interleaved` types its queue `List<() -> <E> unit>`.

Top-level vars settled by a later statement (A5-Q1): annotated in `core/lambdas/basics`,
`core/operators/not_index`, `stdlib/iterable/iterable`, `stdlib/hashmap/hashmap`,
`stdlib/hashset/hashset`, `stdlib/list/list`, `core/ufcs/with_lambda`; the list written inline in
`core/variadic/packs/erased` and `stdlib/os/pipe_wait`; `core/collections/narrowing` moves its two
literals into a function, which keeps testing narrowing inside one body.

A parameter nothing settles outside effect labels: `stdlib/throw/attempt` annotates `fine`;
`stdlib/throw/failure` writes `return fail(…)`; `core/variadic/generic` writes
`count<int>("none")`; `core/static_params/type_params/main` types `x: T` and `list: Array<T>`;
`effects/generic/unconstrained_at_call` is now the error fixture
`effects/generic/errors/unconstrained_at_call`.

Source order: `effects/callee_checked_after_statement` and `callee_checked_across_statement`
declare their vars before the first call (a function is checked where it is first reached, and
read them before they were declared).

Diagnostics: `core/traits/errors/unknown_method` (I33),
`core/traits/errors/generic_impl_no_operator` (the error is now in the instance, at
`self.a + self.b`), `types/gadt/errors/leaked_constraint` (the instance also catches `p + 1` at a
string; the comment's "accepted and fails while running" is dropped),
`effects/errors/row_argument_kind` (its two errors are no longer listed twice).

Moved: `meta/03_derive/errors/gen_in_comptime` from `expected_failing` into the error cases (it
passes). `core/functions/errors/generic_captures` is now `core/functions/generic_captures_bounded`,
a passing fixture: a local generic function may capture (§2.6).

### Fixture changes in A6

New, all passing: `types/expected/var_annotation`, `return_type`, `argument`, `field`,
`open_argument`, `function_value`, `written_key` (`var h = helper<int>;`), `lambda` (a lambda's
parameters from a `var` annotation, a return type and a field), `trait_payload` (a `List<Shape>`
literal and an `Option<Shape>` payload, coerced through the expected type), and the error fixture
`types/expected/errors/unsettled_value` (`var f = helper;`). All but `written_key`, `lambda` and
`trait_payload` already passed on A5, through I28 and the `Collection` kind variable.

Extended: `meta/syntax/round_trip` prints `var named = pick<int>;`. No existing fixture changed.

### Fixture changes in A7

New: `meta/05_order/29_operator_reached`. An operator's impl method is reached when the operator is
checked, so its meta block runs before that of a function called later in the same body. Here
`meta add` now prints before `meta report`. A6 printed them the other way round, since Resolve
reached `add` at the root statement's end (checked against an A6 build). New:
`types/expected/associated_argument` (I56). No existing fixture changed. No fixture in the suite
has an operator impl holding a meta block, so none moved.

### Fixture changes in A10/A8

No existing fixture changed in either step. Meta blocks that fail to check now fail in place, but no
`.err` file moved.

New in A10: `meta/01_basic/display_in_meta` (a meta block prints a value through its `Display`
impl, I58), `meta/05_order/errors/meta_calls_walking` (I58),
`meta/05_order/errors/top_level_var_in_meta` (I61), `meta/code/errors/quoting_at_runtime` (I59).

New in A8: `types/expected/errors/unsettled_lambda` and `types/expected/errors/unsettled_variant`
(I68).

### Fixture changes in A9

No existing fixture changed. New, both in `cases` and in the `pruned` probe (I72):
`meta/prune/meta_only_function` (`doubled`, called only from a meta block, is absent; `shared`,
called from both, is present) and `meta/prune/unreferenced_impl` (`Area for Circle` and `Display for
Circle` are absent; `Square`'s are present, and `print(s)` still prints through its `Display`).

### Fixture changes in S3

`tests/effects/v2/effect_handler_shape.txt`: the instance prints each `@ctl` method generic in its row (I201),
`@ctl fn choose<Rho>(options: Array<int>, resume: (int) -> <Rho> string): <Rho> string;`. New:
`v2/continuation_row` (a stored continuation typed `(int) -> <Console> string`, called after its run),
`v2/errors/arm_body_error`, `v2/errors/arm_resumes_wrong_type`, `v2/errors/arm_unmarked_error` (I203),
`v2/defaulted/never_throws`, `v2/defaulted/joins_later_throw` (I206).

### Fixture changes in S4

No expected output (`.txt`, `.err`) changed. Sources changed, to the step's syntax:
- `run<R>` written on every run (I209): 117 files under `tests/effects/v2`, `tests/stdlib/v2`,
  `tests/core/defer/v2`, `tests/core/traits/dyn/v2/effect_resumes`, `tests/effects/methods/v2/suspending_receiver`,
  `tests/meta/syntax/round_trip`; stdlib `prelude.cx`, `core/Error.cx`, `random/Random.cx`, `io/Console.cx` (a doc
  comment).
- A generic effect's handler writes its arguments (I210): `v2/discontinue/nested_after_outer` (`Throw<string>`),
  `v2/fn_values/captures_assigned` and `v2/root/root_shaped` (`Fails<X>`), `v2/generic/generic`, `nested`,
  `nested_relay`, `nested_relay_fn`, `written_row` (`Yield<int>`, `Yield<string>`), `v2/generic/shared_param`
  (`Store<int>`), `v2/generic_unmarked` (`Emit<int>`), `stdlib/v2/Error.cx` and `Task.cx` (`Throw<X>`),
  `stdlib/v2/Yield.cx` (`Yield<T>`); stdlib `prelude.cx` and `core/Error.cx` (`Throw<X>`).
- `@abort` (I215): stdlib `core/Error.cx` (`Throw.throw`), `core/Assert.cx` (`Assertion.failed`); the arms of
  `__root` and `attempt` drop `resume`.
- `meta/traits/effect_handler.cx`: `fail<unit>(str(E) + " is not a trait, so it has no operations to handle")`
  (I212, I213).

New: `v2/errors/run_without_answer`, `v2/errors/handle_unwritten_arguments`, `types/expected/discarded_return_param`,
`meta/params/type_param_value`, `core/traits/in_type/in_type`, `core/traits/in_type/errors/declared_twice`,
`v2/handler/in_type`, `v2/abort/abort`, `v2/abort/shape`, `v2/abort/named`, `v2/prompt/return_crossing`; and
`v2/prompt/named_handler` in `expected_failing` (I217).

### Fixture changes in S4b

No expected output (`.txt`, `.err`) changed, and no existing fixture's source. `v2/prompt/named_handler` left
`expected_failing` (I219). New: `v2/prompt/named_handler_resumes` (I219), `meta/declof/generic_type` (`declof` of a
plain generic type at arguments and through a key, `typeof(Box<string>)`, written `Box<int> { … }`; I221),
`core/types/copies` (two keys of one type with a `Display` impl, a nested copy, a generic function over `Box<T>`, a
generic enum matched at two keys, a type with a row parameter; I223), `core/types/errors/written_arguments` (I221).
`stdlib/encoding/generic` now passes (I222). Stdlib: `core/Transform.cx` (I219), `compiler/Ast.cx` (`named_method`).

## Plan-order changes made during implementation
- **P1 (after A7):** A10 (meta blocks processed by the walk) now runs before A8 (deleting Type_mono) and A9 (Prune). Type_mono, `resolve.ml`, `bound_calls`, `coercions` and `dp_instance` are now reached only by `Compile.program` for meta programs, so they can't be deleted until meta programs are on the walk (I52).

## Reviewer notes (orchestrator)
- **N1 (C5b): RESOLVED 2026-11-22 (always loaded, I150, I121).** `Transform.cx` is loaded only when a unit's tokens contain `handle <` or `with`. That is a load-time optimization keyed on token sniffing. It doesn't run library code on a condition, but it is close to the no-hooks line, and it is fragile: artifacts, and runs created by `gen`. Review: always load it and make loading cheap, or key it on the parsed AST.
- **N2 (C5a, I112): ANSWERED 2026-11-22, see I112 (handed form deleted).** an `@ctl` op called with one extra argument is "handed its continuation" and bound by the core. User code can write `ask(k)` by hand. Review whether that should be allowed.

I320. **DECIDED (user, 2026-11-23), REVISED the same day: `defer` stays through metaprocessing and a Zig-style pass
after Prune lowers what is left (the user, worried a closure per `defer` adds an allocation to `alloc` + `defer free`).
The library transform keeps handling `defer` in converted code; the pass copies each remaining deferred statement in front
of every exit of its scope, so the interpreter has no `defer`. The text below, up to "Finalization", is the first version
it replaces.** `defer` does not exist
after metaprocessing: it becomes the cleanup written before every way the scope is left (falling off the end, `return`
with its value computed first, `break`, `continue`), and the lowering marks the cleanups it inserts. The CPS transform
(`stdlib/core/Transform.cx`) emits the discontinue check (`__is_discontinued`) only in frames holding a marked cleanup, so
a continuation with nothing to clean up is plain (`hv#Throw.throw("negative", (x) => { return join(()); })`).
Finalization: an `@abort` handler always finalizes, and the cleanups run before its arm (exception order); a `@ctl`
resumed several times runs a scope's cleanup once per resumption that leaves it (`defer_multishot`, unchanged); a `@ctl`
that does not resume never finalizes by itself, since its arm may keep the continuation to resume later (`Async`), as
Koka's plain `ctl` (only `final ctl` finalizes). `defer_multishot_abort`'s `fail` becomes `@abort`, and its output takes
the cleanup-before-arm order. Accepted cost: a `@ctl` continuation dropped and never resumed runs no `defer`s. Placement (user): "compiler handles defer, but
library handles cps. Our rule is the compiler doesn't know CPS is a thing." The compiler lowers `defer D;` to `var
cleanup#n = __cleanup(() => { D });` (a prelude identity function, the marker) and a call `cleanup#n()` before each exit;
the transform recognises `__cleanup` and emits the discontinue check only in frames a marked cleanup encloses.

I320 (implementation, 2026-11-23, superseding the `__cleanup` placement above). The closure/marker lowering was dropped
before landing. As built: `defer` stays a statement through metaprocessing, and `Transform.cx` keeps its own `cleanups`
for the code it splits. A new pass, `bootstrap/lib/defers.ml`, runs on the walk's resolved output in `Compile.run`, just
before `Interp.run` (so every program and every meta block): each `Defer` still present is in code the transform never
split, so it is copied in front of each exit of its block, latest first (fall-through unless the block already leaves;
`return e` as `var returned#n = e; <copies>; return returned#n;`; `break`/`continue` run the copies declared inside the
loop they leave; lambda and `fn` bodies are their own scopes; a deferred statement's own body is lowered with nothing
around it). The interpreter's native defer is gone; `Defer` stays in the resolved type (it is the shared `stmts` group, so
removing it is a refactor of every stage) and the interpreter fails on one. A panic or runtime error no longer runs
`defer`s (Zig's behaviour). Discontinue check: a continuation with no cleanup in scope whose whole body is `return k(x)`
(the frame's own `k`) or, at the run's top, `return x`, gets none: the signal reaches `k` as it is. Every other
continuation keeps one, cleanups or not, and a frame without cleanups only forwards: `if (__is_discontinued(x)) { return
k(__discontinued()); }`. A fully plain form is unsound: in `checked` (`if (n < 0) { throw(..); } return n;`) the
continuation is `return join(())`, and resumed with the signal without a check it would run `join`, which calls `k(n)`,
so the caller carries on as if `checked` had returned `n`. Removing those checks needs a second continuation per frame
(an unwinder passed alongside `k`, extended only by frames with cleanups), a calling-convention change to the whole
transform. `@abort`: inline arms get `discontinue(k)` prepended by `__tx_dropping` (it reads the new `Operation.aborts`);
named handlers get it from the compiler's `Metaprocess.aborting_impls`, which already encoded discontinuation and now puts
it first — a standing exception to "the compiler knows no CPS", left in place since a named impl's methods never pass
through the transform. `@ctl` arms that never resume are no longer discontinued. Output changes: `defer_multishot_abort`
(cleanup before "caught second") and `effects/v2/abort/abort` (cleanups before "failed: empty").
I320 (cont.), **DECIDED (user, 2026-11-23): no discontinue signal; double-barrelled CPS.** The transform passes a second
continuation `u` ("the rest was abandoned, unwind") next to `k`. A converted frame without `defer` forwards `u`; one with
`defer D` hands on `() => { D; u(); }` inside D's scope. An `@abort` handler calls `u()` then runs its arm and never `k`;
a `@ctl` handler only has `k`, so never finalizes; a `run` supplies a `u` doing nothing. `u` travels with `k` when a
continuation is stored (Async). `__discontinued` / `__is_discontinued` are removed. All in `stdlib/core/Transform.cx`.
I320 (as built, 2026-11-23, superseding the discontinue checks and the `@abort` placement in the implementation note
above; `defers.ml` stands). `u` is CPS-shaped: `u(then, d)` runs the cleanups between the call and the handler, innermost
first, each able to take control, then `then(())`. A run supplies `(then, d) => { return then(()); }`; a scope holding a
`defer` that a split follows binds `var u2 = (then, d) => { D; return u(then, d); }` (D split like any code) and hands
it on; every other frame forwards the `u` it was given, so code with nothing to clean up asks nothing (`checked`:
`hv#Throw.throw("negative", u)`, its continuation `(x) => { return join(()); }`). `d` counts runs: a bound run's or a
prompt's own `u` carries on at `d == 0` and otherwise hands `d - 1` to the one around it, and the outer handlers its code
is handed are wrapped (`__tx_wrapped`, `__tx_past_run`) to add one, so a handler's own unwinding stops at its run and an
outer one's goes past it. `@abort` methods are handed only `u` (no `k`) and become `return u((x) => { arm }, 0)`; a
`@ctl` method gets `u` after `resume`, and its `discontinue(resume)` (also inside a closure the arm makes, as `Task.park`
and `Yield.abandon` do) becomes `return u((x) => { rest of the block }, 0)`; nothing else unwinds a `@ctl` continuation.
Inside a prompt the split rewrites a top-level `discontinue(resume)` and an `@abort` method's body runs as the `then`.
The return-crossing flag is a value variable initialised with `__unanswered()` plus a `Bool` set beside it
(`remember`ed by name); `__unanswered()` (a new builtin, `() -> 'a`, Unit at run time) also stands for the run's answer
once a `return` has left through it, which nothing reads. `__discontinued`/`__is_discontinued` and the interpreter's
`discontinue` are gone (`discontinue` keeps only its type, so arms check before the transform rewrites them; reached at
run time it fails). Compiler: `aborting_impls`/`aborting_arms` deleted and `@abort` arms and named-handler records take
only the operation's parameters; what still knows the calling convention, kept minimal: `Typecheck.unwinder` (the `u`
type) used by `handler_type`, `cps_lambda`, `cps_call`, `cps_shape` (`+2`), dyn calls (`+2`), `wrapped`, the
handler-record fitting in `run_value`/`bound_value` (a method one parameter longer or shorter than its effect's
signature), `named_method_call`, and `Verify` (`+2`). Moving those into the library needs the transform to declare the
shapes it makes, which the checker would read; not done. Accepted cost: `discontinue` written outside a handler's own
method body (passing `resume` to another function first) is a compile error. Output changes: `defer_multishot_abort`,
`effects/v2/abort/abort`, `effects/v2/abort/named` (cleanups before the arm); `defer_effect`, `defer_in_run` (their
exception-style `@ctl` became `@abort`, then the same order); `effects/discontinue/signal` rewritten through a handler.

I321. **REVIEWED (2026-11-24): changed — the query becomes public `effects_of` (no underscore), beside `typeof` and `implements`, working inside and outside meta blocks (I347).** **2026-11-23 (user asked): the root handles only the system effects the top level performs.** `__root<E>(main: () -> <E>
Unit)` is an instance at the top level's row; its meta block reads it with a new meta-only query `__effects_of(E)` (the
labels a row parameter of the instance stands for, checked as `implements` is) and keeps, from one quoted `run … handle …`
of every system handler, only the clauses whose effect is performed, plus `Time` when it schedules. It calls `block_on`
only when the top level performs `Async`. `hello` 224 → 110 ms, `effects/v2/working_example` 211 → 135 (median of 7); a
hand-written Console-only root is 106, so the meta block costs about 4. `effects/errors/unimported_effect` loses its
second error ("Unhandled effect 'Async'", the first one's consequence). `__meta_root_io` is unchanged.

I322. **REVIEWED (2026-11-24): changed — `@abort` operations are handed their call site so an uncaught failure is reported at the `throw` (I348).** **2026-11-23: a failure in a call made from tail position is reported at that call.** `tests/stdlib/async/uncaught`
reported "uncaught failure: …" at `Transform.cx:2346` (the `declare` making a copy), and `core/top_level/uncaught` at
`prelude.cx:228` (`__throwing`'s `run`), not at `panic(…)` in `__throwing`'s `throw` arm. Cause: the interpreter's tail
calls. A call in tail position is handed back as `pending`, and `bounce` applied it with the span of the call that
started the chain rather than its own, so a builtin failing there (`panic`) took that outer span; under the transform
the outermost call is generated, and a generated span is read as the meta call that made it. Fix: `pending_call` keeps
the call's span (`p_span`) and `bounce` applies it with that. Also, in `Transform.cx`, the call `__tx_split_call`
rewrites a call that takes control to keeps that call's span (`__tx_call_at`), so what fails at it points at the
program. The location is now the prelude's `panic` (`prelude.cx:231:23`), not the user's `throw`: a handler has no way
to know where the operation it answers was performed, and reporting the `throw` site would need the runtime to carry
it into the arm, which nothing does. **Review after:** whether an uncaught failure should name the `throw` site, which
would need a call-site value handed to the arm. `.rt` fixtures pin a location only when they start with `[`, and only
in the entry's own file (the prelude's path differs by machine), so `stdlib/async/uncaught.rt` stays message-only. New:
`core/top_level/uncaught_located` (a catcher of the user's own panicking in its arm, pinned at `[9:23]`; before, `[7:9]`,
the `main()` call that began the chain).

I323. **REVIEWED (2026-11-24): accepted.** **2026-11-23: a named function passed where its type would take control defaults the effect as a lambda does.**
`caught<X, T, E>(f: () -> <Throw<X>, E> T)` at `caught(pure)`, `pure` performing nothing, failed in Verify ("A lambda of
3 parameter(s) is annotated () -> Int") where `caught(() => pure())` printed `Some(7)`. `X` stands only in a label, so
the key defaults it to `type#absent` and the label is none (I25, I206): that is the intended rule, so the call is not
"unsettled", and the fix makes the defaulted instance work. Cause: a function named as a value whose use type takes
control is eta-expanded (`eta`), but `named` was built first, and `value_of` entered `pure`'s instance at the use type,
with `Throw<X>` in its row; the eta's own call then reached that instance, so the lambda's body performed `Throw`, was
made taking its handler and continuation, and `pure` was copied taking them, while the key then dropped the label and
`caught#0`'s `f` was `() -> Int`. Fix: the non-eta branch builds `named` only when it is the result, so the eta is
checked as the written lambda is. New: `effects/v2/defaulted/named_function` (`caught(pure)` is `Some(7)`,
`caught(failing)` with `failing` throwing a `String` is `None`).

I325. **2026-11-23 (user: "Remove precheck"): Precheck is gone; only what the walk reaches is checked.** It cost about 75 ms of
every compile (`hello` 110 → 36 ms, `working_example` 134 → 62, `stdlib/v2/block_on` 149 → 74), since it checked every
loaded file, the prelude's reach of the library included. `bootstrap/lib/precheck.ml` and `Typecheck.check`/`partial` are
deleted; `Pipeline.whole` runs the walk alone. Consequences, each fixture handled:
- An error in code nothing reaches is not reported (Zig's rule): `meta/07_precheck` is renamed `meta/07_unreached`, and
  its `errors/unreached_value_param` became `unreached_not_checked` (it runs, printing `never called`).
- `.err` fixtures whose broken function nothing called now call it at the end (positions unchanged): `defer_cannot_fail`,
  `purity_violated`, `effects/generic/errors/one_type`, `types/errors/return_mismatch`, `gadt/errors/impossible_arm`,
  `arm_settles_op_row`, `arm_ties_op_param`, `break_outside_loop`, `continue_outside_loop`.
- Generic code is checked at its key, so three errors that only a generic check of unreached code could give no longer
  exist: `traits/errors/ambiguous_receiver` (`x.len()` on an unknown `x`), `tuples/errors/unknown_arity`,
  `gadt/errors/match_expr_unannotated` — deleted. At a key, `arm_settles_op_row`/`arm_ties_op_param` say "settles 'E' at
  <>" / "settles 'T' at Int", `leaked_constraint` reports only its first error (its stale header comment dropped), and
  `defer_cannot_fail`'s generic `callback` reports the concrete `Throw<String>`, not "an effect row its caller decides".
- `declared_twice` reports only the real error (its "missing method" was the first one's consequence).
- Found: a defer error in a function the transform copied was reported once per copy; identical walk errors are now
  reported once (`type_errors` in metaprocess.ml).
- Found: the walk skipped the impossible-arm check at every key, so `'Nil' cannot be a Vec<Succ<Zero>, Int>` was only ever
  Precheck's; it now runs where the instance has no type parameters (no other key could reach the arm).
- Found, not fixed (review after): `effects/v2/errors/handler_method_takes_control` — a plain handler's method calling an
  outer run's `@ctl` operation was rejected only outside the walk; in the walk the call goes straight to the outer
  handler's value, so nothing in the method's row shows it, and it crashes at run time ("fn expects 4 argument(s)").
  Moved to `known_unsound`.

I326. **2026-11-23 (internal-docs/Inlining.md): an evidence-passed effect's handler is part of the key, and its
operations are called directly.** Only effects whose operations are all plain `fn`s; `@ctl`/`@abort` stay the
library transform's, untouched. Measured, median of 7–9 (`--time`, compile · run · total, ms): `hello` 34.6 · 0.0 ·
34.7 → 34.4 · 0.0 · 34.4; `working_example` 59.7 · 0.0 · 59.8 → 60.2 · 0.0 · 60.3 (both within noise: they barely
run). A loop of 200 000 calls of a function performing a captured `Log` plus 20 000 `print`s: run 106.6 → 67.5.
`print("hello, world")` is now `fn print#0(value: String) { __write_out((str#0(value) + "\n")); }`, called
`print#0("Hello, World!")`, no `ev#h`.
- **Key.** `Key.Handler id`, one entry per label, named `<run's handler>@<run number>` (the run number because a run
  the transform rebuilt re-binds the same handler names, and what was made under the first check is not emitted).
  Computed in `reached` only (calls; a function named as a value, a vtable slot and an operator entry are never keyed)
  from `known_handlers !effect_bindings`: each label bound by a run, up to the function's own frame. A call first
  keys every handler around it; once an instance at those types finishes, the labels it answered are recorded
  (`answered_labels`, its row plus what it answered through its key) and later calls keep only those, with
  `handler_alias` mapping the narrow key to the instance (also consulted by `Metaprocess.made`, so `declof` and the
  transform find it). (review after: the first call at a new type key carries the whole set; with the meta root's six
  handlers that is long, cosmetic, cost not measured.)
- **Inside a keyed instance** the frames are the key's bindings before its own frame (`bd_key` marks them). An
  operation answered there still joins the instance's row (so `purity_violated` and "handles nothing" keep working,
  and callers pass evidence as the type says).
- **No `ev#h`.** A processed function whose body never reads `ev#h` (and takes no control) drops the parameter;
  calls to one processed earlier pass none (`without_evidence`, the callee's annotation loses its row). A call to one
  not yet processed still passes it; the interpreter drops the extra argument. A recursive function keeps its
  evidence (its own call passes it). (review after)
- **The root.** The top level's own frame is `root_frame` (`* = root` in a key, for every evidence label nothing
  nearer binds); instances reached from it inherit it. The program root's `main()` call records the bindings around it
  (`root_bindings`); when processing an operation under the root frame, a label whose root handler was lifted calls the
  lifted function; anything else (the root's `Exit`, which reads `ended`; a scheduled program, `block_on(main)`) reads
  `ev#h` as before. A handler nearer than the root that no key can name (one in a run the transform takes apart, e.g.
  with `@abort Exit`) drops the root from the key, or it would answer for that run (`stdlib/v2/os/cli` caught it).
- **Direct and inlined.** An inline handler (not in a transformed run) whose every method reads only its parameters
  and top-level names (`names_used` against `runtime_names`), reads no other run's handler value, and checks pure and
  closed, has each method made a top-level function `handler#N#method` from its checked lambda (`Walk_ops.lift`, a
  Done instance) — not checked again; the run's value holds those functions. Calls go straight to it, in the run body
  as well. A call in statement or `return` position is inlined when, after folding a `match` on a parameter given an
  empty variant, the body is one expression with no lambda and each non-trivial argument is used once (at most one):
  `handler#7#write(Out, text)` → `__write_out(text)`.
- **Direct with its environment.** An inline handler reading a run's locals stays a value; an instance keyed by it is
  emitted at the head of that run's block (`run_instances`, placed after the handler values) and calls
  `hv#N.write(...)` there, no evidence. A local function's instances are never keyed by such a handler (they are
  emitted where declared). A named handler (`with T`) calls `T`'s impl method directly; its key home is wherever
  what its `bd_outer` binds lives.
- **Kept as evidence:** function values (lambdas, parameters; `twice(f)` is keyed for its own `print`, and keeps
  `ev#h` for `f`), `dyn` calls, handlers passed as values (`hv#Label` parameters), every handler of a run the
  transform takes apart (its body is checked again as what the transform made), and every call inside a function a
  transform made (`in_plain`; it sees its caller's runs but is emitted at the top level). (review after: the
  transform's runs are where most stdlib runs are; keying them needs the rebuilt run to carry the keyed instances.)
- **Not done from the plan:** "a named handler with fields, called with the value as `self`" — `with` names a type
  only, so no handler has a value with fields to pass; nothing to build. Calls inside `__throwing`'s lambda (a
  top-level statement that throws) are a function value's, so evidence.
- **Recursion.** A call of a declaration with an instance still being checked keys only handlers that instance's key
  already holds, so a run inside a recursive function does not make a new instance per level.
- **Fixtures changed:** `effects/v2/meta_once` prints `report is processed` twice (two handlers, two instances, as the
  plan says); `meta/declof/processed` runs `made`'s meta block twice (the meta block's instance and the top level's,
  keyed by the root). (review after: both were written when one instance was the rule.) `meta/prune/unreferenced_impl`
  matches `(fn Square#Area#area` without the trailing space: an instance whose first call carried handlers it turned
  out not to answer keeps the `#0` name that key gave it (an unkeyed instance must stay the bare name, which other
  code names directly). (review after)
- **New:** `effects/v2/direct/captured_and_root` (one function under a captured `Console` and under the root, two
  instances), `reads_run_local` (a handler pushing to a function's local, instance emitted in the run),
  `named_handler` (two `with` types, two instances), `function_value_kept` (`twice`'s own `print` direct, `f`'s by
  evidence, under a captured handler and the root).

I327. **2026-11-23 (follow-up to I326): the root's dead record, transformed runs, and exact evidence.** Timings
(`--time`, median of 9, ms, compile · run · total; before is I326's starting point, measured again alongside):
`hello` 35.6 · 0.0 · 35.6 → 35.1 · 0.0 · 35.1; `working_example` 61.4 · 0.0 · 61.5 → 61.1 · 0.0 · 61.2; the
200 000-call `Log` loop 35.1 · 108.8 · 144.5 → 36.0 · 70.0 · 106.1. `hello` processes to `fmt#0`, `str#0`,
`print#0` (`__write_out(...)`), `fn __root#0(main) { main(); }` and `__root#0(() => { print#0("Hello, World!"); })`.
- **Unread run leftovers.** `processed_block` drops a `hv#N` handler value (a record of lambdas and names) and an
  `answer#N` with no initializer when nothing else in the block reads it, then splices a block left declaring
  nothing into its parent (`without_unread`). This covers every run whose operations all went direct, not only the
  root's.
- **The root's evidence.** `Metaprocess.finish_root` drains everything but the program root's instance, processes
  the top level, then the root. Processing the top level's lambda (the argument of a `__root` instance) tells whether
  its body reads `ev#h`; if not, it takes none (its signature gets the transform's plain marker, so Verify counts no
  evidence and its type still says what it performs) and the root's `main()` call (found by its span and name,
  recorded at check) passes none, with the callee's annotation losing its row. (review after: the plain marker
  stands for "takes no evidence" here, not "a transform made this".)
- **`Exit` bookkeeping.** `__root` (stdlib/prelude.cx) generates `var ended` and the closing `match ended` only when
  the top level performs `Exit`, from the same meta block that picks the clauses.
- **Transformed runs go direct.** The cause of I326's stale instances: a run handling an `@ctl`/`@abort` effect is
  read as written (the transform asks the checker about it) and then checked again as what the transform made;
  instances keyed under the first read were made against the run as written, which a call in the rebuilt run then
  reached. Fix: such a run's handlers are registered for keys only after the transform returns, so the as-written
  read makes the evidence instances it always made, and only the rebuilt run keys (the `@run` in a key's handler name
  still separates a rebuilt `Bound` run's instances from an earlier block). Its inline handlers are lifted as any
  other's. `effects/v2/direct/beside_abort` (a `Log` handler beside an `@abort Throw` in one run) calls the lifted,
  inlined `List#push#0(lines, …)` from the CPS copy of `work`. Tried and dropped: one key per handler across both
  reads with the instance put in every block binding it, which shared an as-written instance into the rebuilt code
  and broke `stdlib/async/failure` and `cancel_defers` ("fn expects 7 argument(s) but got 3"). Cost: a function
  reached in a transformed run is made twice, once as written (evidence, as before I326) and once keyed —
  `meta_once` now prints `report is processed` three times. (review after)
- **Kept as before:** calls inside a function a transform made with the plain marker (`in_plain`) are not keyed —
  it sees its caller's runs but is emitted at the top level, and its operations already go straight to those runs'
  values.
- **Exact evidence.** `Typecheck.exact_stmt` runs over the finished program (`Metaprocess`, after pruning): a call
  to a function known to take no evidence that still hands it one (processed before its callee) loses the argument
  and the callee's annotation its row. A recursive function still keeps its evidence when its own call passes it
  (the decision is made from its body, which holds that call). (review after)
- **New fixture:** `effects/v2/direct/beside_abort`. Changed: `effects/v2/meta_once.txt`.

I328. **2026-11-23 (user: "code should only ever be processed once unless it's monomorphizing over different
types"): processed code passes through.** Timings (`scratch/tools/timing.py`, median of 7, ms, compile · run · total):
`hello` 35.5 · 0.0 · 35.6 → 35.4 · 0.0 · 35.5; `working_example` 61.0 · 0.0 · 61.1 → 63.0 · 0.0 · 63.0 (the cost is the
notes below; recording them eagerly into a hash table cost 4 ms, so they are lists loaded only when shown).
- **The node.** `` `Pre_checked of int `` in `Ast.expr_kind` and `Ast.stmt_kind` (new `Ast.pre_checked`), an id into
  `Typecheck.passed`: the checked code (`Passed_expr` or `Passed_stmts`), the row it performs, its view (the source it
  was checked from: one expression, one statement, or a statement list), the names it bound (with their schemes), the
  names it reached (replayed through `refer`), for a whole function body its return type, and its notes (each
  expression's type and each run's lowering, recorded while checking, loaded into `noted_types`/`noted_runs` the first
  time the view is shown). Checking one returns the stored node, contains its row in the context's, binds what it
  bound; nothing inside runs or is checked again. Source walkers (`assigned_names`, `names_used`, `gather`) read the
  view. In the library tree it is `ExprKind.Processed(Int)` / `StmtKind.Processed(Int)`, which `Syntax` reads back
  as the node; `std/compiler/Printer` prints `processed#N`.
- **Shown to a meta block.** Under `processed(...)`, `Syntax` shows a pass-through as its view, with the noted types,
  and shows a meta block (statement or expression) as what it generated (`meta_stmts`/`meta_exprs`, recorded at
  every meta block the checker runs), so what a transform makes of the code never runs a meta block again. A node
  handed out for a pass-through (`Syntax.handed`, by identity, with its kind as handed out) and handed back as the
  same record with the same kind is read as the pass-through. The library decides by returning the node it was
  given: `__tx_block` hands back a statement with no split that `__tx_untouched` says the plain path would not
  change (no exit, `defer`, declaration, own lambda, bound run or unsettled `Let` type), instead of rebuilding it.
- **Where they are made.** (1) `root_block`: every top-level statement's final check is a pass-through with its own
  row (the root already checks each with its own); a throwing one is wrapped as `__throwing(() => { <its
  pass-through> })` and only the wrapper is checked; the globals are bound before, since the transform's output for
  the catcher's body is checked inside it. (2) `root_rewritten` is the list of those pass-throughs, so the root's
  conversion re-checks only the statements the transform splits. (3) `typed_block` (what `processed` checks) asks
  `walk_block` to keep the asked block's statements (`kept_block`: a run's body, or a lambda value's body): each is
  checked with a row of its own contained in the block's (`kept_stmt`), and becomes a pass-through when the read
  was whole (no `final_read` gate fired: lambda conversion, eta, controlled slot, lifting, all skipped while
  recording) and it `stands_alone` (no exit or function declaration, meta blocks judged by what they generated). A
  block declaring types or functions keeps nothing. (4) A function value the checker converts is shown to
  `effect_lambda` as its first check (one `Stmts` pass-through of the whole body, with its return type), so the
  transform's read checks nothing again.
- **Handler keys through it.** A transformed run's handlers are registered for keys before the transform reads the
  run (I327 registered them after): what the read checks and the transform keeps is the code emitted, so it is keyed
  by those handlers, and a call the transform rewrites reaches the same key. The I327 failures (`stdlib/async/failure`,
  `cancel_defers`) do not recur. (review after)
- **Copies.** `processed_fn` reads the instance `declof_call` just showed (`declof_shown`, by name) under the frames its
  key names (`key_frames`, shared with instance checking), so the read reaches the instances already made instead of
  evidence ones. (review after: matched by name between the two calls, which the transform always makes together.)
- **The catcher.** A CPS lambda checked as an argument of `__root`/`__throwing` at the top level (`at_root`) takes the
  root's frame, as the statement did where it was first checked: a function called in a throwing top-level
  statement is one instance, keyed by the root, not that plus an evidence one (`show` in `processed_once`).
- **The memo is gone.** `top_generated`/`same_block` removed from metaprocess.ml.
- **Still processed twice (review after):**
  - A statement the transform splits is checked as read and again as what the transform made of it, including the
    parts of it the transform kept (they have no row of their own, so none passes through): the interior of a
    throwing top-level statement, a split statement of a transformed run, of the root's conversion, and the whole
    body of a converted function value (checked where written, then as made). Meta blocks inside are not run again
    (shown as what they generated), and calls reach the same keys, so no instance is made twice.
  - A run's handler values: read as written for `arms_row`, then checked as the transform rebuilt them.
  - `processed_fn` still checks a copied instance's body once more for its types (now at the instance's key).
  - A statement only gets a row of its own at the top of the asked block or the root; giving every nested statement
    one would change how rows are inferred everywhere (`row_within` is a snapshot, not a constraint).
  - `__tx_prompt` (a run whose code takes control outward) does not hand untouched statements back.
- **Fixtures:** new `core/top_level/meta_once` (the reproduction: `compiling` and `expr` once each), new
  `effects/v2/processed_once` (meta blocks in a converted lambda, before and after a split in a transformed run, and
  in a function a throwing top-level statement calls: each once). `effects/v2/meta_once.txt` now prints `report is
  processed` twice and `asking is processed` once: one `report` per handler key (the first run's `Log`, the second
  run's `Log`, which the transform's read, the kept `report(2)` and the copy of `asking` all reach), one `asking`.
- **Found, left:** the printer does not round-trip a `meta` statement followed by a run block's value expression
  (`meta { … } a + b` prints as a call of the meta block); `processed_once` avoids that shape.

I329. **2026-11-23 (user asked): `str` writes a short `Display` method in place (review after).** `str<T>`'s meta block reads
the method `value.fmt()` reaches (`processed` of the call, then `declared_call`, new: `declof_call` answering `None` for
what `declof` cannot show, a local function) and, when its body is at most two statements and it takes only the
receiver, generates `var self = value;` followed by that body; otherwise it generates the call as before. `print("hi")`'s
`str#0` is `var self = value; return self;` with no `String#Display#fmt` left; a user `Point` with a one-line `fmt`
inlines likewise, its own `str(self.x)` reaching its own instance. A local type's `fmt` stays a call. Not covered by a
fixture of its own: output is unchanged, so every `Display` fixture covers it.

I330. **2026-11-23 (user asked): calls inlined in the walk (review after).** Where an instance's processed code is made
(`processed_of`, metaprocess.ml) and where the root's statements are (`finish_root`, after its drain), `inlined`
rewrites the resolved code with `Inline.program` (new `bootstrap/lib/inline.ml`) against the instances already
processed, so `print("hi");` processes to `__write_out(("hi" + "\n"));` and the existing prune drops `str#0`,
`print#0` and `__root#0`. Not a pass after the walk: nothing in `Compile` changed, and `--dump-processed`/`--dump-code`
show the inlined program because `on_code` sees what the walk returns. Decisions:
- **Spliced as resolved code, not through `Pre_checked`.** The callee's body is its `i.processed`, already resolved,
  so nothing is checked or resolved again; a `Pre_checked` holds checked (unresolved) code, which would have to go
  through `processed_stmt` a second time. Only the argument bindings are new nodes. (review after)
- **Order.** An instance is processed after the instances its body reached (drain order), so a callee's body is
  already inlined when its caller reads it; a callee not processed yet, still walking, homed, local, quoting, or with
  more than one instance under its name is left as a call. No re-processing, so no fixpoint loop: recursion cannot
  unfold, because a body is inlined only once it exists and a body naming itself is refused.
- **What is inlined.** A top-level function whose processed body is at most 3 statements and 40 nodes, holds no
  `fn`/type/`defer`, has closed types (no `Generic`: Type_mono could not rename what a generic body carries into a
  concrete caller), is not `cps`-marked, and takes exactly as many parameters as the call passes (so evidence a
  callee does not take, which the interpreter drops, is never in play). Where a value is wanted: only a single
  `return e`. As a statement (`f(..);`, `return f(..);`, `var x = f(..);`, `x = f(..);`): also a short body with no
  `return`/escaping `break`/`continue`. Thresholds are guesses. (review after)
- **Arguments.** Literals and variables that hold one value (bound once in the caller and never assigned, a
  function's name, or a binding inlining made) are substituted; an unused lambda is dropped; a lambda the body calls
  once as a statement is substituted and beta-reduced. Where a value is wanted, a variable that may change, or a
  pure expression that makes nothing (`s.side`; never an array or record literal, which read twice would be two
  values), is substituted when every read of it comes before anything that could change it
  (interpreter evaluation order); one argument with effects is substituted only into a pure expression that reads it
  exactly once unconditionally. Otherwise (and always as a statement) arguments are bound to fresh locals ahead of
  the body, in order, and the binding is itself inlined when it is a call.
- **Copy propagation.** `var x = y;` with `x` bound once and never assigned and `y` as above (or a literal) is dropped
  and `x` read as `y`, not in a block declaring a `fn` (hoisted above it).
- **Beta.** `(lambda)(args);` as a statement becomes its statements after the arguments when its arity matches, it has
  no `return`/escaping `break`, no `fn`/`defer`, and is not `cps`. A lambda taking evidence (the effectful root's
  `(ev#h) => {…}`) is still called: `__root`'s body calls `main` inside a block, which the substitution rule does not
  reach. (review after: the effectful root stays a call of a bound lambda.)
- **Names.** Every binder of a spliced body is renamed `inlined#<name>#<n>`, scope by scope; a callee is refused where a
  name it reads free is bound anywhere in the caller.
- **Handler keys (I326/I327) and the transform.** Untouched: inlining runs on processed code after every key is
  settled, and splices the instance that key named, so a call reaching a handler-keyed instance runs the same code.
  The transform reads `declof`/`processed`/`processed_fn`, which show the checked source (`i.source`, `kept_stmts`),
  never `i.processed`, so it never sees inlined code. `i.deps` is unchanged, so a meta block's program still carries
  an inlined callee (harmless).
- **Found and fixed:** `names_in_expr` did not read an object's `equal`, so `==` on a trait object kept its `Eq` impl
  only while a direct `==` also named it (`core/traits/dyn/equal_impl` failed once the direct call was inlined).
- **Fixtures:** `tests/meta/prune/meta_only_function` no longer expects `(fn shared` kept and
  `tests/meta/prune/unreferenced_impl` no longer expects `(fn Square#Area#area` kept: both are now inlined at their
  only call and dropped. The absent lists are unchanged. The prelude-walk probe "a prelude function a later pass
  calls survives" now accepts `from_array` kept or its body inlined (`count:(array-len`), since `var xs: List<Int> =
  [1, 2];` inlines it.

I331. **2026-11-24 (user: "yes fix it"): an impl's bounds on the type's own arguments are checked when it is matched.**
`impl Shout for Box<T: Display>` records, beside the trait arguments naming that impl, that argument 0 must be `Display`
(`ctx_impl_bounds`, scoped and reset with `ctx_impl_params`); `satisfies` takes the type's arguments and checks them through
`admits`. `loud(Box { held: Point { x: 2 } })` is now "Expected Shout, got Box<Point>." at the call, not "Expected Display,
got Point." inside `loud`'s instance. Only a bound written as a bare trait name (`T: Display`) is checked; one with
arguments (`T: Into<Int>`) is not yet (review after). Fixtures `core/traits/errors/impl_bound_unmet`,
`core/traits/impl_bound_met`. Resolves I240.

I332. **2026-11-24 (user: "Reflection objects are just objects; the only part that is metaprocess-bound is lowering
code/typeof to the struct literals"): every reflection form works outside a meta block.** Each is lowered, when the walk
checks it, to a literal the program builds at run time, as `typeof` already was:
- `implements(T, Trait)` → `true`/`false`. A generic function's instance is checked at its key, so
  `fn show<T>(x: T): Bool { return implements(T, Display); }` answers per instance. The guard on `in_meta` is gone, so
  `gen code(implements(T, Display))` answers in the generated code too.
- `code(e)` / `code { … }` / `code fn …` → the `Expr` / `List<Stmt>` / `Decl` built as constructor calls
  (`Syntax.expr`/`stmt`/`decl` of the quote, then `Splice.built`: records `New`, variants `New_variant`, a `List`
  a collection literal, a `Name` a name literal). A runtime local named in the quote stays a `Var` (no substitution, unlike a
  meta block's quote, which writes each meta value in) (review after).
- `declof(f)` / `declof(T)` → the `Decl` value the meta path would hand out (the same `declared_instance`/`declared_type`),
  built as a literal. Inside a generic function `declof(T)` reads `T` at the instance's key (the meta path had `T`
  written in by the key already). A run-time value holding a `Name` is "'n' is not a declaration." outside meta.
- `moduleof(m)` → the `Module` value of `module_record`, as listed when the statement is checked (review after: a
  later top-level meta block of that module that has not run yet is missed, as in a meta block).
- Inside meta blocks nothing changed: quotes and `declof` still go through the context table.
- **Spans** are the source span: each `span` field is `__span_here()` placed at the node's own span, a new builtin
  returning its call's span (generated nodes stay `<generated>`). Printing a value therefore shows `file:line:col` with
  the path as the compiler was given it, so the fixtures print through `std/compiler/Printer` instead (review after).
- **A function quoting code is used by meta blocks or at run time, not both.** One first made outside meta has its
  quotes as literals; a meta block calling it later is "'make' quotes code at run time, so a meta block cannot call it."
  (the mirror of the existing "only a meta block can call it"), because the meta block's quote would have written its
  values in (review after: an instance per mode would lift both errors).
- **Fixtures:** flipped `meta/code/outside_meta`, `meta/declof/outside_meta`, `meta/moduleof/outside_meta` (with
  `thing.cx`), `meta/implements/at_runtime` out of `errors/` with run-time output; added `meta/code/generic`,
  `meta/declof/generic`, `meta/implements/generic`, `meta/code/errors/run_time_quote_in_meta`.

I333. **2026-11-24 (user: "I want inlining to be explicit. … `shown` needs the inline keyword if we want to inline it
automatically"; and: an `inline` function that cannot be inlined soundly is a compile error saying why): inlining is
explicit.** Timings (`scratch/tools/timing.py`, median of 9, ms, compile · run · total): `hello` 36.6 · 0.0 · 36.7,
`working_example` 67.9 · 0.0 · 68.0 (no baseline measured alongside; I328 recorded 35.5 and 63.0 before I329–I332).
`print("Hello, World!")` still processes to `__write_out(("Hello, World!" + "\n"));`.
- **Syntax.** `inline fn` on a top-level function, a method in an impl or a type body, and a handler method
  (`handle<E> { inline fn op(…) { … } }`, which is a `method_def`). `inline` is contextual, like `global`: a keyword
  only before `fn`, otherwise a name, so the reflected field `sg.inline` and the existing locals named `inline`
  (`os/Cli.cx`) still read. Not in the scanner's keyword table, as the brief suggested (review after). Not accepted on
  a trait's method signature.
- **Carried** as `inline : bool` on `Ast.signature`, so it rides every stage that holds one (`Fn`, `method_def`, the
  lambda a handler method becomes — `handler_record` copies it from `md_signature` — and the lifted
  `handler#N#method`, whose walk decl now takes the checked `Fn`'s signature). Reflected as `Signature.inline: Bool`
  (`Syntax` reads and writes it); every `Signature { … }` literal in the library and fixtures gained `inline: false`
  (on the `static_params` line, so no `.err` line moved), except `__tx` copying a function, which keeps
  `fd.signature.inline`. Printed back by `Source`, `Printer` (`--dump-ast`, `--dump-processed`) and
  `std/compiler/Printer` (`__inline_mark`; the name `__inline` was taken). The s-expression dump (`(fn …`) does not
  show it.
- **What is inlined.** Only calls of a function declared `inline`, at every call the walk processes (an instance's
  body, the root's statements): no size limit. Generic ones per instance, as before. Stays automatic: beta-reduction of
  a lambda called where written, copy propagation of `var x = y`, and `str`'s meta block writing a short `fmt` (I329).
  Everything else is a call, including a lifted handler method not declared `inline` (a direct call, I326).
  `typecheck.ml`'s handler-method folding (`inline_lifted`) runs only for an `inline` method.
- **Where a body can now stand** (needed once size no longer decides and a refusal is an error): a body whose
  `return`s all end it or end a branch that ends it (`if (c) { return a; } rest` is read as if/else) is written in a
  value position as `var x;` followed by the body assigning `x` at each return; `return f(…)` takes the body whole,
  its returns the caller's; a body with a local `fn` or a `defer` stands in a block of its own (its functions renamed,
  hoisted as before); an `inline` call nested in an expression is taken out to `var inlined#value#N = f(…)` ahead of
  its statement, with everything evaluated before it there bound ahead in order (literals, lambdas and names that keep
  one value stay), then inlined as a statement. Arguments past the parameters that are names or literals (evidence the
  callee does not take) are dropped. (review after)
- **Errors** ("'f' is declared inline, but …"). At the declaration: it calls itself; it is declared inside another
  function. At a call: recursion through other `inline` functions ("it is recursive, and its own body reaches this
  call"); it takes control; it declares a type; its types are not settled; it quotes code; more than one instance
  under the name; it returns from inside a loop where its value is used; the call stands where nothing can be taken
  out (the right of `&&`/`||`, a `while` condition). (review after: the last two could be lifted with a labelled
  exit.)
- **Not errors** (review after): an instance emitted inside a body (`homed`, keyed by a local type) stays a call; an
  `inline` handler method of a handler that stays a value (reads a run's locals, `hv#N.write(…)`) is a field call; a
  call passing fewer arguments than the callee takes (evidence missing, only in a program already failing); once the
  session has errors, no inline errors are reported.
- **Order.** A callee is processed on demand when its call is read (`processed_of` from `inlined`'s `find`; a
  `processing` table tells recursion), and `reached` (a meta block's program) now processes an instance's callees
  before it.
- **Marked in the library:** `print` (`io/Print.cx`), `str` (`text/Format.cx`), `__root` and its Console `write`
  handler method (`prelude.cx`). Nothing else. `str`'s structural path (no `Display`, no `Debug`) moved to a new plain
  `__structure<T>`: written in place it made `str` of a recursive type call itself, and its loops return from inside.
  `printerr` and `__meta_root`'s handler are not marked.
- **Fixtures:** new `core/functions/inline/not_marked` (the user's example, `shown#0..2` kept), `marked` (`inline fn
  shown`, no `shown` left), `members` (an `inline` method in a type body and in an impl, a function returning from
  branches, an `inline` handler method, and `decl_source` printing each back), `errors/recursive` (at the
  declaration), `errors/mutual`. `pruned` gained the three output fixtures; its existing entries are unchanged and
  pass (`shared` and `Square#Area#area` are expected kept, which holds: neither is `inline`).

I334. **2026-11-24 (user: "yes make that change"): an argument read once, before any effect, is written in place.** The inliner
bound every argument that was not a variable, literal or lambda to its own local ahead of the body
(`var inlined#value#9 = shown#0(…)`). Now the one such argument of a call is substituted when the body reads it exactly
once, unconditionally, and nothing with an effect or that can fail is evaluated before that read (`first_effect_after`
in bootstrap/lib/inline.ml; in a statement body, the read must be in its opening statement): it then runs where the
binding would have. `print(shown(Money { cents: 1 }))` is `__write_out((__display(shown#0({ cents: 1 })) + "\n"));`. A body
with an effect before the read keeps the binding (fixture `core/functions/inline/argument_order`). A substituted argument
keeps its own span, so a failure in it points at the call (`core/builtins/chr_invalid`, `operators/negative_shift`
stayed at `[1:7]`).

I335. **2026-11-24 (user: "This part should probably be explicitly inlined"): `debug` and the primitives' `debug` are `inline`.**
`debug<T>` is `inline fn`, and its structural case moved to a plain `__debug_structure<T>` (as `str`'s did to
`__structure<T>`): a recursive type's parts reach it again. The one-line `debug` of `Int`, `Float`, `Bool`, `Byte`, `Char`,
`String`, `Unit`, `Name` and `Span` are `inline fn`. `__shaped` now writes a structure a part per statement (`__started`,
`__appended`, `__appended_call`, `__finished`): a part's `debug` call stands alone, `var part = debug(x);`, since the
inliner will not move a call past an earlier one in the same expression. `Point`'s field is `__debug(value.x)`, with no
`debug#1` or `Int#Debug#debug#0` left. Found and fixed in the inliner: a callee calling back into its caller
(`debug<Tree>` → `__debug_structure<Tree>`) was refused as a capture, because the caller's own name is bound in its body;
`opened` now exempts that name when it is the body's only binding of it (scope field `own`).

I336. **2026-11-24 (user: "do the recommended version"): `tcp_connect` waits for the connection.** `TcpStream` gains
`established(self): <Async, Throw<IoError>> Unit` (the OS socket's is its existing `__connected()`; `fake_net`'s `Canned` has
an empty one), and `tcp_connect` calls it before returning, so its row is `<Net, Async, Throw<IoError>>` and a refused
connection is thrown at `tcp_connect`, not at the first `read`/`write`. The `Net` handler's `connect` stays plain (it still
only starts the connection). `stdlib/net/fake_net`'s refused case now separates the connect from the write and still prints
only `refused`. Resolves I259's open choice.

I337. **2026-11-24 (user: "accept and do the rename"): the `v2/` fixture folders are gone.** Every fixture under
`tests/effects/v2`, `tests/core/defer/v2`, `tests/stdlib/v2`, `tests/effects/methods/v2` and `tests/core/traits/dyn/v2`
moved to the same path without `v2/` (335 files), and `bootstrap/test/test_bootstrap.ml` follows. Three clashed with an
existing fixture: `core/traits/dyn/v2/effect_resumes` was the same program as `core/traits/dyn/effect_resumes` (only the
`handle` clause moved) and is deleted; `stdlib/v2/io/files` (buffering, `using`, `lines`, directories) is
`stdlib/io/files_and_dirs`; `stdlib/v2/os/process` (args, env, `exit`, `all`) is `stdlib/os/process_effects`. Older log
entries still name the `v2/` paths.

I338. **2026-11-24 (user: "yes fix it"): an effect a handler's method leaves unhandled is reported at the call inside the
method.** `note_effect_sites` also records, while a handler value is checked (`run_value`, wrapped in `walk_bindings`'
`check_values`), where each effect is first performed inside its methods (`arm_sites`), and keeps those once the value is
checked (`escaping_sites`); when such an effect first reaches the top level's row, its site is that call, not the `run`'s.
`trait Log { fn log(s: String); } run<Unit> { log("x"); } handle<Log> { fn log(s) { log("again " + s); } }` is now
`[2:51]` (the inner `log`), for a plain and a `@ctl` handler alike. `effects/handler/errors/arm_without_outer.err`:
`[2:1]` → `[2:51]`.

I339. **2026-11-24 (user: "accept and add the ambiguity error"): `module.op` naming two effects' operation is an error.**
Where the module bound whole declares no export by the name and two or more of its effect traits have the method, the
loader's qualifier raises `Ambiguous_operation`, reported at the use (`qualified_at`, in the `Method_call` and `Field`
cases): "Ambiguous operation 'signal.stop': Signal.stop or Halt.stop. Import the one you mean by name and write
'Signal.stop(…)'." (worded as the same-file "Ambiguous operation 'log': Log.log or Journal.log."). The suggestion is
`import { Signal } from "signal"` and `Signal.stop(…)`, which works; `signal.Signal.stop(…)` does not (questions.md).
Fixture `effects/errors/ambiguous_module_operation/` (`main.cx`, `signal.cx`, `main.err`).

I340. **2026-11-24: a misplaced `discontinue` is a compile error.** `discontinue(e)` (the builtin, so a binding of the
same name is untouched) checks only when `e` names, lexically, the continuation parameter of the handler method it is
written in: that method's body, or a lambda written inside it. Otherwise: "'discontinue' takes the continuation of the
handler method it is written in, and 'k' is not one here." at the call (a non-name argument: "…, by its name."). In
`typecheck.ml` the continuation parameter's `Ast.param` record is noted (`note_continuation_param`) wherever a handler's
methods are made — `handler_record` (inline handlers in the walk), `handle_block` (outside the walk), `note_continuation`
for an `impl EffectHandler<E, R>` method (walk and non-walk impl checks) — the last parameter of a `@ctl`, non-`@abort`
operation's method. `bind_param` marks the scheme bound for such a parameter (generic lambdas, keyed walk decls, impl
methods, `handle_block`), and the check compares `lookup env k` with those schemes physically, so shadowing and a
parameter it was passed on as both end it. Skipped while `!recording` (a meta block asking about code, i.e. the
transform reading the arm): that code is rebuilt from quoted values, so the parameter records are new; the final check
of what the transform generates still catches it. The run-time native stays as a backstop. Fixture
`effects/discontinue/errors/outside_handler` (the `give_up` example); a lambda inside the arm was already covered by
`effects/discontinue/discontinue` (`later.push(() => { discontinue(resume); })`). Gap: a named handler type's
`discontinue(resume)` is accepted statically (as asked) but still fails at run time, since the transform only rewrites
inline handlers' records (`__tx_discontinuing`).

I341. **2026-11-24: a plain operation's arm that takes control is rejected again, as a permanent rule.** In the walk an
inline handler's lambda for a plain operation is noted in `handler_record` (`plain_arms`); after the generic `Lambda`
case checks it, a `controlling_row` of its own row (not the record's, which I325 read) is an error: "A handler's 'log'
performs 'Stop', which takes control; 'log' is a plain operation, so its handler must return. Mark it `@ctl` if it should
take control." reported at the arm's span, which is the `run` holding it (`[13:5]`), as before. `handle_block` (outside the
walk) uses the same message. A helper the arm calls that performs `Stop` is caught too; a lambda in the arm that performs
it is not (its row is its own, as in Precheck). `effects/errors/handler_method_takes_control` moved from `known_unsound`
back to the error list, `.err` reworded.

I342. **2026-11-24 (user: "accept and add the ambiguity error"): a bare name two declared effect traits share is an
error.** `operation_owners` lists every declared effect trait with an operation of the name; where nothing else binds the
name and two or more do, the checker reports "Ambiguous operation 'log': Journal.log or Log.log." at the use (traits
sorted), as the loader does for imported and same-file traits. One owner still resolves (`bare_operation`). Fixture
`meta/02_gen/errors/ambiguous_generated_operation` (two generated traits with `log`).

I343. **2026-11-24 (user: "yes fix it"): a value becomes a trait object only if each method fits what the trait wrote.**
A call through a trait object's table arranges handlers for the row the trait wrote and nothing more, so where a value
is made into one (the `Object` slots in typecheck.ml), each slot's method's inferred row must hold only labels the trait's
method wrote; a row parameter there lets anything through. `var s: Speaker = Cat;`, with `Cat`'s `speak` performing `Ask`
and `Speaker.speak` writing none, is "Cat cannot become a 'Speaker': its 'speak' performs 'Ask', which Speaker.speak does
not allow." at `Cat`. The check is at the coercion, not on every impl: a named handler's methods, a static or generic call
(its instance's real row reaches the caller) and operator traits are sound already, and checking every impl rejected
eleven fixtures of those kinds. `core/traits/errors/impl_row_inferred` moved from `known_unsound` (now empty) to the
error list.

I344. **2026-11-24 (replaces I303's shared-name handling): each instance's local functions have names of their own.** A
local function's `walk_decl` now carries `wd_owner`, the name of the instance being checked when it was declared
(`Typecheck.checking_instance`, set and restored by `check_instance`); `instance_base` (`metaprocess.ml`) names its
instances `<owner>#<name>`, then `#<n>` per key as before: `twice#0#cx11#loop` and `twice#1#cx39#loop`, or
`quadruple#0#twice#0`. A local in code no instance checks (a root `run` body, a meta block) has no owner and keeps its own
name; those are walked once. Every reference already went through the instance's name, so nothing in the body needed
rewriting, and `renamed_locals`/`rename_local_types` (types) are unchanged. Removed: `by_name` holding several instances
under one name (now `Hashtbl.replace`, and `reached`/`pruned` follow the one instance), and the inliner's "it has more
than one instance under this name", whose only cause this was. Instrumenting `made` and `lift` over every `tests/**/*.cx`
found no name added twice, so nothing keeps `find_all`. `declared_at` (the transform's `instance_of`, which keys
`remembered`) uses the owner-prefixed name too, so two owners' locals at one key no longer share a remembered conversion.
`declof_shown`/`typed_fn` and `declof` look up declarations by their written name and key, not instances, and are
unchanged. New fixture `core/functions/inline/local_of_same_name` (an `inline fn twice` and a local `fn twice` in another
function; before: "it has more than one instance under this name" at the top-level call). `effects/loop_copy_two_keys`
still passes.

I345. **2026-11-24 (user: "anything can use files and the network … not something we should protect against"; replaces
I318): every meta block runs under one effect-driven meta root, wherever it is written.** `__meta_root<E>(main: () -> <E>
Unit)` (`stdlib/prelude.cx`) is an `inline` instance keyed by the block's row, as `__root<E>` is (I321): its meta block
reads `__effects_of(E)` and generates a run with the handlers of exactly the system effects the block performs, calling
`block_on` (and handling `Time`) only for `Async`. It never handles `Exit`: `exit` in a meta block stays "Unhandled effect
'Exit'", as before. Both roots now share three plain helpers: `__performs`, `__wanted` (the labels to handle) and
`__system_run` (the quoted run of every system handler, kept to the wanted clauses); `__root` adds only its `ended`/
`__exit` around it. Removed: `__meta_root_io`, `Ast.meta_io_root_function`, the walker's `meta_io_root` field and the
`~io` argument of `meta_stmt`/`run_meta` (the position-based choice). The cycle the split avoided: a meta block in what
the meta root's own meta block reaches runs under the meta root, so the root's block must reach no meta block. `str` has
one, so `__named`, `__handled_name`, `__performs` and `__wanted` read a name with the builtin `__display` (what `Name`'s
`Display` impl calls) instead of `str`; noted at `__performs`. A walker flag making everything the root's block reaches
run bare was tried and not needed once the root reached no `str`, so it was dropped. New fixture
`stdlib/os/meta_files_in_function` (a meta block in a function body writes, reads and removes a file at compile time and
returns what it read); before: "Unhandled effect 'Dirs'" at the meta block. Checked by hand: `sleep` in a function-body
meta block runs. Results: `fixtures.py` 936/936; `dune test --force` 1680/1680; `dune test cx` 131/131. Timing (median
of 7, compile ms): `hello` 41.7 → 42.6 (noise), `stdlib/os/meta_environment` 180.2 → 131.2 (the top-level block no longer
reaches the whole I/O library, only `Fs`/`Dirs`/`Env`/`Time`'s handlers), `meta_files_in_function` 130.0.

I346. **2026-11-24 (I320c: "the compiler doesn't know CPS is a thing"): the transform declares the shapes it builds, and
the checker reads them.** `stdlib/core/Transform.cx` declares two functions the checker reads (`Core.handed`,
`Core.handed_method`; hoisting a top-level `fn` of either name records its scheme, parameters and body in
`Typecheck.shapes`):
`fn __tx_shape<R, A, K, U>(value: R, k: (R) -> <K> A, u: ((Unit) -> <U> A, Int) -> <U> A): A { return k(value); }` and
`fn __tx_method_shape<A, P>(value: A, u: ((Unit) -> <P> A, Int) -> <P> A): <P> A`. A shape is read generically
(`handed_params`): instantiated (every variable and row its own per use, since a hoisted scheme quantifies no rows),
its first parameter unified with what the item returns as its type shows, its result with what a call answers, its row
with the item's row; its other parameters are what the item is handed. `__tx_shape`'s body is also the body of a function
value whose type takes control though nothing in it splits (`wrapped`, which puts the value's result for `value`; only a
call of parameters is accepted there). Markers: `cps#made` became `handed#made` (`Ast.handed_marker`, library
`handed_marker()`), and a new `method#made` (`Ast.handed_method_marker`, `handed_method_marker()`) marks the handler
methods `__tx_dropping` makes (the run's own `@ctl`/`@abort` arms handed `u`).
- **Removed from the compiler:** `Typecheck.unwinder`; the literal `+ 2` in `cps_shape`, the dyn-call through a table,
  `cps_lambda`'s parameter split and both counts in `verify.ml` (each now `handed_count Core.handed`, the shape's
  parameters less `value`); `cps_call`'s and the dyn call's `k`/`u` types; `handler_type`'s appended unwinder (now the
  method shape's parameters at the method's answer and row); `wrapped`'s own `k(value)` body; `run_value`'s "one
  parameter longer" (a field whose lambda carries `method#made` is the method's type and the method shape's parameters;
  any other must match exactly); `bound_value`'s "one shorter", "one longer" and "longer still" cases (a named handler's
  record of methods as its operations show them is read against `handler_shown`, the same record before the method
  shape, kept beside `handler_values` by `handler_types`). Renamed: `is_cps` → `is_handed`, `cps_shape`/`cps_call`/
  `cps_lambda` → `handed_shape`/`handed_call`/`handed_lambda`, the context's `cps_answer` → `handed_answer`.
- **What remains, and why:** a function value whose type takes control is handed one handler per effect in its row that
  takes control, before the shape's parameters (`controlling`, `handler_param`, `handled_by`): handlers as values are the
  checker's own model (evidence, bound runs, `param_binding`), not the transform's. A handler method for a `@ctl`
  operation is written taking its continuation last and an `@abort` one is not (`handler_types`, `handler_record`,
  `handler_signature`, I340's `discontinue` check): that is the source language. `plain#made` (takes no evidence) stays.
  The counts `ps + handlers + handed_count` remain, as arithmetic over the declaration. `eta`, `controlled_slot` and the
  named handler's forwarding record are unchanged. Grep of `bootstrap/lib/*.ml`: no `unwinder`, no `+ 2`/`- 2` over
  parameters, no `cps` name; `inline.ml` still says "its body is rewritten into continuations" in a refusal message.
- **Declared rows (review after):** `cps_lambda` declared only `k`'s row; `handed_lambda` declares every row of the
  shape's parameters not already in what the lambda returns or answers, so `u`'s row is declared too. All fixtures pass
  either way; the rule is the simpler one, and needs no field of the shape to be told apart.
- **Settled leftovers in `wrapped` (review after):** the shape's answer and rows, which nothing there fixes, are settled
  as `Unit` and closed rows in the annotations, as the old body annotated `k` (`(R) -> Unit`, pure); Verify rejects a
  generic annotation otherwise.
- **Checked:** `--dump-code` of every fixture (936), with `#N` suffixes renumbered and `cps#made` read as `handed#made`,
  is identical to the tree before the change, output and diagnostics included. `fixtures.py` 936/936; `dune test --force`
  1680/1680; `dune test cx` 131/131. Timing (`timing.py -n 9`, compile · run · total ms, alternating with a copy of the
  tree before): `hello` 34.3/33.6 · 0.0 · 34.4/33.7 → 34.0/33.9 · 0.0 · 34.0/33.9; `working_example` 64.9/63.8 · 0.0 ·
  65.0/63.9 → 65.5/64.8 · 0.0 · 65.6/64.9 (about 1 ms, one instantiated shape per handed lambda, call and handler type).

Reviews of the 2026-11-23 design-session items (sections of the review note named I320a … I330c):
- I320a (a panic runs no `defer`s): REVIEWED (2026-11-24): accepted (Zig behaviour).
- I320b (`discontinue` only in the handler's own body): RESOLVED (2026-11-24) by I340: a compile error at the call.
- I320c (the compiler still knows the `u` convention): REVIEWED (2026-11-24): changed — the transform declares its shapes and the checker reads them (I346, built).

I347. **2026-11-24 (user: "yes but no underscore to keep it like the others"): `effects_of` is public.** `effects_of(E)` (the
loader turns it into `__effects_of`, as it does `implements`) gives the labels a row parameter of the function it is
written in stands for, as a `List<Name>`, inside and outside meta blocks, decided per instance; `prelude.cx`'s roots use
it. Outside a function with that row parameter it is "'effects_of' takes a row parameter of the function it is written
in, as in `fn f<E>(g: () -> <E> Unit)`." Fixture `meta/effects_of/at_runtime` (counts 1, 2 and 0 effects).

I348. **2026-11-24 (user: an uncaught failure reports the position of the `throw`, for `@abort` operations only): an
`@abort` method is handed where its call was written.** `stdlib/core/Transform.cx` declares a third shape,
`fn __tx_abort_shape<A, P>(value: A, at: Span, u: ((Unit) -> <P> A, Int) -> <P> A): <P> A`; `__tx_method_shape` is now
the `@ctl` one only, so ordinary and `@ctl` operations are unchanged. The checker reads it as it reads the others
(`Core.handed_abort`, hoisted into `Typecheck.shapes`), choosing by the operation's kind (`method_shape`, which
`handler_types` and `run_value` use; `run_value` finds the operation through a new `handler_labels`, handler → effect).
- **How the position travels:** `__tx_split_call` hands a call of an `@abort` operation `__span_here()` carrying the
  call's own span (`__tx_written_at`) before `u`: a constant, nothing captured. Every maker of an `@abort` method takes
  and forwards it: `__tx_dropping` (a run's own arm), `__tx_prompt_method` (typed `Span`, since that record is open),
  `__tx_wrapped` and `__tx_past_run`.
- **What an `@abort` arm sees:** nothing new unless it asks. The builtin `aborted_at(): Span`, written in an `@abort`
  arm's body (a function value made in it included), is made the handed position by the transform (`__tx_placed`), as
  `discontinue` is recognised by name. Anywhere else it is a run-time error, "Only the method of an '@abort' operation
  knows where it was called." (review after: not a compile error, which would mean teaching the checker the name as
  I340 did `discontinue`; and a named handler's impl method, `type Quit impl EffectHandler<Stop, Int>`, is reached only
  on the prompt path, so elsewhere it is that error too.) Handler syntax is unchanged.
- **Reporting:** a new builtin `panic_at(at: Span, message: String)` panics at `at` (at the call when `at` is nowhere),
  and `prelude.cx`'s `__throwing` writes `panic_at(aborted_at(), "uncaught failure: " + str(e))`. The example
  `fn load(): <Throw<String>> Int { return throw("missing config"); } print(load());` now reports
  `uncaught failure: missing config` at `ex.cx:2:41`, underlining `throw`.
- **Library throws (review after):** `tests/stdlib/async/uncaught` now points at `stdlib/async/Task.cx:294`, the scope's
  `throw(failure[0])` that rethrows its task's failure, not at the task's `throw`; its `.rt` stays message-only. Carrying
  the first position through would mean the scope keeping `aborted_at()` beside the failure and an operation to rethrow
  at a position.
- **Fixtures:** `core/top_level/uncaught.rt` → `[4:18] …`, `core/top_level/uncaught_structure.rt` → `[5:39] …`; new
  `core/top_level/uncaught_at_throw` (`[2:41] uncaught failure: missing config`) and `effects/abort/aborted_at` (a
  run's own arm, an arm across a bound run, through a function value in the arm, and a run's own arm on the prompt
  path). `cx/test/library/expected.json` gains the two builtins. `effects/root/root_failure` (a user-written `@ctl`
  root) is unchanged.
- **Checked:** `fixtures.py` 938/938; `dune test --force` 1685/1685; `dune test cx` 131/131. Timing (`timing.py -n 9`,
  compile · run · total ms): `hello` 36.2 · 0.0 · 36.2 → 34.6 · 0.0 · 34.6 (noise).
- I325b (fixtures changed for checking only reached code): REVIEWED (2026-11-24): accepted.
- I325c (handler method reaching an outer `@ctl`): RESOLVED (2026-11-24) by I341: a compile error again.
- I325d (the same error is reported once): REVIEWED (2026-11-24): accepted.
- I326a (a first call's key names every handler): REVIEWED (2026-11-24): accepted.
- I326b (the interpreter drops extra evidence): REVIEWED (2026-11-24): changed — one rule (a function value whose type performs effects takes evidence, made continuations included) and strict arity in the interpreter (I349, being built). Blocked 2026-11-24: the uniform rule cannot hold for continuations made in shared copies. Decided 2026-11-24 (user: "a method call fails if it has the wrong number of args"; "yes build it"): a continuation takes exactly its value and closes over its handlers; one that escapes as an ordinary function value is wrapped once where it escapes; then strict arity (I349, being built).
  - Paused 2026-11-24, reverted: patch at scratch/arity/continuations.patch (full files in arity/continuations/, pre-edit copies in arity/orig/). Neutral builtin `__exact(f)` (call hands only the written arguments; processed strips it), Transform.cx `__tx_call` exact by default + `__tx_ordinary_call`, arm rewrite `__tx_resumed_by` (calls of `resume` exact, escapes wrapped `(x) => resume(x)`), Verify accepts no-evidence counts. With strict arity on: 933/938 fixtures; left: effects/named_handler_generic, effects/handler/in_type (exact handler-method call hides `handler_call`), stdlib/async/failure, stdlib/async/cancel_defers, types/expected/written_key (named fn stored at a type that performs). No escaping fixture yet; I350 not started.
- I326c (one instance per handler): REVIEWED (2026-11-24): accepted — a meta block runs once per handler key.
- I327a (the plain marker means "takes no evidence"): REVIEWED (2026-11-24): changed — a separate marker for "takes no evidence" (I350, queued after I349).
- I327b (a recursive function keeps its evidence): REVIEWED (2026-11-24): changed — user: "that is a valid method written as-is. The issue is that the method is getting generated that way… in cases where the handler is stateless cps does not wrap the handler." A function whose calls all go direct to stateless handlers takes no evidence, its own recursive calls included.

I351. **2026-11-24 (I327b, user: "in cases where the handler is stateless cps does not wrap the handler"): a recursive
function's own evidence hand-off does not keep its parameter.** Deciding whether a function takes evidence
(`reads_own_evidence` in typecheck.ml) ignores a call of the function itself whose last argument is its `ev#h`;
`exact_stmt` then drops that argument from the self-calls. `count` (calls `log` direct, recurses) processes to
`fn count#0(n)` / `count#0((n - 1))` / `count#0(2)`. Review after: only direct self-recursion; a mutually recursive
pair that only forwards `ev#h` between its members still keeps it (needs a fixed point over the group). No fixture
pins processed code (the suite compares output only).
