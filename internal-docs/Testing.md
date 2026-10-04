# Testing

`cx test` runs the `@test` functions under a package's `tests/`, recursively. `@test` does nothing by itself: it is what the standard test framework, `std/test/Test`, looks for.

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

Nothing in `tests/` reaches an artifact, because it was never part of the package. `cx publish` therefore ships none of it — a consumer could not build it in any case, since a package's test-only dependencies are not in their graph.

```cronyx
import "tested" as pkg;

@test
fn adds() {
    assert(pkg.add(1, 2) == 3, "1 + 2 is 3");
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

A crash that is not an effect — an index out of range, a division by zero — is what that does not cover: it ends the program, and with it the rest of the file's tests. So each test runs in a process of its own, as `cargo nextest` does: a file is compiled once, the program asks `__test_selected()` which test the process is for, and `cx` forks one child per test and reads what it printed back through a pipe. An index out of range ends that test and nothing else (`cx/test/packages/crashing_test`), and a child that ends before reporting is a failure. It is the strongest isolation there is and it asks nothing of the language. Runtime errors becoming an effect a handler can catch is wanted anyway, for programs generally, and would give an in-process runner the same guarantee; the two do not compete.

This is the part worth keeping in mind when comparing to other runners. `cargo test` catches a panic with `catch_unwind`, which is wrong under `panic=abort`; `go test` uses `runtime.Goexit`, which silently fails if a test fails from a goroutine it did not start; `cargo nextest` gives up on both and forks a process per test. Cronyx gets the same isolation from the effect system, statically — a test's row says it may fail.

## Discovery is a library

`cx test` finds nothing itself. For each file under `tests/` it writes a small program under `target/test/` that imports the file and hands it to `std/test/Test`:

```cronyx
import { collect, run_tests } from "std/test/Test";
import "../../tests/adding" as suite;

meta { collect(moduleof(suite)); }
run_tests(__test_names(), __test_run);
```

`moduleof(suite)` reflects the file ([Modules](Modules.md), decision 2): its top-level declarations with their attributes, written or generated. Asking is a reference to the file, so its top-level `meta` runs first and a test it generates is among them (`cx/test/packages/generated_tests`). `collect` keeps the functions carrying `@test` and generates `__test_names()` and `__test_run(index)`, one call per test. `run_tests` runs the one this process is for, or with none chosen lists them all, which is how `cx` learns how many processes to start.

A test takes no parameters. `collect` checks rather than assumes, and reports one that does at its declaration with `compile_error`: it is called by name and there is nowhere for an argument to come from.

An HTTP framework collecting `@route` functions is the same shape: a `meta` block reflects the modules it is given and generates what the attribute asks for.

## Output is captured by the host, not by the program

`print` is a builtin already parameterized by where it writes — `Builtins.env ~out` — so `cx test` passes a buffer instead of `print_string`. The runner marks the stream with lines beginning `\x1e`, and whatever a test printed lands between the line that opened it and the line that closed it. A passing test's output is dropped; a failing test's is replayed under it.

That is why making `print` an algebraic effect is *not* a prerequisite for any of this, though it remains worth doing for its own reasons — see Open.

## Benchmarks judge growth, not speed

`cx bench` is `cx test`'s machinery pointed at `benches/` and `@bench`: one program per file, `std/test/Bench` generating the calls from `moduleof`, each benchmark in a process of its own. What differs is what a run is held to.

A single timing is a fact about one machine on one afternoon, and a gate built on it is either loose enough to catch nothing or tight enough to fail on a busy runner. How a benchmark *grows* is a fact about the program. So each one runs at its size `n` and at `4n`, and the report is the exponent `k` in `n^k` for time and for peak memory. A benchmark declares the class it belongs to, `@memory("constant")` for a loop of calls that each let go of what they made, and fails if it grows half a power faster. A leak shows up as memory `n^1` where `n^0` was declared, whatever the machine.

Memory is the major heap's peak above what the program needed once loaded, measured in the child after compacting, so it counts what the run kept rather than what it passed through. Below 10ms and 1MB a ratio is noise, so each measurement is floored there.

## Settled

**Tests live in `tests/`.** A `@test` written in `src/` is not looked for. A manifest key naming a different folder is the expected way to change that, and is not built.

**`cx test` exits 1 when anything failed**, and prints `no tests` rather than succeeding silently on a package with none.

## Open

**The boundary is the loader's, not the type system's.** A test file cannot reach into `src/` by path, but everything the package declares is visible once it is reached by name: there is no export marker yet, so `tests/` checks the contract by convention rather than because the compiler stops it. When visibility lands, this is where it bites first.


**`assert` takes its message.** `assert(x == 1, "x is 1")` is what is expressible today. pytest's rewritten asserts — reporting the subexpression values of a bare `assert x == 1` — cannot be had by expanding `assert` in a `meta` block: a meta block sees only what is known at compile time, and `x` is a run-time value, which does not cross into one. Getting it needs the compiler to reify the argument's *source* into the message, which `Source.expr` can already print. That is one pass away and it is the single largest improvement available here.

**`print` as an effect.** Then a test could handle its own output rather than the host capturing it, and the row would say which functions print. The cost is not small: 332 fixtures call `print` and 50 files write explicit effect rows, so every one of those signatures changes, and an implicit top-level handler has to be designed for programs that do not write one. Worth doing, worth designing first, and not required by anything above.

**No property testing, no snapshots, no doctests.** In that order of value. `stdlib/` has documentation and nothing checks its examples, which is the cheapest of the three to fix and the one that stops documentation rotting.
