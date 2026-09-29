# I/O

Status: **designed.** `Console` and the root are built ([Algebraic
Effects](Algebraic%20Effects.md#print-is-an-effect)); files, `Reader`, `Writer`
and `stdin` are not.

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
    ctl open(path: string, mode: Mode): File;
}

trait Reader { fn read(self, max: int): <async, Throw<IoError>> Option<string>; }
trait Writer { fn write(self, text: string): <async, Throw<IoError>> unit; }
```

The effect is the capability — a function's row says `<Fs>` exactly when it
opens something, and a test or a sandbox handles `Fs` to give out in-memory files
or none. The files themselves are values behind `Reader` and `Writer`, which
files, standard input and later sockets share, so code handed a `Reader` does not
care which it has. `open` returns a trait object, so a handler can return a file
of its own kind. It is `ctl` because the root's handler suspends inside it; a
`fn` operation's caller holds no continuation to suspend.

Threading a filesystem value through every call instead — an interface only — is
what effects exist to remove; an effect only makes every file operation a free
function over a handle.

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
