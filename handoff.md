# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Current working branch: `main`
- Structural integration PR #15, `Restructure Linux::Event::HTTP around protocol
  roles`, was explicitly authorized and merged.
- Structural merge commit: `122b749600d6a17246e0165f8b15cc4dfa4a6af6`
- Final PR head before merge: `2ce7af84bb6bcdc68ea6dbc01ec95790a62f66de`
- CI run `34162687196` passed on that exact PR head before merge.
- Post-merge architecture wording cleanup was committed directly to `main` as
  `ce5a7eb27bc2e94cd9000b3e2407e291f2248941`.
- Older draft PR #14 was closed as superseded and must not be used as design
  guidance.

Merged/abandoned feature and refactor branches are considered disposable by
default. Keep a branch only when it contains unique work that is still useful.
At the time of the post-merge audit, `experiment/fused-request-index` still had
seven unique commits containing the request-index fusion experiment and was the
only non-main branch with a concrete reason to preserve it.

## Charter

Linux::Event is the Linux-native communications engine. Reusable low-level
performance work belongs in Linux::Event core so multiple protocol layers can
benefit from it.

Linux::Event::HTTP is an HTTP protocol distribution. Prioritize protocol
correctness, ease of correct use, a simple API, maintainability, and
composability over winning isolated HTTP microbenchmarks.

Do not add routing, middleware, sessions, templates, PSGI/PAGI, or other web
framework responsibilities here. Those are separate layers for other projects.
There is no planned PSGI layer inside this distribution.

Use established CPAN/community libraries for standards and utilities when they
fit the protocol boundary. Do not force a dependency or object model into the
hot wire path merely because a prominent module exists.

Do not add HTTP-specific XS merely to improve a benchmark. First determine
whether the expensive primitive is generic transport, buffer, or write machinery
that belongs in Linux::Event core.

## Public structure

Current server-side public modules:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
```

The old `Linux::Event::Net::HTTP` namespace is gone. There is no public generic
`Linux::Event::HTTP::Connection`; the implemented connection is specifically
the server-direction protocol connection.

Future native client structure is reserved as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet and should be developed as a separate feature
effort. Do not force client lifecycle behavior into `Server::Connection` merely
for naming symmetry.

## Request/Response CPAN audit conclusion

Prominent CPAN message/header modules were evaluated, including `HTTP::Request`,
`HTTP::Response`, `HTTP::Headers`, `HTTP::Headers::Fast`, and
`HTTP::XSHeaders`.

Keep Linux::Event::HTTP's own Request and Response because they are live
protocol roles rather than complete buffered messages:

- Request is a validated native incoming request-head view. Method, target, and
  headers are materialized lazily. Request bodies remain streamed connection
  input rather than Request-owned content.
- Response is a live writable server transaction with `write`, `end`,
  backpressure, framing, persistence, and Upgrade behavior.

Do not replace native request header storage with HTTP::Headers-family objects.
Those APIs normalize header names in ways that can conflate legal wire names
such as `X_Foo` and `X-Foo`, while this parser intentionally preserves them as
distinct fields.

Do not grow Request/Response into another generic HTTP utility ecosystem. URI,
cookie, date, authentication, MIME, and similar application-level conveniences
should use appropriate external libraries where suitable.

## Consolidated native HTTP/1 boundary

The distribution now builds one private HTTP-local native extension:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

The single private `_HTTP1` shared object owns:

- HTTP/1 request-head parser and lazy Request XSUBs
- chunked request decoder (`_HTTP1::Chunked` logical package)
- response-head serializer
- narrow default scalar response builder

picohttpparser is compiled once. The old separate `xschunked` and `xsresponse1`
extensions are gone, eliminating duplicated native request-state structure
layouts.

This consolidation reduces HTTP-local native maintenance. It is not a reason to
move HTTP semantics into Linux::Event core.

## Server request API

There is one canonical request API:

```perl
on_request => sub ($conn, $req, $res) {
    $res->end("hello\n");
}
```

Optional body lifecycle callbacks remain:

```text
on_body
on_request_end
```

The former public `on_request_final` callback has been removed. Passing it to
`Server` or direct `Server::Connection` construction fails with migration
guidance to use `on_request` plus `Response->end`.

For bodyless requests without an `on_request_end` handler, the connection marks
the body complete before `on_request`, so the canonical
`on_request -> Response->end` path remains eligible for the narrow private
native default-final optimization. If `on_request_end` is configured, that
lifecycle boundary is preserved instead of bypassed for benchmark speed.

## Final-response experiment conclusion

The historical `on_request_final` experiment was useful, but its public API was
rejected.

Measured work showed that eager general Response/transaction machinery can be
expensive for trivial complete responses. The public lesson is not to expose a
benchmark-specific callback. The ordinary `Response->end(...)` path therefore
retains the private `_try_native_default_final` /
`_HTTP1->build_default_final` optimization when eligible.

HEAD, HTTP/1.0, custom status/headers, streaming, deferred responses, request
bodies, and other non-eligible cases continue through the general Response
state machine.

Do not reopen the public fast-final API without a fundamentally new reason.

## Server and transport boundary

`Linux::Event::HTTP::Server` remains a thin control-plane convenience around
`Linux::Event::IO::Sock::Listener`:

```text
HTTP::Server
    -> Linux::Event::IO::Sock::Listener
        -> HTTP::Server::Connection
            -> Request + Response
```

Server retains callback CVs once and reuses them for accepted connections. The
private `_ServerConnection` adapter exists only to bridge Listener accepted
stream construction into the configured HTTP connection class and HTTP-specific
constructor callbacks.

Do not enlarge Linux::Event Listener merely to eliminate this small private
adapter. Reconsider only if multiple protocol distributions independently need
the same reusable accepted-stream constructor capability.

TLS remains Linux::Event transport policy on the Server::Connection subclass.
There is no separate HTTPS connection hierarchy.

## Upgrade boundary

Keep the existing Upgrade design:

1. HTTP validates HTTP/1.1 Upgrade semantics and the selected protocol.
2. HTTP queues the valid 101 response.
3. HTTP clears completed transaction state.
4. Linux::Event `transition_to()` hands the same live transport object to the
   target protocol class.

Socket, TLS state, output queue, backpressure, deadlines, watcher state,
application data, and bytes already read beyond the HTTP head are preserved.

WebSocket semantics belong in a separate `Linux::Event::WebSocket`
distribution. HTTP owns only the HTTP Upgrade transaction and handoff.

## Client direction

A native HTTP client belongs in Linux::Event::HTTP because initiating and
speaking HTTP is protocol functionality in this communications ecosystem.

Do not base it on HTTP::Tiny or LWP; their public request lifecycles are
blocking/synchronous and are not a clean transport seam for Linux::Event's
event-driven connection lifecycle.

Compatibility adapters for LWP, HTTP::Tiny, frameworks, or other ecosystems
belong in separate adapter distributions. The native client should use
`Linux::Event::HTTP::Client` / `Client::Connection` and share private HTTP wire
machinery only where semantics are genuinely common with the server.

## Structural audit result

The merged structure has been checked for the following invariants:

- no live `lib/Linux/Event/Net/HTTP` package tree
- no public generic `HTTP::Connection`
- only the server-specific `HTTP::Server::Connection`
- one HTTP-local native extension, `_HTTP1`
- old `xschunked` and `xsresponse1` extension directories removed
- old parser/Response1 private wrapper packages removed
- `on_request_final` retained only in explicit rejection tests/errors and
  historical discussion
- superseded unshipped `bench/run-http-hotpath.pl` removed
- superseded unshipped `bench/run-http-response-path.pl` removed
- duplicate `_HTTP1` imports removed from `Response.pm` and the native response
  test
- end-to-end, cross-server, and transaction-ladder benchmark JSON identities
  use `linux-event-http-*`
- transaction-ladder wording uses `_HTTP1` and `Server::Connection`, not the old
  `Response1` or generic Connection names

The maintained architecture, README, Request/Response POD, Server POD, and
Server::Connection POD reflect the flat namespace and canonical API.

## Validation

Namespace/native consolidation and API cleanup were validated through build,
full tests, end-to-end benchmark smoke, and distribution testing during the
refactor.

The final PR head `2ce7af84bb6bcdc68ea6dbc01ec95790a62f66de`
passed GitHub Actions run `34162687196` before merge. The normal CI matrix
covered Perl latest, Perl 5.36, latest threaded Perl, HTTP benchmark smoke, and
distribution integrity. Heavy cross-server diagnostics remain intentionally
manual/workflow-dispatch work rather than ordinary CI performance claims.

## Closed performance experiments

Do not reopen these without a new measured hypothesis:

- duplicated bodyless Perl driver: only a small gain; rejected
- HTTP input-buffer COW/adopt/clear: small gain in one shape but regressions for
  split/coalesced reads; rejected
- libh2o as the HTTP/1 engine: benchmark/reference competitor only
- splitting ordinary HTTP head/body writes: likely trades memcpy for another
  syscall; revisit only with a measured generic Linux::Event segmented/gathered
  submit primitive
- broad native HTTP connection driver: not justified by measurements

## Benchmark policy

`bench/run-http-final-response.pl` measures only supported public callback
shapes. The cross-server benchmark has no `fast-final` Linux::Event mode.

Heavy comparison/performance CI remains `workflow_dispatch` only. Ordinary CI
covers supported Perl configurations, HTTP smoke, and distribution integrity.

## Branch policy

Do not keep merged or abandoned working branches merely as history; Git already
preserves the commits. Delete them unless they contain unique work that has a
specific reason to remain accessible.

The request-index fusion experiment is currently the notable exception because
its branch contains unique benchmark/research work. Re-evaluate and delete that
branch once the experiment is either incorporated, documented elsewhere, or
formally closed.

## Next substantive steps

1. Native HTTP client work can begin as a separate feature under
   `Linux::Event::HTTP::Client` / `Client::Connection`.
2. Keep HTTP protocol work within the charter: correctness and simple protocol
   APIs first; move reusable low-level performance primitives into Linux::Event
   core when appropriate.
3. Do not add PSGI/PAGI/framework responsibilities to this distribution.
4. Preserve `handoff.md` as current-state continuity documentation after major
   conclusions or integration changes.
