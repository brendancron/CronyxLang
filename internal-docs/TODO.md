# Open questions

Decisions deferred deliberately, with enough context to pick them up cold. A line leaves when it is answered — in the document that owns the subject, not here.

## When a declaration query runs

Owner: [Attributes and Test Frameworks.md](Attributes%20and%20Test%20Frameworks.md)

Metaprocessing generates declarations, so a `gen` can emit a function carrying `@Test`. A meta block that enumerates declarations therefore sees a different program depending on when it runs, and nothing in the source says when that is — it falls out of the walk order, so reaching a module earlier could change which tests exist.

The three answers in the wild: rounds to a fixpoint, as Java's annotation processors do; a hard phase split where generation finishes before any query runs and generated code is invisible to other generators, as C# source generators do; or no answer at all, as Rust proc macros, which is why that ecosystem builds registries at link time instead.

What the walk does is neither: a generated declaration is visible to every block the walk reaches after the one that generated it, and a use it reaches before is an error ([Metaprocessing.md](Metaprocessing.md#generated-names)). That answers a single name; it does not answer a query over all of them.

The direction is that a query is asked of a module, not of the program. A module is reflected the way a type is ([Modules.md](Modules.md), decision 2): `moduleof(m)` gives a `Module` record of its top-level declarations with their attributes, and asking is a reference to the module, so its top-level `meta` runs first and the answer includes what it generates. A collector names the modules it reads, so nothing about ordering is new and a module nobody asks about is never metaprocessed. Zig's `zig test` works this way: tests are found in what the test root reaches.

`cx test` then runs a dedicated test root, which reflects the package — recursively, through its directories — and generates a call per `@test` it finds; reflecting a module is the walk's first reference to it, so that is when the module is metaprocessed. A test run is a root like any other — a file that reflects the modules under test and generates a call per `@test` — with `cx test` supplying the obvious root (every file of the package and `tests/`) when there is none, and discovery moving out of the compiler into a test library. An HTTP framework collecting `@route` functions is the same shape. Not built: `moduleof`, the test root, and discovery as a library.

Until then, `cx test` runs the walk with every `@test` function as a root, after running every loaded module's top-level `meta`, and finds tests on what it produced ([Testing](Testing.md)).

## What "generic" names

Owner: [Type System.md](Type%20System.md)

One word carries three meanings, and the rename of comptime params to static params left the third one wrong.

`Types.Generic` and the helpers around it — `has_generic`, `subst_generic`, `match_generic`, `Type_mono`'s template table — are a type variable `resolve` decided is quantified rather than not-yet-known. That is not the feature a reader thinks of on seeing the word, and it never reaches a diagnostic, so renaming it is internal and free. `Quantified` is what [Type System.md](Type%20System.md) already calls it in prose; `Rigid` is the standard HM term but invites confusion with a flexible/rigid distinction Cronyx does not make.

The prose sense — "generic code", "a generic function" — is now the old name for a function with static params, in six compiler comments and across the internal docs. The exception is the user docs, where "other languages call these generics" is the pointer that makes the feature findable and should stay.

The third is a dozen fixture paths (`typeof_generic`, `generic_bound`, `generic_impl_operator`, `tests/effects/generic/`), where the word means "has type params". Mechanical once the first is decided.

## A flat type reaching a trait object

Owner: [Static vs Dynamic Invocation.md](Static%20vs%20Dynamic%20Invocation.md)

Trait objects are built, and a normal type reaching one costs nothing: the value is behind a pointer already and the coercion pairs it with a table. A `flat` type is the case left open — the author wrote `flat` to say the value lives in place, and an object needs it not to.

The direction is that it takes an explicit box at the coercion — `var s: Speaker = box azalea;` — so the allocation is written where it happens rather than inferred from the target type. Since there is no `dyn`, this is the only marker a reader gets, which is the argument for it.

What is not settled is the spelling, whether the box is a type a program can name or only a coercion the checker inserts, and whether the same form is what an explicitly boxed recursive type already uses. Nothing rejects the coercion today because `flat` does not exist yet either.

## Comparing two trait objects

Owner: [Static vs Dynamic Invocation.md](Static%20vs%20Dynamic%20Invocation.md)

`==` on a trait-typed operand is accepted and answers `false` however equal the two are, because `Value.equal_with` has no case for an object and falls through. `Cat == Cat` is `true`; the same two behind a `Speaker` are not.

What makes it more than a missing case is that the data carries no discriminator — two fieldless types are the same record at run time — so equality has to consult the table to tell a `Cat` from a `Dog`, or the checker has to reject the comparison. Deciding that is the work; the language has no `Eq` bound on `==` today, which is the argument for fixing the runtime rather than the checker.

## Wildcard imports and metaprocessing

Owner: [Modules.md](Modules.md)

A module's top-level `meta` runs the first time the walk asks that module for a name, so an import is pure symbol resolution and moving one changes nothing. That works only because every name says which module it comes from: `import "util"` is reached as `util.foo`, a selective import binds each name to its module, and `import "utils/*"` still qualifies each file by its basename.

An import that brings a module's names in unqualified — Rust's `use m::*`, Zig's former `usingnamespace` — breaks that. A bare name could then come from any such module, and since a `meta` block can generate anything, every one of them would have to run before the name resolves. The working answer is to keep imports qualified; what a wildcard should be able to do beyond that is open. `derive` is where it will be felt first, since a derive names a trait and a type that usually live in other modules: `meta/06_modules/derive_across` writes both qualified and `derive_across_selective` imports them by name.

## What a meta program inherits

Owner: [Metaprocessing.md](Metaprocessing.md)

A meta program is compiled with the same prelude as the program, so it sees everything the program does, and the program sees the compile-time-only parts too: the reflection types `TypeShape`, `TypeField`, `TypeVariant`, `Attr` and `AttrArg`, and `Gen` once it is declared there. The one handler a `meta` block installs is `Gen`'s.

Three things are left for when the prelude is reworked. Whether it splits into a shared base and a layer only meta programs see. Whether `meta` also handles `Assertion`, which would make `meta assert(…)` a compile-time check with the author's message rather than an unhandled effect. And which builtins a meta program may call — `print` goes to compile-time output today, and file access and the rest are the evaluator's to allow.

## What a meta program costs

Owner: [Metaprocessing.md](Metaprocessing.md)

Each `meta` block — and under the walk each instantiation's `meta` — is compiled as a program of its own: the prelude, what the block reaches, and the block, through every pass from `Desugar` to the interpreter. `fib<n>` compiles one per instantiation. Nothing is shared between them, so the prelude is desugared, checked and resolved once per block. Caching a compiled prelude and the declarations already processed is the obvious answer, and waits until something is slow enough to measure.

## `Gen` as an effect

Owner: [Metaprocessing.md](Metaprocessing.md)

The design is an effect in the prelude, `effect Gen { fn emit(item: Code): unit; }`, with `gen S` performing it and a `meta` block handling it by splicing what it collects. What is built is the behaviour without the effect: `gen` is lowered to a native call that appends to whichever block is collecting, and whether a function performs `Gen` is worked out by the walk — it holds a `gen` outside any meta block, or calls something that does — which is what rejects calling one at run time.

The effect is what would let a program handle `Gen` itself, and so test a deriver by collecting what it would generate rather than generating it. It needs `Code` to hold declarations and statements as well as expressions, which is the open question about `code` itself, so the two go together.

`Reifiable` is built with it too: how a value crosses from a meta block into what a `gen` emits is decided per type by `fn reify(self): Code` ([Reify](Reify.md)), and until then a value of a named type — a `List`, a `Point` — is written back as an anonymous record.

Promotion in `code(…)` waits on the same work. Inside a `gen`, the largest subexpression made of meta values is evaluated and written back; inside `code(…)` only a bare meta variable is, so `code(str(t) + " {")` keeps `str(t)` as syntax. Doing what `gen` does is unsafe while the walk sees only syntax: in `code(check && n > 0)`, `check` holds a `Code` value, and evaluating the whole expression early fails. With `Code` typed, the checker can say which subexpressions hold one, and promotion in `code` becomes as safe as in `gen`. Until then the way through is a meta variable: `var label = str(t); … code(label + " {")`.

## Runtime errors as an effect

Owner: [Testing.md](Testing.md)

An index out of range, a division by zero or a failed `readfile` ends the program; nothing can handle it. Making it an effect, `Panic` say, would let a program recover from one the way it recovers from any other, and would let a test runner isolate a crashing test in-process. The cost is that indexing and division then carry it in their row everywhere, which needs a design for keeping it out of the way — Koka's `exn` is the precedent. Tests do not wait on this: each already runs in a process of its own.

## Launching a process

Owner: [Algebraic Effects.md](Algebraic%20Effects.md)

A program cannot start one. Its I/O is `print` and whole-file `readfile` and `writefile`; there is no `spawn` or `exec`, no environment and no command-line arguments, and `stdlib/` has nothing for them either. (`cx test` forks per test, but that is `cx` itself, in OCaml, not the program.)

The likely shape is an effect rather than a builtin — `effect Process { fn spawn(cmd: string, args: Array<string>): ProcessHandle; … }` — so a function's row says it launches processes, and a test or a sandbox can handle it differently. The same argument covers file access, the environment and arguments, which are builtins today; deciding one decides the pattern for the rest.

## Whether resumptions share locals

Owner: [Algebraic Effects.md](Algebraic%20Effects.md)

A `ctl` arm that resumes twice runs the rest of the block twice, and a variable that already existed when the operation was performed is shared by both runs:

```cronyx
effect flip { ctl flip(): bool; }

run {
    var count = 0;
    var b = flip();
    count += 1;
    print(count);
} handle flip { ctl flip() { resume false; resume true; } }
```

This prints `1` then `2`, and the same holds when the body is a function. A variable bound after the operation is bound again on each resumption, which is why the user docs' `wants_tea` differs per branch — `multiple-resumption.mdx` still says each resumption gets its own copy of the block's locals.

Sharing is what a closure-based continuation gives, and what Koka does for mutable locals; copying would cost a snapshot of the frame per `ctl`. Deciding which is the semantics settles either the docs or a fixture.

## `defer` under a `ctl` arm that does not resume

Owner: [Algebraic Effects.md](Algebraic%20Effects.md)

A `final ctl` arm unwinds, so a `defer` in the frames it abandons runs. A plain `ctl` arm that returns without resuming only drops its continuation, and a `defer` inside that continuation never runs:

```cronyx
effect E { ctl t(msg: string); }

fn r() { defer { print("cleanup"); } t("boom"); }

run { r(); } handle E { ctl t(msg) { print("caught"); } }
```

This prints only `caught`. Running the cleanup at the arm's exit would be wrong when the arm stored the continuation to resume later, so the choice is between documenting that an aborting operation that needs cleanup is declared `final ctl`, and running the defers once a continuation is provably dead, which needs tracking whether the arm kept it. `error-handling.mdx` currently claims only the `final ctl` case.

## `cx toolchain install` and the standard library

Owner: [Package Manager.md](Package%20Manager.md)

`Toolchain_store.install` copies the `cx` binary it is given to `~/.cronyx/toolchains/<v>/bin/cx` and nothing else, so an installed toolchain cannot find its standard library and every `import "std/…"` fails with `Cannot find the standard library.` The release archive already has the install layout — `bin/cx`, `bin/cronyxc`, `lib/cronyx/stdlib` — so the direction is for `install` to take the unpacked archive and copy `bin/` and `lib/` together; the alternative is to keep the binary-only form and make `CRONYX_STDLIB` part of the documented setup.

## How values print

Owner: [Data Structures.md](Data%20Structures.md)

`print(xs)` and `str(xs)` on a `List` show the record behind it — `{ items: [1, 2, 3], count: 3 }` — and after `[1, 2]` and a `push(3)` the backing array's spare capacity too: `{ items: [1, 2, 3, 3], count: 3 }`. The direction is to print the live elements the way an `Array` prints, `[1, 2, 3]`, and give `Map` and `Set` the same treatment; what is open is whether that is a `Show` impl in the prelude or a case in the evaluator's printer.

Three more cases belong to the same decision. A `byte` prints as its raw octet, so `print("hé".bytes())` shows `[h, �, �]`, and nothing turns a `byte` into its number. A `float` prints with six significant digits — `1.0 / 3.0` is `0.333333` and `1234567.5` is `1.23457e+06` — while a whole one prints as `9.0`. And a string inside a collection prints without quotes, so `"".split(',')`, one empty string, prints as `[]`, the same as no strings at all.

## Running the docs' examples in the browser

Owner: [Architecture.md](Architecture.md)

The examples in `docs/` are static. Letting a reader run them needs no native backend: `meta` blocks already make the interpreter part of every compiler, so the whole pipeline built with `wasm_of_ocaml` (or `js_of_ocaml`) is the playground. The library's one tie to the OS is `Unix.realpath` in `toolchain.ml`, already guarded; the rest is a web entry point beside `bin/main.ml` that takes a source string and returns stdout, diagnostics and the exit code instead of calling `exit`, the standard library embedded in the bundle rather than read from disk, and a Docusaurus component that runs it in a Web Worker so a runaway program can be killed. A file a `meta` block or a program reads needs a virtual filesystem or an error.

If Cronyx is later compiled natively, the browser is a target of its own rather than a side effect of LLVM: LLVM's `wasm32` backend emits linear memory only, so each program would ship its own collector, where emitting WasmGC directly — through Binaryen or a small emitter — leaves collection to the engine. Selective CPS already makes continuations heap closures, so effects need Wasm's tail calls but not its stack-switching proposal. Whether that backend is ever worth having is open; the interpreter playground does not wait on it.

## Registry dependencies from `tests/`

Owner: [Package Manager.md](Package%20Manager.md)

A file under a package's `tests/` imports the package and its path dependencies, but not its registry ones: `Test.of_file` builds its roots with `Workspace.dependency_roots`, which knows nothing of the registry. `cx run <file>` had the same gap and now goes through `Build.file_roots`, which resolves and fetches registry dependencies before compiling; the direction is for test files to take the same route, with a registry test that imports a registry dependency from `tests/`.

## Checking the whole of a library

Owner: [Metaprocessing.md](Metaprocessing.md)

The walk metaprocesses and fully checks only what it reaches, and the early check never reports an undefined name, because a `meta` block could still generate it. A library's `src/lib.cx` has no top-level code calling its functions, so a function nothing in the package calls is never fully checked:

```cronyx
fn f(): int {
    return nothere;
}
```

`cx build` accepts this, and so does the build `cx publish` runs before publishing; the mistake surfaces in the first consumer that calls `f`. The direction is to treat every top-level function of a library as a root when building it, the way `cx test` treats each `@test` function, so the public surface is checked where it is written. The alternative — reporting an undefined name early whenever no reachable `meta` block could generate it — needs the early check to know what every `meta` block might emit.
