# Errors

Status: **built.** Everything here is `std/core/Error`, with the fixtures in
`tests/stdlib/throw/`; [Async](Async.md) uses it.

A failure is a typed value, performed through one effect:

```cronyx
effect Throw<X> { final ctl throw(err: X); }
```

```cronyx
type IoError { NotFound(string), Denied(string) }

fn read(path: string): string {
    if (!exists(path)) { throw(IoError.NotFound(path)); }
    …
}

run {
    print(read("config.toml"));
} handle Throw {
    final ctl throw(e) {
        match e {
            IoError.NotFound(p) => { print("no such file: " + p); }
            IoError.Denied(p) => { print("not allowed: " + p); }
        }
    }
}
```

## Why a value and not a string

A string is read by the caller or not at all, so telling one failure from another
means matching on its wording, and the wording becomes an interface nobody
declared. A value is matched on, carries what the failure was about (the path, the
line), and a case the handler forgets is a case the checker can see.

## Why one effect

A row holds one instantiation of an effect
(`tests/effects/generic/errors/two_instantiations`): a `throw(e)` picks its handler
by the type of `e`, which inference may not have settled yet. So a function throws
one error type, and where two meet they are wrapped in a sum:

```cronyx
type LoadError { Io(IoError), Parse(ParseError) }
derive Wraps for LoadError;

fn load(path: string): <Throw<LoadError>> Config {
    var text = rethrow { read(path) };
    return rethrow { parse(text) };
}
```

`rethrow` converts with `To`, as Rust's `?` converts with `From`, so the call
says nothing about which variant: the error type decides it. The written row is
what a caller matching on the variants needs; with only one `To` from each error
type, inference settles it without one.

The alternative was an effect per failure domain — `IoFailed`, `ParseFailed` —
which coexist in a row and need no wrapping. It was not taken because code could
then not be generic over *the* failure: rows abstract over effects wholesale, and
`attempt`, `retry`, and a scope catching a failed task ([Async](Async.md)) each
need to intercept a failure without knowing its kind. With one effect each is
written once, over `Throw<X>`.

Zig removes the wrapping another way, by inferring a function's error set as the
union of what its body can fail with. Here that would be a row holding several
`Throw` instantiations, which the reason above rules out while a `throw` can be
reached before its argument's type is known. Zig's errors carry no payload, which
is why the question does not arise there.

## `final ctl`

A thrown error never resumes the code that threw it, which is what `final ctl`
says. It also makes a failure free on the path that does not fail: no
continuation is captured, and the throw is an unwind ([Algebraic
Effects](Algebraic%20Effects.md#what-each-translation-costs)). A failure a handler
answers with a value, so the work carries on, is `Fallible<T>`, a different tool.

## A stored failure

A failure that has to be kept — one per task in a scope, one per line of a file —
is a `Result`:

```cronyx
type Result<T, X> { Ok(T), Err(X) }

fn attempt<X, T, E>(f: () -> <Throw<X>, E> T): <E> Result<T, X> { … }
```

`attempt` turns the effect into the value and `rethrow` goes from one error type
to another; both are ordinary library code over `Throw`. `attempt` around work
that throws nothing still has an `X`, which nothing settles; `Type_mono` gives it
a type of its own choosing, since no value of it can exist.

## A catch-all

Precise error types everywhere are tiring, which is why Rust applications reach
for `anyhow`, and why Swift, having added typed `throws(E)`, still recommends
untyped `throws` for most code. The catch-all here is a trait object:

```cronyx
trait Failure { fn message(self): string; }
impl Failure for string { fn message(self): string { return self; } }

fn fail<T>(err: Failure): <Throw<Failure>> T { return throw(err); }

fn step(n: int): int {
    if (n == 1) { return fail(IoError.NotFound("a.toml")); }
    if (n == 2) { fail("just a message"); }
    return n;
}
```

`fail` exists because a trait object is made only where its type is written
([Static vs Dynamic Invocation](Static%20vs%20Dynamic%20Invocation.md)): `throw`'s
parameter is `X`, inferred, so `throw(ParseError.BadLine(3))` in a function
already throwing `Failure` is a second instantiation, not a coercion. `fail`'s
parameter is written, so its call coerces. It answers with any type, as `throw`
does, so it stands where a value is expected. Being a `Throw<X>` like any other,
the catch-all works with `attempt` and everything else generic over the failure.

## Wrapping, generated

A sum of error types needs a conversion per variant to be used with `rethrow`.
`Wraps` derives them, which is what Rust's `thiserror` crate exists to do:

```cronyx
type LoadError { Io(IoError), Parse(ParseError) }
derive Wraps for LoadError;
// impl To<LoadError> for IoError { fn to(self): LoadError { return LoadError.Io(self); } }
// impl To<LoadError> for ParseError { … }
```

A variant gets one only when it carries exactly one value of a plain named type,
which is what reflection can name: `TypeVariant.payload` lists the types a
variant carries when each is a plain name, and is empty otherwise
(`tests/reflection/shape_sum_payload`).

## What is not an error

`panic` is a bug, not a failure a caller is expected to handle, and stays outside
`Throw`: nothing catches it. An index out of range or a division by zero is the
same kind of thing; whether those become a catchable effect of their own is
[TODO](TODO.md#runtime-errors-as-an-effect).
