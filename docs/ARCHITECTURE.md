# Linux::Event::HTTP architecture

Linux::Event::HTTP is an HTTP protocol implementation for Linux::Event. It is
not a web framework or a framework-adapter distribution.

## Boundaries

The design has four distinct responsibilities:

- **Transport** - Linux::Event owns sockets, TLS, readiness, buffering,
  backpressure, deadlines, ordered write queuing, and event dispatch.
- **Protocol execution** - Client::Connection and Server::Connection own HTTP
  framing/parsing, ordering, persistence, and movement of message bytes across
  the Linux::Event transport.
- **Messages** - Request and Response represent HTTP messages independent of
  whether they were created or received by a client or server.
- **Exchange lifecycle** - Transaction represents exactly one Request/Response
  exchange and owns lifecycle operations such as cancellation and outgoing
  incremental body producers.

`Body::Stream` is the writable producer used by Transaction for an outgoing
incremental body. It is not a message and does not own a second transport queue.

Reusable transport or byte-stream performance work belongs in Linux::Event.
HTTP-specific native code should remain limited to HTTP wire work where a native
boundary is justified.

Routing, middleware, sessions, templates, PSGI/PAGI integration, and other web
framework concerns are outside this distribution.

## Public structure

The current public foundation is:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Transaction
Linux::Event::HTTP::Body::Stream
```

The connection class is deliberately server-specific. Client and server
connections have opposite protocol roles, so there is no generic public
`Linux::Event::HTTP::Connection`.

Native client support belongs in this distribution as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet. It will reuse Request, Response, and
Transaction rather than introducing Client::Request or Client::Response types.

## Message model

Request and Response identify HTTP concepts, not endpoint roles:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

A locally constructed message is mutable until committed. A received message
uses the same public message type but its parsed wire metadata is read-only.
Native parsed Requests retain lazy XS-backed storage rather than being eagerly
expanded into Perl hashes or header objects.

The common message concepts include:

```text
Request                         Response
-------                         --------
method                          status
target                          reason
version                         version
header                          header
add_header                      add_header
remove_header                   remove_header
header_values                   header_values
header_count                    header_count
header_name                     header_name
header_value                    header_value
content_length                  content_length
body                            body
is_complete                     is_complete
```

`target` is intentionally used instead of `uri`: an HTTP request message has a
request-target, while URL resolution, scheme, authority, destination host, and
redirect resolution are Client concerns.

HTTP/1-only parser decisions such as transfer-body framing and persistence are
private protocol-execution state rather than generic Request message methods.

## Transaction model

A Transaction represents exactly one HTTP exchange:

```text
Transaction
    Request
    Response
    lifecycle state
    cancellation
    error
    outgoing body producer(s)
```

A redirect is another HTTP exchange and therefore another Transaction. A
Transaction does not own a socket, parser, connection pool, or transport queue.
Its current Client/Connection controller performs the protocol work.

The coarse public lifecycle is intentionally small: Request, Response, state,
cancellation, completion, and error. Protocol implementations may track finer
wire phases privately.

## Server transaction model

`Linux::Event::HTTP::Server` is the normal server entry point. It is a thin
control-plane convenience over `Linux::Event::IO::Sock::Listener`.

The ordinary callback remains:

```perl
on_request => sub ($conn, $req, $res) {
    $res->body("hello\n");
}
```

The active exchange is available without adding another callback argument:

```perl
my $tx = $conn->transaction;
```

The objects have different lifetimes:

- `$conn` is the persistent TCP/TLS HTTP connection.
- `$tx` is one HTTP exchange on that connection.
- `$req` is the Request in that Transaction.
- `$res` is the Response in that Transaction.

A complete HTTP response does not imply transport shutdown. On a persistent
HTTP/1.1 connection the same socket normally remains open for later
Transactions.

The server advances only when the complete request input boundary has been
consumed and response output for the current Transaction has completed.

## Body model

HTTP wire framing and application body handling are separate concepts.
`Content-Length`, HTTP/1 chunked transfer coding, close delimiting, or a future
HTTP/2 DATA-frame boundary tell the protocol implementation how to identify body
bytes. They do not dictate whether the application buffers or incrementally
produces/consumes those bytes.

A message's `body(...)` means the application has a complete scalar byte body.
Incremental production is owned by the Transaction.

A complete scalar response body is selected with:

```perl
$res->status(200);
$res->header('Content-Type', 'text/plain');
$res->body("hello\n");
```

`body(...)` is a complete-body declaration, not an immediate transport write.
While an HTTP callback is running, the Response remains mutable until that
callback returns:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

When `body(...)` is called later from an asynchronous event callback while a
Response is waiting, it commits the complete response immediately.

Incremental server response production is explicit through the active
Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write("one\n");
$body->write("two\n");
$body->complete;
```

`response_body()` lazily creates one stable producer owned by the Transaction.
Creating it does not commit response headers. The first producer `write()` or
`complete()` is the output commit point and freezes Response metadata.

A complete scalar body and an incremental producer are mutually exclusive.
Response deliberately has no public `write`, `complete`, `stream_body`, or
`end` method. Public message completion introspection remains
`Response->is_complete`; whole-exchange completion is
`Transaction->is_complete`.

## Backpressure

Body::Stream does not maintain a second output queue. Its writes are HTTP-framed
and then fed into the existing Linux::Event ordered-byte output machinery.
Linux::Event continues to own queued bytes, segmented output, high/low
watermarks, `pending_bytes`, write readiness, `on_drain`, `max_pending_bytes`,
and TLS transport progress.

`Body::Stream->write()` preserves Linux::Event flow control:

```text
true  = accepted and producer may continue
false = accepted, but producer should pause until on_drain
```

`on_cancel` means the Transaction abandoned an unfinished producer. Connection
level drain and close callbacks are composed with this bookkeeping rather than
replaced.

## Request body delivery

`on_request($conn, $req, $res)` runs as soon as the validated request head is
available. A request body may continue afterward.

Optional server callbacks are:

```perl
on_body => sub ($conn, $req, $res, $bytes) {
    ...
},

on_request_end => sub ($conn, $req, $res) {
    ...
},
```

Content-Length bodies are consumed directly from the connection input buffer.
Chunked request bodies are decoded before application delivery. If `on_body` is
not installed, body bytes are drained and discarded rather than accumulated.
`on_request_end` runs once when the complete request input boundary has been
consumed, including bodyless requests. Request `is_complete` becomes true at
that actual message boundary.

For HTTP/1.1 requests with a body and `Expect: 100-continue`, the connection
emits `100 Continue` after validating the request head. Unsupported expectations
are rejected before application dispatch.

## HTTP/1 response framing

The HTTP/1 execution layer chooses wire framing after message/body state is
known.

- Complete scalar bodies normally produce Content-Length.
- HTTP/1.1 incremental output without Content-Length uses chunked transfer coding.
- A declared Content-Length is enforced across incremental writes.
- HTTP/1.0 unknown-length incremental output is close-delimited and therefore
  requires connection close after queued output drains.
- HEAD and body-forbidden status handling are enforced by the protocol layer.

These choices are private HTTP/1 framing policy rather than generic Response
body modes.

## HTTP/1 native boundary

HTTP/1 native work is consolidated into one private extension:

```text
Linux::Event::HTTP::_HTTP1
```

That shared object owns:

- the picohttpparser request-head parser and lazy Request accessors;
- the chunked request decoder;
- response-head serialization;
- the narrow default scalar-response builder.

picohttpparser is vendored at a recorded upstream revision and compiled once.
Request metadata remains in native state and Perl strings are materialized only
when application code asks for them.

The scalar-response builder is a private optimization behind eligible ordinary
`Response->body(...)` calls. Applications do not select a special performance
callback or alternate Transaction API.

## HTTP/1 request validation

HTTP/1 policy rejects ambiguous framing, obsolete folded headers, invalid Host
requirements, conflicting Content-Length values, Transfer-Encoding plus
Content-Length, and unsupported transfer codings.

Original header spelling and duplicate field order are preserved. Header names
are compared using HTTP ASCII case-insensitive semantics without normalizing
legal names such as `X_Foo` and `X-Foo` into one field.

## Server::Connection

`Linux::Event::HTTP::Server::Connection` is a
`Linux::Event::IO::Sock::Stream` subclass and owns HTTP/1 connection state.
There is no wrapper object between Linux::Event byte I/O and the HTTP parser.

Most applications do not need to subclass it. `connection_class` is the
advanced extension point for reusable transport defaults, stream tuning, socket
policy, or named callback methods.

Constructor callbacks supplied to Server override same-named methods on the
configured connection class for that accepted instance.

Server resolves its HTTP connection policy into one Linux::Event Listener
`stream => {...}` recipe. The recipe names the actual `connection_class` and
holds application data, tuning overrides, TLS policy, and accepted-connection
lifecycle callbacks. Listener therefore constructs the HTTP Connection class
directly; HTTP does not need an acceptance adapter or a per-connection wrapper.

HTTP may temporarily pause application reads while a completed request waits for
a later asynchronous Response so a pipelined request cannot overtake it. Peer
terminal-readiness handling while such reads are paused is a generic
Linux::Event core concern; HTTP must not add polling or a second buffer to solve
it.

## TLS

HTTPS uses the same Server, Server::Connection, Request, Response, Transaction,
and Body::Stream classes. Server `tls => {...}` activates Linux::Event transport
policy for generated Connections. A Connection subclass may provide reusable
`tls_defaults()`, but defaults do not activate TLS by themselves, so one class
can serve both plain and TLS listeners.

HTTP parsing receives decrypted bytes after the TLS handshake, while response
output travels through the same Linux::Event TLS transport. There is no separate
HTTPS class hierarchy.

## Upgrade

HTTP Upgrade is a transaction boundary, not a second transport acquisition.
Upgrade still currently enters through the server Response:

```perl
$res->header('Upgrade', 'my-protocol');
$res->upgrade('MyProtocolConnection');
```

HTTP validates the HTTP/1.1 Upgrade request and response, queues the 101
response, then Linux::Event `transition_to()` hands the same live stream object
to the target protocol class.

Socket identity, TLS state, queued output, backpressure, deadlines, watcher
state, application data, and bytes already read beyond the HTTP request head are
preserved.

Upgrade lifecycle ownership is a remaining server-specific concern that can be
moved toward Transaction independently of the message/body model.

WebSocket handshake/frame semantics belong in a separate
`Linux::Event::WebSocket` distribution. Linux::Event::HTTP owns only the HTTP
Upgrade transaction and handoff.

## Performance policy

Correctness, ease of correct use, coherent API design, maintainability, and
composability take priority over HTTP-specific benchmark tricks.

Benchmark discoveries may justify private optimizations, but they do not justify
alternate public APIs merely to expose a fast path. The ordinary API should take
an optimization transparently when eligible.

Before adding HTTP-specific native transport machinery, first ask whether the
expensive primitive is reusable socket, buffer, or write machinery that belongs
in Linux::Event core.

Do not add a second HTTP output queue. Do not split the consolidated `_HTTP1`
extension without a measured reason. Do not add HTTP-specific XS merely to win
a benchmark.

Parser microbenchmarks and end-to-end transaction benchmarks answer different
questions. See `docs/BENCHMARKING.md` for the measurement contract.

## Current status

The current server/client-ready foundation includes:

1. Direction-neutral Request and Response message types.
2. Locally constructible messages plus lazy native parsed Request state.
3. A Transaction object representing exactly one Request/Response exchange.
4. HTTP/1 request-head parsing, validation, and persistence policy.
5. Incremental Content-Length and chunked request-body delivery.
6. Expect: 100-continue handling.
7. Complete scalar Response bodies and Transaction-owned incremental response production.
8. Ordered persistent/pipelined request processing.
9. Deferred asynchronous scalar Response bodies.
10. Linux::Event backpressure propagation for incremental response producers.
11. TLS transport integration.
12. Atomic HTTP/1.1 Upgrade handoff.
13. One consolidated private `_HTTP1` native extension.
14. One canonical server callback API, with `$conn->transaction` available when lifecycle operations are needed.

The next major protocol layer is the native HTTP Client and Client::Connection.
HTTP/2 is future protocol work. WebSocket remains a separate protocol
distribution.
