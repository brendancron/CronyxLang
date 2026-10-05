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

A socket overlaps: the scheduler waits on it in `select` while other tasks run
([Net](Net.md#the-scheduler-waits-on-sockets)). A file, the terminal and a
child's pipes do not yet — their natives block and call back at once — since
`select` cannot wait on them on every platform, and threads are what would.
When something needs that, the native becomes a submission and no caller
changes. The alternative, blocking functions now and async ones beside
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

## Everything else the OS offers is an effect too

Directories, subprocesses, arguments, the environment, the clocks and entropy
are each an effect the root handles, as `Fs` is, so a function's row says which
of them it reaches and a test replaces any one — a fixed clock, fixed arguments,
a seeded generator, a child process that prints what the test wants:

| Effect | Module | The root answers with |
|---|---|---|
| `Dirs` | `std/fs/File` | the disk: `read_dir`, `stat`, `create_dir`, `remove`, `rename` |
| `Process` | `std/os/Process` | a program the system starts, as a `Child` |
| `Net` | `std/net/Net` | connections, listeners and datagram sockets over the system's |
| `Args` | `std/os/Args` | what followed `--` on the command line |
| `Env` | `std/os/Env` | a copy of the environment the program started with |
| `Time` | `std/os/Time` | the wall clock and one that never goes backwards |
| `Random` | `std/random/Random` | the system's entropy |

Each is its own effect for the reason `Stdin` is: a handler answers every
operation of its effect, and a test faking files does not want to answer for
directories too. `Process.start` is `ctl`, as `open` is, so a handler can hand
back a child that waits; the rest are `fn`, since the root answers them without
suspending, and evidence passing is cheaper than continuations. A failure is a
value in the result, as `open`'s is, and the library function over the
operation — `list_dir`, `spawn` — throws it.

Setting a variable changes the copy, which a child is started with; the
process's own environment is never written, since nothing in the interpreter
reads it and OCaml cannot unset a variable. OCaml has no monotonic clock either,
so `instant` is the wall clock held from going backwards.

Nothing else reaches the OS: each builtin that touches it is how the root
answers one of these operations, which is what lets a handler stand in for all
of it.

## A failure is `Throw<IoError>`

```cronyx
type IoError { NotFound(string), Denied(string), Other(string) }
impl Failure for IoError { … }
```

It can be handled by kind, turned into a `Result` with `attempt`, wrapped into a
caller's error type with `Wraps`, or left to reach the root ([Errors](Errors.md)).

## A path is relative to the working directory

As in C, Python, Rust, Go, Java, Node and C#: a program opening `"data.txt"`
gets the one in the directory it was started in. A `meta` block runs under the
same root, so the same holds at compile time, and `cx` compiles from the package
root — where Cargo runs a build script. `embed` is the exception: the loader
resolves it against the source file that wrote it, as Rust's `include_str!`,
Zig's `@embedFile` and Go's `go:embed` are.
