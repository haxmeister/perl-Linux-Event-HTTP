# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical working branch: `main`
- Current `main` includes the Linux::Event Listener-recipe, runtime-tuning, and
  runtime-TLS compatibility migration described below.
- PR #16 (`Finalize Response body and streaming API`) was the preceding major
  server API baseline.
- Historical CI run `34181760630` on that baseline succeeded across Perl 5.36,
  latest Perl, latest threaded Perl, end-to-end benchmark smoke, and
  distribution integrity.
- There is no release planned yet. Continue architecture/design work.

The server-side Response body redesign is now on `main` and should be treated as the current baseline.

## Linux::Event main compatibility

HTTP has been migrated to the Listener, tuning, and accepted-TLS APIs now on
Linux::Event `main`:

- `HTTP::Server` resolves one `stream => {...}` Listener recipe.
- Listener constructs the configured HTTP `connection_class` directly.
- The private `Linux::Event::HTTP::_ServerConnection` acceptance adapter has
  been removed.
- `HTTP::Server->new(tuning => {...})` supplies deployment tuning that overrides
  Connection `stream_tuning()` defaults.
- `HTTP::Server->new(tls => {...})` activates accepted TLS. Connection
  `tls_defaults()` may provide reusable ALPN and timeout defaults without
  forcing every listener using that class to be TLS.
- Accepted-Connection lifecycle callbacks are stored in the Stream recipe.
  `on_error` retains its accepted-Connection meaning;
  `on_listener_error` handles Listener and acceptance errors distinctly.
- Direct Listener tests and benchmark adapters use the new Stream recipe, and
  all `stream_options()` methods have been renamed to `stream_tuning()`.

Validation against Linux::Event main commit `321d4c2`:

- full suite: 17 files, 354 tests, all successful;
- `bench/run-http-end-to-end.pl --smoke`: successful;
- `bench/run-http-transaction-ladder.pl --smoke`: successful.

The current Linux::Event source still reports version `0.112`, although these
API changes are newer than the published 0.112 baseline. Therefore
`Makefile.PL` still says `Linux::Event => 0.112`; update that prerequisite as
soon as the next Linux::Event release version is assigned. Until then, test
HTTP against Linux::Event `main`. CI temporarily installs exact core commit
`321d4c2` before resolving HTTP dependencies so CPAN 0.112 cannot mask this
compatibility boundary.

## Current Response/body API

Conceptual split:

```text
Response     = HTTP response message
Body::Stream = streaming body producer
```

Ordinary scalar response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->body("hello\n");
};
```

Streaming response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->header('Content-Type', 'text/plain');

    my $body = $res->stream_body(
        on_drain => sub ($body) {
            # Resume upstream production.
        },
        on_cancel => sub ($body) {
            # Stop upstream work because this HTTP connection
            # abandoned the unfinished body.
        },
    );

    $body->write("one\n");
    $body->complete("two\n");
};
```

Public Response surface includes:

```text
status
reason
header
add_header
header_values
body
stream_body
upgrade
connection
request
is_started
is_complete
is_upgrading
```

Body::Stream surface:

```text
write
complete
is_complete
is_cancelled
```

Do not restore Response-level `write`, `complete`, `end`, or `is_ended` compatibility aliases. The distribution is unreleased and we deliberately removed those ambiguous/transitional APIs.

## Response commit semantics

`$res->body($bytes)` declares a complete scalar body.

When called inside an HTTP callback, `body(...)` does not serialize immediately in the middle of the callback. Response metadata remains mutable until the callback returns. This is intentionally valid:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

At callback return, the connection commits the complete response when transaction state permits.

When `body(...)` is called later from an asynchronous event callback while a Response is waiting and no HTTP callback dispatch is active, it commits the waiting response immediately.

`stream_body()` lazily creates one stable Body::Stream object. Selecting the stream does not itself start output or freeze metadata. The first Body::Stream `write(...)` or `complete(...)` is the streaming commit point.

Scalar `body(...)` and streaming `stream_body(...)` are mutually exclusive.

## Backpressure and transport ownership

Do not add another HTTP response-body output queue.

Body::Stream is a protocol-facing producer over Linux::Event's existing ordered-byte output machinery. Linux::Event remains the owner of queued transport bytes, segmented output, watermarks, `pending_bytes`, write readiness, drain signaling, pending-byte limits, and TLS transport progression.

`Body::Stream->write(...)` preserves Linux::Event flow control:

```text
true  = bytes accepted; producer may continue
false = bytes accepted; producer should stop until on_drain
```

HTTP framing is applied before bytes enter that transport machinery.

HTTP lifecycle bookkeeping composes with custom Connection lifecycle callbacks:

```text
transport drain
    -> HTTP Body::Stream drain handling
    -> custom Connection on_drain

transport close
    -> HTTP Body::Stream cancellation
    -> custom Connection on_close
```

## Tests and documentation

Important body API tests:

```text
t/21-response-body-stream-unit.t
t/34-response-body-stream.t
```

Coverage includes scalar body behavior, scalar/stream exclusion, stable stream identity, backpressure propagation, drain callbacks, completion, cancellation, asynchronous scalar completion, callback-return commit semantics, stream selection without commit, first-write commit, metadata locking, HTTP/1.1 chunk framing, persistent/pipelined ordering, and lifecycle callback composition.

README, Response POD, Server POD, `docs/ARCHITECTURE.md`, `docs/BENCHMARKING.md`, Changes, tests, and Linux::Event benchmark adapters were migrated to this body/stream model.

The transaction benchmark still has a historical stage identifier named `complete`; that is not a public Response method. Its callback uses `Response->body(...)`. Benchmark contract version is 6.

## Linux::Event paused-read / terminal-readiness finding

While testing body cancellation, we noticed a generic Linux::Event behavior:

- HTTP pauses application reads while a completed request waits for a later asynchronous response so a pipelined request cannot overtake the active response.
- Linux::Event still receives terminal readiness (`EPOLLERR`, `EPOLLHUP`, `EPOLLRDHUP`).
- `_ByteStream::_on_read_terminal_ready` only enters the read path when `read_paused` is false, so input-side EOF/half-close observation may be delayed while application reads are paused.

Current conclusion:

1. This is not established as a Linux::Event correctness bug.
2. `pause_read()` deliberately pauses application input consumption/delivery.
3. Forcing `_read_ready` while paused could consume or expose unread application payload and violate pause semantics.
4. TCP FIN / `EPOLLRDHUP` means the peer has finished sending to us; it does not mean the peer has stopped reading our response.
5. Therefore peer read-side EOF is not valid evidence by itself that an outgoing HTTP Body::Stream should be cancelled.
6. TLS already separates transport progress from paused application input, so any future generic terminal-observation capability must preserve that distinction.

Decision: do not change Linux::Event core merely to make HTTP observe peer FIN sooner, and do not add an HTTP workaround, polling layer, duplicate buffering, or second response queue.

This question is intentionally parked. Reopen it only if a concrete protocol requirement, failing test, or real-world behavior demonstrates a need to observe peer/transport terminal state independently of application read pause. A future generic design would need explicit semantics for unread buffered data, half-close, full close, and TLS.

For the current HTTP API, `on_cancel` remains deterministic when the HTTP connection itself closes or abandons an unfinished streaming body.

## Project charter

Linux::Event is the Linux-native communications engine. Reusable low-level performance work belongs in Linux::Event core when it benefits multiple protocol layers.

Linux::Event::HTTP is the HTTP protocol layer. Priorities are:

1. correctness
2. ease of correct use
3. coherent/simple API
4. maintainability
5. composability
6. performance without unnecessary HTTP-specific native complexity

Do not add PSGI, PAGI, routing/framework responsibilities, middleware, sessions, or templates to this distribution.

Prefer established CPAN/community libraries for standards/utilities where appropriate. Do not add HTTP-specific XS merely to win benchmarks.

Keep the single private native HTTP extension unless a measured reason requires otherwise:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns pico request parsing/lazy Request accessors, chunked request decoding, response-head serialization, and the narrow default scalar final-response builder.

HTTP Upgrade remains a boundary operation: validate Upgrade, queue 101, clear the HTTP transaction, then use Linux::Event `transition_to()` on the same live transport. WebSocket belongs in a separate distribution.

## Immediate next steps

1. When Linux::Event assigns/releases the version after 0.112, update the
   `Makefile.PL` minimum prerequisite to that version.
2. Move on to HTTP CLIENT ARCHITECTURE rather than trying to force a solution to the parked paused-read/terminal-readiness question.
3. Evaluate the public client object model and responsibilities before implementing substantial code.
4. Compare the proposed client API with prominent CPAN HTTP request/response/client conventions and reuse familiar semantics where they fit the project charter.
5. Explicitly design connection lifecycle, request/response ownership, persistent connections, connection reuse, streaming request bodies, streaming response bodies, backpressure, cancellation, redirects, timeouts, TLS, and HTTP/1.1 ordering.
6. Keep transport queues/backpressure owned by Linux::Event; do not invent a second HTTP transport queue.
7. Preserve symmetry with the now-stable server Response/body concepts where it genuinely improves the API, but do not force false symmetry between client and server roles.
8. Keep this handoff current immediately after major architectural conclusions, experiments, or tests.

## Branch policy

`main` is the canonical branch for the current work. Do not keep merged or abandoned feature branches merely as history. Delete them after merge/abandon unless they contain unique work with a concrete reason to preserve them.

The old `feature/response-body-stream` branch contains no work that is not now on `main` and is safe to delete.
