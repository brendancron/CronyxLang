# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

`bootstrap/` (OCaml) is the compiler and `cx/` is the package manager, which
links the compiler as a library rather than shelling out to it. They are two
dune projects under one `dune-workspace` at the repo root.
`legacy-bootstrap/` (Rust) is the one `bootstrap/` replaced — it is kept for
reference, is not in CI, and no longer compiles the current `stdlib/` or
`tests/`.

Compiler commands run from `bootstrap/`; anything touching `cx` runs from the
repo root, so that the workspace is in scope.

```bash
# Build
dune build

# Test — the whole fixture suite
dune test
dune test --force            # again, ignoring dune's cache

# Run a program (paths are relative to the repo root)
dune exec --root . bin/main.exe -- ../tests/core/print/hello.cx
```

```bash
# From the repo root: build both projects, and run a program through `cx`
dune build
dune exec cx -- run tests/core/print/hello.cx
dune exec cx -- new mypkg

# The package manager's own suite: manifest fixtures, and the version and
# requirement tables
dune test cx

# `cx run` and `bootstrap` must agree on every fixture, both streams and the
# exit code.
./scripts/cx-parity.sh
```

`cx/test/manifests/` holds `.toml` fixtures paired with a `.ok` of what the
tool read or a `.err` of the diagnostics it produced, and `cx/test/packages/`
holds whole packages paired with an `expected.txt` or an `expected.err`. The
same rule as `tests/` applies to both: a fixture no list in
`cx/test/test_cx.ml` names is a failure of its own.

**CLI flags**, each printing one stage and then running:
- `--dump-source` — the source as the scanner received it
- `--dump-tokens` — the token stream
- `--dump-ast` — the parsed tree
- `--dump-types` — the tree after checking, every node annotated
- `--dump-code` — the program as Cronyx after metaprocessing, which is how to
  read what a `gen` or a deriver produced

## Working in this repo

**Never commit or push without being asked, in those words.** Not as a tidy-up,
not because the work looks finished, not because a branch was asked for. `git
commit`, `git push` and `gh pr create` run only when the instruction to run them
was given — "commit", "push", "open a PR" — and each is its own instruction: a
request to commit is not a request to push.

**Do the thing that was asked, and stop there.** A request to write a file is a
request to write a file. A request for a *branch* is a request for a branch, and
the work belongs in its working tree, uncommitted, until told otherwise. When
work is finished and unasked-for, say what is in the working tree and let the
user decide where it goes.

**Questions go in a file, not in the summary.** After a piece of work, report
what was done, but do not end on a list of open questions, loose ends, or
things found and not fixed. Write each one to `scratch/questions.md` (gitignored)
with enough context to answer it cold — what was found, a Cronyx example where
one helps, and the options with a recommendation — then say how many there are
and ask whether to go through them. Take them one at a time, and remove each
from the file once it is answered.

`main` is protected: it takes no direct pushes, so a change that is *meant to
land* lands through a pull request. Branch, push, open the PR, and let the
`test` check run.

**Ask before watching CI.** Opening the PR is where the work ends. Do not poll
`gh pr checks`, start a monitor on a run, or report back on whether it went
green unless that was asked for — but offering is welcome: end with something
like "would you like me to watch the build?" and wait for an answer. A yes
covers that run, not every run after it.

**Keep a branch current with `main`.** Merge `main` in before opening a PR and
again whenever `main` moves — a branch cut from a commit that has since been
superseded reviews against the wrong thing, and its checks pass against a tree
nobody will merge. Two PRs open at once is the case that bites: the second one
is stale the moment the first lands.

## Code style

Applies to `legacy-bootstrap/` (Rust), `bootstrap/` (OCaml), and the `.cx` fixtures in `tests/`. A fixture is read alongside its `.txt`, which already says what the program produces, so a header explaining what it demonstrates is the same noise as anywhere else.

**A comment is the exception.** Start from the assumption that it should not exist and make it earn its place. Two kinds do:

1. **A trap** — a subtle invariant, an ordering that has to hold, why the obvious alternative fails. The test is whether a competent reader would lose an hour without it.
2. **A label** over a long list, like `(* One or two character tokens. *)` in `token.ml`.

Everything else is noise, including all of these:

- what a function does — the name and signature say it
- what a pass consumes and produces — the types say it
- why a design was chosen — that belongs in `internal-docs/`
- a restatement of the line below, however rephrased
- narrating a branch of a `match` that already reads clearly

A file may carry a one- or two-line header when its purpose is not obvious from its name. Most files do not need one.

Rewriting a comment to be more insightful is usually the wrong fix. Deleting it is the right one.

**Never describe development in code.** No stages, milestones, plan phases, what a rewrite replaced, or what is coming next. Write for someone reading the file in three years with no memory of how it was built — "Stage 1 → stage 2" means nothing to them, and the types (`desugared_expr` → `typed_expr`) already say what a pass consumes and produces. That material belongs in conversation or `internal-docs/`, never in a source file.

**Explain why, not how.** The code shows how. A comment is for the reasoning a reader cannot recover from it.

```ocaml
(* Bad — development framing, and the types already say this. *)
(* Stage 1 → stage 2: Hindley-Milner inference over the desugared tree.
   Three passes, in this order: hoist, infer, resolve. *)

(* Good — a trap that costs an hour to rediscover. *)
(* Drop the monomorphic binding [hoist] installed: leaving it in place makes the
   function's own variables count as free in the enclosing scope, so nothing is
   ever quantified. *)
```

## Architecture

Cronyx is a statically-typed, metaprogramming-first language.
[internal-docs/Architecture.md](internal-docs/Architecture.md) is the authority
on the pipeline and carries a heading per pass; the order itself lives in
`bootstrap/lib/pipeline.ml` up to metaprocessing and `bootstrap/lib/compile.ml`
from `Desugar` on, and nowhere else.

```
Scanner → Parser → Loader → Precheck → Metaprocess → Desugar → Typecheck
  → Type monomorphize → Resolve → Reflect → CPS → Verify → Interp
```

### Key distinctions

**A registry is a root, not a protocol.** `CRONYX_REGISTRY` points at an index
of releases and a store of archives; it is a directory today and a URL when
there is a server. `cx publish` writes both, immutably. The client — checksum
verification before anything is unpacked, the shared cache under
`~/.cronyx/registry`, and yanks that skip new resolutions but leave a pinned
lockfile alone — is the same either way.

**Dispatch is a mode of `cx`, not a shim.** On startup `cx` finds the package
it was invoked in, reads the toolchain it requires with `Preamble` — a reader
for one frozen key, so a manifest written for a newer compiler is answered with
a version rather than a syntax error — and hands the job to that toolchain's
`cx`. `~/.cronyx/bin/cx` only ever moves forward, and `CRONYX_HOME` points the
whole thing somewhere else for a test.

**A package compiles to an artifact.** `cx build` compiles each package in the
graph to `target/debug/<name>.cxa` — its declarations, mangled under the
package's own name, plus what each unit exports — and links the artifacts
rather than reading a dependency's source. `Artifact` is `Marshal` of the
compiler's own types with the version that wrote them, which is sound because
the compiler that reads one is always the compiler that wrote it. An artifact
is the package loaded and mangled, not metaprocessed: which copy of a template
exists is decided by the program that uses it, so the walk runs once over the
linked program, from the package root (`Build.within`) because an artifact's
paths are relative to it. A file a `meta` block reads is therefore not an input
of the artifact.

**An import never leaves its package.** `Loader` takes the roots it may
reach — the package, the standard library, and each dependency by name — and
an import resolving outside the root of the file that wrote it is an error.
`import "std/…"` comes from the toolchain rather than the filesystem, and a
dependency is reached by the name the manifest gave it, so `cx` decides what is
reachable and the compiler only consumes that decision.

**An import is symbol resolution and nothing else.** Importing a file loads its
declarations; its top-level statements run only when it is the entry. Its
top-level `meta` blocks and `derive`s run the first time the walk asks that
module for a name, so moving an import changes nothing. That depends on every
name saying which module it comes from, which is why imports stay qualified.

**One AST, several stages of it.** `Ast` is parameterized by its annotation and
by what a statement holds, so `desugared_stmt`, `typed_stmt`, `resolved_stmt`
and `cps_stmt` are the same tree at different points. A construct that has been
lowered is gone from the type, which is what stops a later pass from meeting it.

**Metaprocessing is a walk from the roots.** The entry's top-level statements
are walked in source order, and a declaration is metaprocessed the first time
the walk reaches it, once; what nothing reaches is never metaprocessed or
emitted. A template taking a static *value*, or holding a `meta` block, is
instantiated when a call to it is reached, memoized by name and arguments across
the whole program, because a value can decide a type. `Type_mono` copies the
rest — bodies generic only over types — after checking, because inference is
what says which types those are. See
[internal-docs/Metaprocessing.md](internal-docs/Metaprocessing.md).

**Metaprocessing is the pipeline calling itself.** A `meta` block is compiled by
the passes above and run by the interpreter, which is why `Compile` holds
everything from `Desugar` on and `Pipeline` holds the rest.

**Checking happens twice.** `Precheck` checks the whole program before the
walk, reached or not, with meta erased and `Typecheck.partial` treating what a
meta block could still declare as unknown; the full check runs on what the walk
emitted. An error in code nothing reaches is still reported, and nothing a meta
block could still make right is.

**Dispatch is static unless a trait is written as a type.** Operators are
traits and `Resolve` turns every impl into plain functions — see
[internal-docs/Elaboration.md](internal-docs/Elaboration.md). A trait in type
position is a trait object, which pairs a value with a table of those same
functions; the checker inserts that coercion only where the type was written,
so inference never produces one — see
[internal-docs/Static vs Dynamic Invocation.md](internal-docs/Static%20vs%20Dynamic%20Invocation.md).

**CPS is selective.** Only functions performing control effects are rewritten,
and each effect gets evidence passing or full continuations according to its
declaration: a `ctl` operation means continuations, and only `fn` and `final
ctl` operations mean evidence.

### Test fixtures

`tests/` (repo root, not `bootstrap/test/`) holds `.cx` sources paired with
what they must produce: a `.txt` of expected stdout, a `.err` of expected
diagnostics, or a `.rt` for one that runs and then fails.

Every fixture must be named by a list in `bootstrap/test/test_bootstrap.ml`,
and a fixture no list names is a test failure of its own. A feature that does
not work yet goes in `expected_failing` with the work it waits on — the suite
asserts it still fails, and says so the moment it starts passing. Write the
fixture before the feature.
