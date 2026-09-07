# Contributing

Contributions are welcome.

Linux::Event::HTTP is a protocol distribution in the Linux::Event ecosystem.
Substantial API or architectural work should be evaluated against the ecosystem
charter before implementation begins.

The charter is maintained in the Linux::Event core repository at
`docs/ECOSYSTEM-CHARTER.md`.

## Priorities

Protocol-layer changes should be judged in this order:

1. correctness
2. ease of correct use
3. a clear and consistent public API
4. maintainability
5. composability and bridgeability
6. good performance

A microbenchmark win is not sufficient justification for protocol-specific XS,
C, public fast-path callbacks, or other specialized complexity.

Before adding protocol-specific optimization, ask whether the same work belongs
in a reusable Linux::Event primitive such as Stream, framing, buffering,
backpressure, TLS, lifecycle management, or multiplexing.

## Scope

Keep the distribution focused on HTTP communication rather than application
framework concerns. Routing frameworks, templates, controller hierarchies,
ORMs, and application-wide middleware systems are outside the project goal.

Linux::Event owns transport, TLS, buffering, backpressure, deadlines, and event
dispatch. HTTP owns HTTP message semantics and the public Request/Response API.
Third-party implementation libraries must not dictate the public API.

Prefer suitable established Perl community libraries over new custom protocol
code when they can be wrapped cleanly behind Linux::Event::HTTP.

## Tests and benchmarks

Behavioral changes require tests, and public documentation must stay in sync
with the implementation.

Competitive and exploratory HTTP benchmarking belongs in the separate
`haxmeister/perl-Benchmark-Web` repository. Add protocol-local performance
measurement here only when investigating a demonstrated realistic bottleneck.

Run the normal distribution checks before submitting a pull request:

```sh
perl Makefile.PL
make
make test
make disttest
```

Keep source and documentation ASCII unless a protocol test specifically needs
other bytes.

## Security issues

Do not report suspected security vulnerabilities in public issues or pull
requests. See `SECURITY.md` for private reporting instructions.
