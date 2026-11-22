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

### R28. Rewritten code keeps false rows (raised by the user 2026-11-22): open bug
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

### R30. Case convention (user, 2026-11-22): decided, convention only
All types are uppercase, identifiers stay lowercase: `Int`, `String`, `Bool`, `Float`, `Byte`,
`Char`, `Unit`, and every user type, trait and effect (`Async`, `Log`, `Sched`, `Logic`, `Stream`,
`Ask`). Type params stay `T`/`R`/`E`; values (variables, functions, fields, value static params
`<n: Int>`) stay lowercase; variants stay as they are. **Convention only:** the compiler does not
check it and case never carries meaning. The built-in names are renamed in the compiler, and the
stdlib and fixtures follow (about 4,000 uses of the built-in names, 76 lowercase declarations),
as part of the stdlib rework. To build.

### R31. `type X impl A, B { … }` (user, 2026-11-22): decided, defaults to review
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

### R5. The `str(E)` fix in the doc: taken, REVIEWED 2026-11-22: user chose A (a static param is a value inside a meta block: a type param is a `Type`, so `str(E)` works); to build, then restore the doc's `str(E)` message
A type param is not a value inside a meta block, so the EffectHandler example's fallback arm
now reads `fail("not a trait, so it has no operations to handle")`. Review: whether a meta
block should be able to name a static param as a value (`str(E)`).

## Defaults taken without asking (80% rule)

| # | Decision | Source | Review question |
|---|---|---|---|
| R6 | A key is settled strictly at the call, after its arguments. CONFIRMED by the user 2026-11-22 (strict) | 01 Q2 | Should a later statement be allowed to settle it (a queue at the end of the statement)? |
| R7 | Plain generic types (`type Box<T>`) stay parametric; only functions and methods are instances. REVERSED by the user 2026-11-22: types are monomorphized exactly like functions (`Box$int`, `Box$string`); a use of a type reaches Check decl cache → Metaprocess decl (diagram diamond now "call, operator, method, type"). To build | 01 Q3/D1 | Literal "every declaration at a key": would `Box$int` records be worth it? |
| R8 | A trait instance may keep a param open (`EffectHandler<Effect, _>`), so `Picker<R>` works. CONFIRMED by the user 2026-11-22 (`Picker<R>`, R settled by the run) | 02 Q2 | Fine as it is, or generic handlers another way? |
| R9 | `run<R>` may omit `<R>`, which is inferred, or `unit` for a statement run. REVERSED by the user 2026-11-22: `<R>` is required on every run for now (`run<unit>` for a statement); inferred static params come later, once designed properly. To build | 04 A1, 03 D8 | Should `<R>` be required? |
| R10 | `handle<E>` on a generic effect (`Throw<X>`) settles E's arguments from the body's row. REVERSED by the user 2026-11-22: written, `handle<Throw<IoError>>`; leaving them out is an error, until inferred static params are designed. To build | 04 A4 | Should they be written, as in `handle<Throw<IoError>>`? |
| R11 | Untyped params of a handler or impl method take the trait's types (not implicit static params). CONFIRMED by the user 2026-11-22 (an expected type, not inference) | 04 A5 | Consistent with "an unannotated param is an implicit static param"? |
| R12 | Lowercase effect names (`log`, `async`) are kept. REVERSED by the user 2026-11-22: renamed trait style (`Async`, `Log`, …), see R30 | 04 A8 | Rename to trait-style names? |
| R13 | Migrated code names the continuation `resume`. CONFIRMED by the user 2026-11-22 | 04 A2 | Fine, or `k`? |
| R14 | `final ctl op` → `@ctl fn op<T>(…): T` (keeps the fresh result type at each call site, loses the cheap unwind). REVISED by the user 2026-11-22: add `@abort` (users may skip it). Defaults taken, to review: `@abort fn throw<T>(err: X): T` keeps the fresh `T`; EffectHandler gives an `@abort` arm no continuation param and it returns the run's `R`; the transform compiles the call as an early exit to the run, building no continuation; stdlib `throw`, `exit`, `failed` use it. To build | 03 D9, 04 A3 | Measure compile time (stop if over ~3x); is a cheap abort worth a mechanism? |
| R15 | The `return (x) { … }` clause on `run` is deleted and folded into the run's tail (4 fixtures). CONFIRMED by the user 2026-11-22 (left out; may return later as an EffectHandler method) | 04 A6 vs 03 D3 | Was it worth keeping? |
| R16 | A trait-object method that performs a bound `@ctl` effect is rejected (`methods/suspending_receiver`, `core/traits/dyn/effect_resumes` deferred). REVERSED by the user 2026-11-22: rejection dropped; trait-object methods take handler + continuation under the R1 function-value rule. To build | 03 D6 | How should dynamic dispatch meet the transform? |
| R17 | Discontinue insertion is syntactic: an arm that never names its continuation gets `discontinue(k)`. CONFIRMED by the user 2026-11-22 (A: stored-then-dropped continuations are the programmer's to discontinue) | 03 D7 | Is syntactic enough, and what about an arm that stores `k` and drops it later? |
| R18 | One intrinsic, `discontinue(k)`, plus tail calls as an interpreter guarantee. CONFIRMED by the user 2026-11-22: the full list is discontinue, tail calls, the R1 function-value rule, and `@abort` (library first if it can express an exit to the run); no Cont/Frame/Abort | decision log | Is anything else of Cont/Frame/Abort needed? |
| R19 | Display/Debug impls stay rooted for every type the program constructs. REVISED by the user 2026-11-22: make Display static in the stdlib rework (`str<T: Display>` an ordinary generic call, real impls for built-in types, `List<T>` calling `T`'s; a type without an impl decided when built), then delete this Prune exception. To build | 01 D6 | Goes away once Display is static (Stdlib Plan). |
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

I25. **REVISED by the user 2026-11-22:** a param that defaults because nothing performs its effect makes the call contribute no such effect to the caller's row (the call never throws, so its type says so); replaces keeping the use open. To build. Was: U4 as built: a parameter standing only in effect labels defaults to `unit` in the key, but
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

I68. **REVIEWED 2026-11-22: delete the "named by the author" (handler leaves an effect param open) exemption when written `handle<Throw<X>>` is built; keep the others.** Unsettled at the processed stage. `processed_expr` fails with "This is not settled when its
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

I90. **REVIEWED 2026-11-22: B, a static param only in the return type, at a call whose value is discarded, defaults to `Unit` (unobservable, like R4); `effect`→removed with old syntax; `String` per R30. To build.** `traits/effect_handler` departs from the doc's code in three places:
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

I132. **REVISED by the user 2026-11-22: drop the first check of arms; errors and processed types come from checking the record (R28 rule); keep error spans on the arm as written. To build.** **C6: a run is lowered to a bound run** (`HandlerClause.Bound(label, handler, Option<Stmt>)`, OCaml
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

I143. **REVISED by the user 2026-11-22: B, EffectHandler generates each `@ctl` method generic in the row: `fn choose<ρ>(options: Array<Int>, k: (Int) -> <ρ> R): <ρ> R`; each run settles ρ when it binds the handler; named handlers write nothing extra; the core's per-op row becomes this per-run ρ. Also covers the `async.suspend` waker. To build.** **U2 as built.** Continuation types are honest: what a continuation performs is in its type, stored
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

I197. **What a prompt refuses** ("… is not supported yet."): a `return` that crosses it, since the flag (I140) has to
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

I200. **`stdlib/encoding/generic`, diagnosed, not fixed (types are monomorphized in a later step).** `from_json<T:
Decode>` performs `Throw`, so since S2 the top-level statement's function value splits at it and copies it. The copy
comes from `declof_call`, whose `surface` substitutes a type parameter only where the key binds it to a plain name;
here `T = Page<Item>`, so `T.decode(…)` keeps `T`: "Undefined variable 'T'". Options: (a) monomorphize types, the
planned step; (b) a copy keeps the type parameters its body names and its call writes them (`copy<Page<Item>>(…)`);
(c) substitute an applied type where it is a receiver, which needs an expression for `Page<Item>.decode`. Recommend
(a).

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

A5-Q1 (plan gap). **DECIDED by the user 2026-11-22: one `__root` for the whole top level (I162): vars stay globals, initializers assigned in place inside the one main, so the top level is one function body and the annotations come out; per-statement Throw catchers only where a statement throws. To build.** A top-level `var`'s initializer runs under `__root`, so the var's type is
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

## Plan-order changes made during implementation
- **P1 (after A7):** A10 (meta blocks processed by the walk) now runs before A8 (deleting Type_mono) and A9 (Prune). Type_mono, `resolve.ml`, `bound_calls`, `coercions` and `dp_instance` are now reached only by `Compile.program` for meta programs, so they can't be deleted until meta programs are on the walk (I52).

## Reviewer notes (orchestrator)
- **N1 (C5b): RESOLVED 2026-11-22 (always loaded, I150, I121).** `Transform.cx` is loaded only when a unit's tokens contain `handle <` or `with`. That is a load-time optimization keyed on token sniffing. It doesn't run library code on a condition, but it is close to the no-hooks line, and it is fragile: artifacts, and runs created by `gen`. Review: always load it and make loading cheap, or key it on the parsed AST.
- **N2 (C5a, I112): ANSWERED 2026-11-22, see I112 (handed form deleted).** an `@ctl` op called with one extra argument is "handed its continuation" and bound by the core. User code can write `ask(k)` by hand. Review whether that should be allowed.
