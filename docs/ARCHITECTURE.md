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
3. Protocol parsing may move into XS/C and should avoid unnecessary copies and
   avoid Perl callback churn in hot paths.
4. Linux::Event transport tuning, buffering, TLS, and backpressure must be
   reused rather than reimplemented here.
5. The connection layer must permit protocol handoff so HTTP Upgrade can later
   transfer a connection to another protocol such as WebSocket.
6. The canonical callback-scoping model should preserve Linux::Event's
   subclass/cached-callback performance characteristics.
7. Convenience APIs must not make streaming, backpressure, or protocol limits
   second-class features.

## Initial implementation order

1. HTTP/1 parser and protocol state machine.
2. Request representation.
3. Response serialization.
4. Bind one HTTP connection to Linux::Event stream transport.
5. Sequential keep-alive requests.
6. Streaming request and response bodies.
7. Chunked transfer coding.
8. Server/listener convenience layer.
9. TLS integration.
10. Upgrade handoff.
11. Benchmarks and profiling.

Routing, middleware, sessions, templates, PSGI/PAGI adapters, compression,
WebSocket, HTTP/2, and HTTP clients are intentionally outside the initial
scope.
