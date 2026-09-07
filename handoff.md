# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Working branch: `refactor/http-charter-structure`
- Base `main` when this work started: `e38254d6513e2044019f2516ea1a45633932facc`
- Main implementation commit for namespace/native consolidation:
  `d5018cd9979be7be3d6e439509c69563e8d8a180`
- Main implementation commit removing the public fast-final shortcut:
  `a3d91c42808fd9ba99869c6bafa736acaf32fe7e`
- Temporary workflow/helper scaffolding used to validate the refactor has been
  removed from the branch.
- Do **not** merge this branch to `main` without Joshua's explicit authorization.

## Charter being applied

Linux::Event is the Linux-native communications engine. Reusable low-level
performance work belongs in Linux::Event core so multiple protocol layers can
benefit from it.

Linux::Event::HTTP is an HTTP protocol distribution. It prioritizes protocol
correctness, ease of correct use, a simple API, maintainability, and
composability. It should not grow routing, middleware, sessions, templates,
PSGI/PAGI adapters, or other web-framework responsibilities.

Use established CPAN/community libraries for standards and utilities when they
fit the protocol boundary. Do not force a dependency or object model into the
hot wire path merely because a prominent module exists.

Do not add HTTP-specific XS merely to improve a benchmark. First identify
whether the expensive primitive is generic transport/buffer/write machinery
that belongs in Linux::Event.

## Public structure after this refactor

The current server-side public modules are:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
```

The old `Linux::Event::Net::HTTP` namespace has been flattened. The old generic
`HTTP::Connection` name was also removed because the implemented connection is
specifically the server-direction protocol connection.

Future client structure is intentionally reserved as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is **not implemented on this branch**.

## Client decision

A native HTTP client belongs in Linux::Event::HTTP because initiating and
speaking HTTP is protocol functionality of the communications engine ecosystem.

Do not base the Linux::Event client on HTTP::Tiny or LWP. Their public request
lifecycles are fundamentally blocking/synchronous and are not a clean transport
seam for Linux::Event's event-driven connection lifecycle.

If someone wants LWP, HTTP::Tiny, framework, or other compatibility adapters,
those belong in separate adapter distributions. The future native client should
use `Linux::Event::HTTP::Client` / `Client::Connection` and share private HTTP
wire machinery only where the semantics are genuinely common with the server.

## Request/Response CPAN audit conclusion

Prominent CPAN message/header modules were evaluated before this refactor,
including `HTTP::Request`, `HTTP::Response`, `HTTP::Headers`,
`HTTP::Headers::Fast`, and `HTTP::XSHeaders`.

Keep Linux::Event::HTTP's own Request and Response because they represent live
protocol roles rather than complete buffered HTTP messages:

- Request is a validated native incoming request-head view. Method, target, and
  headers are materialized lazily; request bodies remain streaming connection
  input rather than Request-owned content.
- Response is a live writable server transaction with `write`, `end`,
  backpressure, framing, persistence, and Upgrade behavior.

Do not replace native request header storage with HTTP::Headers-family objects.
Those APIs normalize header names in ways that can conflate legal wire names
such as `X_Foo` and `X-Foo`, while this parser intentionally preserves them as
distinct fields.

Also do not grow Request/Response into another generic HTTP utility ecosystem.
URI conveniences, cookies, dates, authentication helpers, MIME interpretation,
and similar application-level semantics should use appropriate external
libraries when needed rather than being reinvented here.

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

The single private `_HTTP1` shared object owns the current:

- HTTP/1 request-head parser and lazy Request XSUBs
- chunked request decoder (`_HTTP1::Chunked` logical package)
- response-head serializer
- narrow default scalar response builder

picohttpparser is compiled once. The old `Response1.xs` duplicated the native
`le_http_request_state` structure layout from the parser extension; that
maintenance risk is gone.

The native consolidation is about reducing protocol-local native maintenance,
not moving HTTP semantics into Linux::Event core.

## Server request API after this refactor

There is one canonical request API:

```perl
on_request => sub ($conn, $req, $res) {
    $res->end("hello\n");
}
```

Optional body lifecycle callbacks remain:

```perl
on_body
on_request_end
```

The former public `on_request_final` callback has been removed. Passing that
option to `Server` or direct `Server::Connection` construction now fails with a
clear migration error directing the caller to `on_request` + `Response->end`.

## Final-response experiment: keep the lesson, not the API

The historical `on_request_final` experiment was valuable and should not be
forgotten:

- focused real-Connection runs were roughly +24% to +34% over the then-optimized
  ordinary `on_request -> Response->end` path
- one shared-harness run showed about +21%
- the narrow native default-final response builder itself saved only about 48 ns
  for a 32-byte response body in its focused A/B

The important conclusion is that eager general Response/transaction machinery
can be expensive for a trivial complete response. The conclusion is **not** that
applications should choose a separate benchmark-oriented callback API.

The public shortcut has therefore been removed, while the ordinary
`Response->end(...)` path retains the private `_try_native_default_final` /
`_HTTP1->build_default_final` optimization when a response is eligible.

HEAD, HTTP/1.0, custom status/headers, streaming, deferred responses, request
bodies, and other non-eligible cases continue through the ordinary Response
state machine.

## Server and transport boundary

`Linux::Event::HTTP::Server` remains a thin control-plane convenience around
`Linux::Event::IO::Sock::Listener`.

```text
HTTP::Server
    -> Linux::Event::IO::Sock::Listener
        -> HTTP::Server::Connection
            -> Request + Response
```

Server retains callback CVs once and reuses them for accepted connections. The
private `_ServerConnection` adapter still exists solely to bridge Listener
accepted-stream construction into the selected HTTP connection class and its
HTTP-specific constructor callbacks.

Do not enlarge Linux::Event's Listener API merely to eliminate this small
private adapter. If future protocol distributions independently need the same
accepted-stream constructor capability, reconsider it then as reusable core
functionality.

TLS remains Linux::Event transport policy on the Server::Connection subclass.
There is no separate HTTPS connection hierarchy.

## Upgrade boundary

Keep the existing Upgrade design:

1. HTTP validates HTTP/1.1 Upgrade semantics and the selected protocol.
2. HTTP queues the valid 101 response.
3. HTTP clears its completed transaction state.
4. Linux::Event `transition_to()` hands the same live transport object to the
   target protocol class.

Socket, TLS state, output queue, backpressure, deadlines, watcher state,
application data, and bytes already read beyond the HTTP head are preserved.

WebSocket semantics belong in a separate `Linux::Event::WebSocket`
distribution. HTTP owns only the HTTP Upgrade transaction and handoff.

## Validation completed

### Namespace/native consolidation

A temporary GitHub Actions working checkout applied the refactor with ordinary
`git mv`, built the distribution, and committed only after all validation
passed.

Validated:

- `perl Makefile.PL`
- `make`
- full test suite: 15 files / 304 tests, PASS
- end-to-end benchmark smoke, PASS
- `make disttest`, PASS

### Public final-response API removal

A second guarded run removed the shortcut and validated the supported API.
GitHub Actions run: `34159940212`.

Validated:

- full test suite: 15 files / 292 tests, PASS
- end-to-end benchmark smoke, PASS
- focused response-finalization benchmark smoke, PASS
- `make disttest`, PASS

The focused smoke in that shared runner happened to report:

```text
on_request -> Response->end          18091.1 req/s
on_request_end -> Response->end      15715.4 req/s
```

That is only a smoke/directional result and is **not** a performance claim.

## Closed performance experiments

Do not reopen these without a new measured hypothesis:

- Duplicated bodyless Perl driver: only a small gain; rejected.
- HTTP input-buffer COW/adopt/clear: about +2% in one shape but regressions for
  split/coalesced reads; rejected.
- libh2o as the HTTP/1 engine: keep as a benchmark/reference competitor, not an
  integration direction.
- Splitting ordinary HTTP head/body writes: likely exchanges memcpy for another
  syscall. Reconsider only if Linux::Event gains a measured generic segmented or
  gathered submit primitive.
- Broad native HTTP connection driver: not justified by measurements.

## Current benchmark policy

`bench/run-http-final-response.pl` now measures only supported public callback
shapes. The cross-server benchmark no longer has a `fast-final` Linux::Event
mode.

Heavy comparison/performance CI remains `workflow_dispatch` only. Ordinary CI
covers supported Perl configurations, HTTP smoke, and distribution integrity.

## Next steps

1. Audit the final branch diff for stale old namespace, old public Connection,
   `Net::WebSocket`, or obsolete fast-final implementation references.
2. Treat historical mentions in this handoff as history, not live API.
3. Run/inspect normal CI after the branch is proposed for integration.
4. Do not merge without explicit authorization.
5. After this structural branch lands, client implementation can be a separate
   feature effort. Do not mix that new feature into this refactor.
