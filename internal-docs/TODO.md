# Open questions

Decisions deferred deliberately, with enough context to pick them up cold. A line leaves when it is answered — in the document that owns the subject, not here.

## When a declaration query runs

Owner: [Attributes and Test Frameworks.md](Attributes%20and%20Test%20Frameworks.md)

Metaprocessing generates declarations, so a `gen` can emit a function carrying `@Test`. A meta function that enumerates declarations therefore sees a different program depending on when it runs, and nothing in the source says when that is — it falls out of the metaprocessor's walk order, so adding a file could change which tests exist.

The three answers in the wild: rounds to a fixpoint, as Java's annotation processors do; a hard phase split where generation finishes before any query runs and generated code is invisible to other generators, as C# source generators do; or no answer at all, as Rust proc macros, which is why that ecosystem builds registries at link time instead.

The phase split looks right — every use case so far only reads a finished program and emits a table, never needs its output visible to another generator — but nothing depends on choosing yet, and the first collector that wants to react to another's output is the case that decides it.

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
