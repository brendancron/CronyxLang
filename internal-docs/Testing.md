# Testing

`cx test` runs the `@test` functions in a package: those in `tests/`, and any written inline beside the code.

(This is a package's own `tests/`. The compiler's golden-file suite at the repo root is also called `tests/` and belongs to `dune test`; the two share a name and nothing else.)

## A test file is a consumer

`cx new` puts the example test in `tests/`, which is the default place for one. A file there is not part of the package — it is compiled *against* it, reaching it by the name the manifest gave it:

```cronyx
import "hello" as pkg;

@test
fn greets() {
    assert(pkg.greeting() == "Hello, World!", "the greeting changed");
}
```

so the boundary is the one the loader already enforces. An `import "../src/main.cx"` from a test file is refused for reaching outside its root, exactly as it would be from any other package. What crosses is the dependency name, and the package's declarations arrive through its artifact already mangled.

Each file in `tests/` is its own program, as a Rust integration test is its own crate: one that fails to compile is reported alongside the others rather than standing in front of them. The program a test file runs in holds the package's *declarations* — its top-level `meta` blocks and `derive`s among them — without its top-level statements — a test links the library, not the program, so `main.cx` does not re-run once per test file.

An inline `@test` still works and still sees what the package does not export. That is the split Rust draws between `#[cfg(test)] mod tests` and `tests/`: inline for an invariant with no public surface, `tests/` for the contract a consumer depends on.

Nothing in `tests/` reaches an artifact, because it was never part of the package. `cx publish` therefore ships none of it — a consumer could not build it in any case, since a package's test-only dependencies are not in their graph.

```cronyx
fn add(a: int, b: int): int { return a + b; }

@test
fn adds() {
    assert(add(1, 2) == 3, "1 + 2 is 3");
}
```

```
ok   adds
FAIL reports_its_output
  1 + 2 is not 4
  | printed by a failing test

2/3 passed
```

## A failure is an effect, so isolation is free

The prelude declares one effect and one function:

```cronyx
effect Assertion {
    final ctl failed(msg: string);
}

fn assert(cond: bool, msg: string) {
    if (!cond) { failed(msg); }
}
```

`final ctl` is what makes this work. Its handler cannot resume, so no value is ever owed and the call is usable wherever it stands — which is why `assert` needs no bottom type and why a failure leaves the block it is in. Each test is wrapped in its own `run`:

```cronyx
run {
    the_test();
} handle Assertion {
    final ctl failed(msg) { … }
}
```

so a failure abandons that test and the next one still runs.

A crash that is not an effect — an index out of range, a division by zero — is what that does not cover: it ends the program, and with it the rest of the file's tests. So each test runs in a process of its own, as `cargo nextest` does: a file is compiled once, every test's wrapper is guarded by which test the process is for (a builtin under a name no program can write), and `cx` forks one child per test and reads what it printed back through a pipe. An index out of range ends that test and nothing else (`cx/test/packages/crashing_test`), and a child that ends before reporting is a failure. It is the strongest isolation there is and it asks nothing of the language. Runtime errors becoming an effect a handler can catch is wanted anyway, for programs generally, and would give an in-process runner the same guarantee; the two do not compete.

This is the part worth keeping in mind when comparing to other runners. `cargo test` catches a panic with `catch_unwind`, which is wrong under `panic=abort`; `go test` uses `runtime.Goexit`, which silently fails if a test fails from a goroutine it did not start; `cargo nextest` gives up on both and forks a process per test. Cronyx gets the same isolation from the effect system, statically — a test's row says it may fail.

## Discovery is a walk, not reflection

`Discover.carrying "test"` walks the program for `` `Attributed `` wrapping a `` `Fn ``, after metaprocessing — so a test a `meta` block generates is found under the name it was given (`cx/test/packages/generated_tests`). Nothing calls a test, so nothing would reach one; the walk is run with every `@test` function as a root instead, after every loaded module's top-level `meta` has run (`Metaprocess.program ~rooted_by`, `Pipeline.rooted`). A test file's run takes the tests declared in that file.

That is the stand-in for a test root: a file that reflects the package with `moduleof`/`packageof` and generates a call per `@test`, which would make discovery a library ([TODO](TODO.md), "When a declaration query runs").

It has to be a walk. Attributes belong to a *declaration*, and `typeof` takes a *value* — a function value's type is `(int, int) -> int`, which names no declaration to look an attribute up under. So reflection cannot reach a function's attributes however much is added to `TypeShape`, and the walk runs on surface syntax because `Desugar` is where the wrapper is unwound.

A test takes no parameters, which is checked rather than assumed: it is called by name and there is nowhere for an argument to come from.

## Output is captured by the host, not by the program

`print` is a builtin already parameterized by where it writes — `Builtins.env ~out` — so `cx test` passes a buffer instead of `print_string`. The runner marks the stream with lines beginning `\x1e`, and whatever a test printed lands between the line that opened it and the line that closed it. A passing test's output is dropped; a failing test's is replayed under it.

That is why making `print` an algebraic effect is *not* a prerequisite for any of this, though it remains worth doing for its own reasons — see Open.

## Settled

**The runner is synthesized, not written.** `cx test` appends one `run` block per test to the linked program and compiles the result. Those blocks are what the metaprocessing walk starts from, so a test is metaprocessed only if it runs, and the walk runs from the package root, as `cx run`'s does. There is no test harness written in Cronyx to keep in step with the tool, and nothing is generated on disk.

**`cx test` exits 1 when anything failed**, and prints `no tests` rather than succeeding silently on a package with none.

## Open

**The boundary is the loader's, not the type system's.** A test file cannot reach into `src/` by path, but everything the package declares is visible once it is reached by name: there is no export marker yet, so `tests/` checks the contract by convention rather than because the compiler stops it. When visibility lands, this is where it bites first.


**`assert` takes its message.** `assert(x == 1, "x is 1")` is what is expressible today. pytest's rewritten asserts — reporting the subexpression values of a bare `assert x == 1` — cannot be had by expanding `assert` in a `meta` block: a meta block sees only what is known at compile time, and `x` is a run-time value, which does not cross into one. Getting it needs the compiler to reify the argument's *source* into the message, which `Source.expr` can already print. That is one pass away and it is the single largest improvement available here.

**`print` as an effect.** Then a test could handle its own output rather than the host capturing it, and the row would say which functions print. The cost is not small: 332 fixtures call `print` and 50 files write explicit effect rows, so every one of those signatures changes, and an implicit top-level handler has to be designed for programs that do not write one. Worth doing, worth designing first, and not required by anything above.

**No property testing, no snapshots, no doctests.** In that order of value. `stdlib/` has documentation and nothing checks its examples, which is the cheapest of the three to fix and the one that stops documentation rotting.
