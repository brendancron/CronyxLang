# Native code: readiness

What has to be true before a native backend is started, and why. The test for each is the same: a backend should be a translator. Every decision it needs is made upstream, and it only writes those decisions down. A backend that has to decide anything — a type, a capture, where a handler lives — is doing a front-end pass badly.

## What the first backend taught

`legacy-bootstrap/src/codegen/mod.rs` went from the AST to LLVM through inkwell in one 5,371-line file, and its comments record where it struggled:

- **It guessed types.** With no monomorphization, type variables reached codegen. It fell back to the argument types at a call site, inferred a handler's parameter types from how the body used them — a `for` over a parameter meant it "must be a Slice" — and segfaulted when a continuation came through as a variable. [Type System.md](Type%20System.md) already names this shortcut as the one not to repeat.
- **Handlers were LLVM globals.** The active handler was tracked statically (`with_fn_active`, `__ctl_outer_k`), so a nested or re-entered handler could not be right.
- **Codegen did analysis.** Free-variable capture, knowledge of the CPS transform, and whether a program needs a heap at all were all worked out inside it.
- **Memory was `malloc` with nothing that freed it.**

Every failure surfaced as a crash in a native binary, because nothing could say what the right answer was.

## What `bootstrap` already settles

- `Type_mono` emits concrete instances of everything generic only over types.
- `Resolve` flattens every impl to plain functions, so no trait reaches the end of the pipeline.
- A trait object is already a value beside a table of functions ([Static vs Dynamic Invocation.md](Static%20vs%20Dynamic%20Invocation.md)).
- CPS is selective and chosen per effect by its declaration ([Algebraic Effects.md](Algebraic%20Effects.md)).
- `Verify` checks each node's annotation against its children.
- The runtime surface is the natives in `builtins.ml` and `system.ml`, which become a small runtime library written in Zig.

What is missing sits between CPS and the backend.

## 1. No type variable survives

`Verify` takes a `Var` at its word (`verify.ml`), so an unresolved type can still reach the end of the pipeline unnoticed. A strict mode rejects any type variable or quantified type after CPS. Row variables are erased rather than rejected, since no code depends on them.

**Done when**

- Strict `Verify` runs on every fixture in the suite and passes.
- A fixture that leaves a type unresolved is rejected by strict `Verify`, not by a later pass.

## 2. A lowered IR the interpreter runs

One more tree after CPS, in which nothing a backend needs is implicit, and from which either target is emitted:

- **Closures are converted.** Each function's free variables are computed, its environment is a record, and every function is lifted to the top level.
- **Allocation is a node.** Every heap allocation is visible in the tree.
- **Handlers are values.** Evidence and continuations are ordinary arguments; nothing is installed in a global. Evidence is one vector per function, as Koka passes it ([Algebraic Effects.md](Algebraic%20Effects.md#evidence-is-one-vector)).
- **Every intermediate is named** (A-normal form), so evaluation order is fixed before the backend sees it.

The interpreter runs this tree. That is the point of the step: the fixture suite then proves the lowering correct before any machine code exists, and each later lowering is checked the same way. The first backend had no oracle, which is why its bugs were segfaults.

**Done when**

- The interpreter runs the lowered tree, and the whole fixture suite passes against it.
- `cx run` on the lowered tree and on the CPS tree agree on every fixture, both streams and the exit code.
- No node in the lowered tree refers to a variable outside its own function's parameters, its environment, or the top level.

## 3. Representations, decided

Most are a choice of layout; three are semantics that the interpreter currently inherits from OCaml.

| Value | Native representation | Decision it forces |
| --- | --- | --- |
| `int` | `i63`, wrapping | The interpreter's `int` is OCaml's 63-bit integer, and Zig has that width. Arithmetic is emitted with the wrapping operators, so overflow is OCaml's on both. |
| `float` | `double` | — |
| `string` | flat (pointer, length, ASCII flag) over UTF-8 bytes | Positions count characters on both, so `len`, `s[i]` and slicing walk the bytes natively unless the flag, set when the string is built, says every character is one byte. `byte_len` answers the length in bytes in O(1). |
| `byte`, `char`, `bool` | `i8`, `i32`, `i1` | — |
| `unit` | erased | — |
| `Array` | flat (pointer, length) | — |
| record | pointer to a heap block | — |
| `flat` record | the fields, in place | — |
| variant | pointer to a tagged block, or an immediate for a fieldless one | Whether two fieldless types are told apart at run time, which is also the open `==` on trait objects in [TODO.md](TODO.md). |
| trait object | (data, table) pair | — |
| closure | (code, environment) pair | — |

`string` and `Array` are flat handles over a buffer: copying one copies the handle and shares the buffer, which is safe because neither changes length once made and a `string` is immutable. `List` is a plain type, so every copy is the same object; as a flat handle, a copy would keep its own count over the shared buffer and a `push` that grows it would leave the other copy pointing at freed memory, and Cronyx has no moves to prevent that.

**Done when**

- This table is in [Architecture.md](Architecture.md), and the three semantic decisions each have a fixture that pins them.

## 4. Memory is an effect

Allocation is the effect `Alloc`, with `fn` operations to allocate and to free, so it goes by evidence passing and never through continuations. `__root` handles it with the runtime's general-purpose allocator, and an arena is a handler nested inside it that frees everything at once when its `run` ends. There is no collector.

- **A plain `type` allocates; a `flat type` does not.** A literal of a plain type performs `alloc`, so nearly every function carries `Alloc` in its row. A `flat` value has a size known at compile time and lives in place.
- **A local a continuation captures moves to the heap**, allocated through `Alloc`, when its function yields ([Algebraic Effects.md](Algebraic%20Effects.md#continuations-are-built-by-yielding)). Until then the frame is an ordinary stack frame, `flat` locals in place. A continuation can run after its function returns, more than once and after its `run` has exited, so each captured mutable local becomes one heap cell that every resumption reads, and the continuation itself is a heap closure. Under an arena the arena owns both; under the root allocator the runtime counts the continuations holding each and frees it at zero.
- **Mistakes are the program's, and the interpreter reports them.** `free` reaches the innermost handler, so freeing a block under an allocator that did not make it is an error, as it is in Zig. So is reading a block freed by `free` or by a closed arena, and reading through a `&` to a frame that has returned. None is ruled out statically. The interpreter marks freed blocks and reports a use after free, a double free and a free through the wrong allocator, as Zig's debug allocator does, and the fixture suite runs under that check.

**Done when**

- `Alloc` is declared in the standard library and handled in `__root`, and an arena handler exists.
- The interpreter allocates through `Alloc` and reports each of the mistakes above, each pinned by a fixture.

## 5. The open questions that change code shape

Most of [TODO.md](TODO.md) does not touch a backend. These do, and are answered first:

- **Runtime errors as an effect.** If indexing and division perform an effect, their calling convention changes.
- **Multiple resumption.** A `ctl` arm may resume any number of times, so a continuation must be a heap closure that can be invoked more than once. Yield bubbling builds it as one; the backend must not optimize it into a one-shot jump.

## The target

Zig, at one exact release pinned by each Cronyx toolchain. `cx` fetches that release into `~/.cronyx/` beside the toolchain that names it, so a program builds with the Zig it was tested against and nothing on `PATH` is consulted. Release builds go through LLVM; debug builds go through Zig's own backend, which compiles faster.

- **No bindings.** Emitting Zig is string output, as `Printer` already does for Cronyx. The OCaml LLVM bindings are tied to one LLVM release and would make every release target find or bundle LLVM.
- **The output can be read.** A wrong program is a Zig file with named temporaries, not SSA.
- **Zig does the lowering.** Blocks and branches, struct layout, and the platform calling convention — passing a struct by value differs between x86-64 Linux, Windows and ARM64 — are Zig's job. Textual `.ll` would make each of them the emitter's.
- **Every target from one host.** Zig cross-compiles to each platform in `targets.json` with no sysroot, so a release is cut for all of them from one machine.
- **The runtime is Zig.** The natives are written against Zig's standard library, which already abstracts files, sockets and polling across Linux, macOS and Windows.
- **C libraries are an `@cImport`.** A host's interface header such as Godot's `gdextension_interface.h` is C, and Zig reads it directly.
- **The whole program is one unit.** The walk already runs over the linked program, so each program is emitted as one `.zig` file and compiled once.

What the emitter has to get right:

- **Calls are ordinary calls.** Effectful code is not in continuation-passing style: a function returns normally, and a yield moves up the stack by returning ([Algebraic Effects.md](Algebraic%20Effects.md#continuations-are-built-by-yielding)), so nothing depends on a guaranteed tail call. Every continuation has one signature — a boxed value and the context — so composing and resuming them needs no per-type code.
- **Overflow wraps.** Zig's `+`, `-` and `*` treat overflow as illegal behaviour — a panic in safe builds and undefined in `ReleaseFast` — so every integer operation is emitted with `+%`, `-%` and `*%`, and no check is left to Zig's build mode: whether a runtime error is checked is the language's decision ([TODO](TODO.md#runtime-safety-as-a-static-parameter)).
- **Generated code passes Zig's lints.** An unused local or parameter, a `var` never mutated, and a shadowed name are compile errors. The emitter discards what it does not use with `_ = x;`, chooses `const` or `var` from whether the lowered tree assigns the name, and relies on A-normal form for unique names.
- **Only a small core of the language is used.** Functions, structs, pointers and `@call`: no `comptime`, no generics, no error unions, no `defer`. `Type_mono` and `Resolve` have already removed everything generic, and Zig's errors and `defer` cannot express an effect that resumes. The core is also the part of Zig that changes least between releases, so a new pinned Zig mostly touches the runtime, which is written by hand.
- **Source positions are comments.** Zig has no `#line`, so a debugger shows the generated file. Each statement carries a `// path.cx:line` comment, which is what makes the generated file usable in gdb and lldb.

Textual `.ll` replaces Zig when something Zig cannot express is needed: precise GC stack maps, a calling convention of Cronyx's own, or generating code in-process for compile speed. Both start from the tree step 2 produces, so the switch rewrites only the emitter.

## Growing the backend

Every target in `targets.json` is supported from the first subset on: each is built, and the native fixture suite runs on each target's CI runner — every one but `x86_64-apple-darwin`, which has none.

Once steps 1–4 hold, the backend is mechanical and grows by subset, each against the fixtures that need nothing more:

1. Integers, functions and control flow
2. Records and variants
3. Closures
4. Effects by evidence passing — `fn` and `final ctl` operations
5. `ctl` operations with full continuations

The nine `tests/compile/m0`–`m8` fixtures, parked since the first backend, are the first target.
