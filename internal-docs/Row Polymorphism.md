# Row polymorphism

A function may abstract over the effects its callback performs:

```cronyx
fn map<T, U, E>(items: List<T>, f: (T) -> <E> U): <E> List<U>
```

`E` is an ordinary type parameter standing in a row, and which of the two a
mention is follows from where it stands. `<E>` alone is the whole row; `<log, E>`
is `log` and whatever else the caller brings.

Inference always had this. Schemes carry `quantified_rows`, `generalize` and
`instantiate` handle row variables, and unification is Rémy-style rewriting over
an open tail. What was missing was everything downstream of it.

## Evidence arity is per instantiation

`Cps` gives a function one evidence parameter per operation in the row it
declares, and a call site passes one per operation in the row it inferred. A
function whose row a caller settles has a different arity at each call, which is
not something one definition can have — hence `Type_mono` copies it, exactly as
it copies a generic body per concrete type.

Two things had to exist for that copy to be correct.

**A resolved row carries its tail.** `resolve_row` used to flatten to labels, so
by the time `Type_mono` ran, "open in a variable" and "empty" were the same
thing and there was nothing to copy per. `row` now holds `tail : int option`,
and `match_rows` reads off what an instantiation settled it to — a difference
between a generic's row and an instance's can only come from a variable,
since a row the definition closed is one the call site would already have been
rejected against.

**A copy is owed only when a parameter brings the row in.** Nearly every
function has an open row, because nothing constrained it; copying those per call
site would copy the program. `row_polymorphic` asks the narrower question —
whether the function's own tail also appears in a parameter — which is the
condition under which evidence arity can differ at all. The tail may also be
one on a function the result holds: `fn counted<E>(f: () -> <E> int): () -> <E>
int` is pure itself, but the closure it builds declares `E`, and compiled once
it took no evidence while a caller holding `() -> <log> int` passed one
(`tests/effects/rows/returned_closure`).

## A declared row is contained, not tied

`admits_row` ties a callee's row to its caller when the callee's row is not yet
known, which is what a forward or recursive reference needs. A row the author
opened is not that, and treating it as such is what made `<log, E>` reject its
own body: unifying `E` with `<log | E>` is recursive. So a declared row survives
unification against an inference variable, the way a declared type parameter
does, and calls through it are contained.

## A row as a type's argument

A type or a trait may take a row as an argument where its parameter stands in
one:

```cronyx
type Iter<T, E> { next: () -> <E> Option<T>, close: () -> unit }
trait Source<T, E> { fn pull(self): <E> Option<T>; }

fn lines(from: Reader): Iter<string, <async, Throw<IoError>>>
impl Source<int, <log>> for Counter { … }
fn drain<S: Source<int, E>, E>(s: S): <E> int
```

Which parameters stand in a row is read off the declaration rather than
written: a type's where its body leaves a row open in the parameter, a trait's
where a method's signature puts it in a row. An argument in that position is
read as a row — `<…>`, or a parameter of the enclosing function, which is a row
there — and any other argument as a type; a row where a type goes, or a type
where a row goes, is an error (`tests/effects/errors/row_argument_kind`).

A row carried as an argument is its own kind of type, `IRow` while checking and
`Row` after, so it unifies, substitutes and is matched by `Type_mono` as a row.
Each declared parameter already had a row variable beside its type variable —
that is how `<E>` in a field was always read — so instantiating a type maps
that row variable to the argument's row, and a fresh instance gives the
parameter a fresh row rather than a fresh type. `Cps.fields_of` substitutes the
rows before it widens a field, since a field's function takes evidence for
what its row argument performs. An impl's `Self` is built with the row in that
position, and an impl method generic over a row is copied per row as a function
is (`tests/effects/rows/row_argument`, `trait_row_argument`).

## What it bought

`stdlib/collections/List.cx` — `map`, `filter`, `fold`, `any`, `all` — takes
effectful callbacks. Before, a combinator was pure-only and abstracting over an
effect meant one copy of it per effect.
