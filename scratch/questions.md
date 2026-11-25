# Open questions

## 2. A suspending body in a `fn` (or tail-resumptive `ctl`) arm

**Found while fixing #160.** #160 fixed `final ctl` arms whose bodies suspend. A
`fn` arm of an evidence-passed effect is still compiled as a plain function, so
if its body suspends, the performer gets back `unit` instead of the value:

```cx
effect Get { fn get(): int; }
fn nap(): int { sleep(Duration.milliseconds(1)); return 7; }
fn use_it(): int {
    return run { get() + 1 } handle Get { fn get() { return nap(); } };
}
```

This fails at run time with "Operator is not defined for unit and int." The
performer of a `fn` operation was compiled for a direct answer, so the arm
can't hand the answer over later.

**Options.**

- **A. Reject it in the checker** (recommended): a `fn` arm, and a `ctl` arm
  reached as tail-resumptive, may not perform a delimited effect. The error suggests `ctl`. This matches what the declaration
  promises: `fn` means "answers in place".
- **B. Make it work**: the operation's performers would need continuations
  whenever any handler's arm suspends, which defeats choosing `fn`.

## 3. `scratch/inline.md` — how the plan covers `ctl`

**Found.** `inline.md` says it is a plan to replace algebraic effects, but it
never mentions effects again. The argument it builds toward is that a handler
becomes a static fn parameter, and inlining it gives evidence passing at no
runtime cost. That covers `fn` and `final ctl` operations, but not a resumable
`ctl`:

```cx
effect Logic { ctl choose(options: Array<int>): int; }
```

Resuming more than once is a continuation, and inlining can't express that.

**Options.**

- **A.** Drop multi-shot resumption from the language.
- **B.** Keep CPS for `ctl`, and use inlining for everything else.

User marked this todo on 2026-11-18, to decide once the doc is further along.

## 7. Two top-level functions with the same name crash the compiler

**Found.** Cronyx has no overloading (`internal-docs/Math.md:36`), and a
duplicate method is reported properly ("Type 'P' already has a method 'add'").
A duplicate top-level function is not — the compiler dies with an uncaught
OCaml exception and exit 2:

```cx
fn greet() { print("Hello"); }
fn greet(name: string) { print("Hello, " + name); }
greet("x");
```

```
Fatal error: exception Invalid_argument("List.iter2")
```

The second declaration is not rejected, so something later pairs the call's
arguments with the wrong declaration's parameters via `List.iter2`.

**Options.**
- **A. Reject the duplicate at declaration** (recommended), with the same shape
  as the method error: "'greet' is already defined, at file:1." Add an `.err`
  fixture under `tests/core/` for it.
- **B. Only guard the `List.iter2`** so it reports an arity error — fixes the
  crash, but the message points at the call, not the real cause.

## 10. `Algebraic Effects.md` says a run's answer type is always unit

**Found** checking the shape of `ctl`. `internal-docs/Algebraic Effects.md:217`
says "Because `run` is a statement, that answer type is always `unit`". The same
doc's "A `return` inside an arm" section (line 246) and the compiler both treat
`run` as an expression whose arms can answer it:

```cronyx
var a = run { var n = ask(); n * 2 } handle Ask { ctl ask() { resume 5; return 100; } };
print(a);   // 100
```

**Options.**

- **A. Rewrite line 217 to match** (recommended): `resume e` checks `e` against
  the operation's type; the arm's `return` checks against the run's type.
- **B. Leave it** if `ctl` is being replaced anyway.

## 11. Docs out of date after S5b (one `__root`, static `Display`)

**Found** by the S5b agent, not edited (docs are edited only when asked):

- `internal-docs/Architecture.md`: the Desugar section, and "The root runs every program under `block_on`".
- `internal-docs/IO.md:34`.
- `internal-docs/Algebraic Effects.md:62`.
- `internal-docs/Type System.md:124` ("the row `__root` hands a statement"): the root now takes the whole top level as one body.
- `internal-docs/Stdlib Plan.md:39,41,49`: describe a deriver per trait and `derive Display`; printing is now reflective, with no derivers (I242), and a type with no impl prints its structure (I236 replaced).
- The reflection and metaprocessing docs (`Reflection.md`, `Metaprocessing.md`) do not mention `implements(T, Trait)` (I243).
- `docs/docs/language-metaprogramming/deriving.mdx`, `reflection.mdx`: may show `derive Display`/`derive Debug`, which no longer exist (I242). Not checked.

- Found after S5c: `internal-docs/Async.md`, `IO.md`, `Net.md`, `Stdlib Plan.md`, `stdlib.txt`, `Type System.md`, `CPS Migration.md` (`Iter`'s close row, the root), `Architecture.md` (the meta root), and `docs/docs/language-effects/async.mdx` describe the old async/io shapes (I251–I260).

**Options.** A. Rewrite them now as built (recommended: I236 and I245 are settled). B. Wait for the rest of the S5b review.

## `module.Trait.op` loses a generic operation's type parameter

Found 2026-11-24 while adding the ambiguous-operation error. With `signal.cx` declaring
`trait Signal { @abort fn stop<T>(reason: String): T; }` and `import "signal";`:

```cronyx
fn halt(): Int { return signal.Signal.stop("no reason"); }
```

fails with `Unknown type 'T'.` at `signal.cx:1:51`, while `signal.stop("no reason")` and, after
`import { Signal } from "signal";`, `Signal.stop("no reason")` both work. The three-part form seems to reach the
operation without instantiating its own static parameter `T`.

Options: (a) fix it, so `module.Trait.op` works like `Trait.op` (recommended: it is the natural way to pick one
trait when a module has two with the same operation); (b) make `module.Trait.op` an error pointing at the
named-import form.

## A named handler type cannot `discontinue`

Found 2026-11-24 by the agent building the misplaced-`discontinue` error. In a named handler type
(`type T impl EffectHandler<E, R> { fn op(…, resume) { discontinue(resume); } }` used with `with T`),
`discontinue(resume)` passes the new compile check but fails at run time with "Only a handler's method can
discontinue its continuation.": the library transform (`__tx_discontinuing` in stdlib/core/Transform.cx) only
rewrites `discontinue` in inline handlers' records, never in a named handler's impl methods. This predates
today's change.

Options: (a) make the transform rewrite named handlers' methods too (recommended: named and inline handlers
should behave the same); (b) make `discontinue` in a named handler a compile error until then.

## Two smaller gaps from the same work

- A lambda written inside a plain operation's arm that performs a `@ctl` effect is not caught by the new
  "plain operation's handler must return" rule (the lambda's effects are its own). Precheck had the same gap.
- That rule's error renders as "Meta error" rather than "Type error", because it is raised while the walk's
  meta-driven check runs; the position and message are right.

## An empty effect row prints as nothing in a mismatch

**Found while updating `docs/docs/language-basics/structs.mdx`.** A field typed
`(Int) -> Unit` is a pure function type, so a lambda that prints doesn't fit it.
The rejection is right, but the expected row prints as an empty string:

```cronyx
type Handler { apply: (Int) -> Unit }
var h = Handler { apply: (n: Int) => { print(n); } };
```

`Type error: Expected a function performing , got one performing <Console|_>.`

The docs example was changed to return an `Int` instead, so nothing in the docs
depends on this.

**Options.**

- **A.** Print the empty row as `<>` or say "a pure function" (recommended:
  "Expected a function performing nothing, got one performing <Console|_>.").
- **B.** Leave it.

## Two `throw` gaps found while writing the recursion fixtures

**1. `throw` without importing `Throw` reaches Verify.** With only `attempt` imported:

```cronyx
import { attempt } from "std/core/Error";
fn check(n: Int) {
    if (n < 0) { return throw("negative"); }
    return n;
}
print(attempt(() => check(4)));
```

fails with "Verify error: A call passes 4 argument(s) to a function of 1." at `throw`. Importing `Throw`
too prints `Ok(4)`. A Verify error is the compiler's own fault, so either `throw` should not resolve
without `Throw` in scope ("Undefined function 'throw'"), or it should work. Recommendation: make an
operation resolve only through its imported trait, and report the missing import at the call.

**2. `throw(...)` as a statement is "not settled".** `if (n < 0) { throw("negative"); }` fails with
"This is not settled when its statement ends: its type is (String) -> <Throw<String>> T, and nothing
fixes it. Write the type." even with the function's return written. `return throw(...)` works.
Options: **A.** default an operation's unsettled result type to `Unit` (or the never type, when there
is one) where the call is a statement, as nothing reads it (recommended); **B.** leave it, and say
"write `return throw(…)`" in the message.

## `run … return (x) { … }` is gone from the docs

**Found while updating `resumable-effects.mdx` and `generators.mdx`.** Both
taught a `return` clause on a `run`, run only when the body finishes on its own:

```cronyx
var first = run { each() } handle Yield {
    ctl yield(v) { return v; }
} return (nothing) { 0 };
```

The branch has no such clause. The pages now put the fallback as the body's
last expression, which behaves the same way (an arm that answers skips it):

```cronyx
var first = run<Int> {
    each();
    0
} handle<Yield> {
    fn yield(v, resume) { return v; }
};
```

**Options.** A. Leave it gone; the body's last expression is the return clause
(recommended). B. Bring the clause back, and restore the pages.

## `typeof` of an unannotated function: the error talks about static params

**Found while updating `reflection.mdx`.** An unannotated function is generic, so
`typeof` of it is rejected, which is fair, but the message reads as if the
function had static parameters:

```cronyx
fn double(n) { return n * 2; }
print(typeof(double).name);
```

`Type error: 'double' is generic and its static params are not settled here; write them or give it a type: {_ = ?}.`

The page now annotates `double` and `greet`.

**Options.** A. For a function generic only through inference, say "'double'
is generic; annotate it, or take the type of a call" and drop `{_ = ?}`
(recommended). B. Leave it.
