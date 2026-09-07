# Architecture

Linux::Event::HTTP is the HTTP protocol layer for the Linux::Event ecosystem.
Its job is to make HTTP communication correct, easy to use, maintainable, and
composable without becoming a web application framework.

## Layer boundary

Linux::Event core owns reusable transport machinery:

- event dispatch
- stream sockets and listeners
- buffering and write queues
- backpressure
- connection lifecycle
- timers and deadlines
- TLS
- protocol handoff primitives

Linux::Event::HTTP owns HTTP semantics above that transport:

- request parsing and validation
- HTTP message framing
- request body delivery
- response metadata and serialization
- keep-alive semantics
- Expect handling
- HTTP Upgrade validation and handoff

The HTTP distribution should not duplicate lower-level transport capabilities
that belong in Linux::Event core.

## Public object model

The supported public API consists of:

    Linux::Event::HTTP::Server
    Linux::Event::HTTP::Connection
    Linux::Event::HTTP::Request
    Linux::Event::HTTP::Response

`Server` is a convenience over a Linux::Event listener. `Connection` owns one
HTTP protocol session. `Request` represents received request metadata.
`Response` is the writable handle for the paired response transaction.

The API should remain stable even if internal parsing or serialization
libraries change.

## Request lifecycle

For a new request, the protocol layer:

1. parses and validates the request head
2. establishes body framing and persistence semantics
3. creates the Request and paired Response handles
4. invokes `on_request`
5. streams request body bytes through `on_body` when configured
6. invokes `on_request_end` once the complete request boundary is consumed

If the application does not consume body bytes, the protocol layer drains them
so framing and keep-alive remain correct.

The common API should not require applications to understand chunk syntax or
other HTTP/1 wire details.

## Response lifecycle

Applications write through the Response object.

Status and headers remain mutable until output begins. `write` starts or
continues response output; `end` completes it. The protocol layer selects and
emits the required HTTP transfer framing.

The same API should support complete, streamed, and deferred responses rather
than exposing separate public object models for benchmark-specific cases.

## TLS

HTTPS is HTTP over a TLS-enabled Linux::Event transport. There is no separate
HTTPS protocol class.

TLS policy belongs to the Connection subclass through Linux::Event. HTTP sees
application bytes after handshake and sends response bytes through the same
transport.

## Upgrade and protocol bridging

HTTP Upgrade is an explicit bridge to another protocol. The HTTP layer validates
and sends the switching response, then hands the same live Linux::Event stream
to the target protocol class.

The target retains transport state, backpressure, deadlines, TLS, application
data, and bytes already read beyond the HTTP boundary.

This keeps upgraded protocols such as WebSocket in their own distributions.

## Parser and serializer policy

HTTP parser, serializer, compression, and standards-support libraries are
implementation details. Linux::Event::HTTP owns the public API.

The current HTTP/1 parser uses picohttpparser plus additional validation for
HTTP framing and security semantics. See `docs/HTTP1-PARSER.md`.

Existing native code is not automatically considered permanent. It should be
kept when it materially supports correctness, safe framing, or a demonstrated
realistic bottleneck. Community libraries should be preferred when they provide
the required behavior and can be wrapped cleanly.

## Performance policy

Performance is important, but protocol-level benchmark leadership is not a
project goal.

Aggressive reusable optimization belongs in Linux::Event core. HTTP-specific
optimization should be considered only after realistic measurement identifies a
material bottleneck that cannot reasonably be solved in a reusable lower layer.

Do not add public fast-path APIs merely to avoid allocations or win a synthetic
benchmark. One coherent request/response API is preferable to multiple
performance-specialized application paths.

## Non-goals

This distribution does not define application architecture. Routing frameworks,
templates, controllers, ORM integration, and framework-wide middleware systems
belong elsewhere.

The boundary test is simple: features that help endpoints communicate are in
scope; features that tell the programmer how to structure the application are
usually not.
