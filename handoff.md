# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Current direction

Repository: `haxmeister/perl-Linux-Event-HTTP`

Working branch: `refactor/ecosystem-charter`

The project has adopted `docs/ECOSYSTEM-CHARTER.md` from the Linux::Event core
repository as an architectural constraint.

For protocol-layer work the priority order is:

1. correctness
2. ease of correct use
3. clear and consistent public API
4. maintainability
5. composability and bridgeability
6. good performance

Aggressive reusable performance work belongs in Linux::Event core. Do not add
protocol-specific complexity or public fast-path APIs merely to win a
microbenchmark.

## Namespace

The supported namespace is now `Linux::Event::HTTP`, not
`Linux::Event::Net::HTTP`.

The first migration stage introduces public facade packages under:

- `Linux::Event::HTTP`
- `Linux::Event::HTTP::Server`
- `Linux::Event::HTTP::Connection`
- `Linux::Event::HTTP::Request`
- `Linux::Event::HTTP::Response`

The existing Net-prefixed implementation is temporarily retained underneath so
behavior can stay stable during migration. It is marked non-public/no_index and
should be removed or renamed internally in a later cleanup once the public
facade is green.

## Benchmark policy

Competitive and exploratory HTTP benchmarking belongs in
`haxmeister/perl-Benchmark-Web`.

The HTTP repository should not carry cross-server comparison machinery,
transaction ladders, parser microbenchmarks, or CI jobs whose purpose is
benchmark leadership. Protocol-local measurement should return only when a
realistic workload demonstrates a material bottleneck.

## Current implementation review

The existing engine includes benchmark-driven complexity from the previous
performance-first phase, notably `on_request_final` and the native default-final
response builder. These remain under review and are intentionally omitted from
the newly documented supported API.

Do not optimize them further. The next cleanup pass should determine whether to
remove them entirely in favor of the ordinary `on_request -> Response` path.

The current picohttpparser integration remains for now because request framing
and security behavior must not be destabilized during the policy transition.
Parser choice is an implementation detail and should later be reevaluated under
the ecosystem dependency policy rather than benchmark results.

## Next steps

1. Get the namespace/policy transition branch green.
2. Remove the old benchmark directory and benchmark-era documentation from this
   repository; retain benchmark work in perl-Benchmark-Web.
3. Remove or simplify benchmark-specific public/implementation fast paths,
   starting with `on_request_final`, if behavioral tests confirm no correctness
   dependency.
4. Rename the remaining internal Net-prefixed implementation packages to the
   direct `Linux::Event::HTTP` namespace once the public migration is stable.
5. Review the API for easy common-case use, bridgeability, and unnecessary
   framework-like or performance-specific complexity.
6. Evaluate community HTTP parsing/standards libraries only after the public API
   is stable; dependencies must remain hidden implementation details.

Update this file whenever a policy conclusion or cleanup milestone is completed.
