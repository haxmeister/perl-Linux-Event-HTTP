# Linux::Event::HTTP architecture

Linux::Event::HTTP is an HTTP protocol implementation for Linux::Event. It is
not a web framework or a framework-adapter distribution.

## Boundaries

The design has three layers:

- **Transport** - Linux::Event owns sockets, TLS, readiness, buffering,
  backpressure, deadlines, write queuing, and event dispatch.
- **Protocol** - Linux::Event::HTTP owns HTTP parsing, serialization, message
  framing, persistence, limits, transfer coding, and Upgrade.
- **Application-facing transaction objects** - Request exposes the incoming HTTP
  request and Response controls the outgoing HTTP response.

Reusable transport or byte-stream performance work belongs in Linux::Event.
HTTP-specific native code should remain limited to HTTP wire work where a native
boundary is justified.

Routing, middleware, sessions, templates, PSGI/PAGI integration, and other web
framework concerns are outside this distribution.

## Public structure

The current server-side public structure is:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
```

The connection class is deliberately server-specific. Client and server
connections have opposite protocol roles, so there is no generic public
`Linux::Event::HTTP::Connection`.

Future native client support belongs in this distribution as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet. It should be a native Linux::Event protocol
client rather than an HTTP::Tiny or LWP transport adapter. Compatibility
adapters can live in separate distributions.

## Server transaction model

`Linux::Event::HTTP::Server` is the normal server entry point. It is a thin
control-plane convenience over `Linux::Event::IO::Sock::Listener`.

The ordinary callback is:

```perl
on_request => sub ($conn, $req, $res) {
    $res->complete("hello\n");
}
```

The three objects have different lifetimes:

- `$conn` is the persistent TCP/TLS HTTP connection.
- `$req` is one incoming request on that connection.
- `$res` is the outgoing response paired with that request.

`Response->complete` completes the HTTP response, not the connection. On a
persistent HTTP/1.1 connection the same socket normally remains open and can
carry later requests.

A persistent connection advances only when both halves of the current
transaction are complete: the full request input boundary has been consumed and
the Response is complete.

## Request body streaming

`on_request($conn, $req, $res)` runs as soon as the validated request head is
available. A request body may continue afterward.

Optional callbacks are:

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
consumed, including bodyless requests.

For HTTP/1.1 requests with a body and `Expect: 100-continue`, the connection
emits `100 Continue` after validating the request head. Unsupported expectations
are rejected before application dispatch.

## Response output

Response status and headers may be configured before output starts:

```perl
$res->status(200);
$res->header('Content-Type', 'text/plain');
$res->complete("hello\n");
```

`complete($bytes)` supplies optional final body bytes and marks that Response
complete. It does not itself mean close the socket.

Streaming uses `write` followed by `complete`:

```perl
$res->write("one\n");
$res->write("two\n");
$res->complete;
```

The first output commits the response head and freezes status/header metadata.
For HTTP/1.1, streaming without Content-Length uses chunked transfer coding. If
Content-Length was declared, the emitted byte count is enforced. HTTP/1.0
unknown-length streaming is close-delimited, so that particular response
requires connection close after queued output drains.

HEAD and body-forbidden status handling are enforced by the protocol layer.

The public completion introspection method is `is_complete`. The distribution
deliberately has no Response `end` or `is_ended` alias; `end` remains a transport
concept on Linux::Event streams rather than an HTTP Response concept.

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

The scalar-response builder is a private optimization behind ordinary
`Response->complete(...)`. Applications do not select a special performance
callback or alternate transaction API.

## Request semantics

The Request API exposes validated protocol decisions rather than parser
internals. Important methods include:

```text
method
target
http_version
body_mode
content_length
keep_alive
header
header_values
header_count
header_name
header_value
```

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
advanced extension point for reusable transport policy, TLS, stream tuning,
socket policy, or named callback methods.

Constructor callbacks supplied to Server override same-named methods on the
configured connection class for that accepted instance.

## TLS

HTTPS uses the same Server, Server::Connection, Request, and Response classes.
TLS remains Linux::Event transport policy on the configured Connection subclass.
HTTP parsing receives decrypted bytes after the TLS handshake, while response
output travels through the same Linux::Event TLS transport.

There is no separate HTTPS class hierarchy.

## Upgrade

HTTP Upgrade is a transaction boundary, not a second transport acquisition.
The Response validates and schedules the switching transaction:

```perl
$res->header('Upgrade', 'my-protocol');
$res->upgrade('MyProtocolConnection');
```

HTTP validates the HTTP/1.1 Upgrade request and response, queues the 101 response,
then Linux::Event `transition_to()` hands the same live stream object to the
target protocol class.

Socket identity, TLS state, queued output, backpressure, deadlines, watcher
state, application data, and bytes already read beyond the HTTP request head are
preserved.

WebSocket handshake/frame semantics belong in a separate
`Linux::Event::WebSocket` distribution. Linux::Event::HTTP owns only the HTTP
Upgrade transaction and handoff.

## Performance policy

Benchmark discoveries may justify private optimizations, but they do not justify
alternate public APIs merely to expose a fast path. The ordinary API should take
an optimization transparently when eligible.

Before adding HTTP-specific native transport machinery, first ask whether the
expensive primitive is reusable socket, buffer, or write machinery that belongs
in Linux::Event core.

Parser microbenchmarks and end-to-end transaction benchmarks answer different
questions. See `docs/BENCHMARKING.md` for the measurement contract.

## Current status

The current server foundation includes:

1. HTTP/1 request-head parsing and lazy Request representation.
2. Strict HTTP/1 request framing validation and persistence policy.
3. Streaming Content-Length and chunked request bodies.
4. Expect: 100-continue handling.
5. Response serialization, fixed-length output, and chunked streaming.
6. Ordered persistent/pipelined request processing.
7. Deferred Response completion.
8. TLS transport integration.
9. Atomic HTTP/1.1 Upgrade handoff.
10. One consolidated private `_HTTP1` native extension.
11. One canonical server callback API using Response `write` and `complete`.

Future protocol work includes the native HTTP client and HTTP/2. WebSocket
remains a separate protocol distribution.
