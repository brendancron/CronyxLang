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
  - I1–I200 are implementation entries. Entries marked "To build" are decided and not yet built.
- `scratch/plans/00-unified.md`: the original plan (A1–A10, B1–B6, C1–C10). It has been
  overtaken by the steps below, but it explains the codebase.
- `scratch/questions.md`: older open questions, from the main checkout.
- `scratch/ctl-as-function.md`: the design conversation log.
- `scratch/tools/fixtures.py`: pass counts over every fixture
  (`python3 scratch/tools/fixtures.py [--list-fail] [--out f.tsv]`). Build first.
- `scratch/checkpoints/*.patch`: these are not committed, because they are too big. Each is a
  `git diff` against `d418029` at the end of a step. The committed state is S2b.

## Build
From `bootstrap/`: `dune build --root .`, then
`dune exec --root . bin/main.exe -- ../tests/core/print/hello.cx`.
In a git worktree, plain `dune` fails with "No rule found for alias", so pass `--root .`.
`--dump-code` shows processed code.

## Status (end of step 2b, committed)
Pass counts are 711/947 overall, tests/effects/v2 117/118, tests/core/defer/v2 6/6,
tests/stdlib/v2 4/4, tests/meta 156/160. The rest is red because the stdlib and old fixtures
still use the deleted old syntax. The user has accepted that red.

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

## Next steps, in order
1. **Step 3, correct types.** It was started and stopped half-done, and that work is not
   committed. Redo it from the committed state.
   - R28: rewritten code is type checked from scratch and keeps no types from the code it replaced.
   - I181/I194: the handler plumbing must be genuinely type checked.
   - I132: check arms once, as the record, with errors still at the arm.
   - I143: `EffectHandler` makes each `@ctl` method generic in the row, `fn op<ρ>(…, k: (A) -> <ρ> R): <ρ> R`.
   - I25: a defaulted effect param contributes nothing to the caller's row.
   - A5-Q2 stays.
2. **Step 4, smaller language changes.**
   - `run<R>` is required (R9), and `handle<Throw<X>>` is written (R10).
   - `@abort` (R14).
   - Types are monomorphized like functions (R7; the diagram's diamond is now "call, operator,
     method, type").
   - A static param is a value inside a meta block (R5), so `str(E)` works and the doc's message
     can be restored.
   - `type X impl A, B { … }` (R31, a doc section).
   - A return-type-only param defaults to `Unit` when its value is discarded (I90).
   - Remove the "handler leaves an effect param open" exemption (I68).
   - I197's two refusals.
3. **Step 5, the stdlib rework** (R29: a redesign, not a mechanical migration).
   - One `__root` for the whole top level, with per-statement Throw catchers only where a
     statement throws (A5-Q1, I162).
   - Static `Display` (R19).
   - Uppercase type names (R30: `Int`, `String`, `Async`; convention only, never checked).
   - Rewrite Task/Timer/net/Yield/Iter and async in the prelude.
   - Rewrite every old fixture in the new syntax.
4. **After:** `docs/` pages and editor keyword lists. List the internal-docs and CLAUDE.md
   rewrites for the user, and do not edit them unasked. Then reach full green (`dune test --force`,
   `dune test cx`, `./scripts/cx-parity.sh`).

How it has been run: one fresh agent per step, working directly in the tree, never in parallel,
because the steps share `typecheck.ml` and `Transform.cx`. Each agent records its decisions as new
I-entries in `scratch/review-later.md` and writes a checkpoint patch.

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
- `int` stays a native 63-bit int. Prefer one big PR while at 0.0.x.
