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
