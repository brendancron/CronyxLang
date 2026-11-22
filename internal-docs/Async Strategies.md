# Async strategies

Status: **proposed.** Nothing here is built. It replaces `ctl` and effect
handlers, and builds on [Inlining](Inlining.md) and
[Static Params](Static%20Params.md). The async that exists today is
[Async](Async.md).

How a function suspends is not a compiler feature. A library writes it, as a
comptime rewrite of the function, and a program picks one the way it picks any
static argument:

```cronyx
my_async<KotlinAsync>();
```

## What `ctl` does today

The stdlib uses `ctl` in three ways, and none of them resumes more than once.

**Abort: never resume.** These are the `final ctl` operations, with 23
handlers across the stdlib:

```cronyx
effect Throw<X> { final ctl throw(err: X); }
effect Exit { final ctl exit(status: int); }
```

**Resume once, later.** The handler keeps the rest of the computation and
resumes it, or discards it, at some later point:

```cronyx
ctl suspend<T>(register: ((T) -> unit) -> unit): T;   // async/Task.cx
ctl yield(value: T): unit;                            // iter/Yield.cx
```

`iterator` stores `() => { resume; }` and calls it on the next `next()`. A task
stores its resumption until I/O wakes it. `discontinue` unwinds a resumption
instead of running it.

**Resume immediately, but the handler might wait first.**

```cronyx
ctl open(path, mode) { resume __open_on_disk(path, mode); }
```

`open` is `ctl` only so the handler is allowed to suspend. Once a handler is a
static function and a function can suspend, it is an ordinary function.

Multi-shot resumption, where `choose` runs the same continuation twice,
appears only in `tests/`.

## How other languages suspend

| | Saved state | Which functions can suspend | Pointer to a local |
|---|---|---|---|
| C# / Kotlin | one heap object per suspending frame | `async` / `suspend` only | lives in the frame object |
| Go / Lua | a whole heap-allocated stack | any | stays valid; Go rewrites it if the stack moves |
| Koka / Cronyx today | heap closures built while unwinding | effect-typed only | captured by a closure |

All three keep suspended state on the heap. Each is a different trade-off, and
the point of a strategy is that the compiler does not pick one.

## A strategy is a rewrite

Under the C# / Kotlin strategy, this source:

```cronyx
async fn my_async(): unit {
    another_async();
}
```

becomes a state machine:

```cronyx
type Poll { Done, Pending }

trait Continuation {
    fn resume(self): unit;
}

type MyAsyncFrame {
    state: int,
    caller: Continuation,
}

fn my_async(frame: MyAsyncFrame): Poll {
    match frame.state {
        0 => {
            frame.state = 1;
            var inner = AnotherAsyncFrame { state: 0, caller: frame };
            match another_async(inner) {
                Poll.Pending => { return Poll.Pending; }
                Poll.Done => {}
            }
        }
        1 => {}
    }
    return Poll.Done;
}

impl Continuation for MyAsyncFrame {
    fn resume(self): unit {
        match my_async(self) {
            Poll.Pending => {}
            Poll.Done => { self.caller.resume(); }
        }
    }
}
```

When `another_async` suspends, it returns `Pending`. `my_async` returns
`Pending` too, and so on up to the scheduler. The native stack is then empty,
and all that remains is the chain of frames, each pointing to its caller. When
the I/O finishes, `another_async`'s frame runs to the end and resumes
`my_async`'s frame. That frame's `state` is `1`, so it skips past the call.

A local that is live across a call becomes a field of the frame. Each further
call adds a state.

The output is ordinary Cronyx, so static params and inlining apply to it like
anything else. If `another_async` is `inline`, the two state machines merge into
one frame.

`KotlinAsync` is the library code that performs this rewrite. Another strategy
is another library, and two can live in one program.

## The strategy is passed down

A strategy is a static param, so it is passed to every function that needs it:

```cronyx
fn my_async<S: AsyncStrategy>() {
    another_async<S>();
}
```

Instantiating `my_async<KotlinAsync>` reaches `another_async<KotlinAsync>()`,
and the walk instantiates that copy with the same strategy. Coloring still
exists, but it is written out, and a function written over `S` works with any
strategy.

## Functions inherit a strategy through rows

A higher-order function does not name a strategy:

```cronyx
fn for_each<T, E>(xs: Array<T>, f: (T) -> <E> unit): <E> unit {
    for (x in xs) { f(x); }
}

fn my_async<S: AsyncStrategy>(urls: Array<string>) {
    for_each(urls, (u) => { fetch<S>(u); });
}
```

`for_each` performs whatever its callback performs, so this instance of
`for_each` has the row `<S>`, and `S` rewrites it too. Without that, `fetch`
would return `Pending` into a loop that cannot unwind or resume, and the
suspension would be lost.

This is effect polymorphism, implemented with row polymorphism as in
[Row Polymorphism](Row%20Polymorphism.md). `Type_mono` already makes a separate
copy of a function for each row a caller settles. What changes is what the
copy is for: a strategy rewrites it, where today it takes different evidence.
Effect rows stay as type-level bookkeeping, and handlers, the runtime half, go
away.

## Rewrites run after type checking

Nothing at the call to `for_each` says it needs `KotlinAsync`. Inference works
that out from the closure. So a strategy cannot run in the metaprocessing walk,
which comes before checking. It has to run once the rows are inferred.

That makes a loop:

1. The walk runs. `for_each`'s row is not known yet.
2. Checking infers that this `for_each` has the row `<KotlinAsync>`.
3. `KotlinAsync` rewrites that instance. The new code has to be checked itself.
4. The rewrite can reach things the walk never visited, such as `Poll` or a
   comptime function the strategy uses, which needs the walk again.

Instead of a walk and then a check, compilation becomes walk, check and
rewrite, repeated until nothing new appears. That means revisiting how the
type checker and metaprocessing fit together. One thing to settle when that
happens is whether a rewrite returns typed code, so step 3 needs no full
re-check, or plain code that is checked again.

## What the language still owes

A stackless strategy, like the one above, is a pure rewrite, so a library can
write all of it. A stackful strategy rewrites nothing, but it needs a way to
switch stacks at run time, and library code cannot provide that. So the
language still has to supply one stack-switch primitive, even though every
strategy built on it is library code.

## Open

Whether multi-shot resumption survives. Nothing in the stdlib uses it. Keeping
it means a strategy must be able to copy a continuation. A stackful strategy
would then have to copy a stack, and a pointer to a local in the copy would
still point into the original. That collides with
pointers to locals ([Boxing and References](Boxing%20and%20References.md)).
