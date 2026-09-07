# Project policy

Linux::Event::HTTP follows the Linux::Event ecosystem charter in
`haxmeister/perl-linux-event`, `docs/ECOSYSTEM-CHARTER.md`.

The charter is an architectural constraint for this project, not a temporary
preference.

## HTTP-specific interpretation

For this distribution, priorities are:

1. correct HTTP behavior and safe framing
2. make the common correct use easy
3. keep Request, Response, Connection, and Server APIs small and coherent
4. prefer maintainable protocol code over benchmark-specific machinery
5. make HTTP easy to bridge to other Linux::Event protocols
6. remain comfortably fast without treating benchmark leadership as the goal

## Public namespace

The supported namespace is:

    Linux::Event::HTTP
    Linux::Event::HTTP::Server
    Linux::Event::HTTP::Connection
    Linux::Event::HTTP::Request
    Linux::Event::HTTP::Response

`Linux::Event::Net` is not a public umbrella namespace. Older Net-prefixed
packages that still exist during the implementation migration are private
transitional details and must not be used by new application code.

## Performance policy

Protocol-specific optimization is justified only by a realistic measured
bottleneck that materially affects actual HTTP workloads.

Do not add public callbacks, constructors, object types, or semantics solely to
win a microbenchmark. Before optimizing HTTP-specific code, ask whether the
same improvement belongs in Linux::Event core where Stream, buffering,
backpressure, TLS, lifecycle, or other protocols can benefit.

Competitive benchmarking belongs in `haxmeister/perl-Benchmark-Web`.

## Dependencies

Suitable established CPAN modules should be preferred over reimplementing
protocol machinery when they can be hidden cleanly behind the Linux::Event::HTTP
API.

Dependency evaluation should consider correctness, standards compliance,
maturity, maintenance, documentation, licensing, dependency weight,
architecture fit, and realistic performance.

No dependency is allowed to dictate the public object model merely because its
own API is convenient internally.

## Bridgeability

HTTP should expose useful protocol data in forms that are straightforward to
send through another Linux::Event protocol. Preserve HTTP-specific semantics,
but do not bury common payloads behind unnecessary framework abstractions.

HTTP Upgrade should remain a transport/protocol handoff boundary rather than
pulling WebSocket or other upgraded protocols into this distribution.

## Non-goals

Linux::Event::HTTP is not intended to become a web application framework. It
does not need MVC, templates, controllers, ORM integration, or a universal
middleware architecture.

The project succeeds when it makes HTTP communication correct, easy to use,
maintainable, composable, and sufficiently fast.
