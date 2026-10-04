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
- The runtime surface is the natives in `builtins.ml` and `system.ml`, which become a small C runtime library.

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
- **Handlers are values.** Evidence and continuations are ordinary arguments; nothing is installed in a global.
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
| `int` | `i64` | The interpreter's `int` is OCaml's 63-bit integer. Overflow differs, so the language says which it means. |
| `float` | `double` | — |
| `string` | UTF-8 bytes and a length | The interpreter holds an array of code points, while `bytes` documents UTF-8 as "what it is stored as". Indexing and length have to mean the same thing over bytes. |
| `byte`, `char`, `bool` | `i8`, `i32`, `i1` | — |
| `unit` | erased | — |
| record | pointer to a heap block | — |
| variant | pointer to a tagged block, or an immediate for a fieldless one | Whether two fieldless types are told apart at run time, which is also the open `==` on trait objects in [TODO.md](TODO.md). |
| trait object | (data, table) pair | — |
| closure | (code, environment) pair | — |

`flat` types are not needed for a first backend: everything is boxed, and `flat` lands as an optimization once [Boxing and References.md](Boxing%20and%20References.md) is settled.

**Done when**

- This table is in [Architecture.md](Architecture.md), and the three semantic decisions each have a fixture that pins them.

## 4. A memory strategy

Boehm GC to start: a conservative collector is a drop-in `GC_malloc`, needs no stack maps, and is replaced without touching anything above it. A precise collector, or reference counting as Koka does with Perceus, is a later decision made against measurements.

**Done when**

- The runtime allocates through one function, so the collector is swapped in one place.

## 5. The open questions that change code shape

Most of [TODO.md](TODO.md) does not touch a backend. These do, and are answered first:

- **Whether resumptions share locals.** This decides whether a captured mutable variable becomes a heap cell, which is closure conversion's job in step 2.
- **Runtime errors as an effect.** If indexing and division perform an effect, their calling convention changes.
- **Multiple resumption.** A `ctl` arm may resume any number of times, so a continuation must be a heap closure that can be invoked more than once. Selective CPS already gives this; the backend must not optimize it into a one-shot jump.

## The target

C, compiled by Clang. Clang lowers C to LLVM IR and runs LLVM's optimizer and code generator, so the program still goes through LLVM; C is only what the compiler writes. Koka, the nearest language to Cronyx — algebraic effects, evidence passing, selective CPS — compiles to C.

- **No bindings.** Emitting C is string output, as `Printer` already does for Cronyx. The OCaml LLVM bindings are tied to one LLVM release and would make every release target find or bundle LLVM.
- **The output can be read.** A wrong program is a C file with named temporaries, not SSA. `#line` directives map it back to the `.cx` source in gdb and lldb, without writing DWARF.
- **Clang does the lowering.** Blocks and branches, struct layout, and the platform C calling convention — passing a struct by value differs between x86-64 Linux, Windows and ARM64 — are Clang's job. Textual `.ll` would make each of them the emitter's.
- **C libraries are an `#include`.** The runtime, Boehm GC and a host's interface header such as Godot's `gdextension_interface.h` are all C.

Two things the emitter has to get right:

- **Tail calls are required, not hoped for.** A CPS'd function passes its result to its continuation in tail position, so a loop that performs a `ctl` operation on every iteration is a chain of calls; without a guaranteed tail call, each leaves a frame and a long loop overflows the stack. Every call to a continuation is emitted with `__attribute__((musttail))`, which Clang lowers to LLVM's `musttail`. This is why Clang is required — 13 or later — rather than any C compiler; a trampoline would work everywhere and cost a return and a call per step.
- **C's undefined behaviour is turned off.** Signed overflow and strict aliasing would let the C compiler change Cronyx's meaning, so the driver always passes `-fwrapv -fno-strict-aliasing`.

Textual `.ll` replaces C when something C cannot express is needed: precise GC stack maps, a calling convention of Cronyx's own, or generating code in-process for compile speed. Both start from the tree step 2 produces, so the switch rewrites only the emitter.

## Growing the backend

Once steps 1–4 hold, the backend is mechanical and grows by subset, each against the fixtures that need nothing more:

1. Integers, functions and control flow
2. Records and variants
3. Closures
4. Effects by evidence passing — `fn` and `final ctl` operations
5. `ctl` operations with full continuations

The nine `tests/compile/m0`–`m8` fixtures, parked since the first backend, are the first target.
