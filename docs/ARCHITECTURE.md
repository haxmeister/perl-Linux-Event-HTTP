# Linux::Event::HTTP architecture

Linux::Event::HTTP is an HTTP protocol implementation for Linux::Event. It is
not a web framework or framework-adapter distribution.

## Boundaries

The design has four distinct responsibilities:

- **Transport** - Linux::Event owns sockets, TLS, readiness, buffering,
  backpressure, deadlines, ordered write queuing, connection acquisition, and
  event dispatch.
- **Protocol execution** - Client::Connection and Server::Connection own HTTP
  framing/parsing, ordering, persistence, and movement of message bytes across
  Linux::Event transports.
- **Messages** - Request and Response represent HTTP messages independent of
  whether they were created or received by a client or server.
- **Exchange lifecycle** - Transaction represents exactly one Request/Response
  exchange and owns cancellation plus operations that belong to one exchange
  rather than to a message or socket.

`Body::Stream` is the writable producer used by Transaction for an outgoing
incremental body. It is not a message and does not own a second transport queue.

Reusable transport or byte-stream performance work belongs in Linux::Event.
HTTP-specific native code should remain limited to HTTP wire work where a native
boundary is justified by correctness or measurement.

Routing, middleware, sessions, templates, PSGI/PAGI integration, and other web
framework concerns are outside this distribution.

## Public structure

```text
Linux::Event::HTTP
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Transaction
Linux::Event::HTTP::Body::Stream
```

There is deliberately no generic public `Linux::Event::HTTP::Connection`.
Client and server connections execute opposite HTTP roles and therefore have
different state machines even though both are Linux::Event stream sockets.

There are also deliberately no `Client::Request`, `Client::Response`,
`Server::Request`, or `Server::Response` classes. Endpoint direction does not
change HTTP message identity.

## Message model

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

A locally constructed message is mutable until protocol commit. A received
message uses the same public type but its wire metadata is committed/read-only.
Parsed server Requests retain lazy XS-backed storage rather than being eagerly
expanded into Perl hashes or header objects.

Common message concepts are:

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

`target` is intentionally used instead of `uri`. An HTTP Request contains a
request-target. Full URL parsing, scheme, authority, destination selection,
Host synthesis, redirect resolution, and connection pooling are Client policy.
They do not belong in the Request message merely because a client needs them.

Request and Response deliberately do not retain their peer message, carrying
Connection, output writer, pool, or protocol-transition state. Those
relationships and operations belong to Transaction and protocol executors.

HTTP/1-only framing and persistence decisions remain private protocol state
rather than generic message methods.

## Transaction model

A Transaction represents exactly one HTTP exchange:

```text
Transaction
    Request
    Response
    lifecycle state
    cancellation
    error
    exchange-specific body/output operations
    protocol handoff state where supported
```

A redirect is another HTTP exchange and therefore another Transaction.
Transaction does not own a socket, parser, connection pool, URL, redirect chain,
or transport queue. Its current Client/Connection controller performs protocol
execution.

On the server, Transaction owns outgoing Response body production, deferred
scalar send, response-output progress, and Upgrade lifecycle. On the client,
Transaction owns outgoing incremental Request body production. These operations
do not make Request or Response transport objects.

## Server model

`Linux::Event::HTTP::Server` is the ordinary server entry point and a thin
control-plane convenience over `Linux::Event::IO::Sock::Listener`.

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

A complete HTTP response does not imply transport shutdown. On persistent
HTTP/1.1 the same socket normally remains available for later Transactions.

The server advances only when the complete request input boundary has been
consumed and response output for the current Transaction has completed.

## Client model

`Linux::Event::HTTP::Client` is the ordinary outbound entry point. It owns
application-facing destination policy:

```text
Client
    absolute URL parsing
    scheme/host/port selection
    Host synthesis
    TLS transport creation
    connection selection/reuse
    convenience verbs

Client::Connection
    one HTTP/1 socket
    Request serialization/framing
    Response parsing/framing
    persistence/reuse eligibility
    one active Transaction at a time

Transaction
    one Request/Response exchange
```

The generic high-level form is:

```perl
my $tx = $client->request(
    'POST',
    'https://example.com/api/items',
    headers => [ [ 'Content-Type', 'application/json' ] ],
    body => $bytes,
    on_response => sub ($tx, $res) { ... },
    on_body => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error => sub ($tx, $error) { ... },
);
```

Convenience methods are `get`, `head`, `post`, `put`, and `delete`.
All return Transaction rather than Request because the returned object is the
cancellable asynchronous exchange. The canonical Request is available at
`$tx->request`.

The initial connection-reuse policy is intentionally simple and bounded:

- no HTTP/1 pipelining;
- one active Transaction per Client::Connection;
- sequential keep-alive reuse;
- at most one idle connection retained per origin;
- if the retained connection is busy, concurrent requests create other
  connections rather than queueing behind it;
- when multiple connections later become idle for one origin, one is retained
  and extras are closed.

This policy is sufficient to establish ownership and correctness without
prematurely turning Client into a large pooling subsystem. Richer pool limits
can be added later without changing Request/Response/Transaction identity.

## Client URL policy

Client uses the established `URI` distribution rather than implementing a URL
parser inside Linux::Event::HTTP.

Only absolute `http` and `https` URLs are accepted. Fragments are not
transmitted. Origin-form path plus query becomes the Request target, with `/`
used when the URL has no path. For HTTP/1.1, Client synthesizes Host when the
caller did not provide one; non-default ports are included.

Userinfo is rejected rather than silently creating authentication policy. Proxy,
authentication, cookies, and redirects remain later Client features.

## Body model

HTTP wire framing and application body handling are separate concepts.
`Content-Length`, HTTP/1 chunked transfer coding, close delimiting, or a future
HTTP/2 DATA-frame boundary tell protocol execution how to identify body bytes.
They do not dictate whether the application buffers, incrementally
produces/consumes, forwards, parses, writes to disk, or discards those bytes.

A message's `body(...)` means the application has a complete scalar byte body.

### Server outgoing Response

```perl
$res->status(200);
$res->header('Content-Type', 'text/plain');
$res->body("hello\n");
```

Inside an HTTP callback, body assignment is a complete-body declaration rather
than an immediate transport write. Response metadata remains mutable until
callback return.

For a Response completed by another event, retain the Transaction and send the
configured message explicitly:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Incremental server Response production is Transaction-owned:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

Creating the producer does not commit response headers. First write/complete is
the output commit point. A complete scalar body and incremental producer are
mutually exclusive.

### Server incoming Request

`on_request` runs after the validated request head. `on_body` receives decoded
body bytes and `on_request_end` marks the actual body boundary. If `on_body` is
absent, body bytes are drained/discarded rather than accumulated.

### Client outgoing Request

A complete scalar Request uses normal message body state. Client::Connection
adds Content-Length when needed and checks an explicit Content-Length against
the scalar body length.

Incremental Request production is Transaction-owned:

```perl
my $tx = $client->post(
    $url,
    stream_body => {
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    },
);

my $body = $tx->request_body;
$body->write($bytes);
$body->complete;
```

`body` and `stream_body` are mutually exclusive. If the Request declares
Content-Length, producer bytes are enforced against that exact size. If no
length is known, HTTP/1.1 automatically uses `Transfer-Encoding: chunked`.
HTTP/1.0 streaming requires Content-Length because request bodies are never
close-delimited.

Request `is_complete` remains false while the producer can still supply bytes
and becomes true only after successful producer completion. A failed final write
that does not satisfy Content-Length leaves the Request incomplete.

Producer writes go directly into Linux::Event's existing ordered-byte output
queue. A false `write` return means bytes were accepted but the producer must
pause until `on_drain`. HTTP composes that producer drain signal with any custom
Client::Connection `on_drain` behavior rather than replacing it.

If a final server Response arrives while the Request producer is unfinished, the
producer is cancelled and that HTTP/1 connection is marked non-reusable. The
Response may still complete the Transaction normally; Request message
completion is not fabricated just because the peer rejected the upload early.

### Client incoming Response

Client bodies are incremental-first:

```perl
on_response => sub ($tx, $res) { ... },
on_body => sub ($tx, $res, $bytes) { ... },
on_complete => sub ($tx) { ... },
```

`on_response` runs after the final response head has been validated and before
body delivery. The Response is incomplete at this point when a body remains.
`on_body` receives body bytes after HTTP/1 transfer framing has been removed.
`on_complete` runs after the actual body boundary and Transaction success.

If `on_body` is absent, bytes are drained/discarded by default. The protocol
layer never creates an implicit unbounded whole-body scalar.

For callers that explicitly want one scalar, Client and Client::Connection
support bounded buffering:

```perl
$client->get(
    $url,
    buffer_body => 1_048_576,
    on_response => sub ($tx, $res) {
        # head is available; body may still be incomplete
    },
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
);
```

`buffer_body` and `on_body` are mutually exclusive. The configured limit counts
exactly the bytes that `on_body` would have received after HTTP/1 chunk framing
is removed. Content-Encoding is not decoded by this protocol layer, so encoded
representation bytes remain encoded for both streaming and limit accounting.

If a validated Content-Length is already above the limit, `on_response` still
runs with the committed Response head and then the Transaction fails before body
accumulation begins. For chunked, close-delimited, or otherwise unknown-length
bodies, accumulation fails as soon as adding delivered bytes would cross the
limit. Buffer-limit failure is a Transaction error and closes the HTTP/1
connection so an unfinished response cannot be mistaken for a reusable stream.

On successful completion, the committed received Response exposes the buffered
scalar through `body`; bodyless buffered responses expose the empty string.
Attaching this completed received body is private protocol/convenience state and
does not make received metadata mutable.

## Commit and completion state

Message completion and protocol execution are intentionally different.

- Request/Response `is_complete` describes the message body boundary.
- Received message metadata is committed/read-only once parsed.
- An outgoing streaming Request remains incomplete until its producer completes.
- Server `Transaction->is_response_started` describes output commit/start.
- `Transaction->is_complete` means the whole exchange succeeded.
- Cancellation and error are separate terminal states.

For a Client response, the Response object may exist and be readable while
`is_complete` is false because body bytes are still arriving. In bounded
buffering mode, `Response->body` remains undef until successful completion.

## Client HTTP/1 response framing

Client::Connection applies framing independently from application body handling:

- HEAD, 204, and 304 have no delivered body;
- informational 1xx responses may be surfaced before the final Response;
- Content-Length is delivered to the exact declared boundary;
- HTTP/1.1 chunked transfer coding is decoded with the existing native chunked
  decoder;
- a response without Content-Length or Transfer-Encoding is close-delimited and
  makes the connection non-reusable;
- Transfer-Encoding plus Content-Length is rejected as ambiguous;
- only plain `chunked` Transfer-Encoding is currently supported;
- 101 client Upgrade and CONNECT tunneling are later protocol-handoff work.

Cancelling an active client Transaction closes the HTTP/1 connection. An
unfinished response cannot generally be skipped safely while preserving reuse of
that same ordered byte stream. Buffer-limit failure follows the same safe-close
rule.

## Backpressure and transport ownership

Linux::Event remains the only transport-output queue. HTTP does not maintain a
second queue for server Response producers or client Request producers.

`Body::Stream->write()` preserves Linux::Event flow control:

```text
true  = accepted and producer may continue
false = accepted, but producer should pause until on_drain
```

Linux::Event owns queued bytes, watermarks, pending-byte limits, readiness,
drain signaling, connection progress, and TLS transport state.

The optional Client response buffer is application-facing retained message data,
not a transport queue. It is bounded explicitly and is populated only from bytes
already consumed through the normal HTTP body path.

## HTTP/1 native boundary

HTTP/1 native work is consolidated in one private extension:

```text
Linux::Event::HTTP::_HTTP1
```

It currently owns:

- picohttpparser server request-head parsing and lazy Request accessors;
- chunked transfer decoding used by both server and client;
- server response-head serialization;
- the narrow default server scalar-response builder.

The client response-head parser is intentionally strict Perl code. This is the
correctness baseline. Do not add response-parser XS merely for symmetry with the
server. Benchmark the client parser in representative end-to-end workloads
before deciding whether another native fast path is justified.

## Server::Connection

`Linux::Event::HTTP::Server::Connection` is a
`Linux::Event::IO::Sock::Stream` subclass and owns HTTP/1 server connection
state. Listener constructs the configured Connection class directly from its
Stream recipe; HTTP does not maintain an acceptance wrapper object.

Most applications do not subclass it. `connection_class` is the advanced hook
for reusable stream tuning, socket policy, TLS defaults, or named callbacks.

## Client::Connection

`Linux::Event::HTTP::Client::Connection` is also a
`Linux::Event::IO::Sock::Stream` subclass. It executes one Transaction at a time
and owns HTTP/1 Request serialization/framing and Response parsing on one
persistent socket.

It is usable directly for low-level work where destination acquisition is
already known. The high-level Client normally creates and reuses it.

The Connection reserves its raw data/eof/error/close callbacks for HTTP protocol
execution. Transport drain is composed with Transaction-owned Request producer
backpressure. Per-Transaction response callbacks, request producer options, and
optional bounded response-buffering policy are supplied to its `request` method.

## TLS

HTTPS uses the same message and connection classes. TLS remains Linux::Event
transport policy.

Server TLS is supplied through the Listener/Server recipe. Client HTTPS creates a
normal Linux::Event TLS client transport using the URL host as server name and
offers only `http/1.1` through ALPN.

There is no separate HTTPS class hierarchy.

## Upgrade

Server-side HTTP Upgrade is a Transaction lifecycle operation:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

The 101 response is validated and queued, the HTTP Transaction completes, and
Linux::Event `transition_to()` hands the same live stream object to the next
protocol class while preserving transport identity/state.

Client-side 101 handoff is not part of the current Client foundation. WebSocket
handshake/frame semantics belong in a separate `Linux::Event::WebSocket`
distribution.

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

## Current status

The current foundation includes:

1. Direction-neutral Request and Response message types.
2. Transaction as one Request/Response exchange with outgoing body producers.
3. HTTP/1 Server and Server::Connection with request-body delivery, persistent
   ordering, scalar/incremental responses, TLS, deferred response send, and
   Upgrade.
4. HTTP/1 Client::Connection with scalar and streaming Request serialization,
   strict Response parsing, informational responses, incremental
   Content-Length/chunked/close body delivery, cancellation, and sequential
   reuse.
5. High-level Client with URL parsing, Host synthesis, HTTP/HTTPS destination
   acquisition, bounded same-origin idle reuse, common convenience verbs,
   streaming Request production, and explicit bounded whole-response buffering.
6. One consolidated private `_HTTP1` native extension and no duplicate transport
   queues.

Later client work includes redirects, richer pool policy, proxy/auth/cookie
conveniences, CONNECT/client Upgrade, and measurement-driven parser
optimization.

HTTP/2 is future protocol work. WebSocket remains a separate protocol
distribution.
