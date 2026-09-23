# GADT refinement

How a match arm learns what a constructor says about the scrutinee, why the way
it does that now is unsound, and which of four fixes to take.

The declaration syntax and what shipped are in
[type-system.md](Type%20System.md); this is only the refinement.

## What refinement has to do

```cronyx
type Expr<T> {
    Lit(int)                            -> Expr<int>,
    Add(Expr<int>, Expr<int>)           -> Expr<int>,
    BoolLit(bool)                       -> Expr<bool>,
    If<A>(Expr<bool>, Expr<A>, Expr<A>) -> Expr<A>,
}

fn eval<T>(e: Expr<T>): T { … }
```

In the `Lit` arm, `return n` has to typecheck against `T` while `n` is an `int`.
That is only sound because reaching the arm means the value was built by `Lit`,
and `Lit` builds an `Expr<int>` — so in that arm, and only there, `T` is `int`.

Three properties are wanted, and they pull against each other:

1. The equation holds inside the arm.
2. It does not hold outside it — the next arm says `T` is `bool`.
3. Everything else the arm does to the type store is ordinary and permanent.

## What it does now

`refine` unifies the scrutinee's arguments with the head the constructor builds,
`Types.retracting` records every cell written from then until the arm ends, and
restores them all. The arm's own tree is snapshotted first — `Types.snapshot`
expands what is bound and keeps sharing what is not — or the annotations would
be undone along with the equation.

This gets (1) and (2). It fails (3).

## The hole

```cronyx
fn f<T, U>(q: Q<T>, p: U): int {
    match q { Q::Num => { print(p + 1); }  Q::Text => { } }
    print(p + "s");
    return 0;
}

print(f(Q::Num, "boom"));
```

`U` belongs to the function, not to the refinement. The arm pins it to `int`,
retraction takes that back, and `string` sticks after the match. The program is
accepted and dies at runtime on `Operator is not defined for string and int`.

The same shape on an ordinary sum is rejected at compile time, so this is the
price of substitute-and-undo rather than something older.

`tests/types/gadt/errors/leaked_constraint` holds the case and the diagnostic it
should produce. The harness's `known_unsound` list asserts it is *still* wrongly
accepted, and announces the moment it starts being caught.

## Why the obvious narrowing does not work

Record only during `refine`, not for the whole arm. `U` is then left alone,
which is exactly what is wanted.

It breaks `If<A>`. The recursive `eval(c)` unifies `eval`'s parameter `Expr<T>`
with `Expr<bool>`, and `hoist` binds a function monomorphically while its own
body is checked, so that pins the arm's `A` to `bool`. The wide retraction
currently undoes it and the arm stays generic. Narrow the retraction and the arm
is compiled as though `A = bool`, which is wrong for
`Expr::If(…, Lit(1), Lit(0))`.

**The retraction is load-bearing for two unrelated reasons and only one of them
is legitimate.** Anything that fixes the leak has to answer the recursion
question at the same time. That is the constraint the options below are shaped
by, and it is the thing that is easy to miss.

## The four options

### A — a generation-marked trail

Stamp each variable with the counter at arm entry. Retract only cells for
variables created after that mark, plus the ones `refine` itself wrote. `U` is
older and survives; `A` is newer and stays generic.

**Rejected.** An arm that links an old variable to a new one loses the
constraint anyway: `U := β` is kept because `U` is old, `β := int` is retracted
because `β` is new, and `U` ends up pointing at an unbound variable. Unsound by
a second route. It is the cheapest option and it trades a known hole for a
subtler one.

### B′ — substitute into the arm's view, leave the store alone — **done**

Solve `scrutinee args ≡ variant head` into an ordinary substitution — a one-way
match returning an assoc list, not a mutating unification — and apply it to
everything that *enters* the arm. Check the body normally. Nothing global is
mutated, so nothing needs taking back: `p + 1` constrains `U` permanently and
`p + "s"` is correctly rejected.

"Everything that enters the arm" is the whole of it, and the narrower reading —
the return type and the payload only — is not enough. A parameter of the refined
type reaches the arm through the *environment*:

```cronyx
fn eval<T>(e: Expr<T>, acc: T): T {
    match e {
        Expr::Lit(n)     => { return acc + n; }
        Expr::BoolLit(b) => { return b; }
    }
}
```

`acc` keeps its unrefined `T`, `acc + n` pins `T := int` globally, and the
`BoolLit` arm then fails. An accumulator is a far more likely program than a
local annotation, and this one **works today** —
`tests/types/gadt/accumulator` guards it, so the narrow reading of B would show
up as a regression rather than as a new limit.

So the substitution is applied at four places:

- the arm's scope, rebuilding the visible bindings through
  `Types.substitute mapping` — the fresh `new_env` is already built there, so
  this is a shallow rebind rather than a new mechanism
- annotations resolved inside the arm, which is what makes `var x: T = 5;` work
  rather than being the stated cost
- the scrutinee's own annotation, so `e` is an `Expr<int>` in the `Lit` arm and
  can be passed on as one
- the expected return type and the payload bindings

**What it needs.** The polymorphic-recursion fix, as a companion: a function
with a written signature must bind its **recursive occurrence** to that
signature generalized rather than to `Types.mono` (`typecheck.ml:1460`). The
retraction has been standing in for the absence of it.

**What it removes.** The body-wide `Types.retracting` at `typecheck.ml:1806`,
and the whole `freeze_expr`/`freeze_stmt` walk, which has exactly one call site
and exists only to survive that retraction — around forty lines. The trail
itself stays, used solely for the reachability probe at `typecheck.ml:1741`,
which is a genuine throwaway and what a trail is good at.

**What is left over.** A type variable that reaches the arm through inference
rather than through a written type or a binding. Nothing in the suite hits it,
and the predicted cost — `var x: T = 5;` inside a refining arm — does not
happen: the arm's annotations are rewritten too, so it works. Reusing the
scrutinee at its refined type works for the same reason.

**One thing the plan missed.** `in_ctx` puts the whole context back, and
`saw_return` is a fact about the *function*, not the arm. Restoring it made
every refining function look as though it never returned, and its result was
unified with `unit`. It is carried out of the arm by hand.

### D — reject the leak instead of fixing it — **done**

Take A's machinery — mark the counter at arm entry — but instead of narrowing
what gets retracted, **error** when the arm is about to retract a write to a
variable that predates the mark:

```
This arm constrains 'U', which this match does not refine.
```

Soundness is restored immediately. `If<A>` is untouched, because `A` is created
inside `refine` and so is post-mark and retracts as it does today. `freeze_expr`
stays. `leaked_constraint` moves out of `known_unsound` and into `error_cases`.
It also catches A's own counterexample, since the write to the old `U` is the
error whatever `β` goes on to do.

The cost is false positives: an arm where pinning `U := int` was in fact
consistent gets rejected. Same safe direction as B′, and a strictly smaller
change.

`Types.retracting ~beyond` sets the horizon; `Types.unguarded` turns it off for
`refine` itself, whose whole job is to write older variables. The trap predicted
here — that D depends on which side of the refinement `unify` keeps — did not
bite, because the polymorphic-recursion step had already made a declared
parameter the survivor. Two others did.

**The row guard was too blunt.** Applying the same horizon to effect rows
rejected `tests/types/gadt/main`: a function's own binding has
`quantified_rows = []`, so the declaration's row variable is *shared* into every
call site, and a recursive call writes it legitimately. Rows are unguarded, and
the effect leak stays open — see below.

**A no-op write looked like a constraint.** Unifying two variables rewrote the
survivor's cell to recompute its kind even when nothing changed, which against
an older variable is indistinguishable from the arm constraining it. It is
skipped when both kinds are `Any`, which is the overwhelming majority.

This is the interim that closes the type hole. It is not a replacement for B′:
rejecting a program is not the same as typing it.

### The same leak, still open, in the effect row

`tests/effects/errors/leaked_effect` — an arm that performs an effect the
function does not otherwise reveal. The retraction takes the row write back, the
function is inferred pure, nothing asks for a handler, and `ev#note` is missing
at run time. Registered in the harness's `known_unsound` list, and the reason it
is not guarded is the shared row variable above.

B′ closes it for the same reason it closes the type case: nothing is retracted,
so nothing is lost.

### C — skolemise and carry equations

The arm's parameters become rigid constants, the refinement becomes an equation
set, and `unify` normalizes against it. Sound and complete. This is what OCaml
does.

**A deliberate exception to Koka-as-tiebreaker**, rather than an oversight:
Koka has no GADTs, so it has no answer to copy. OCaml has them in the same
HM-with-unification setting this checker is, which makes it the reference for
this one question.

It is a rewrite of the one function every pass depends on. The endgame, and its
own piece of work rather than a follow-on from B.

## Direction

Three steps, in this order.

1. ~~**Polymorphic recursion**, on its own.~~ **Done.** The recursive
   occurrence of a function with a written signature is bound to that signature
   generalized. Two things fell out that the plan did not anticipate: a declared
   parameter has to win unification, or an operator aliasing it leaves the
   scheme's recorded id pointing at nothing; and `Type_mono` needed both a
   self-call exclusion and a depth cap, because polymorphic recursion cannot be
   monomorphized at all. See [type-system.md](Type%20System.md).

   `If<A>` no longer depends on retraction for its genericity, which is what
   step 3 was waiting for.
2. ~~**D**, so the hole closes now.~~ **Done** for types.
   `tests/types/gadt/errors/leaked_constraint` is an `error_cases` fixture now.
   The effect row is not covered and remains `known_unsound`.
3. ~~**B′**~~ **Done.** `Types.solve` produces the refinement as a
   substitution, and it is applied to the payload, the expected return type, the
   names in scope whose type mentions a refined variable, and what a written
   `T` means inside the arm. The store is untouched, so a constraint the arm
   places on anything else is ordinary and permanent.

   Both leaks are closed. `tests/types/gadt/errors/leaked_constraint` and
   `tests/effects/errors/leaked_effect` are `error_cases` now, and
   `known_unsound` is empty. D's rejection is gone with it: an arm that
   constrains an outer variable *consistently* is accepted again, which D could
   not tell from the unsound case.

   Deleted: the `freeze_expr`/`freeze_stmt` walk, and the horizon guard D
   needed. `Types.retracting` is kept but is now used by nothing — a
   speculative unification is the obvious next thing to want, and that is how
   it is done here.

C stays where it is: the thing to do if refinement ever needs to be trusted
rather than merely useful. What would call for it is a refinement whose
consequences have to flow *back* out of an arm, which a substitution into the
arm's view cannot express.

**The fixture moved twice, as predicted.** Under D it said what the arm did
wrong; under B′ it says `[14:11] No operator + for int and string.` and
`[18:7] Expected int, got string.` — exactly what the same program over an
ordinary sum says, which is the point.

## What works, and what has not been tried

Covered by fixtures: refinement in a free function and in an `impl` method;
a variant binding parameters the head does not mention, and one whose head is
built from two at once (`tests/types/gadt/pair` — `Pair<A, B> -> Expr<(A, B)>`
and `Fst<A, B>(Expr<(A, B)>) -> Expr<A>`); an accumulator of the refined type;
polymorphic recursion; exhaustiveness against a concrete scrutinee, so
`eval_int(e: Expr<int>)` needs only the arms that can occur; a wildcard arm;
length indexing, where `head` takes a vector that cannot be `Nil`. Reflection
reads a GADT's shape, and a GADT crosses a module boundary.

Rejected, with fixtures: an ill-typed tree, an arm returning the wrong type for
its refinement, a genuinely non-exhaustive match, an arm for a variant that
cannot occur, and both leaks.

**Not GADT-specific, but it bites here.** A `match` on an unannotated lambda
parameter fails — *Only a sum type can be matched, and this is '331* — because
nothing tells inference the parameter is a sum before the match is reached. An
ordinary sum fails the same way, so this is inference, not refinement.

**Not tried.** A refining match inside a meta block, and a GADT built by
generated code.

## What would settle it

Nothing, by decision. The question this document originally asked — whether
rejecting `var x: T = 5;` inside a refining arm is acceptable — was the wrong
one: B′ substitutes into the arm's annotations, so that case works, and the real
cost was the environment, which B′ also covers. What is left over is narrow
enough that the suite answers it once B′ exists.
