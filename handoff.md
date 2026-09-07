# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Working branch: `main`
- The public Response completion API is now `Response->complete(...)`.
- Public completion introspection is `Response->is_complete`.
- `Response->end` and `Response->is_ended` are deliberately absent; there are no compatibility aliases because this distribution is still unreleased.
- Transport-level `Server::Connection->end(...)` remains a Linux::Event Stream operation and was not renamed. The naming change is specifically intended to keep HTTP transaction completion distinct from transport shutdown.
- The API/README cleanup was committed directly to `main` as `971c9f167dc8e11ed9c2d6976ea1d11377734bfe`, followed immediately by `ffa0dfcbdc7f779dc4fc6b671ebf4e4f5f7b4d19` correcting the placement of the prepared `Response.pm` and `Server::Connection.pm` blobs. Treat `ffa0df...` as the code-bearing cleanup state before this handoff update.
- CI run `34165954005` was started for `ffa0df...`; check its final result before treating validation as complete.

The README was substantially simplified. It now teaches the normal callback API first, explains `$conn`, `$req`, and `$res` immediately, and makes the key semantic distinction explicit: `$res->complete(...)` completes one HTTP response and normally does not close a persistent HTTP/1.1 connection. Request-body streaming, Connection subclassing, TLS, Upgrade, and native implementation details are progressively later/advanced material rather than front-loaded architecture.

## Charter

Linux::Event is the Linux-native communications engine. Reusable low-level performance work belongs in Linux::Event core so multiple protocol layers can benefit from it.

Linux::Event::HTTP is an HTTP protocol distribution. Prioritize protocol correctness, ease of correct use, a simple API, maintainability, and composability over winning isolated HTTP microbenchmarks.

Do not add routing, middleware, sessions, templates, PSGI/PAGI, or other web-framework responsibilities here. There is no planned PSGI layer inside this distribution.

Use established CPAN/community libraries for standards and utilities when they fit the protocol boundary. Do not force a dependency or object model into the hot wire path merely because a prominent module exists.

Do not add HTTP-specific XS merely to improve a benchmark. First determine whether the expensive primitive is generic transport, buffer, or write machinery that belongs in Linux::Event core.

## Public structure

Current server-side public modules:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
```

The old `Linux::Event::Net::HTTP` namespace is gone. There is no public generic `Linux::Event::HTTP::Connection`; the implemented connection is specifically the server-direction protocol connection.

Future native client structure is reserved as:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet. Do not force client lifecycle behavior into `Server::Connection` merely for naming symmetry.

## Canonical server API

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,
    on_request => sub ($conn, $req, $res) {
        $res->header('Content-Type', 'text/plain');
        $res->complete("hello\n");
    },
);
```

The callback roles are:

```text
$conn  persistent HTTP connection / Linux::Event transport object
$req   current HTTP request
$res   response for that request
```

`$res->complete(...)` means no more bytes belong to that HTTP response. It does not mean close the socket. Persistence is decided by HTTP semantics and transport state.

Streaming output is:

```perl
$res->write("one\n");
$res->write("two\n");
$res->complete;
```

Optional request-body lifecycle callbacks remain:

```text
on_body
on_request_end
```

The former public `on_request_final` callback remains removed. Passing it to `Server` or direct `Server::Connection` construction fails with migration guidance to use `on_request` plus `Response->complete`.

For bodyless requests without an `on_request_end` handler, the connection marks request input complete before `on_request`, so the ordinary `on_request -> Response->complete` path remains eligible for the narrow private native default-final optimization. If `on_request_end` is configured, that lifecycle boundary is preserved instead of bypassed for benchmark speed.

## Response API naming decision

Use these public Response methods:

```text
status
reason
header
add_header
header_values
write
complete
upgrade
connection
request
is_started
is_complete
is_upgrading
```

Do not restore `Response->end` or `Response->is_ended` as aliases. The old wording was ambiguous because `Server::Connection` inherits transport-level `end` from Linux::Event Stream, where it actually concerns transport shutdown/half-close. `complete` is intentionally transaction-scoped vocabulary.

Internal state may still use names such as `ended` or native `default_final`; those are implementation details and are not public API vocabulary.

## Request/Response CPAN audit conclusion

Prominent CPAN message/header modules were evaluated, including `HTTP::Request`, `HTTP::Response`, `HTTP::Headers`, `HTTP::Headers::Fast`, and `HTTP::XSHeaders`.

Keep Linux::Event::HTTP's own Request and Response because they are live protocol roles rather than complete buffered messages:

- Request is a validated native incoming request-head view. Method, target, and headers are materialized lazily. Request bodies remain streamed connection input rather than Request-owned content.
- Response is a live writable server transaction with `write`, `complete`, backpressure, framing, persistence, and Upgrade behavior.

Do not replace native request header storage with HTTP::Headers-family objects. Those APIs normalize header names in ways that can conflate legal wire names such as `X_Foo` and `X-Foo`, while this parser intentionally preserves them as distinct fields.

Do not grow Request/Response into another generic HTTP utility ecosystem. URI, cookie, date, authentication, MIME, and similar application-level conveniences should use appropriate external libraries where suitable.

## Consolidated native HTTP/1 boundary

The distribution builds one private HTTP-local native extension:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

The single private `_HTTP1` shared object owns:

- HTTP/1 request-head parser and lazy Request XSUBs
- chunked request decoder (`_HTTP1::Chunked` logical package)
- response-head serializer
- narrow default scalar response builder

picohttpparser is compiled once. The old separate `xschunked` and `xsresponse1` extensions are gone, eliminating duplicated native request-state structure layouts.

The private `_try_native_default_final` / `_HTTP1->build_default_final` optimization remains behind ordinary `Response->complete(...)`. Applications do not select a benchmark-specific fast callback or alternate response API.

## Server and transport boundary

`Linux::Event::HTTP::Server` remains a thin control-plane convenience around `Linux::Event::IO::Sock::Listener`:

```text
HTTP::Server
    -> Linux::Event::IO::Sock::Listener
        -> HTTP::Server::Connection
            -> Request + Response
```

Server retains callback CVs once and reuses them for accepted connections. The private `_ServerConnection` adapter exists only to bridge Listener accepted-stream construction into the configured HTTP connection class and HTTP-specific constructor callbacks.

Do not enlarge Linux::Event Listener merely to eliminate this small private adapter. Reconsider only if multiple protocol distributions independently need the same reusable accepted-stream constructor capability.

TLS remains Linux::Event transport policy on the Server::Connection subclass. There is no separate HTTPS connection hierarchy.

## Upgrade boundary

Keep the existing Upgrade design:

1. HTTP validates HTTP/1.1 Upgrade semantics and the selected protocol.
2. HTTP queues the valid 101 response.
3. HTTP clears completed transaction state.
4. Linux::Event `transition_to()` hands the same live transport object to the target protocol class.

Socket, TLS state, output queue, backpressure, deadlines, watcher state, application data, and bytes already read beyond the HTTP head are preserved.

WebSocket semantics belong in a separate `Linux::Event::WebSocket` distribution. HTTP owns only the HTTP Upgrade transaction and handoff.

## Client direction

A native HTTP client belongs in Linux::Event::HTTP because initiating and speaking HTTP is protocol functionality in this communications ecosystem.

Do not base it on HTTP::Tiny or LWP; their public request lifecycles are blocking/synchronous and are not a clean transport seam for Linux::Event's event-driven connection lifecycle.

Compatibility adapters for LWP, HTTP::Tiny, frameworks, or other ecosystems belong in separate adapter distributions. The native client should use `Linux::Event::HTTP::Client` / `Client::Connection` and share private HTTP wire machinery only where semantics are genuinely common with the server.

## Validation expectations for the completion rename

The cleanup updates the implementation, POD/docs, normal server/TLS/Upgrade examples, request-body tests, response-streaming tests, final-response tests, end-to-end benchmark adapter, focused response-finalization benchmark, and transaction-ladder benchmark terminology.

`t/00-load.t` explicitly asserts:

```text
Response can complete
Response can is_complete
Response cannot end
Response cannot is_ended
```

This is deliberate: do not add compatibility aliases later without an explicit new decision.

After the code commit, verify at minimum:

- normal CI Perl matrix
- threaded Perl CI
- HTTP benchmark smoke
- distribution integrity
- no stale public `Response->end` / `is_ended` examples remain

Heavy cross-server performance diagnostics remain manual/workflow-dispatch work and are not ordinary CI performance claims.

## Closed performance experiments

Do not reopen these without a new measured hypothesis:

- duplicated bodyless Perl driver: only a small gain; rejected
- HTTP input-buffer COW/adopt/clear: small gain in one shape but regressions for split/coalesced reads; rejected
- libh2o as the HTTP/1 engine: benchmark/reference competitor only
- splitting ordinary HTTP head/body writes: likely trades memcpy for another syscall; revisit only with a measured generic Linux::Event segmented/gathered submit primitive
- broad native HTTP connection driver: not justified by measurements

## Branch policy

Do not keep merged or abandoned working branches merely as history; Git already preserves the commits. Delete them unless they contain unique work that has a specific reason to remain accessible.

`experiment/fused-request-index` remains the notable exception because it contains unique request-index fusion benchmark/research work. Re-evaluate and delete it once the experiment is incorporated, documented elsewhere, or formally closed.

## Next substantive steps

1. Finish validation of the `Response->complete` / README cleanup and record the final CI run/result here.
2. Native HTTP client work can then begin as a separate feature under `Linux::Event::HTTP::Client` / `Client::Connection` if desired.
3. Keep HTTP protocol work within the charter: correctness and simple protocol APIs first; move reusable low-level performance primitives into Linux::Event core when appropriate.
4. Do not add PSGI/PAGI/framework responsibilities to this distribution.
5. Keep `handoff.md` current after each major test or architectural conclusion.
