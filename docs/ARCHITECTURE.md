# Linux::Event::Net::HTTP architecture

Linux::Event::Net::HTTP is a protocol implementation, not a web framework.

## Boundaries

The design is divided into three layers:

- **Transport** - Linux::Event owns sockets, TLS, readiness, buffering,
  backpressure, deadlines, and event dispatch.
- **Protocol** - this distribution owns HTTP parsing, serialization, protocol
  state, message boundaries, keep-alive, transfer coding, limits, and upgrade.
- **Message** - Request and Response expose application-facing HTTP semantics.

## Design rules

1. HTTP/1.1 is the first wire protocol, but application-facing Request and
   Response APIs should not unnecessarily encode HTTP/1-specific details.
2. Bodies are fundamentally streams. A convenience API may accumulate a small
   body, but accumulation is not the protocol primitive.
3. HTTP/1 request-head parsing uses vendored picohttpparser through a private XS
   boundary. The application-facing Request keeps parsed spans in native state
   and materializes Perl strings only when requested.
4. Linux::Event transport tuning, buffering, TLS, and backpressure must be
   reused rather than reimplemented here.
5. HTTP Upgrade transfers the same live stream-socket resource to another
   protocol class rather than detaching and rebuilding transport state.
6. The canonical callback-scoping model should preserve Linux::Event's
   subclass/cached-callback performance characteristics.
7. Convenience APIs must not make streaming, backpressure, or protocol limits
   second-class features.
8. Vendored protocol code must have recorded provenance and license text and
   must never require a network fetch during build, installation, or runtime.
9. Ambiguous HTTP/1 message framing is rejected rather than normalized in ways
   that can disagree with another HTTP implementation on the same path.
10. Every successfully dispatched Request owns one corresponding Response
    transaction. The protocol engine creates and binds that Response before
    application dispatch; application code never has to construct or return it.
11. A persistent connection advances only when both halves of the current
    transaction are complete: the full request input boundary has been consumed
    and the Response has ended.
12. HTTPS is HTTP over Linux::Event TLS transport, not a separate HTTP
    Connection hierarchy. TLS declaration and handshake policy stay on the
    accepted Connection subclass.

## HTTP/1 parser and request state

picohttpparser is vendored at a recorded upstream commit and compiled as part of
this distribution. The parser package is private; applications receive
Linux::Event::Net::HTTP::Request objects rather than parser offsets or pico
structures.

A native Request allocation contains request metadata, header slices, stable
request-head bytes, and validated framing state. Header names are compared in C
using ASCII case-insensitive semantics. Original spelling and duplicate fields
are preserved. Perl strings are created only for fields the application
accesses.

Strict protocol policy belongs above pico. The HTTP layer rejects obsolete
folded headers, imposes explicit header-count limits, requires exactly one Host
field for HTTP/1.1, validates Content-Length agreement, rejects
Transfer-Encoding plus Content-Length, requires chunked to be the final request
transfer coding, and derives connection persistence from HTTP version and
Connection options.

The Request API exposes the resulting framing decision through `body_mode`,
`content_length`, and `keep_alive`; it does not expose parser internals.

## HTTP/1 request body streaming

The Connection dispatches `on_request($self, $req, $res)` as soon as the
validated request head is available. Body bytes are then delivered with cached
callbacks:

```perl
sub on_body ($self, $req, $res, $bytes) {
    ...
}

sub on_request_end ($self, $req, $res) {
    ...
}
```

Content-Length bodies are consumed directly from the Connection input buffer.
No whole-body scalar is built by the protocol engine. If no `on_body` callback
is installed, bytes are drained and discarded so framing and keep-alive remain
correct without forcing an allocation path on applications that do not consume
the body. `on_request_end` runs once after the full request input boundary has
been consumed, including requests with no body.

Chunked request bodies use a private XS wrapper around picohttpparser's stateful
chunk decoder. Chunk framing is removed before Perl sees body bytes. The decoder
retains partial chunk state across reads and preserves bytes after the terminal
chunk so a pipelined request can remain in the same transport buffer. Chunk
extensions are accepted. Trailer sections are consumed to establish the body
boundary but are not yet exposed to applications.

For HTTP/1.1 requests with a body and `Expect: 100-continue`, Connection emits
`100 Continue` after validating the request head. Unsupported expectations are
rejected with 417 before application dispatch.

## HTTP/1 response serialization and streaming

Connection creates one Response before invoking `on_request`:

```perl
sub on_request ($self, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->end("hello\n");
}
```

Response is the transaction-scoped writable output handle. It is bound to the
persistent Connection and paired Request, while status, headers, and response
completion remain specific to that one transaction.

Response keeps application-supplied status and ordered field pairs while the
HTTP/1 response head is serialized in XS. Output validation rejects invalid
field-name tokens and control characters that could permit response splitting.
The serializer also refuses ambiguous framing fields, including multiple
Content-Length fields and Transfer-Encoding combined with Content-Length.

The first body operation commits the response head and freezes status/header
metadata. `end($bytes)` remains the scalar convenience path and adds
Content-Length automatically when it is the first body operation.

Streaming uses `write` followed by `end`:

```perl
$res->write("one\n");
$res->write("two\n");
$res->end("three\n");
```

If Content-Length was declared before the first write, Connection enforces that
fixed-length framing exactly. If HTTP/1.1 streaming starts without
Content-Length, Connection automatically adds `Transfer-Encoding: chunked`,
frames each nonempty write, and emits the terminal zero chunk from `end`.
An empty write emits no chunk and never terminates a response.

HTTP/1.0 cannot use chunked transfer coding. Unknown-length streaming therefore
falls back to close-delimited response framing, which forces connection close
after the response and current request input both complete.

Chunk encoding currently occurs in the Perl protocol layer around the existing
Linux::Event write path. This keeps the API and framing semantics correct first;
per-chunk native encoding is a benchmark-driven optimization rather than a
requirement of the public API.

## HTTP/1 connection

`Linux::Event::Net::HTTP::Connection` is itself a
`Linux::Event::IO::Sock::Stream` subclass. Its cached `on_data` callback is the
HTTP protocol engine, so there is no wrapper object between Linux::Event byte
I/O and HTTP parsing. Linux::Event continues to own transport, TLS, write
queuing, backpressure, and deadlines.

Each parsed request creates one transaction consisting of the Request, its
bound Response, request-body framing state, and response-output state. The next
pipelined request cannot dispatch until the request input has reached its wire
boundary and the Response has ended. If the request finishes first, reads pause
while the application retains the Response. If the Response finishes first,
the connection continues consuming the current request before advancing.

## HTTP Server convenience

`Linux::Event::Net::HTTP::Server` is a control-plane convenience around
`Linux::Event::IO::Sock::Listener`; it is not another protocol or transport
engine. The layering remains:

```text
HTTP::Server
    -> Linux::Event::IO::Sock::Listener
        -> HTTP::Connection
            -> Request + Response
```

The simple callback form retains one callback CV per supplied HTTP callback and
reuses those same CVs for every accepted Connection. A fixed private acceptance
adapter injects the retained callbacks into the configured Connection
constructor. The adapter creates no closure per accepted connection and adds no
Server method dispatch to the steady-state request/body callback path.

The configured `connection_class` defaults to `HTTP::Connection` and may name a
subclass. Constructor callbacks supplied to Server retain the same precedence as
direct Connection construction: they override same-named class methods for the
accepted instance. Application `data` is restored before the real Connection is
constructed, so the private Server acceptance state never leaks through
`$conn->data`.

Listener socket source and acceptance tuning remain owned by Linux::Event.
Server delegates host/port/Unix/adopted-listener construction and methods such
as `port`, `pause`, `resume`, and `close` rather than duplicating them.

## TLS transport integration

HTTPS uses the same `HTTP::Server`, `HTTP::Connection`, Request, and Response
classes. A secure accepted Connection is declared in exactly the same place as
other Linux::Event Stream policy:

```perl
package SecureHTTP;
use parent 'Linux::Event::Net::HTTP::Connection';
use Linux::Event::TLS
    cert_file => '/etc/myapp/server-cert.pem',
    key_file  => '/etc/myapp/server-key.pem',
    alpn      => ['http/1.1'];
```

`HTTP::Server` validates the configured Connection's accepted-stream policy at
construction time. Linux::Event then sees `_accepted => 1` on the real
Connection subclass and creates server-side TLS transport before the HTTP input
engine receives bytes. No HTTPS-specific wrapper object is inserted.

TLS `on_ready` runs only after the handshake and verification state is complete.
The HTTP parser therefore consumes decrypted application bytes, while Response
writes pass through Linux::Event's TLS transport and shutdown semantics.
Negotiated `selected_alpn`, `tls_protocol`, `tls_cipher`, and `tls_stats` remain
available on the same HTTP Connection object.

HTTP/1.1 ALPN is ordinary Linux::Event TLS policy. The current HTTP engine is
HTTP/1.x only, so deployments using ALPN should advertise `http/1.1`; future
HTTP/2 support will require protocol selection and a separate HTTP/2 engine,
not reinterpretation of HTTP/1 bytes.

## HTTP Upgrade handoff

Upgrade is a transaction boundary, not a second transport acquisition step. The
application or target protocol layer prepares the protocol-specific response
fields and asks the bound Response to hand the live connection to another
stream-socket protocol:

```perl
$res->header('Upgrade', 'websocket');
$res->header('Sec-WebSocket-Accept', $accept);
$res->upgrade('MyWebSocketConnection');
```

The HTTP layer validates HTTP/1.1 Upgrade framing: the request must contain
`Connection: Upgrade`, must offer the selected Upgrade protocol, must remain
persistent, and in the initial contract must have no request message body. The
switching response cannot contain Content-Length or Transfer-Encoding.
`Response->upgrade` normalizes the status to 101 and adds `Connection: Upgrade`
when the response did not already supply it.

The handoff is deliberately deferred to the next Loop turn. This lets the
ordinary `on_request` and `on_request_end` stack unwind before the object changes
class. While the handoff is pending, Response metadata and ordinary body output
are locked and HTTP reads remain paused after the request input boundary.

Immediately before transition, HTTP queues the complete 101 response. It then
removes the finished HTTP transaction, passes any bytes already read beyond the
HTTP head as explicit preserved input, and calls Linux::Event `transition_to()`.
The target protocol therefore receives the same Perl object and the same native
ordered-byte state. The socket or socketpair, TLS provider, queued output,
backpressure state, deadlines, watcher registrations, and application data all
remain in place. Target-protocol writes append after the already-queued 101.

This is the intended integration boundary for a separate
`Linux::Event::Net::WebSocket` distribution. WebSocket handshake calculations
and frame semantics belong there; HTTP owns only the validated 101 transaction
and protocol handoff.

## Implementation order

Completed foundation:

1. HTTP/1 request-head parser.
2. Native lazy Request representation.
3. HTTP/1 request message-framing validation and persistence policy.
4. Native HTTP/1 response-head serialization.
5. HTTP Connection bound directly to Linux::Event stream transport.
6. Ordered sequential keep-alive and pipelined request dispatch.
7. Bound Request/Response transaction API with scalar and fixed-length response
   output.
8. Streaming Content-Length request bodies.
9. Native chunked request decoding and request-end callbacks.
10. HTTP/1.1 Expect: 100-continue handling.
11. Automatic HTTP/1.1 chunked response streaming with HTTP/1.0 close-delimited
    fallback.
12. HTTP Server/listener convenience layer with retained Connection callbacks.
13. TLS transport integration through declarative Connection policy and
    HTTP/1.1 ALPN coverage.
14. Atomic HTTP/1.1 Upgrade handoff through Linux::Event protocol transition.

Next protocol work:

15. End-to-end benchmarks and profiling.

Routing, middleware, sessions, templates, PSGI/PAGI adapters, compression,
WebSocket, HTTP/2, and HTTP clients are intentionally outside the initial
scope.
