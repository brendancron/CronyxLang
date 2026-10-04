# Networking

Status: **not built.** This is the design [Stdlib Plan](Stdlib%20Plan.md#10-networking)
builds `std/net/` from.

## A socket that waits holds up every task

[I/O](IO.md#io-is-async-from-the-start) is async in its types and not yet in
what it does. `DiskFile.read` suspends and is woken at once, by the native it
called, which blocked the whole program until the OS answered:

```cronyx
var (status, data, message) = suspend { it(__file_read(self.fd, max)) };
```

A file answers in microseconds, so nothing notices. A socket answers when its
peer gets round to it, and a server and a client in one program never meet:

```cronyx
all([
    () => { var conn = listener.accept(); … },          // sleeps in the OS
    () => { var conn = connect("127.0.0.1", port); … }  // never runs
]);
```

So `net/` starts in the scheduler, with what [Async](Async.md#timers) left for
it: the root's wait becomes "until the first timer, or until a socket is ready".

## The scheduler waits on sockets

`async` gains one operation beside `after`, of the same shape:

```cronyx
/**
 * Calls `wake` once the socket can be read from without waiting, or written
 * to when `writing`, and hands back what cancels that.
 */
fn when_ready(socket: Socket, writing: bool, wake: () -> unit): () -> unit;
```

A socket is non-blocking from the moment it is made. A read tries first; when
the OS says it would block, the task suspends with `when_ready` as its
registration, and reads again when woken. Accepting and writing are the same
loop, and so is connecting, whose result is read once the socket is writable.

`block_on` keeps its waiters beside its timers. When nothing is ready it hands
every live waiter's socket to `select`, with the time to the earliest timer as
the limit, and wakes whatever `select` answered, in the order they were
registered. With no waiters it waits on the clock, as now; with neither, it is
the deadlock it reports today.

In `async` rather than an effect of its own, because only the scheduler can
answer it: a wait is "sleep until any of these", and one handler has to see
every timer and every socket at once to ask the OS that. A handler that fakes
the clock answers it too, and one serving in-memory sockets never registers a
waiter, so a test of either runs as it does today.

`select` takes sockets and nothing else on Windows, which decides what joins
it: sockets. Files, the terminal and a child's pipes stay as they are — a disk
read cannot be asked in advance whether it would be quick on any platform, so
the runtimes that make them async (Node's pool, Tokio's `spawn_blocking`) do it
with threads, as `System.drain` already does for a child's output. Nothing
needs that yet, and the types already allow it.

## A cancelled task closes what it held

A scope whose task fails cancels the others, and a cancelled task is dropped
where it is parked ([Async](Async.md#a-failure-lands-in-its-scope)), so none of
its `defer`s run. Until now that lost a line of cleanup output. With sockets it
loses the close:

```cronyx
serve(listener, (conn) => {
    defer { conn.close(); }   // skipped when a sibling's failure cancels this task
    …
});
```

One failing handler would leave every other connection open — the peer never
sees the end of the stream, and the server runs out of descriptors. So a scope
cancels as `timeout` does: it `discontinue`s the parked task, which unwinds it
and runs its `defer`s, and throws its failure once every task has stopped. That
comes before sockets, since every connection a scope holds depends on it.

## Connecting is an effect; a connection is a value

The same split as files ([I/O](IO.md#opening-is-an-effect-an-open-file-is-a-value)).
`Net` is an effect the root handles, so a function's row says `<Net>` exactly
when it reaches the network, and a test answers it with peers of its own:

```cronyx
effect Net {
    ctl connect(host: string, port: int): Result<TcpStream, IoError>;
    ctl listen(host: string, port: int): Result<TcpListener, IoError>;
    ctl resolve(host: string): Result<List<string>, IoError>;
}
```

`ctl`, as `open` is, because the root's answer suspends. A failure is a value in
the result, and `tcp_connect` and `tcp_listen` throw it where they were asked
for. `connect` resolves a name itself, trying each address in turn; `resolve` is
for a program that wants the addresses.

`TcpStream` is a trait, as `File` is — `Reader`, `Writer` and
`Closer<IoError>`, plus `peer()` and `shutdown_write()` — so `lines(conn)` and
`using` work on a connection unchanged, and a handler can hand back a stream of
its own kind. `TcpListener` has `accept()` and `local_port()`. Listening on port
0 lets the OS choose one, which is how a fixture runs a server and its clients
on loopback without two runs meeting the same port.

A failure is `IoError`, since `Reader` and `Writer` throw that. It gains the
variants a network has and a disk does not — `Refused`, `Reset`, `AddressInUse`,
`TimedOut` — and an `Other` stays the message the OS gave.

The natives are `Unix` sockets in `lib/system.ml`, which is already a
dependency, so there is nothing new to link.

## HTTP is library over TCP

`net/Http` is HTTP/1.1 written in Cronyx over `TcpStream`: a `Request` and a
`Response`, headers as a case-insensitive map, a body as bytes with
`Content-Length` or chunked transfer. The client is `get(url)` and
`request(req)`; the server is `serve(listener, handler)`, which runs each
connection as a task in one scope, so a handler that fails takes its connection
down and not the server. Routing is not in it: a `@route` collector is the
`meta` pattern [Testing](Testing.md#discovery-is-a-library) describes, and
belongs to a framework built on this rather than to `std`.

## What is not in it

- **TLS.** HTTPS needs a TLS implementation, which means linking one or writing
  one, and either is a project of its own. Until then `get("https://…")` is an
  error that says so.
- **UDP.** Its own trait, a datagram rather than a stream, and nothing in the
  first version needs it. It uses the same `when_ready`.
- **Asynchronous files.** Above: threads, when something needs them.
