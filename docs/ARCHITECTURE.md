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
5. The connection layer must permit protocol handoff so HTTP Upgrade can later
   transfer a connection to another protocol such as WebSocket.
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

## HTTP/1 response serialization

Connection creates one Response before invoking `on_request`:

```perl
sub on_request ($connection, $request, $response) {
    $response->status(200);
    $response->header('Content-Type', 'text/plain');
    $response->end("hello\n");
}
```

Response keeps application-supplied status and ordered field pairs while the
HTTP/1 response head is serialized in XS. Output validation rejects invalid
field-name tokens and control characters that could permit response splitting.
The serializer also refuses ambiguous framing fields, including multiple
Content-Length fields and Transfer-Encoding combined with Content-Length.

The first body operation commits the response head and freezes status/header
metadata. `end($bytes)` is the normal scalar convenience path and adds
Content-Length automatically. `write($bytes)` supports fixed-length streaming
when Content-Length is declared before output starts; its return value preserves
Linux::Event Stream backpressure status. Automatic chunked streaming remains a
later transfer-coding step.

## HTTP/1 connection

`Linux::Event::Net::HTTP::Connection` is itself a
`Linux::Event::IO::Sock::Stream` subclass. Its cached `on_data` callback is the
HTTP protocol engine, so there is no wrapper object between Linux::Event byte
I/O and HTTP request parsing. Linux::Event continues to own transport, TLS,
write queuing, backpressure, and deadlines.

Validated no-body requests are dispatched through
`on_request($connection, $request, $response)`. The Response object commits
output directly through its owning Connection. Completion applies HTTP
persistence rules and permits the next already-buffered request to run only
after the current response has ended. If an application retains Response for a
later event, Connection pauses reads until that transaction completes.

The current connection deliberately refuses positive Content-Length and
chunked request bodies with 501. Request-body streaming is the next
state-machine milestone rather than an implicit whole-body accumulation
feature.

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

Next protocol work:

8. Streaming request bodies.
9. Chunked transfer coding.
10. Server/listener convenience layer.
11. TLS integration.
12. Upgrade handoff.
13. End-to-end benchmarks and profiling.

Routing, middleware, sessions, templates, PSGI/PAGI adapters, compression,
WebSocket, HTTP/2, and HTTP clients are intentionally outside the initial
scope.
