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

Because this distribution is still unreleased, this compatibility facade is
only a migration tool for the branch. The intended end state is a direct
`Linux::Event::HTTP::*` implementation with no Net-prefixed compatibility API.

### Public response API

The supported Server and Connection APIs reject `on_request_final`, both as a
constructor callback and as a Connection subclass method. The ordinary
`on_request -> Response` lifecycle is the supported response API for complete,
streamed, and deferred responses.

The private Server implementation and accepted-connection adapter also reject
or stop forwarding `on_request_final`.

Ordinary `Response->end` no longer attempts the former native default-response
shortcut. Complete, streamed, and deferred responses now share the ordinary
response state machine.

### Removed benchmark-specific native code

The dedicated `xsresponse1` extension has been removed from the build and source
tree.

The old private `_Native::Response1` package is now only a small transitional
compatibility shim that returns undef, forcing the remaining private old
Connection callback path through ordinary Response serialization. It contains
no XS and is not public API.

The benchmark-specific native-response and final-response tests were removed.
General response, framing, connection, streaming, TLS, Upgrade, and Server tests
remain.

The cleanup passed CI on Perl 5.36, latest Perl, and latest threaded Perl, with
`disttest` green on latest non-threaded Perl.

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

1. Remove the now-private residual `on_request_final` code from the old
   Net-prefixed Connection state machine and then delete the Response1
   compatibility shim.
2. Replace the migration facade with the actual direct `Linux::Event::HTTP::*`
   implementation and delete the old Net-prefixed package tree entirely.
3. Review Server/Connection/Request/Response for common-case usability and
   bridgeability rather than microbenchmark cost.
4. Review which custom parser/serializer XS pieces materially serve correctness
   or a realistic bottleneck and which can be simplified or replaced by mature
   community work.
5. Keep the PR draft until the direct namespace migration and final consistency
   review are complete.

Do not merge PR #14 without explicit authorization.

Update this file whenever a policy conclusion or cleanup milestone is completed.
