# Standard library: implementation plan

[stdlib.txt](stdlib.txt) is the layout. This is the order it gets built in and what "done" means at each step.

Two rules shape the ordering. **What changes every program's output goes first**: the layout moves import paths and `Display` moves what `print` writes, so every fixture written before them is written twice. And **a module lands after what it is built on**, which in several places is the language rather than the library — `Sha256` needs bitwise operators Cronyx does not have, and `Timer` needs a scheduler that can wait on the OS.

A milestone is done when its criteria hold *and* a fixture in `tests/` covers each one, written before the module is.

## 0. The layout

The modules that exist move to where [stdlib.txt](stdlib.txt) puts them, with no change to what they do:

- `lang/Throw` and `lang/Fallible` → `core/Error`
- `effects/Yield` → `iter/Yield`; `effects/Async` → `async/Task` and `async/Promise`
- `core/Reflect` → `meta/Reflect`
- `core/List`, `Map`, `Set` → `collections/`, merged with `collections/List`'s helpers
- `core/String`, `lang/String`, `lang/StringBuilder`, `lang/Regex` → `text/`, with `regex/*` beneath it as `text/regex/`
- `automata/*` → `algo/automata/`
- `lang/Math` → `math/`; `lang/Toml` → `encoding/Toml`; `io/Fs` → `fs/File`

This needs `core/` to stop being special first. Today `prelude.ml` concatenates every file in `core/` into the program unqualified, which is both how the compiler finds what it names and why those names are in scope everywhere. The two come apart:

- `core/` is loaded like any other `std` module, mangled under its own path.
- What the compiler names — `List` for a literal, `FromArray`, `TypeShape` for `typeof`, `Option` and `Ordering`, the operator traits — it reaches by module path, so it is loaded whether or not anything imports it, and a program's own `List` is just a different name rather than a replacement `Prelude.owns` has to allow.
- What a file sees without an import is the `global import`s in `stdlib/prelude.cx`, and nothing else. Which of `core` is global is decided there, and moving a module changes a path in that file rather than the compiler.

A file's own declaration shadows a global import of the same name, as a local shadows an outer one, so adding a name to `prelude.cx` never breaks a program that already declares it. What it shadows stays reachable qualified: `core.print`, `core.List`. Today the global import wins silently over a file's own `fn print`, and a file declaring `type List` crashes the compiler.

`collections/Array`'s `filled` joins `core/Array` rather than keeping a second module of that name.

**Done when**

- Every fixture passes with the new import paths, and no module is left at an old one.
- A file declaring its own `print` and its own `List` uses them, and reaches the library's as `core.print` and `core.List`.
- `cx docs std` lists exactly the modules [stdlib.txt](stdlib.txt) does that exist.

## 1. Printing

`text/Format`: the `Display` and `Debug` traits, a deriver for each, and `str` and `print` dispatching through `Display`, with the builtin written form as the fallback for a type with no impl. `List`, `Map` and `Set` implement `Display` by writing each element's `Debug`, which answers how values print: `[1, 2, 3]` rather than the record behind it, strings quoted inside a collection, a `byte` as its number.

Two traits because a string has two forms: `print("a")` writes `a`, and `print(["a"])` has to write `["a"]`, or `[""]` and `[]` print the same. `Display` is the form a value is shown in; `Debug` is the one that tells values apart, and is what a collection uses for its parts and what `assert_eq` reports a mismatch with, so `"1"` and `1` differ there too. For a type with no `Debug`, the builtin form is the fallback, as it is for `Display`.

`print` and `str` keep no bound. Which form they use is decided when the value is printed, by the type name it carries: the impl if the type has one, the builtin form if not, and the builtin form goes through `Debug` for each part that has one ([Data Structures](Data%20Structures.md#how-a-value-prints)).

Number formatting — precision, padding, radix — is here too, since `Display for float` is where six significant digits gets replaced.

**Done when**

- `print` on a `List`, `Map` and `Set` shows its elements, and on a type with `derive Display` shows its fields.
- A type implementing `Display` by hand is printed with it by `print`, `str` and `printerr`.
- A list of strings prints them quoted, through `Debug`, and a type with a hand-written `Debug` is printed with it inside a `List`.
- `"".split(',')` and an empty list print differently.

## 2. Sequences

Pure library over what exists, so it is cheap and everything after it uses it.

- `iter/Adapters`: `map`, `filter`, `zip`, `enumerate`, `take`, `chain` and `collect`, each lazy and carrying the row of the `Iter` it is given.
- `algo/sort`: a stable sort and an unstable one, by `PartialOrd`, by key and by comparator, over `List` and `Array`.
- `algo/search`: binary search, lower and upper bound, partition point.

**Done when**

- An adapter chain over `lines(f)` reads the file only as far as it is pulled, and carries `<async, Throw<IoError>>`.
- Sorting is stable where it says so, with a fixture that would fail under an unstable one.

## 3. Bytes

This one starts in the compiler.

- **Bitwise operators**: `&`, `|`, `^`, `~`, `<<`, `>>`, as traits in `core/Ops` like every other operator. None exist today.

Then the library:

- `text/Utf8`: decoding that fails as a value naming the offset of the bad byte. `read_text` and `lines` call it rather than keeping their own.
- `io/Buffer`: growable bytes that are a `Reader` and a `Writer`, with integers read and written in a chosen byte order.
- `encoding/Hex` and `encoding/Base64`, over `Buffer`, failing with `Throw<DecodeError>`.

**Done when**

- A type implementing the bitwise traits is used with the operators, as `Add` is with `+`.
- A test feeds a parser from a `Buffer` and captures a writer into one, touching no file.
- Invalid UTF-8 from `read_text` names the byte offset.

## 4. The environment

What a program asks of the OS: `os/Args`, `os/Env`, `os/Time`, `os/Process`, `random/`, and `fs/Path` with directory listing in `fs/`.

Each is an effect the root handles, as `Fs` is, so a test replaces it — a fixed clock, fixed arguments, a seeded generator. That decides launching a process for all of them at once ([I/O](IO.md#everything-else-the-os-offers-is-an-effect-too)), and `readfile`, `writefile` and `clock` stop being builtins.

A `meta` block runs under the same root as a program, so compile time can do anything run time can: read and write files, read the environment and the clock, launch a process. Whether a build is reproducible is the program's business, not the compiler's.

**Done when**

- A program reads its arguments and environment, runs a subprocess and reads its output and exit code.
- A test handles `Time` and `Random` and gets the same output on every run.
- No builtin touches the OS that an effect in this list does not.
- A `meta` block reads a file, the environment and the clock through the same effects.

## 5. Tasks that talk

- `async/Channel` and `async/Select` are library over `suspend` and come first.
- `async/Timer` needs `block_on` to wait on the OS clock when every task is parked, rather than panicking that none is left to wake one. That change to the root scheduler is the same one `net/` will need for sockets, so it is written for both.

**Done when**

- A producer blocked on a full bounded channel resumes when the consumer takes a value.
- `timeout` cancels the task it abandons, running its `defer`s.
- A program whose every task is asleep waits rather than panicking.

## 6. Derivers

`Display` and `Debug` come with milestone 1, and this milestone writes three more — `Encode`, `Decode` and `Cli`. `meta/Derive` is extracted from what they share rather than designed ahead of them, and `meta/Name` gathers `as_name` and what builds identifiers.

It starts in the compiler. `Decode` and `Cli` build a record literal with a field per declared field, which the body of a `gen` cannot write, so code becomes data first: [Syntax Trees](Syntax%20Trees.md), with the tree in `std/compiler/Ast`.

Then `meta/Reflect`, since a deriver cannot see the type of a field and `Cli` has to: `verbose: bool` is a flag and `port: int` takes a value. A field gains `ty: TypeRef`, and a variant's `payload` becomes `Array<TypeRef>`, so `Option<int>` is no longer reported as nothing:

```cronyx
type TypeRef {
    Named(Name, Array<TypeRef>),
    Param(Name),
    Other,
}
```

A reference rather than a `TypeShape`, so a type that contains itself is not reflected forever; a deriver that needs to look inside one asks `typeof`.

- `encoding/Codec`: `Encode` and `Decode`, their derivers, and the `Encoder`/`Decoder` interface. Field attributes rename and skip.
- `encoding/Json`, implementing the interface.
- `encoding/Toml` moves onto the interface and gains a writer; its tokenizer and parser stop being its public surface.
- `os/Cli`, over `os/Args`: a parser derived from a type, with help from its doc comments.

**Done when**

- One type with `derive Encode, Decode` round-trips through JSON and TOML.
- A `Decode` failure names the path to the field and what it expected.
- A `Cli` type's `--help` shows each field's doc comment, and a bad argument ends the program with a message and a non-zero exit.

## 7. Numbers and digests

On the bitwise operators from 3.

- `math/BigInt`, implementing the operator traits and `Display`.
- `crypto/Sha256`, a `Writer`, printed through `encoding/Hex`.
- `math/`'s `min`, `max` and `abs` get written types.

**Done when**

- `Sha256` matches the NIST test vectors, including a message streamed in pieces.
- `BigInt` arithmetic agrees with `int` wherever `int` does not overflow.

## 8. Testing and logging

This one starts in the compiler, with `moduleof` as [Modules.md](Modules.md) decides it: a `Module` record of a module's top-level declarations, each with its doc and attributes, and asking for it is a reference to the module, so its top-level `meta` runs first and the record includes what that generates. A `fn`'s doc and a method's become readable from a `meta` block with it, which [Generated Documentation](Generated%20Documentation.md) waits on.

Then the library:

- `test/Test`: discovery as a library. A test root reflects the modules under test and generates a call per `@test` it finds, and `cx test` supplies the root — every file of the package and `tests/` — when the package has none ([When a declaration query runs](TODO.md#when-a-declaration-query-runs)). `cx test` stops finding tests itself.
- `test/Bench`, on `os/Time`.
- `log/Logger`, an effect with severity levels, handled at the root to write to standard error.

**Done when**

- A `meta` block lists a module's functions with their docs and attributes, and one a `gen` in that module generated is among them.
- `cx test` runs the same tests as before with discovery in `test/Test`, and a package's own test root replaces the default.
- A test handles `Logger` and asserts on what was logged.
- A benchmark reports through a handled `Time`, so its fixture's output is fixed.

## What is not in the plan

`net/` and HTTP over it, and `algo/graph`. `net/` is the next step after 5, since it shares the scheduler work.
