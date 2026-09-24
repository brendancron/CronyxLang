# Meta scope and instantiation

"Static" and "dynamic" are not properties a construct has. They are a question
asked from a scope, and the same construct answers differently depending on
which scope asks. A static parameter `n` is static to the function's body and
dynamic inside a `meta` block in that body — not because anything changed, but
because the question did.

Two operations cross the boundary between a scope and a `meta` scope inside it,
and they are inverses:

- **`meta` demotes.** A meta scope receives the static constructs of the scope
  around it, and receives them as *dynamic*. The dynamic constructs of that
  scope are not received at all.
- **`gen` promotes.** A dynamic construct inside a meta scope can be written
  into the code that scope emits, where it is static.

Everything below is those two sentences applied. There is no third case, and
nothing crosses more than one boundary per operation.

## `meta` demotes

Inside a meta block, a static parameter is an ordinary value. That is the whole
point — it makes analysis ordinary code:

```cronyx
fn fib<n: int>(): int {
    meta {
        print("Mono " + str(n));
        if (n <= 1) {
            gen return 1;
        } else {
            gen return fib<n-1>() + fib<n-2>();
        }
    }
}
```

The `if` is an `if`. Nothing about it is special, because `n` is a value there.

Two things follow from `n` being *dynamic* inside the block rather than merely
available:

**It cannot be a static argument there.** `fib<n>()`, written in the meta block
and not inside a `gen`, asks for an instantiation whose argument is a dynamic
construct of that scope. It is the same error as writing `fib<d>()` in ordinary
code, and it says so: *'fib' cannot be instantiated from inside a meta block:
'n' is a value there. Write the call inside a gen.*
(`meta/05_order/errors/static_arg_in_meta`). There is no deep reason it could
not be made to work — the metaprocessor would have to re-enter itself from
inside an interpreter frame, mid-block — but nothing a `gen` cannot express
needs it.

**It does not reach a further meta block.** A `meta` inside a `meta` receives
the static constructs of the scope around it, and in that scope `n` is dynamic.
So it does not cross a second time. What crosses a boundary is decided by what
a construct *is on the outside of it*, which is why one demotion is where it
stops: *'n' is a value of the enclosing meta block and does not cross into a
nested one.* (`meta/05_order/errors/double_demotion`).

An ordinary parameter never crosses at all, for the same reason: `d` is dynamic
in the function's body, so `meta print(d)` has nothing to receive. That is an
error rather than an unimplemented case: *'d' is a run-time parameter and does
not cross into a meta block.* (`meta/05_order/errors/dynamic_in_meta`).

A type parameter is the exception, because a type is not a value in a meta
block. It is not demoted; it is written by name everywhere in the
instantiation, the meta blocks included, so `typeof(S).name` in a block reads
the type the call was made at (`meta/05_order/07_type_mono`).

## `gen` promotes

A `gen` writes code for the scope above, so a dynamic value of the meta scope
appearing inside it crosses the other way. Crossing means being *written
down*: the value becomes the syntax that denotes it, which is
[Reify](Reify.md).

**The arithmetic happens below.** `gen return fib<n-1>()`, in the instantiation
for `n = 4`, emits `fib<3>()` — not `fib<n-1>()`. The subtraction is ordinary
code in the meta scope, and its result is what crosses. That is why the
instantiation asked for is `3`, and why the promoted argument is static where it
lands even though `n` was dynamic where it was read.

**What is promoted is the largest piece that can be.** Inside a `gen`, the
largest subexpression that reads a meta-scope value and otherwise names only
what the meta program can see is evaluated while the block runs and written
back; the rest stays syntax. A statement's own call is never evaluated whole,
only its arguments, and a static call never is, though its static arguments
are — which is exactly what `fib<n-1>()` needs (`meta/02_gen/promote`,
`meta/05_order/19_gen_static_arg`).

**Not every value can cross.** Reify is a structural judgement on the value:
scalars, tuples, arrays and records can be written down when their parts can; a
function never can, and saying so is an error at the `gen`
(`meta/02_gen/errors/reify_fn`). That is the limit on promotion, and it comes
from the value rather than from anything written.

A name the meta scope does not bind is not promoted: it is quotation, and it
resolves in the *emitted* scope:

```cronyx
var y = 4;
meta {
    gen var x = y + 5;      // the runtime y, not a meta-level one
}
print(x);                   // 9
```

```cronyx
meta {
    var xs = [1, 2, 3];
    gen print(xs);          // emits print([1, 2, 3])
}
```

A name bound on both sides means the meta binding, since the `gen` is written in
the meta scope. A declaration inside the `gen` is the exception — it binds its
own name in the code it lands in (`meta/02_gen/shadowed_local`).

## Instantiation is demand-driven

An instantiation is created when it is asked for, its body's meta runs at that
moment with the arguments bound, and the result is remembered under those
arguments. Demand is depth-first, since a `gen` mentioning `fib<n-1>` asks for
that instantiation while producing the body that needs it.

Order therefore follows the call sites (`meta/05_order/21_demand_order`,
`22_demand_order_reverse`, where the body prints `fib<n>` rather than `Mono n`):

```cronyx
print(fib<2>());        print(fib<4>());
print(fib<4>());        print(fib<2>());
```

```
Mono 2                  Mono 4
Mono 1                  Mono 3
Mono 0                  Mono 2
Mono 4                  Mono 1
Mono 3                  Mono 0
```

Left: `fib<2>` walks 2, 1, 0; `fib<4>` then walks 4, 3 and finds the rest
already made. Right: `fib<4>` walks the whole chain and `fib<2>` finds
everything.

The compile-time output of a program is thus a function of the order of its call
sites. Deterministic, but a contract rather than an accident: moving a call
changes the order a `meta` prints in.

## Memoization is the semantics, not an optimization

`fib<2>` is demanded twice in the left column — once directly, once through
`fib<3>` — and `Mono 2` prints once. Three reasons that is the right answer:

**Identity.** [Static Params](Static%20Params.md) says `addPrintStatic<3,4>` is
physically a different function from `<5,6>`. The converse is the same
statement: two uses of `<3,4>` are the *same* function.

**Correctness.** Each instantiation is emitted as a declaration. Making one
twice emits two declarations under one name, which is a duplicate rather than a
slow build — and runs its `meta` twice, which a program can see.

**Cost.** Without the table, `fib<n>` instantiates its whole call tree —
exponential compile time for a function that is linear at runtime.

The table is the walk's: `copies` in `Metaprocess`, keyed by the name and the
static arguments, handing back a mangled instance and consulted before making
another. It is one table for the whole program, so two modules asking for
`util.f<1>` get one copy (`meta/06_modules/template_two_importers`). An
instantiation is entered in it before its body is walked, which is what makes
mutual recursion between templates terminate (`meta/05_order/20_template_mutual`).

## Bound, not substituted

A static parameter has to be *bound* where the instantiation is made rather than
substituted through the body as a literal. Substitution puts `4` everywhere the
name appeared, including inside a nested meta block — so `n` arrives in a scope
that should never have received it, and the rule that stops it has to be
reimposed as a special case against the pass that broke it.

Binding also gives the diagnostics somewhere to stand: a construct used where it
is not received can say which scope demoted it, instead of arriving as
`Undefined variable`.

So an instantiation substitutes a value parameter only *outside* its meta
blocks, where it is part of the code, and binds it inside them with a
`var n = <literal>;` at the head of each block's program. A block nested in one
of those does not see the binding, and the double-demotion error above falls out
rather than being enforced.

## Where it happens

Instantiation is part of the metaprocessing walk, not a pass after it. There is
no separate value monomorphizer: a value can decide what a body's `meta`
generates, and so its type, so the walk has to make the copy before anything can
check it. The walk reaches a call, makes or finds the instantiation, walks its
body — running its meta blocks with the arguments bound, and reaching whatever
their output calls — and rewrites the call to the copy. `meta` in a function
body is simply part of that body's walk.

A template taking only types, whose body runs no meta block, is left to
`Type_mono` after checking, since inference is what says which types it is used
at. One whose body runs a meta block is made by the walk too, since the block
may read the type, and so needs that argument written — or visible from what
built the value — at the call: `printSpeak<Cat>(cat)`, not `printSpeak(cat)`.

For the order in which nested blocks are processed, spliced and executed — a
separate question from what crosses between them — see
[Metaprocessing](Metaprocessing.md).

## Decided

**Termination.** There is no bound. `fib<n-1>` stops on its base case;
`fib<n+1>` does not, the same as a run-time function recursing without one. A
budget on compile-time work belongs to the evaluator, as
[Metaprocessing](Metaprocessing.md#the-evaluator-is-a-parameter) says, not to
instantiation.

**Declarations made during instantiation.** A body's `gen` that emits a
declaration emits it into the body, local to that instantiation, so two
instantiations generating the same helper each get their own
(`meta/05_order/15_gen_local`). Nothing else sees it, which settles whether a
top-level block that already ran should. An `impl` has no local form, so
generating one in a body is an error: *An impl cannot be generated inside a
function body.*

## Open

**Reifying a trait object.** An object is data beside a table of functions, so
the structural rule says never. Reifying the concrete value instead, and letting
the coercion at the destination rebuild the table, is probably the answer, since
an object only exists where the trait was written as a type.
