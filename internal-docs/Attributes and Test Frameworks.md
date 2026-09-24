# Attributes and test frameworks

[Attributes.md](Attributes.md) is what an attribute is in the compiler today and [Testing.md](Testing.md) is how a failed assertion becomes an effect. This is the shape the two grow into: attributes as ordinary values, and a test framework written in Cronyx rather than in the compiler.

The claim underneath it: *find every declaration marked X and generate a table from it* is one problem, not several. A test runner is the first instance. A routing table, a serialization registry, a benchmark harness and a CLI dispatcher are the same instance wearing different attributes. If the runner is compiler code, each of those is another compiler patch.

## An attribute is a value

```cronyx
@Test
fn adds() { … }

@Test { group: "parser.recovery" }
fn recovers_unclosed_brace() { … }

@Route { path: "/users", method: Get }
fn list_users() { … }
```

`@` takes a value of a declared type. There is no attribute namespace beside the type namespace, no separate grammar for arguments, and nothing about `Test` that the prelude could not have written in Cronyx.

What that buys is what a declaration always buys. An attribute naming no type fails to resolve, so `@Tset` is an error rather than something silently inert. Fields are checked against a shape, so an argument in the wrong position is caught where it is written instead of misread by a deriver later. And a deriver matches a type rather than destructuring a list of variants by a convention nothing records.

Java, C# and Kotlin all describe an annotation by its type. Rust does not — `#[foo(bar = 1)]` is an inert token tree meaning whatever the macro reading it decides — and the cost shows up as every proc macro shipping its own argument parser and its own error messages.

## An attribute must be reifiable

Records, enum variants, arrays, and nestings of those. Not a closure, an effect, or a reference.

The rule is not aesthetic. An attribute value is written back into source — see [Reify.md](Reify.md) — and `cx build` marshals it into a `.cxa` that a *different* invocation of the compiler reads. A value that cannot survive both crossings cannot be an attribute, whatever else it can do.

This is the same line Java draws at compile-time constants, enums and class literals, and C# at constant expressions, and for the same reason both times: the value is encoded in metadata that outlives the compilation that produced it. The languages where an attribute is an arbitrary object — Python's decorators, Ruby — have no such boundary to cross.

Defaults are a prerequisite rather than a nicety. `@Test` with no braces is a literal with every field defaulted, so struct field defaults — declared in the type, omitted in the literal — are load-bearing for this whole direction. They also interact with reification: a reified value either writes back every field, or defaults must be stable across compilations.

Within that line, values are *computed*, not merely written out. The metaprocessor already runs the whole pipeline, so an attribute may be built by a function called from a `meta` block the way any other static value is.

## A test is a function carrying `Test`

Nothing else marks it. `Test` is a type in the prelude, an ordinary function is a test because it carries one, and a function carrying `Route` is a route by the identical mechanism.

Test functions compile like any other function. There is no attribute-directed removal pass: what is unreachable from a program's root is dropped because it is unreachable, and a test that no longer ships was never special-cased to make it so.

## A test's name is its path

A test is named by the unit it lives in and whatever finer structure it declares:

```
parser.recovery.recovers_unclosed_brace
```

Selection is then a filter over that name. Worth being explicit, because it is easy to reach for a feature here: **Rust has no grouping feature.** `cargo test parser::` works because a test's name contains its module path and the filter is a substring match. The hierarchy already existed; the runner just stopped throwing it away.

**How a filter is written.** A bare argument selects by path, matched segment by segment, and the fuzzy case gets its own flag:

```
cx test parser.recovery      # a path: this unit, this group
cx test -k unclosed          # substring, anywhere in the name
```

Segment matching is what stops `parser` from selecting `superparser.x`. This is pytest's split — a positional path, `-k` for a name fragment — and it leaves room for `--with`, `--without` and a second positional filter without renegotiating what a bare argument means. Its cost is that today's `cx test adds` becomes `cx test -k adds`, which is friction on the common path if most selection is by remembered name.

*Options considered.* A trailing `.` marking a prefix (`cx test parser.`) reads as punctuation carrying invisible meaning, and was dropped for that. Globs (`parser.*`) need no new concepts but get eaten by the shell before `cx` sees them. A regex, as `go test -run` takes, subsumes everything and commits the CLI to a dialect forever.

## What `Test` holds, and what a tag is

Two axes, and the survey is unusually consistent: JUnit, pytest, ExUnit, RSpec, xUnit, NUnit and Catch2 all separate *where a test lives* from *what it is labelled*, and none of them merges the two. Only Rust and Go have neither, substituting `#[ignore]` and `testing.Short()` — one hard-coded tag each, which is what a framework looks like just before it grows tags properly.

`Test` is a struct with defaults, holding only what the runner acts on — which for now is nothing. It starts bare and gains a field when the runner has a reason to read one. A field that is pure metadata is a tag that got promoted for no reason: `speed` would only earn its place if the runner ordered by it or derived a timeout from it, and it does neither.

```cronyx
@Test
fn adds() { … }

@Test
@Tag { name: "slow" }
fn recovers_unclosed_brace() { … }
```

`Tag` belongs in the prelude as a general facility, not as `TestTag`: tagging is not a testing idea, and naming a mechanism for its first consumer is how `BenchTag` and `RouteTag` get written a year later. Selection works over any attribute, so nothing about tags is privileged in the test runner.

A tag can also be its own declared type — `struct Slow {}`, `@Slow` — which makes a typo fail to resolve and a value checked. Java arrived at exactly this by the long way, as composed annotations (`@SlowTest` meta-annotated with `@Tag("slow")`), and it is the right escalation for an axis durable enough to deserve a declaration. The open form stays the default because declaring a type per axis is real friction, and pytest and RSpec both show a loose bag is pleasant in practice.

There is no field for finer structure inside a unit. The unit path is the hierarchy and a file is the thing you split — which is how Rust and Go live, and the pressure for anything more only appears in large test files. A `group` keyword introducing a block was considered and rejected outright: a keyword existing for one library concern is rent the language pays forever, and benchmarks or routes wanting the same thing would either overload it or grow a second one.

## Structure comes from units, not from annotations

A label describing a whole file was usually a directory. `slow` and `flaky` vary test by test and are written where they apply; `integration` does not vary, and saying it once per file is a question about *where the file is*.

So tests are organised the way the code is:

```
src/
  parser.cx
  parser/
    recovery.cx
  lexer.cx
tests/
  integration/
    round_trip.cx
```

```cronyx
// src/parser/recovery.cx

@Test
fn unclosed_brace() { … }               // parser.recovery.unclosed_brace

@Test
@Tag { name: "slow" }
fn deeply_nested_recovery() { … }       // parser.recovery.deeply_nested_recovery
```

and selection follows the same shape:

```
cx test parser                # the parser unit and everything under it
cx test parser.recovery       # one unit
cx test integration           # everything in tests/integration
cx test --without slow        # the cross-cutting axis, the only thing a path cannot say
cx test -k unclosed           # a remembered fragment of a name
```

Nothing is inherited, because nothing needed to be. Every framework in the table above has a way to state a label once per file — `@moduletag`, class-level `@Tag`, `pytestmark`, RSpec's enclosing `describe` — and each exists because tests are grouped by *class* or *describe block*, where the file is incidental. When the unit path is the hierarchy, the same grouping is expressed by where a file sits, which is a decision made once and visible in a directory listing rather than repeated in a header.

Go and Rust both land here. Go has no test metadata at all and separates by file and directory; Rust's `tests/` is the same idea with a build boundary attached.

**If some future axis genuinely cannot be a directory** and still must be declared once per file, the parked answer is a target prefix on the attribute — Kotlin's `@file:JvmName(…)`, C#'s `[assembly: …]` — which needs no keyword, no second attribute form, and no invisible sticky state like D's `@safe:`. Nothing in the test design needs it now.

## Inline tests see internals; `tests/` sees the package

Both, because they answer different questions. This part is built — see [Testing.md](Testing.md) for what `cx test` does with each.

An inline `@Test` sits beside what it tests and reaches package internals. That is right for an invariant with no public surface — a cache's eviction policy produces correct output right up until it doesn't — and wrong for checking the contract a consumer depends on, since insider access means the test can never notice a bad API.

`tests/*.cx` compile as consumers. A test file reaches the package by name through its artifact, exactly as a downstream package would, so the boundary is the one [Modules.md](Modules.md) already enforces — an import never leaves its root — rather than a new visibility concept invented for tests. Nothing in `tests/` enters an artifact or a published archive, because it was never part of the package.

What that boundary does *not* yet do is hide anything. There is no export marker, so every declaration a package makes is visible once it is reached by name, and a `tests/` file checks the public contract by convention rather than because the compiler refuses. Visibility lands here first when it lands.

Every language that chose only the outsider form later built an escape hatch back in: Java mirrors package names across `src/test/java`, Swift has `@testable`, C# has `InternalsVisibleTo`. Three admissions that the boundary alone was too strong. Rust ships both from the start, and that is the model here.

Each file in `tests/` is its own program, as a Rust integration test is its own crate: a test file that fails to compile takes only itself down, and per-file programs are the obvious boundary if runs are ever parallelised. The cost is one link step per file rather than one for the directory.

`cx publish` leaves `tests/` out of the archive. A consumer could not build it — dev-dependencies are absent from their graph — so shipping it is bytes that can never compile. Cargo includes them, but Cargo publishes source that is rebuilt in full; `cx` publishes something a consumer links against. A manifest opt-in would be the answer if someone wants an archive that can be verified standalone.

`tests/` is also what makes `[dev-dependencies]` meaningful: a test-only library attaches to a target that no consumer builds. [Package Manager Plan.md](Package%20Manager%20Plan.md) parks dev-dependencies until a feature needs them, and this is that feature.

## Discovery is reflection over declarations

`typeof` takes a *value*, and a function value's type is `(int, int) -> int` — it names no declaration, so there is nothing to look an attribute up under. No amount of detail added to `TypeShape` closes that gap; it is the wrong end of the arrow.

So reflection reaches declarations: a meta-time handle carrying a qualified path, the attribute values, the signature, and the function itself as a callable. A closure could never be reified, but a *reference to a declaration* is a name, and a name writes back into source cleanly.

Metaprocessing generates declarations, so a query that enumerates them while a `gen` is still producing them sees an unfinished program, and the answer would otherwise be whatever traversal order fell out. Nothing depends on choosing yet; the options and the leading candidate are in [TODO.md](TODO.md).

## The runner is a library

Given the above, `cx test` is a meta function: ask for every declaration carrying `Test`, wrap each in its own

```cronyx
run {
    the_test();
} handle Assertion {
    final ctl failed(msg) { … }
}
```

and emit the table. The isolation argument does not change and is not repeated here — `final ctl` is why a failure abandons one test and leaves the next standing, and that lives in [Testing.md](Testing.md).

What changes is who can write one. A benchmark harness that collects `@Bench` and times each call, a router that collects `@Route` and emits a dispatch table, a CLI that collects `@Command` — none of them need a compiler that knows their name.

## Where this stands

Attributes are a name and a list of literal arguments; `Discover.carrying` walks the program after metaprocessing — with every function carrying the attribute a root, so a generated one is found — for functions carrying one, and the runner in `cx` synthesizes the wrappers. Names are matched and reported by their leaf, so the namespace is flat and the filter is a plain substring. `tests/`, dev-dependencies, declaration reflection, and attributes-as-values are design, as is struct field defaults, which the rest of it rests on. One decision is deferred rather than made — when a declaration query runs relative to generation — and it is in [TODO.md](TODO.md) with what it is waiting on.
