# I/O

Status: **built**, but for anything beyond opening, reading, writing and
closing a file — deleting, listing, metadata. `std/io/Console` is the
terminal ([Algebraic Effects](Algebraic%20Effects.md#print-is-an-effect)),
`std/io/Io` the streams and `IoError`, `std/fs/File` files; `tests/stdlib/io/`
holds real files and a faked filesystem.

## I/O is async from the start

A function that may wait says so by performing `async.suspend` ([Async](Async.md)),
so an I/O function has `async` in its row from the first version:

```cronyx
fn read_file(path: string): <async, Fs, Throw<IoError>> string { … }
```

Until the scheduler polls the operating system, the native underneath blocks and
calls back at once, so nothing overlaps yet. When `block_on` learns to poll for
completions instead of declaring a deadlock, the native becomes a submission and
no caller changes. The alternative, blocking functions now and async ones beside
them later, is Rust's `std::fs` next to `tokio::fs`: every I/O function twice, and
the blocking one holding up every other task with nothing in its type to say so.

Output to the console is the exception ([Algebraic
Effects](Algebraic%20Effects.md#print-is-an-effect)).

## The root runs every program under `block_on`

A program that performs I/O performs `async`, and an effect nothing handles at
the top level is refused. So each top-level statement runs under `__root` in
`stdlib/prelude.cx`, which handles `Console` around `block_on`, and `block_on`
handles `Throw`: a statement may wait, and a failure nothing catches stops the
program with its value (`tests/stdlib/async/top_level_scope`). The root is the
prelude's rather than the compiler's, so a different one is a different prelude;
how a package would choose one is not decided.

## Opening is an effect; an open file is a value

```cronyx
effect Fs {
    ctl open(path: string, mode: Mode): Result<File, IoError>;
}

trait Reader { fn read(self, max: int): <async, Throw<IoError>> Option<Array<byte>>; }
trait Writer { fn write(self, data: Array<byte>): <async, Throw<IoError>> unit; }
trait Closer<X> { fn close(self): <async, Throw<X>> unit; }
trait File: Reader, Writer, Closer<IoError> {}
```

A file is closed by `using`, however its block is left:

```cronyx
using(open_file("notes.txt", Mode.Read)) { f ->
    for (line in lines(f)) { print(line); }
};
```

`using<T: Closer<X>, X>` is handed a `File` object, which meets the bound because an object meets its own trait and each supertrait, at the arguments the supertrait is written with — `Closer<X>` at `X = IoError` ([Static vs Dynamic Invocation](Static%20vs%20Dynamic%20Invocation.md)). `Closer` is generic over the error rather than over a row: `using` closes in a `defer`, which may not fail, and `attempt` can discharge a `Throw<X>` it knows but not a row a caller decides. A close that fails after the block succeeded is thrown; after the block failed it is dropped, so the caller sees the cause. `lines` streams any `Reader` — a file, or `stdin()` — as an `Iter`, so a loop that stops early closes it, and reads no further than it was asked to.

Bytes, since not everything opened is text; `read_text` and `write_text` are the
UTF-8 layer over `read_file` and `write_file`.

The effect is the capability — a function's row says `<Fs>` exactly when it
opens something, and a test or a sandbox handles `Fs` to give out in-memory files
or none. The files themselves are values behind `Reader` and `Writer`, which
files, standard input and later sockets share, so code handed a `Reader` does not
care which it has. `open` returns a trait object, so a handler can return a file
of its own kind (`tests/stdlib/io/fake_fs`), and a `File` passes as a `Reader`
or a `Writer` as it is, its table already holding their methods. It is `ctl`
because the root's handler suspends inside it; a `fn` operation's caller holds no
continuation to suspend.

A failure to open is a value in the result, not a `throw` in the handler: the
root's arm is outside the caller, so a failure thrown there would pass every
handler the caller installed. `open_file` throws it where it was asked for.

Threading a filesystem value through every call instead — an interface only — is
what effects exist to remove; an effect only makes every file operation a free
function over a handle.

## Standard input is its own effect

```cronyx
effect Stdin { fn stdin(): Reader; }

fn read_line(): <Stdin, async, Throw<IoError>> Option<string> { … }
```

Not a second operation of `Console`: a handler answers every operation of its
effect, so capturing output would also have to supply an input, and a test fakes
one far more often than both (`tests/stdlib/io/fake_stdin`). The prelude imports
`Stdin` and `read_line` into every package and the root hands out the process's
own input. Getting the stream never waits; reading it may, so a task waiting for
a line suspends like one waiting for a file. Koka has one `console` label for
both directions, but there it is a label the checker tracks, not operations a
handler answers, so the question of answering both does not arise.

## A failure is `Throw<IoError>`

```cronyx
type IoError { NotFound(string), Denied(string), Other(string) }
impl Failure for IoError { … }
```

It can be handled by kind, turned into a `Result` with `attempt`, wrapped into a
caller's error type with `Wraps`, or left to reach the root ([Errors](Errors.md)).

## A path is relative to the working directory

At run time, as in C, Python, Rust, Go, Java, Node and C#: a program opening
`"data.txt"` gets the one in the directory it was started in. At compile time a
path is relative to the source file that wrote it, as Rust's `include_str!`,
Zig's `@embedFile` and Go's `go:embed` are, which is what `embed`, and `readfile`
in a `meta` block, already do.
