# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Current direction

Repository: `haxmeister/perl-Linux-Event-HTTP`

Working branch: `refactor/ecosystem-charter`

Draft PR: #14, `Refactor HTTP around Linux::Event ecosystem charter`

The project follows `docs/ECOSYSTEM-CHARTER.md` from the Linux::Event core
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

## Completed in this branch

### Repository and public namespace

The repository was renamed to `perl-Linux-Event-HTTP` and the supported public
namespace is now:

- `Linux::Event::HTTP`
- `Linux::Event::HTTP::Server`
- `Linux::Event::HTTP::Connection`
- `Linux::Event::HTTP::Request`
- `Linux::Event::HTTP::Response`

`Linux::Event::Net` is no longer a supported umbrella namespace. The old
Net-prefixed HTTP packages remain temporarily underneath as migration
implementation details and are marked `no_index` in distribution metadata.

Request and Response engine objects satisfy the new public Request/Response
types so the namespace can migrate without destabilizing protocol behavior.

### Public API policy

The newly supported Server and Connection APIs reject `on_request_final`, both
as a constructor callback and as a Connection subclass method. The ordinary
`on_request -> Response` lifecycle is the supported response API for complete,
streamed, and deferred responses.

The old private engine still contains the former `on_request_final` and native
default-response implementation. Do not optimize or advertise it. Remove that
legacy implementation in a separate focused cleanup rather than mixing a large
private-engine rewrite into the namespace migration.

### Benchmark separation

The entire in-repository `bench/` tree was removed from this branch, along with
benchmark-era documentation and all benchmark execution from CI.

Competitive and exploratory HTTP benchmarking belongs in
`haxmeister/perl-Benchmark-Web`.

CI now focuses on:

- Perl 5.36
- latest Perl
- latest threaded Perl
- build and behavioral tests
- `disttest`

The current PR head passed all three CI variants, including `disttest` on latest
non-threaded Perl.

### Documentation and packaging

README, CONTRIBUTING, Changes, architecture, parser documentation, distribution
metadata, and MANIFEST were rewritten around the ecosystem charter and the
`Linux::Event::HTTP` identity.

New policy documentation explicitly says:

- correctness and easy correct use come before benchmark leadership
- one coherent Request/Response API is preferred over benchmark-specialized
  application paths
- dependencies are implementation details and must not dictate the public API
- HTTP remains a communication protocol library, not a web application framework
- reusable optimization should be pushed down into Linux::Event core when
  possible
- HTTP Upgrade remains a bridge to separate protocols such as
  `Linux::Event::WebSocket`

## Parser policy

The current picohttpparser integration remains for now because request framing
and security behavior must not be destabilized during the policy transition.
Parser choice is an implementation detail, not public API.

Reevaluate parser/standards dependencies later under the ecosystem dependency
policy: correctness, standards behavior, maturity, maintenance, API fit,
licensing, dependency weight, and realistic performance where material.

Do not replace pico merely for a small benchmark difference.

## Remaining cleanup

1. Remove the legacy private `on_request_final` path and dedicated
   `_Native::Response1` XS extension, together with their old tests, while
   preserving the ordinary Response behavior.
2. Rename or collapse the remaining internal `Linux::Event::Net::HTTP::*`
   implementation packages into the direct `Linux::Event::HTTP` namespace once
   the migration facade has served its purpose.
3. Review Server/Connection/Request/Response for common-case usability and
   bridgeability rather than microbenchmark cost.
4. Review which custom parser/serializer XS pieces materially serve correctness
   or a realistic bottleneck and which can be simplified or replaced by mature
   community work.
5. Keep the PR draft until the private-engine cleanup and final namespace
   consistency review are complete.

Do not merge PR #14 without explicit authorization.

Update this file whenever a policy conclusion or cleanup milestone is completed.
