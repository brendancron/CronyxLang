# Networking

Status: **built.** `std/net/Net`, `Tcp`, `Udp` and `Http` (`stdlib/net/`), the
socket natives in `lib/system.ml`, and `block_on`'s wait in `std/async/Task`; `tests/stdlib/net/` runs servers and clients over loopback
and a faked `Net`. This is the design [Stdlib Plan](Stdlib%20Plan.md#10-networking) builds
`std/net/` from.

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
fn when_ready(socket: int, writing: bool, wake: () -> unit): () -> unit;
```

A socket is non-blocking from the moment it is made. A read tries first; when
the OS says it would block, the task suspends with `when_ready` as its
registration, and reads again when woken. Accepting and writing are the same
loop, and so is connecting, whose result is read once the socket is writable.

`block_on` keeps its waiters beside its timers. When nothing is ready it hands
every live waiter's socket to `select`, with the time to the earliest timer as
the limit, and wakes whatever `select` answered, in the order they were
registered. With no waiters it waits on the clock, as before; with neither, it
is the deadlock it reports.

`block_on` calls `select` as a native rather than through an effect, as
`DiskFile.read` calls `__file_read`: opening is the effect and an open socket is
a value, so waiting on one is an operation on the value. That keeps `async`
free of `net/` — the socket is a handle, an `int`, and nothing in `Task`
imports a type from `Tcp`.

A task waits on a socket as `sleep` waits on a timer, cancelling its watch in a
`defer`: a task unwound while waiting in `accept` would otherwise leave the
scheduler watching a socket nobody reads (`tests/stdlib/net/cancelled_accept`).

In `async` rather than an effect of its own, because only the scheduler can
answer it: a wait is "sleep until any of these", and one handler has to see
every timer and every socket at once to ask the OS that. A handler that fakes
the clock answers it too, and one serving in-memory sockets never registers a
waiter, so a test of either runs as it does today.

`select` takes sockets and nothing else on Windows, which decides what joins
it there: sockets. Elsewhere a child's output pipe joins too, entered in the
socket table but left blocking, so a task reading a slow child does not hold up
the rest (`tests/stdlib/os/pipe_wait`). Files, the terminal and a pipe on
Windows stay as they are — a disk
read cannot be asked in advance whether it would be quick on any platform, so
the runtimes that make them async (Node's pool, Tokio's `spawn_blocking`) do it
with threads, as `System.drain` already does for a child's output. Nothing
needs that yet, and the types already allow it.

## A cancelled task closes what it held

A scope whose task fails cancels the others where they are parked
([Async](Async.md#a-failure-lands-in-its-scope)). It `discontinue`s each one, so
its `defer`s run, and throws the failure once every task has stopped:

```cronyx
serve(listener, (conn) => {
    defer { conn.close(); }   // runs when a sibling's failure cancels this task
    …
});
```

A scope that dropped a cancelled task instead would turn one failing handler
into every other connection left open — the peer never sees the end of the
stream, and the server runs out of descriptors. A `defer` that waits, as a
close does, is resumed while its task unwinds.

## Connecting is an effect; a connection is a value

The same split as files ([I/O](IO.md#opening-is-an-effect-an-open-file-is-a-value)).
`Net` is an effect the root handles, so a function's row says `<Net>` exactly
when it reaches the network, and a test answers it with peers of its own:

```cronyx
effect Net {
    ctl connect(host: string, port: int): Result<TcpStream, IoError>;
    ctl listen(host: string, port: int): Result<TcpListener, IoError>;
    ctl bind(host: string, port: int): Result<UdpSocket, IoError>;
    ctl lookup(host: string): Result<List<string>, IoError>;
}
```

The effect is `std/net/Net`, with `Tcp` and `Udp` beside it rather than under
it, since one handler answers for both: a test faking datagrams imports `Net`
from where a test faking connections does.

`ctl`, as `open` is, because the root's answer suspends. A failure is a value in
the result, and `tcp_connect`, `tcp_listen` and `lookup_host` throw it where
they were asked for. `connect` looks a name up itself and tries each address in
turn, so `localhost` reaching an IPv6 address nothing listens on still reaches
the IPv4 one that does; `lookup` is for a program that wants the addresses. Not
`resolve`, which is a promise's.

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

## A datagram is not a stream

UDP sends separate datagrams, each whole or not at all, which may arrive out of
order or never, with nothing to say one was lost. So a `UdpSocket` is not a
`Reader` or a `Writer` — reading "the next bytes" means nothing when the bytes
come from several peers in pieces that each stand alone. Each send names where
it goes and each receive says where it came from:

```cronyx
trait UdpSocket: Closer<IoError> {
    fn send_to(self, data: Array<byte>, host: string, port: int): <async, Throw<IoError>> unit;
    fn receive(self): <async, Throw<IoError>> Datagram;   // data, host, port
    fn local_port(self): int;
}
```

A receive reads into a buffer as large as any datagram can be, so none is cut
short: Unix truncates one that does not fit, and Windows fails the read. A send
looks its host up in the socket's own family, since a socket bound to an IPv4
address cannot reach an IPv6 one. Waiting is `when_ready`, as for a stream.

## HTTP is library over TCP

`net/Http` is HTTP/1.1 written in Cronyx over `TcpStream`: a `Request` and a
`Response`, `Headers` compared without regard to case, a body as bytes. The
client is `get`, `post` and `send`; the server is `serve(listener, handler)`.

Every exchange is one request and one response on a connection of its own:
both ends send `Connection: close`, so nothing is kept alive and a body never
has to be told apart from the next request. A body is sent with its
`Content-Length`; one received may also be chunked, which a server that
streams sends, and with neither a response runs to the end of the connection.

What a server takes is bounded by `ServerLimits` — the body, the number of
fields, the length of a line — and refused with the status that limit names
(413, 431, 414) before more is read: a body over the limit is refused on its
`Content-Length`, so even a client that asked `Expect: 100-continue` never sends
it. A client also has `patience` to send its whole request and then to take the
response, which is `timeout` around each; one slower than that gets 408 or is
dropped, so a connection that trickles bytes holds one task for that long and
no longer. `serve` is `serve_with` the defaults.

Both ends refuse a header field that would break the message apart — a line
break in a value, or anything but a token in a name — since a handler echoing
what a client sent into a field would otherwise let the client write fields, or
a second response, of its own. The client refuses before connecting; the server
answers 500 in place of the response that held it.

A response to `HEAD`, a `1xx`, a 204 or a 304 has no body whatever its fields
say, at both ends. An interim `100 Continue` is read past to the response that
follows it.

`serve` accepts in the body of a `scope` and starts a task per connection, so a
slow client holds up only itself and cancelling the server unwinds every
connection it has open. A handler that fails answers 500, a request that cannot
be read 400, and a connection's own failure — a client gone mid-request — is
dropped with it, so none of them takes the server down. `serve` runs until it
is cancelled, which `race` does.

Routing is not in it: a `@route` collector is the `meta` pattern
[Testing](Testing.md#discovery-is-a-library) describes, and belongs to a
framework built on this rather than to `std`.

## What is not in it

- **TLS.** HTTPS needs a TLS implementation, which means linking one or writing
  one, and either is a project of its own. Until then `get("https://…")` is an
  error that says so.
- **Multicast and broadcast.** Socket options on top of `bind`, when something
  needs them.
- **Asynchronous files.** Above: threads, when something needs them.
