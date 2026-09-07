# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Working branch: `refactor/http-charter-structure`
- Draft integration PR: #15, `Restructure Linux::Event::HTTP around protocol roles`
- Base `main` when this work started: `e38254d6513e2044019f2516ea1a45633932facc`
- Namespace/native consolidation implementation commit:
  `d5018cd9979be7be3d6e439509c69563e8d8a180`
- Public fast-final callback removal commit:
  `a3d91c42808fd9ba99869c6bafa736acaf32fe7e`
- Final terminology/audit cleanup code head before this handoff-only update:
  `826bbfcfb45341dba9b087c20a6c1cf82d16ea93`
- PR CI run `34162582933` passed on that code head.
- Do **not** merge PR #15 or this branch to `main` without Joshua's explicit
  authorization.

The older draft PR #14 belongs to `refactor/ecosystem-charter` and is stale. Do
not use its description as the current design or integration proposal.

## Charter being applied

Linux::Event is the Linux-native communications engine. Reusable low-level
performance work belongs in Linux::Event core so multiple protocol layers can
benefit from it.

Linux::Event::HTTP is an HTTP protocol distribution. Prioritize protocol
correctness, ease of correct use, a simple API, maintainability, and
composability over winning isolated HTTP microbenchmarks.

Do not add routing, middleware, sessions, templates, PSGI/PAGI, or other web
framework responsibilities here. Those are separate layers for other projects.

Use established CPAN/community libraries for standards and utilities when they
fit the protocol boundary. Do not force a dependency or object model into the
hot wire path merely because a prominent module exists.

Do not add HTTP-specific XS merely to improve a benchmark. First determine
whether the expensive primitive is generic transport/buffer/write machinery
that belongs in Linux::Event core.

## Final public structure

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

Future client structure is reserved as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is **not implemented on this branch** and must remain a separate
feature effort.

`HTTP::Request` and `HTTP::Response` remain the current protocol object names,
but this does not force a future client to combine incompatible server/client
lifecycle semantics into those same implementations. If client-direction live
roles differ materially, keep them under `Linux::Event::HTTP::Client` rather
than adding mode switches to the server Response API merely for naming
symmetry.

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

Before this branch the distribution built three private native extensions:

```text
xshttp1
xschunked
xsresponse1
```

The refactor now builds only:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

The single private `_HTTP1` shared object owns:

- HTTP/1 request-head parser and lazy Request XSUBs
- chunked request decoder (`_HTTP1::Chunked` logical package)
- response-head serializer
- narrow default scalar response builder

picohttpparser is compiled once. The old `Response1.xs` duplicated the native
request-state structure layout from the parser extension; that maintenance risk
is gone.

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
expensive for trivial complete responses. The public lesson is **not** to expose
a benchmark-specific callback. The ordinary `Response->end(...)` path therefore
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

## Client decision

A native HTTP client belongs in Linux::Event::HTTP because initiating and
speaking HTTP is protocol functionality in this communications ecosystem.

Do not base it on HTTP::Tiny or LWP; their public request lifecycles are
blocking/synchronous and are not a clean transport seam for Linux::Event's
event-driven connection lifecycle.

Compatibility adapters for LWP, HTTP::Tiny, frameworks, or other ecosystems
belong in separate adapter distributions. The native client should use
`Linux::Event::HTTP::Client` / `Client::Connection` and share private HTTP wire
machinery only where semantics are genuinely common with the server.

## Final structural audit completed

The branch-diff audit confirmed:

- no live `lib/Linux/Event/Net/HTTP` package tree
- no public generic `HTTP::Connection`
- only the server-specific `HTTP::Server::Connection`
- one HTTP-local native extension, `_HTTP1`
- old `xschunked` and `xsresponse1` extension directories removed
- old parser/Response1 private wrapper packages removed
- `on_request_final` present only in explicit rejection tests/errors and
  historical discussion
- superseded unshipped `bench/run-http-hotpath.pl` removed
- superseded unshipped `bench/run-http-response-path.pl` removed
- duplicate `_HTTP1` imports removed from `Response.pm` and the native response
  test
- end-to-end, cross-server, and transaction-ladder benchmark JSON identities
  use `linux-event-http-*`
- transaction-ladder wording uses `_HTTP1` and `Server::Connection`, not the old
  `Response1` or generic Connection names

The transaction-ladder whole-file edit also removed one blank separator and the
final newline at EOF. CI passed with it; this is formatting-only and not an API,
behavior, or integration issue. It may be tidied later if desired without
reopening the structural design.

## Validation completed

Earlier guarded validation during namespace/native consolidation passed:

- `perl Makefile.PL`
- `make`
- full test suite
- end-to-end benchmark smoke
- `make disttest`

The public fast-final removal was separately validated in Actions run
`34159940212` with 15 test files / 292 tests passing plus benchmark smoke and
`make disttest`.

After the final audit cleanup, draft PR #15 ran normal CI at code head
`826bbfcfb45341dba9b087c20a6c1cf82d16ea93`:

- GitHub Actions run: `34162582933`
- overall conclusion: SUCCESS
- Perl latest: SUCCESS, including build/test, end-to-end smoke, and distribution
  integrity
- Perl 5.36: SUCCESS
- Perl latest threaded: SUCCESS
- heavy cross-server diagnostic: skipped by normal-CI policy

This handoff update itself advances the branch after that validated code head;
it contains documentation only.

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

## Current benchmark policy

`bench/run-http-final-response.pl` measures only supported public callback
shapes. The cross-server benchmark has no `fast-final` Linux::Event mode.

Heavy comparison/performance CI remains `workflow_dispatch` only. Ordinary CI
covers supported Perl configurations, HTTP smoke, and distribution integrity.

## Next steps

1. Keep PR #15 draft and unmerged until Joshua explicitly authorizes integration.
2. If desired, remove the tiny transaction-ladder formatting-only artifact
   (blank separator/final newline) without changing semantics.
3. Do not mix native client implementation into this structural PR.
4. After this branch lands, start the native client as a separate feature effort
   under `Linux::Event::HTTP::Client` / `Client::Connection`.
