# CPS Migration: handoff

Branch `cps-migration`. This file is the starting point for a new Claude session. Read it,
then `CLAUDE.md`, then the design. Work in progress: the suite is red on purpose.

## What this branch does
It implements `internal-docs/CPS Migration.md`, and only that document. Do **not** pull in plans
from `Inlining.md`, `Async Strategies.md`, `CPS in Metaprocessing.md` or the other recent docs.
`internal-docs/Vocabulary.md` is the glossary. Use its words: graduate, built-in, key, instance,
monomorphize, Splice, quote. Avoid "template", "comptime function" and "demote".

## Files
- `internal-docs/CPS Migration.md`: the design, and the source of truth.
- `scratch/review-later.md`: every decision.
  - R1–R31 are design-level: the user reviewed them all on 2026-11-22.
  - I1–I230 are implementation entries. Entries marked "To build" are decided and not yet built.
- `scratch/plans/00-unified.md`: the original plan (A1–A10, B1–B6, C1–C10). It has been
  overtaken by the steps below, but it explains the codebase.
- `scratch/questions.md`: older open questions, from the main checkout.
- `scratch/ctl-as-function.md`: the design conversation log.
- `scratch/tools/fixtures.py`: pass counts over every fixture
  (`python3 scratch/tools/fixtures.py [--list-fail] [--out f.tsv]`). Build first.
- `scratch/checkpoints/*.patch`: these are not committed, because they are too big. Each is a
  `git diff` against `d418029` at the end of a step, plus the step's untracked files. The committed state is S2b.

## Build
From `bootstrap/`: `dune build --root .`, then
`dune exec --root . bin/main.exe -- ../tests/core/print/hello.cx`.
In a git worktree, plain `dune` fails with "No rule found for alias", so pass `--root .`.
`--dump-code` shows processed code.

## Status (steps 3–5a committed, 5b partly built)
Steps 3, 4, 4b and 5a are committed on `cps-migration`, together with the half of step 5b below. Pass counts:
737/972 overall, tests/effects/v2 132/133, tests/core/defer/v2 6/6, tests/stdlib/v2 4/4, tests/meta 158/162; against
the end of 5a the passing set only gained 5b's three new fixtures. The one red in v2 is
`errors/handler_method_takes_control` (old syntax, as before); `expected_failing` holds only the parked
native-compilation fixtures. The rest is red because the stdlib and old fixtures still use the deleted old syntax. The
user has accepted that red. The checkpoint patches in `scratch/checkpoints/` are superseded by the commit.
`dune test cx` deletes `cx/test/registry/app/cronyx.lock`; restore it from `HEAD` after running it (I230).

- **Phases A, B and C1–C7a (earlier):** the metaprocessing core, reflection and Splice, effects as
  traits, `@ctl`, `EffectHandler`, and the library `effect_transform` in `stdlib/core/Transform.cx`.
- **Step 1:** old effect syntax deleted: `cps.ml`, `effect`, `ctl`, `final ctl`, `resume x;`, old
  handlers, and the interpreter's Cont/Frame/Abort. The prelude's `__root` is rewritten minimally.
  Async, Fs, Process, Net, Exit and Stdin are dropped from it for now.
- **Step 2:** handlers are values (the Koka model, R1). A function whose row has a `@ctl` effect
  takes handler and continuation parameters wherever it is written. Handlers are out of the key
  (I104). The handed form is deleted (I112). Lists of stored tasks work.
- **Step 2b:** one CPS form per function value, and runs that take control outward become prompts
  with a "current answer continuation" (I186, I192–I200).
- **Step 3 (I201–I208):** `EffectHandler` makes each `@ctl` method generic in its row (`Rho`); an inline
  handler's value is checked as the record against that signature; rewritten code keeps no false row (R28, for
  runs); a defaulted effect parameter is `absent` (I25). Left: the call-site display of a handler method
  (`answered`), named handlers not tied to one ρ, arms checked twice under a transform, `Verify`'s loose arity.
- **Step 4 (I209–I218):** `run<R>` required (R9), `handle<Throw<X>>` written (R10), the "named by the author"
  exemption gone (I68), a discarded call settles a return-only parameter to `unit` (I90), a type standing as a value
  in a meta block is its `Type` (R5), `type X impl A, B { … }` (R31), `@abort` (R14), a `return` crossing a prompt
  (I197). Found, not fixed: a meta block calling any function that takes control fails when it runs (I212); a named
  `EffectHandler` impl's untyped parameters do not take the instance's types (I214, R11).
- **Step 4b (I219–I225):** a named handler of a `@ctl` effect in a prompt (I217): the prompt takes the impl's
  method (new native `named_method`) and makes it taking control outward as an inline arm (I219). Types are
  monomorphized like functions (R7) for the program the walk finishes: a plain generic type is copied through the
  decl cache, spelled as its use prints (`Box<int>`) (I220); written arguments, `declof(Box<int>)`, `typeof(Box<int>)`
  and keys reach the cache at the node, inferred uses when the walk is done (I221, review against R6); inference
  stays structural and a copy's name is an alias the checker reads as the generic type at its arguments, which
  fixes I200 (I222); the finished program's annotations, values and patterns name copies, its type-level section
  holds the copies it reaches in place of the generic declarations, and `Verify` rejects a generic type left in it
  (I223). Cost: `hello` 161 → 165 ms, `working_example` 179 → 181 (I225).
- **Step 5a (I226–I230):** R30's case convention. The compiler's built-in types are `Int`, `Float`, `String`, `Byte`,
  `Char`, `Bool`, `Unit` (no aliases); every `.cx` under `stdlib/`, `tests/`, `cx/test/` and `benchmarks/` follows,
  red fixtures included, and the 75 lowercase user types, traits and effects are uppercase (`Async`, `Log`, `Sched`,
  `ParseError`). Done by a lexer-based script (I227); expected outputs taken from actual output where they differed
  only in case (I228). Docs and editor keyword lists are listed in I229, not edited.
- **Step 5b, partly built (no I-entries yet):** the agent was stopped mid-step. One `__root` is in: `stdlib/prelude.cx`
  has `__root<Rest>(main: () -> <Console, Logger, Args, Env, Time, Random, Rest> Unit)` for the whole top level and
  `__throwing<T, X, Rest>` wrapping only a statement that throws; the compiler side is in `compile.ml`,
  `metaprocess.ml`, `typecheck.ml`, `builtins.ml`, `ast.ml`. Per-statement annotations were removed from
  `core/lambdas/basics`, `core/collections/narrowing`, `core/operators/not_index`, `core/ufcs/with_lambda`,
  `core/variadic/packs/erased`, `stdlib/list/list`, `stdlib/os/pipe_wait`; `types/expected/written_key.txt` changed.
  New fixtures: `core/top_level/one_root`, `errors/each_statement`, `errors/before_initializer`, `uncaught` (`.rt`).
  Not reviewed: the diff has not been read against A5-Q1/I162, and its decisions are not recorded. Static `Display`
  (R19) is not started.

## Next steps, in order
Write every type in the R30 case from here on: `Int`, `String`, `Unit`, `run<Unit>`, `Async`.

1. **Step 5b, finish:** review the one-`__root` work against A5-Q1/I162 and record it as I231 on (with a
   "Fixture changes in S5b" section, explaining `written_key.txt`); then static `Display` (R19): `str<T: Display>` an ordinary generic call, real impls for the
   built-in types, `List<T>` calling `T`'s, which also removes the printer's first-key instance (I223).
2. **Step 5c, the prelude and stdlib redesign** (R29: a redesign, not a mechanical migration): rewrite
   Task/Timer/net/Yield/Iter and async in the prelude and stdlib, with `run<R>`, written handler arguments and
   `@abort` (`exit`); I163's Iter close row.
3. **Step 5d:** rewrite every old fixture in the new syntax.
4. **R7's rest (I224):** a meta block's program is not monomorphized (the readers of meta values compare
   `Core.list` and reify writes `New (name, …)`); local generic types are not copied; no per-copy impl entries.
   Also from 4b: a named handler's impl type parameter named in its body is unknown inside a prompt (I219, review
   after). Doc proposals not made: I201's EffectHandler expansion, I209's `run<Unit>` in the `Console` example;
   `internal-docs/Metaprocessing.md`'s plain-generic and `Type_mono` lines are out of date (I224 (d)), for the user.
5. **After:** `docs/` pages and editor keyword lists (`@abort`, `impl` in a type header, and R30's names: I229 lists
   the files). List the internal-docs and CLAUDE.md rewrites for the user, and do not edit them unasked. Then reach
   full green (`dune test --force`, `dune test cx`, `./scripts/cx-parity.sh`).

How it has been run: one fresh agent per step, working directly in the tree, never in parallel,
because the steps share `typecheck.ml` and `Transform.cx`. Each agent records its decisions as new
I-entries in `scratch/review-later.md`. If an agent fails, do the step in the main session rather than
relaunching one.

## How the user works (from memory on the other machine)
- Never commit or push unless asked in those words. Do the thing asked and stop.
- Questions go in `scratch/questions.md`. Go through them one at a time, one point per message,
  and wait for the reply.
- Explain the gap with a Cronyx example before offering options. Give a recommendation.
- 80% rule: ask only the questions that block the base. Default the edge cases, record them as
  "review after", and revisit once it runs.
- **No hooks, ever:** the compiler never calls library code on a condition (no row hooks, no parse
  hooks). Only explicit calls.
- Fold decisions into the doc body. Never append a "Settled" section.
- Pipeline diagram: boxes are phases, diamonds are data, no error branches, one step at a time.
- Meta blocks can do anything, including the OS. Non-termination is the user's fault, and there is
  no depth limit.
- Code style per CLAUDE.md: comments only for traps or labels, and never describe development.
- `Int` stays a native 63-bit int. Prefer one big PR while at 0.0.x.
