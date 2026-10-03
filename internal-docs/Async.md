# Async

Status: **built.** `std/async/Task` (`stdlib/async/Task.cx`), with
`Promise`, `Channel` and `Timer` beside it and the fixtures in
`tests/stdlib/async/`. `tests/effects/async/` is the effect machinery on its
own, with a hand-written scheduler.

The effect has three operations:

```cronyx
effect async {
    ctl suspend<T>(register: ((T) -> unit) -> unit): T;
    fn waker(): (() -> unit) -> unit;
    fn after(delay: Duration, wake: () -> unit): () -> unit;
}
```

`suspend` hands `register` a callback and parks. Whoever calls that callback
supplies the value `suspend` returns. `waker` hands out the function that puts a
wake-up in the scheduler's queue, and `after` puts one on the scheduler's clock.
Promises, `await`, channels, `select`, `sleep`, `timeout`, yielding and the
scopes — `all`, `interleaved` and `both` — are ordinary code over the three.

## Why these operations

Koka's `std/async` declares four — `do-await`, `no-await`, `async-iox` and
`cancel` — and three of them exist to talk to the host event loop: register a
callback with libuv, run an I/O action at the outer level, cancel an outstanding
request. `do-await` is the only one that is about suspension itself. Cronyx has
no event loop, so the other three have nothing to bridge to and `suspend` is
`do-await` with the platform removed.

`waker` is what a scope needs from the root and cannot make itself: a way to put
a wake-up in the one queue. It hands out a function rather than the queue, so
what reaches the root is only ever something to run. `after` is the same for
time: only the root can wait on the clock, because only the root knows that
every task is parked ([Timers](#timers)).

## A promise is data

```cronyx
type PromiseState<T> {
    Resolved(T),
    Awaiting(List<(T) -> unit>)
}
```

`await` and `resolve` are ordinary generic functions over that, not operations.
They are polymorphic because any function may be; nothing about waiting on a
value needs the handler's help once `suspend` exists.

The two states are exclusive, which is the point of the variant: a resolved
promise cannot still be holding listeners nobody will call.

## The queue holds wake-ups, not tasks

There is one scheduler, `block_on`, at the root of whatever runs asynchronously.
It holds the only queue, and what is in it is wake-ups — a continuation to
resume, `() -> unit` — never a task:

```cronyx
fn block_on<X, E>(main: () -> <async, Throw<X>, E> unit): <Time, E> unit {
    var ready: List<() -> unit> = [];
    var finished = false;
    run {
        run {
            main();
        } handle Throw {
            final ctl throw(e) { panic("uncaught failure: " + str(e)); }
        }
        finished = true;
    } handle async {
        ctl suspend(register) { register(__once((k) => { ready.push(k); }, (v) => { resume v; })); }
        fn waker() { return (k) => { ready.push(k); }; }
        fn after(delay, wake) { … }   // onto the timer list
    }
    // Drain the queue; when it is empty, wait for the first timer and fire it;
    // stop when there is neither.
    …
    if (!finished) { panic("deadlock: every task is waiting, and nothing is left to wake one"); }
}
```

A task is run by its scope. `all` starts each task itself, under its own handler
for `async`; when a task suspends, the arm registers a callback that hands its
continuation to the root, and falls off, which leaves the task parked and the
scope free to start the next one:

```cronyx
fn all<T, X, E>(tasks: List<() -> <async, Throw<X>, E> T>): <async, Throw<X>, E> List<T> {
    …
    for (task in tasks) {
        var slot: Promise<T> = promise();
        slots.push(slot);
        run {
            resolve(slot, task());
        } handle async {
            ctl suspend(register) {
                var wake = waker();
                register(__once(wake, (v) => { resume v; }));
            }
            fn waker() { return waker(); }
        }
    }
    var results: List<T> = [];
    for (slot in slots) { results.push(await(slot)); }
    return results;
}
```

That is [Continuations and Tasks](Continuations%20and%20Tasks.md) applied: a
continuation carries its handlers and asks nothing of whoever runs it, and a task
asks for a handler. So a task runs where its scope is, under every handler between
`block_on` and the scope — before a suspension, and after one too, because what
the root resumes is the task's own continuation. Handing the task itself to the
root instead would need the operation to say what else the task performs, an
effect parameter standing in a row (`effect async<E>`), which the language does
not have. This is Koka's shape: its `interleaved` is `<async|e>` and runs its
strands in its own frame, and what reaches the event loop is a resumption.

The results are in the order the tasks were given, whatever order they finished
in. `interleaved(actions)` is `all(actions)` with the results dropped, and
`both<A, B>(a, b): (A, B)` is the same scope over two tasks of different types —
a tuple of any length would need a pack mapped over a function type, which the
language does not have. A result per task, failed or not, is `all` over tasks
each wrapped in `attempt` ([Errors](Errors.md#a-stored-failure)), which is what
JavaScript's `Promise.allSettled` is for:

```cronyx
var outcomes = all(tasks.map((t) => () => attempt(t)));   // List<Result<T, X>>
```

One queue at the root, and scopes that own none, is also what Eio (`Eio_main.run`
and switches), Trio (`trio.run` and nurseries) and Kotlin (`runBlocking` and
`coroutineScope`) have. It settles two things a queue per scope cannot:

- **Scopes nest.** A wake-up goes to the root whichever scope the task is in, so
  a promise an outer task resolves wakes an inner scope's task. With a queue per
  scope, the inner one drains, returns with its task still parked, and the
  wake-up lands in a queue nobody reads.
- **A deadlock is seen.** When the queue empties before the root task has
  finished and no timer is pending, every task is waiting on something no task
  will do, and `block_on` stops with that rather than returning as if the work
  were done. Only the root
  can tell this from a scope waiting on its parent. Go's runtime makes the same
  call from the same position (`all goroutines are asleep - deadlock!`), as does
  Eio.

A scope carries `async` in its row, so calling one where no `block_on` encloses
it is an unhandled effect, rejected when the program is checked.

There is no spawn. A task exists only by being handed to a scope, which does not
return until every task in it has finished, so nothing outlives the call that
started it, and a task's failure has a scope to go to. The root takes only
wake-ups, and a wake-up is `() -> unit`: it cannot suspend, so it cannot be an
unstructured task either.

## A failure lands in its scope

A failure ([Errors](Errors.md)) in a task is caught by `all`, which puts a `Throw`
handler around each task it starts:

```cronyx
run {
    run {
        resolve(slot, task());
    } handle Throw {
        final ctl throw(e) {
            if (!cancelled) { failure = Option.Some(e); cancelled = true; }
        }
    }
    …   // count the task finished
} handle async {
    ctl suspend(register) {
        var wake = waker();
        register(__once(wake, (v) => {
            if (!cancelled) { resume v; } else { … }   // count it finished instead
        }));
    }
    fn waker() { return waker(); }
}
```

The first failure is kept and the scope's other tasks are cancelled; once every
one has stopped, `all` throws the failure itself, so a handler around the call
catches it. A second failure is dropped with its task. This is where Trio's
nurseries and Eio's switches send a failure too.

A failure no handler catches reaches `block_on`, which stops the program with
the failure's value, as an uncaught exception would. That is also what lets a
scope be called with no `Throw` handler of its own: every scope carries
`Throw<X>` in its row, and `block_on` discharges it.

A task is cancelled at its next suspension point: when it is woken, the scope
does not resume it. A task that never suspends runs to its end first, as it
would in Trio or Eio. A task abandoned this way runs none of its `defer`s
([TODO](TODO.md#defer-under-a-ctl-arm-that-does-not-resume)).

## Timers

`after(delay, wake)` adds a timer to the root's list and hands back what cancels
it. When the queue is empty the root takes the earliest timer still live, waits
for it through `Time.wait_until`, and calls its `wake`; of two due together, the
one set first fires first, so tasks asleep for the same time wake in the order
they went to sleep. A cancelled timer is never waited for, which is why `sleep`
cancels its own in a `defer`: a task abandoned while asleep would otherwise hold
the program open until a timer nobody listens to went off.

The root reads and waits on the clock through `Time`, the effect a program uses
for it, rather than a builtin. So a test that handles `Time` around its own
`block_on` decides how long a sleep takes — `wait_until` there just moves a fake
clock forward, and an hour's sleep finishes at once with the same output every
run (`tests/stdlib/async/fake_clock`). Waiting is the scheduler's alone: a task
that called `wait_until` would hold every other task with it, so tasks `sleep`.

This is the one place the root blocks on the OS, and `net/` will need it to
block on sockets as well as the clock: the wait becomes "until the first timer
or until a socket is ready", in the same position.

## A channel wakes to look again

A `Channel` holds its values and two lists of waiting tasks, one for a value and
one for room. A change wakes every task on the relevant list, and each looks
again, rather than one being handed the value. That costs a woken task that
finds nothing and parks again, and buys `select`: a task waiting on several
channels is on each one's list, and when one wakes it the others' entries go
stale. A stale entry handed a value would lose it; a stale entry told to look
again does nothing, because `select`'s wake-up runs once.

## A timeout unwinds what it abandons

`timeout(limit, task)` runs the task under its own handler for `async` and sets a
timer. While the task is parked the handler keeps a closure that `discontinue`s
it; if the timer fires first, that closure unwinds the task, so its `defer`s run
— the sleeping timer's cancellation among them — and `timeout` returns `None`.
If the task finishes first, its timer is cancelled. A scope's cancellation still
drops the task instead ([A failure lands in its scope](#a-failure-lands-in-its-scope)).

## A task is woken once

The callback `suspend` hands to `register` resumes the task that suspended.
Calling it again would run the rest of that task a second time, and finish it
twice, which throws off any scope counting its tasks. So every callback is made
by `__once`, which panics on a second call, the way `resolve` panics on a promise
already resolved:

```cronyx
fn __once<T>(wake: (() -> unit) -> unit, k: (T) -> unit): (T) -> unit {
    var fired = false;
    return (v) => {
        if (fired) { panic("a suspended task was woken twice"); }
        fired = true;
        wake { k(v); };
    };
}
```

Ignoring the second call, as a settled JavaScript promise does, would hide a
contradiction: the callback carries the value `suspend` returns, and two calls
are two answers.

## An operation binds its own type parameters

`suspend`'s `T` belongs to the operation, not to `async`. It cannot belong to the
effect: a row holds at most one instantiation, so `async<int>` and `async<string>`
in one program would unify into an error rather than describing two suspensions.

Quantifying an operation's result is otherwise unsound — the handler would owe a
value of a type it never agreed to, which is what `final ctl` exists to promise
it never does. `suspend` is safe because `T` is settled by an *argument*: the
handler is given a `(T) -> unit` and can only produce a `T` by being handed one.

A handler is installed once and serves every instantiation, so an arm is checked
under variables it may not settle. Pinning one is rejected —
`tests/effects/errors/arm_settles_op_param`.
