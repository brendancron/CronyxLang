# CPS Migration: handoff

Branch `cps-migration`. This file is the starting point for a new Claude session. Read it,
then `CLAUDE.md`, then the design. Steps 1–5d are built and all three suites are green; nothing past S5a is committed.

## What this branch does
It implements `internal-docs/CPS Migration.md`, and only that document. Do **not** pull in plans
from `Inlining.md`, `Async Strategies.md`, `CPS in Metaprocessing.md` or the other recent docs.
`internal-docs/Vocabulary.md` is the glossary. Use its words: graduate, built-in, key, instance,
monomorphize, Splice, quote. Avoid "template", "comptime function" and "demote".

## Files
- `internal-docs/CPS Migration.md`: the design, and the source of truth.
- `scratch/review-later.md`: every decision.
  - R1–R31 are design-level: the user reviewed them all on 2026-11-22.
  - I1–I319 are implementation entries. Entries marked "To build" are decided and not yet built; those marked
    "review after" are built and wait for the user's review.
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

The three suites (I319):
- `dune test --root . --force` from `bootstrap/`: about 20 minutes, so run it in the background.
- `dune test cx --root .` from the worktree root. It deletes `cx/test/registry/app/cronyx.lock`; restore it with
  `git checkout -- cx/test/registry/app/cronyx.lock` after every run (I230).
- `./scripts/cx-parity.sh` from the worktree root. Its own `dune build` fails in a worktree, so put a `dune` first on
  `PATH` that runs `/usr/bin/dune "$@" --root .`.

## Status (steps 3–5a committed; 5b, 5c and 5d built, not committed)
Steps 3, 4, 4b and 5a and part of 5b are committed on `cps-migration` (`fcc7db5`). Steps 5b, 5c and 5d, I270, and
everything after them are uncommitted work in the tree. Results at the end of 5d (I319):
- `dune test --force`: 1629/1629.
- `dune test cx`: 131/131.
- `./scripts/cx-parity.sh`: 1850/1850.

The only entries left in `expected_failing` and `known_unsound` are the deliberate ones: `tests/compile/m0`–`m8` (`Parked`,
native compilation) and `traits/errors/impl_row_inferred` (I294). Cost: `hello` takes 213 ms to compile and run, as at the
end of 5c (I268). Most of that is the root's I/O handlers.
`scratch/tools/fixtures.py` still counts a few fixtures red that the suite passes: `[lib.cx …]` prefixes and `os/args` (I294,
I309). The suite is the authority.

- **Phases A, B and C1–C7a (earlier):** the metaprocessing core, reflection and Splice, effects as
  traits, `@ctl`, `EffectHandler`, and the library `effect_transform` in `stdlib/core/Transform.cx`.
- **Step 1:** old effect syntax deleted (`cps.ml`, `effect`, `ctl`, `final ctl`, `resume x;`, old handlers, the
  interpreter's Cont/Frame/Abort).
- **Step 2, 2b:** handlers are values (the Koka model, R1). There is one CPS form per function value, and runs that take
  control outward become prompts (I186, I192–I200).
- **Step 3 (I201–I208), 4 (I209–I218), 4b (I219–I225):** `EffectHandler` generic in `Rho`, `run<R>`, `handle<Throw<X>>`,
  `@abort`, `type X impl A, B { … }`, named handlers in prompts, and plain generic types monomorphized (copies named
  `Box<Int>`).
- **Step 5a (I226–I230):** R30's case convention (`Int`, `String`, `Unit`, uppercase user types).
- **Step 5b (I231–I250):** one `__root` for the whole top level, and `__throwing` around a statement that throws. Static
  `Display` (R19): `str<T: Display>`, and every type prints through metaprogramming (I242). `implements(T, Trait)` (I243).
- **Step 5c (I251–I269):** the prelude and stdlib redesign (R29). It covers `Async`, scopes, timers, `block_on`, `Iter`'s
  close row, and Fs/Dirs/Process/Net/Stdin unmarked with `Exit` as `@abort`. `__root` handles the system and
  `__meta_root` handles meta blocks (I260). I270 fixed I265.
- **Step 5d (I271–I319):** every old fixture is rewritten in the new syntax or deleted where a `v2` copy covers it.
  - Batch 1 is `tests/effects`, batch 2 is `effects/errors` with reflection and meta, batch 3 is `tests/core` and batch 4 is
    `tests/stdlib`. Each batch's rules are in "Fixture changes in S5d".
  - Batch 5 reached green. I296's state leak (`Types.declarations` outlived a compile) is fixed (I312). `cx`'s link kept
    `Index<Range>` apart from `Index<Int>` again (I314). A doc comment can stand over a type with members (I315). A meta
    block sees what its own check declares (I317, which fixes I212). Top-level meta blocks run under `__meta_root_io` with
    the file system and the scheduler (I318, which fixes I300).

## Next steps, in order
Write every type in the R30 case: `Int`, `String`, `Unit`, `run<Unit>`, `Async`.

1. **The user's review of every "review after" entry** in `scratch/review-later.md` (I201 on, and the S5b–S5d ones in
   particular). Take them one at a time.
2. **Step "After": the docs and editor keyword lists.** Update the `docs/` pages and the editor keyword lists for `@abort`,
   `impl` in a type header, R30's names (I229 lists the files), and the removed `effect`/`ctl`/`handler` syntax. List the
   `internal-docs/` and `CLAUDE.md` rewrites for the user, and do not edit them unasked. These include I201's EffectHandler
   expansion, I209's `run<Unit>` in the `Console` example, `Metaprocessing.md`'s plain-generic and `Type_mono` lines
   (I224 (d)), and `__meta_root_io` (I318).
3. **R7's rest (I224):** a meta block's program is not monomorphized, local generic types are not copied, and there are no
   per-copy impl entries. A named handler's impl type parameter named in its body is unknown inside a prompt (I219).
4. **Found, not fixed, still open:** I253, I264, I289, I305, and I315's local `Display` type.
5. **Committing**, only when the user asks for it in those words. The tree holds everything from 5b on, uncommitted.

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
