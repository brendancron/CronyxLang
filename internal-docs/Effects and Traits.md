# Effects and traits

An effect is a trait written as its callers see it ([CPS Migration](CPS%20Migration.md#effecthandler)), and a handler is a value of a type implementing it. That leaves two ways to reach the same implementation, and they differ only in where the receiver comes from.

## The receiver from context, or written out

```cronyx
trait Log {
    fn log(msg: String): Unit;
}

type Prefixed impl Log {
    prefix: String,
    fn log(msg: String) { print(self.prefix + msg); }
}

fn greet(name: String): <Log> Unit {
    log("hello " + name);
}

type Counter<L: Log> {
    count: Int,
    logger: L,

    fn bump(self: mut Counter<L>) {
        self.count += 1;
        self.logger.log("count is " + str(self.count));
    }
}
```

`greet` performs `Log`: `log(...)` is the method on whichever handler the run around it bound, passed in as evidence. `Counter` holds its handler in a field and calls the method on that, so `bump` performs nothing and its row is empty. A function means *whoever is in scope*; a field means *the one this value was made with*, and nothing turns one into the other. A method that wanted the field's handler to answer its own effect calls would have to wrap its body in a `run` handled by `self.logger`, which costs a `run` per method and falls back to the caller's handler silently in any method that leaves it out.

Provided methods of the trait are written once and serve both: a `fn warn(msg: String) { log("warning: " + msg); }` in `Log` is `warn(...)` in `greet` and `self.logger.warn(...)` in `Counter`.

## Taking the handler in scope as a value

A constructor can perform the effect without calling any of its operations, and keep the handler:

```cronyx
fn counter(): <Log> Counter<?> {
    Counter { count: 0, logger: handler<Log>() }
}

var c = run {
    counter()
} with Prefixed { prefix: "[c] " };

c.bump();
```

`handler<Log>()` is the handler answering `Log` where it is written (spelling not settled). It already exists as a value — the evidence every instance under the run's key takes as a parameter — so this only names it. Its type is the static handler type the row binds, so `Counter`'s `L` is inferred as `Prefixed` and nobody writes it. `c.bump()` logs with `"[c] "` wherever it runs, after the `run` has ended.

## Open

- **`self` in an operation.** `Log` declares `fn log(msg: String)` with no `self`, which reads as a static method, yet `Prefixed.log` reads `self.prefix` and `self.logger.log(...)` calls it on a value. Either every operation of an effect implicitly takes the handler as `self`, or effects declare it as ordinary traits do.
- **`@ctl` operations.** A `@ctl` operation needs the continuation of a run, so it cannot be called on a stored handler outside one. Only an effect with no `@ctl` operation — one that is its own `EffectHandler` — can be held in a field and called explicitly.
- **A handler outliving its run.** A `handle` block captures what it reads by reference, so a handler taken out of a `run` with `handler<E>()` dangles once that frame returns, as `&` to a returned frame does.
