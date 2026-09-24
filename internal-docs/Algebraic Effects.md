# Algebraic effects — bootstrap

Status: **implemented.**

| Piece | State |
|-------|-------|
| Effect rows, inference, discharge | `lib/types.ml`, `lib/typecheck.ml` |
| `fn` operations | evidence passing (`lib/cps.ml`) |
| `ctl` operations | continuation passing, whatever a handler does with them
| Aborting `ctl`, multi-shot `resume` | continuation passing |
| Effect inside a loop | the loop is its own continuation, re-entered per iteration |
| Effect inside `&&`/`\|\|` | the operand it sits in becomes a branch |
| Effect inside a record or variant literal | the literal is built in the continuation |
| Effectful function as a value | converted like a named function of the same shape |
| `return` out of a nested `run` whose handler holds a continuation | unwinds past the frames the pass made |

Running: `log`, `ask`, `multi_handle`, `exception`, `delim`, `flip`, `recover`.

Two pieces of work that meet in the middle: effect rows in the type system, and a selective CPS pass that consumes what the checker inferred.

## A handler may narrow a declaration, never widen it

An operation's kind in the `effect` declaration is the worst case every caller is compiled for, and a handler may promise less than it but not more.

```cronyx
effect task { fn yield(): unit; }
effect amb  { ctl flip(): bool; }
```

A `ctl` operation may be answered by a `fn` arm: the caller was compiled holding a continuation the arm simply never reaches for. A `fn` operation may not be answered by a `ctl` arm, because its caller holds no continuation for `resume` to name. `Typecheck` rejects that, and `tests/effects/errors/handler_widens` is the case.

The rule is what lets a compiled dependency exist at all. Under it, whether `yield`'s caller needs continuations is settled by the file that declared `task` — so a package can ship `work` already transformed, and no consumer can demand a different transform of it by writing a different handler. Without it, a dependency's function has as many machine forms as its consumers have handler shapes.

`Cps` reads the declaration and nothing else. An effect with a `ctl` operation is compiled with continuations everywhere; one with only `fn` and `final ctl` operations is compiled with evidence. A handler that happens to resume in tail position no longer changes what its callee was compiled into, which is what `tests/effects/multi_handle/differing_arms` demonstrates: one `range`, used by a handler that resumes and by one that never does, in the same program.

Three things had to hold for that.

**A `run` installs its own evidence.** Evidence used to be named per operation, so `run { … } + run { … }` declared the same frame twice and the second answered for both. Each block now binds the operation to a fresh name while compiling its body, and arms are compiled outside that binding — so an operation performed inside its own arm reaches the handler outside the block rather than itself.

**A block keeps each effect's shape.** One `run` may handle a delimited effect beside an undelimited one. Its arms are built in whichever shape the effect's own declaration asked for, since a caller of an undelimited operation passes no continuation whatever else the block handles.

**A `return` crossing a `run` leaves it.** Converted code hands its result to a continuation, and a call comes back — so a `return` reached while an arm was resuming would let that arm carry on. A converted function is therefore a wrapper around its own body: the `return` stores its value and leaves the body, unwinding runs whatever the arms deferred, and the wrapper hands the value on once there is nothing left to leave. Ordering is the reason for the wrapper rather than a direct call: `tests/effects/return_past_arm_defer` wants the `defer` to have run before the caller sees the value.

## Planned: `print` is an effect

`print` and `clock` are the two entries in `builtins.ml` that exist because they do I/O. The plan for `print` is an effect declared in the prelude with a handler installed at the program's root:

```cronyx
effect out { fn print(s: string): unit; }
```

Output then goes wherever the innermost handler sends it — a file, a buffer, a test harness — without a writer threaded through every call and without `System.out` at each use. It is the canonical use of the feature.

Three consequences, recorded so they are not rediscovered:

- **An operation has a declared signature**, so `print` takes one string. That removes the variadic question rather than answering it, and makes string interpolation the ergonomic companion.
- **Printing becomes visible in a row.** Any function that prints carries `<out>`, so the program root must be handled implicitly or every program starts with a `run`.
- **It depends on containment**, which landed as step 11 of the same document. Under row equality a function that printed could not call anything.

## Reference architecture

**Koka**, per Leijen's row-polymorphic effect types. Where this document is silent or a detail turns out to be underspecified, do what Koka does rather than inventing something.

Cronyx's surface syntax is already Koka-shaped — its `fn` and `ctl` operations are Koka's `fun` and `ctl`, the tail-resumptive and general cases — so the semantics carry over with little translation.

## Surface syntax

Fixed by the fixtures in `tests/effects/`:

```cronyx
effect exception {
    ctl throw(msg: string): unit;
}

fn divide(n, d) {
    if (d == 0) { throw("division by zero"); }
    return n / d;
}

run {
    print(divide(5, 0));
    print("unreachable");
} handle exception {
    ctl throw(msg) { print(msg); }
}
```

One `run` may carry several `handle` clauses (`tests/effects/multi_handle`), and `run` blocks nest (`tests/effects/delim`).

**An effect may take type parameters**, which its operations share:

```cronyx
effect Store<T> {
    fn put(v: T);
    fn take(): T;
}
```

A parameter is one type variable for the whole declaration, and a call site is what settles it. An operation could leave a return unannotated and get the same variable; naming it is what lets two operations agree on it, and what says so to a reader.

**`final ctl` is what makes a non-returning operation usable anywhere.** Its handler cannot resume, so no value is ever handed back — and that is exactly the condition under which the operation's result may be read differently at every call site:

```cronyx
effect Error {
    final ctl throw(msg: string);
}

fn as_int(s: string): int    { … return throw("not an int"); }
fn as_word(n: int): string   { … return throw("not zero"); }
```

Both `return throw(…)` check, at `int` and at `string`, with no type parameter to settle. Declaring `throw` with a parameter instead ties every call site to one type and rejects the second — the two are not interchangeable, and this is the one that works.

Quantifying the result of an ordinary `ctl` would be unsound: the handler would owe a value of a type it never agreed to. `final ctl` is the promise that no such value is ever demanded, and `resume` inside one is an error rather than a wish.

This is Koka's design. It also means Cronyx needs no bottom type: `never` would say the same thing about the value where `final ctl` says it about the handler, and only one of the two can be checked.

**A row entry carries what the effect was instantiated at.** `Yield<int>` and `Yield<string>` are different entries, so one program may hold both, and which handler catches a `yield` follows from its instantiation rather than from its name alone. That is Koka's design: the entry is a label with arguments, not a label.

Three things follow. An operation's scheme quantifies its effect's parameters, so each call site instantiates. Finding a label in a row unifies the arguments rather than comparing them, which is what settles those variables. And a handler discharges *one* instantiation, chosen by unifying against what its arms turn out to take — `handle Yield { ctl yield(x) { print(x); … } }` handles `Yield<int>` or `Yield<string>` depending on the block it is on. `effects/generic/generic` uses both, and `effects/generic/nested` puts one inside the other.

**A row holds at most one instantiation of an effect.** A second is unified with the first, so a single function performing `Store<int>` and `Store<string>` is an error rather than a row with two `Store` entries. Nested `run` blocks are unaffected, since each has its own row.

## Operation kinds

| | `fn op` | `ctl op` | `final ctl op` |
|---|---|---|---|
| After the arm returns | resumes automatically with that value | does **not** resume | does **not** resume |
| Explicit `resume` | not used | resumes; may be called more than once | rejected |
| Falling off the arm | resumes | aborts the enclosing `run` block | aborts the enclosing `run` block |
| Result type | one per program | one per program | **fresh at every call site** |

`log` and `ask` show `fn` ops. `exception` shows abort — `throw`'s handler prints and `"unreachable"` never runs. `flip` shows multi-shot resumption:

```cronyx
ctl flip() { resume false; resume true; }
```

producing four lines of output from two `flip` calls.

## Why CPS and not OCaml 5 handlers

`bootstrap` runs on OCaml 5.5, whose handlers would otherwise map onto this almost directly. They cannot be used: **OCaml's continuations are one-shot** and `flip` resumes the same one twice. CPS continuations are ordinary closures, and multi-shot for free.

Independently, CPS is the representation a compiler backend needs, so the pass is not throwaway the way an interpreter-only mechanism would be.

## Decisions

| Question | Decision |
|----------|----------|
| Row elements | Effect labels, not operations |
| Duplicate labels | Allowed — Koka's scoped rows |
| Subtyping | None. Row polymorphism with unification |
| Inferred rows | Open (fresh tail variable) |
| Written rows | Closed |
| Unconstrained row at `resolve` | Defaults to empty |
| `run` | Statement |
| `resume` | Statement; checked against the operation's return type |
| Handler arms | Checked outside their own handler |
| `typeof` | Prints the row |

### Rows

```ocaml
type row =
  { labels : string list          (* effect names; duplicates significant *)
  ; tail : row_var ref option     (* None = closed, Some = open *)
  }
```

Effect labels rather than operation names, because `handle exception` discharges the whole effect — there is no syntax for discharging one operation and leaving a sibling outstanding. This requires a `handle` clause to implement **every** operation its effect declares; make that a checked error.

Duplicate labels are what make nested handlers for the same effect work: `handle exception` peels *one* occurrence, so two nested `exception` handlers are distinguished rather than the inner one silently discharging both. Order is irrelevant between distinct labels; duplicates are preserved.

This diverges from the Rust bootstrap, which rows over operation names (`type_checker.rs` inserts the callee into the row).

### Unification, not subsumption

Koka's design is row polymorphism *instead of* subtyping, and duplicate labels are precisely what let unification alone suffice. Unifying `{exn | r₁}` against `{r₂}` instantiates `r₂ := {exn | r₃}` rather than failing, which is what lets a pure function be passed where an effectful one is expected — the ergonomics of subsumption without a subtyping relation or coercion insertion.

Row unification is by rewriting: to unify `{l | r₁}` with `r₂`, rewrite `r₂` into the form `{l | r₂'}` and continue with `r₁` and `r₂'`. It fails when `r₂` is closed and has no `l`.

If this proves too strict in practice, add widening at call sites later. Going the other direction — removing subtyping once inference depends on it — is much harder.

**Call sites diverged from this, and the reason is the CPS pass rather than the type system.** A call requires the callee's row to be *contained* in the caller's rather than unified with it. Unification is enough for Koka because evidence arity is decided from a function's definition; here the CPS pass reads the annotation the call site inferred, so a row that subsumed correctly still produced a callee annotated with effects it does not perform, and an evidence argument it has no parameter for. Containment leaves the callee's annotation alone. Unification survives in one place — a forward or recursive reference whose row is not yet known — and the rest of the row machinery, including rewriting and duplicate labels, is unchanged. A row the author opened is not such a reference, and [Row Polymorphism.md](Row%20Polymorphism.md) is what follows from telling the two apart.

### Open, closed, and defaulting

A written row precedes the return type — `fn f(): <log> unit` — because type arguments made the trailing position ambiguous: `Array<int>` and `unit <log>` are the same shape, and nothing distinguishes a type argument list from a row. Koka writes them the same way. Printed types follow, so `typeof` reads `(string) -> <logger> unit`.

Inferred function types get an open row. A written annotation is closed, so `fn f(): <> unit` is a contract that `f` is pure; without that rule there is no way to say so.

An unconstrained row variable **defaults to the empty row** at `resolve` time, exactly parallel to unconstrained numeric variables defaulting to `int`. Without this, `typeof(double)` would print `(int) -> <e5> int`. With it, pure functions print no row at all and effectful ones print theirs.

### `resume` and answer types

The whole difficulty in typing `resume` is the answer type — what the `run` block ultimately produces. Because `run` is a statement, that answer type is always `unit`, so there is nothing to thread and no delimited-continuation typing to implement. `resume e` simply checks `e` against the operation's declared return type: `ctl flip(): bool` gives `resume false;`, and `ctl throw(...): unit` gives bare `resume;`.

Two errors worth checking: `resume` outside a `ctl` arm, and `resume` inside a `fn` arm, which auto-resumes and must not also resume explicitly.

When `run` becomes an expression — likely, for `var x = run { ... }` — that is the moment to introduce answer types. The row machinery will already exist.

### Handler arms

Checked like function bodies, with their rows unioned into the enclosing `run`'s row *after* that run's discharge. A `ctl throw` arm that itself calls `throw` therefore propagates to an enclosing handler rather than catching itself, which is both the standard rule and the one that avoids a handler looping into itself.

## A `return` inside a branch

`CPS` carries two continuations, not one. `return` calls the function's; the statement after this one runs under whatever the enclosing construct supplies — a join for a branch, a fresh continuation for a block. They coincide at the top of a body and part company as soon as anything nests.

They used to be one, and a `return` inside an `if` was left as an ordinary return by the evidence-only translation, so its value never reached the continuation and the call produced nothing at all:

```cronyx
fn pick(n: int): int {
    if (n == 0) { return 42; }   // silently lost
    return ask();
}
```

Only a program whose handler was not tail-resumptive could reach it, which is why no fixture had — `effects/recover` is this shape with a `resume`, and passes. `effects/nested_return` is the one that would have caught it. A statement holding a `return` is now converted whether or not anything in it suspends, which is what makes the two continuations differ in the first place.

## A `return` inside an arm

It answers the `run` block, not the function the arm is written in. `Resolve` rewrites every `return v` in a `ctl` or `final` arm into an assignment to the block's temporary followed by a bare `return`, which leaves the arm without resuming and so aborts the run.

An arm declining to resume is how a handler produces a result at all — it is what exceptions, early exit, and a generator that stops have in common — so the value it carries belongs to the block. Koka draws the same line: a clause that does not resume terminates the handled computation and its value is the result.

The block's type governs, exactly as a function's return type does. A `run` standing where a value is wanted takes whatever its arms answer with; one standing as a statement has block type `unit`, so an arm may write a bare `return;` and nothing else, the same rule that rejects `return 5` in a `-> unit` function.

```cronyx
var first_even = run { each() } handle Yield {
    ctl yield(v) {
        if (v % 2 == 0) { return v; }
        resume;
    }
} return (nothing) { 0 };
```

The cost is that leaving the enclosing function from inside an arm cannot be written. Two alternatives that would have kept it were rejected.

Giving `return` its ordinary meaning and adding a second keyword for the block — `answer v` — buys the missing capability at the price of a keyword, and buys nothing for the case that motivated it. Escaping a run reaches the enclosing function whether or not the handler holds a continuation of its own — through that function's continuation in [`return_in_inner_run`](../tests/effects/return_in_inner_run.cx), by unwinding in [`return_out_of_run`](../tests/effects/return_out_of_run.cx) — so what the keyword would add is the arm's own escape and nothing else.

Kotlin-style `return@` labels were rejected for a reason particular to this language. Labels exist because a nested loop or a lambda has no other channel to its enclosing scopes; here that channel is performing an operation, which the row records and inference checks. A label would be a second control path doing the same work untyped. Nothing is left for it to name, either: an arm is lexically bound to the `handle` clause it appears in, so the run it answers is unique, and a label with one possible value is not a label. Should `break` and `continue` ever arrive they may want labels for the ordinary reason, which this decision does not prejudge.

## A `return` that unwinds past an arm

A `run` block whose handler needs a continuation may sit in a function the pass left alone, because handling the effect discharged that function's row. A `return` in the block's body then has no continuation to call: the frames between it and the function are the ones the pass wrote — the arm that resumed, the continuation it resumed into, the joins around them — and none of them is the function it is leaving.

So it stays a `return` statement, and those frames let it through. `Ast.Frame` is what the pass emits for its own functions, and `Interp` gives a frame no answer for `Return_value`; the source function is the nearest closure that catches one. Every frame the unwind crosses runs its `On_unwind` cleanups on the way, so a `defer` armed inside the block or inside the arm still releases.

An arm's own code after `resume` does not run. The continuation left through the function rather than returning, so there is nothing for `resume` to answer with:

```cronyx
ctl tick() {
    defer { print("cleaned up"); }   // runs
    resume 1;
    print("skipped");                // does not
}
```

Koka draws the line in the same place. Its handler `return` clause is documented as not running when the action exits without resuming — that is why `finally` exists, and the tour's `with-file` example is a file handle left open by exactly this mistake. `defer` is the `finally` here.

The alternative was an `Abort` to a scope at the boundary, carrying the value in a mutable temporary. Where that abort lands is the objection: a continuation re-enters every scope it captured and `Interp.under` catches an unwind for each of them, so the boundary scope is re-installed inside the continuation and would catch the abort there — handing control back to the arm and running the sequel that must not run.

[`return_in_inner_ctl_run`](../tests/effects/return_in_inner_ctl_run.cx), [`return_past_arm_defer`](../tests/effects/return_past_arm_defer.cx) and [`return_out_of_run`](../tests/effects/return_out_of_run.cx) are the three shapes: plain, with a cleanup, and with two resumptions where only the second returns.

## How a row prints

Between the arrow and the result, and naming effects rather than operations:

```
(int) -> <io> unit
(int, int) -> <Yield<int>> unit
```

Koka writes an effect in the same place, `(a) -> e b`, and for the same reason: the effect belongs to the arrow, not to what the arrow returns.

**Operations are not what a row holds.** `effect io { ctl emit(…); ctl request(…); }` is one entry however many of its operations a function performs — what a row records is what has to be handled, and a handler covers a whole effect. The four `reflection/typeof_effect_*` fixtures were written against the other guess, listing `<emit, request>` postfix, and one of them contradicted its own comment.

## What each translation costs

Two translations, chosen per effect. **Evidence passing** hands each operation's handler down as an extra parameter; the call is direct and the shape of the surrounding code is untouched. **CPS** rewrites control flow so a continuation can be captured. Only the second is expensive, and only the second restricts where an effect may appear.

An effect takes the second only when some handler for it actually resumes out of tail position. So:

| Handler | Translation |
|---|---|
| all `fn` operations | evidence only |
| `ctl` resuming in tail position | evidence only — bind inversion rewrites it to a return |
| `final ctl` | evidence only, plus an unwind |
| `ctl` otherwise | CPS |

**`final ctl` earns its place here.** It never resumes, so it needs no continuation — only a way out, which is an unwind: `Abort` in the converted tree, an exception in the interpreter, and a jump wherever this is eventually compiled. Costing nothing on the path that does not throw is the usual property of exceptions, and it means the most common effect in a real program — failing — keeps its function's control flow exactly as written.

That is also why a `final ctl` reaches places a resuming handler cannot: inside a loop, inside a function value. Nothing was rewritten, so there is nothing that had to know the shape. `effects/final/in_loop` covers both.

## A loop that suspends

A `while` whose body suspends becomes a recursive continuation: the body's *what runs next* is the loop itself.

```
fn after(x) { … the rest … }
fn again(x) { if (cond) { … body, ending in again() … } else { after() } }
again()
```

Resuming carries on with the next iteration, and resuming twice runs it twice, which is what makes a multi-shot handler work inside a loop. `effects/logic/simple_guard` is the fixture.

## What a `run` block delimits

The body ends the delimited computation rather than continuing the program. Completing it returns to whoever entered it — the `resume` that re-entered it, or the block itself — and what follows the block runs once, after the handler is done.

That is what makes a multi-shot handler behave. Resuming twice runs the body twice and the sequel once:

```cronyx
run { print("saw", choose([1, 2])); } handle logic { … resume x … }
print("done");
```

The body's terminal continuation used to be the rest of the program, so `done` printed once per resumption plus once more. `effects/flip` is multi-shot and did not catch it, because nothing follows its `run` block; `effects/multishot_sequel` does.

Statements after a block stay where they were written rather than being wrapped in a continuation, which is what lets a `return` among them return from the function it is in.

**A `return` out of the block itself is rejected.** Once an operation suspends, the rest of the body is a continuation function, and returning from *that* is not returning from the enclosing function. Travelling back out through the handler that resumed into it is what a continuation is for, and the enclosing function has none — handling the effect discharged its row, so nothing converted it. Saying so beats the alternative, which was answering with whatever the code after the block returned.

## A continuation puts back the frames it was inside

A `run` block and a `defer` are frames on the interpreter's stack. A continuation is the rest of a computation that was inside them, so invoking one has to be inside them again — otherwise an abort raised in it finds nothing to stop at, and a `defer` it passes finds nothing armed.

**It re-enters every frame it captured, whether or not that frame is still live.** The live ones are the case that matters. When an arm resumes, the block it is handling for is still on the stack, because the arm is nested inside it — and that is exactly why an abort was unwinding *through* the arm and taking the statements after its `resume` with it. The arm is outside the delimited computation; the continuation is inside it. Re-entering a live frame puts a catcher between them, so the abort lands in the continuation and the arm gets control back. An ordinary closure re-enters only frames that are gone: one called where it was written must not start catching an abort meant for further out.

Catching there answers for the whole closure body rather than for the part the scope covered, which is enough, because a scope's `on_abort` calls the continuation that follows it. What came after arrives through the catcher rather than being left behind it.

**The capture is dynamic and cannot be lexical.** The suspension is usually inside a function the `run` block called, so no scope encloses it in the source for a pass to find. `Cps` wrapping continuation bodies in the scopes open around them compiles and does nothing. So `Interp` keeps the frames itself and a closure records them, and the tree says which closures are the pass's own rather than the source's. Two constructs exist only after `Cps` for that reason: `Cont`, whose closure re-enters every frame it captured, and `Frame`, which a `return` passes through on its way to the function it is leaving. Both are told from `Fn` by being a different node, not by how they are named.

A `defer` wants that and one thing more. Its guard is a frame like any other and is rebuilt the same way, but its flag is also cleared on the way out and set only where the `defer` was written, which a resumption never reaches. Continuations arm it again, so each pass releases what that pass acquired.

`effects/abort_under_conversion`, `effects/abort_after_resumption` and `core/defer/defer_multishot_abort` are the three shapes, and all three waited on this together.

## Pipeline placement

CPS runs late, after everything that could introduce a call — see [Architecture](Architecture.md) for the full order.

The checker's rows *are* the CPS marking. The Rust bootstrap runs a separate `mark_cps` analysis to recover the same information.

It has to run after `Resolve` in particular, because an operator can be an ordinary function and an ordinary function can perform effects. `a + b` whose `Add` impl performs `logger` is only visibly a call once elaboration has made it one.

Marking should key on **`ctl` reachability, not on a non-empty row**. `fn` operations are tail-resumptive: they resume exactly once with the arm's value, so they are a plain call to the evidence passed in and need no continuation. This is Koka's bind-inversion, and it means `log`- and `ask`-style effects cost nothing at runtime.

Following the discipline the other passes use, the effect constructs (`effect` declarations, `run`/`handle`, `resume`) live in a fragment present in the parsed, desugared, typed, and reflected trees and **absent** from the post-CPS tree — so the interpreter needs no effect support at all, only closures and calls, which it already has.

## Deferred

Handler aliasing, syntax for writing a row variable in an annotation, and whether effect declarations nest are all deferred. None of them block what is implemented.

Explicit static arguments will hit the same ambiguity in expression position, where `pair<int>(1, 2)` and `a < b` cannot be told apart and `a<b` is idiomatic. Nothing decided here helps there; it needs a turbofish-style marker or inference-only type arguments.
