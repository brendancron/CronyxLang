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
