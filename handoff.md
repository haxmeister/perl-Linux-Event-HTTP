# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical release branch: `main`
- Active branch: `feature/client-streaming-request-body`
- Draft PR: #20, `Add streaming client Request bodies`
- Do not merge PR #20 without explicit user authorization.
- PR #19, `Add bounded buffered client responses`, was merged to `main` as
  `77da070a038f547d09cfe99efce55b1149bad4da`.
- Linux::Event minimum prerequisite is `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Request, Response, and Transaction identity are settled. Do not move URL, pool,
socket, or endpoint-role lifecycle into Request/Response for convenience.

## Settled client baseline

`Linux::Event::HTTP::Client` owns URL/origin/TLS/pool policy and returns one
Transaction per HTTP exchange. `Linux::Event::HTTP::Client::Connection` is one
HTTP/1 Linux::Event stream socket and executes one Transaction at a time. Client
pipelining is disabled. At most one idle connection is retained per origin.

Incoming Response bodies remain incremental-first:

```perl
$client->get(
    $url,
    on_response => sub ($tx, $res) { ... },
    on_body     => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error    => sub ($tx, $error) { ... },
);
```

Absent `on_body`, bytes are drained/discarded. Explicit bounded buffering is
mainline from PR #19:

```perl
$client->get(
    $url,
    buffer_body => 1_048_576,
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
);
```

`buffer_body` is bounded, mutually exclusive with `on_body`, counts body bytes
after HTTP/1 transfer framing is removed, and closes the HTTP/1 connection on
limit failure. There is no implicit unbounded response buffer.

## PR #20 - streaming outgoing Request bodies

Public high-level form:

```perl
my $tx = $client->post(
    $url,
    stream_body => {
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    },
    on_response => sub ($tx, $res) { ... },
    on_complete => sub ($tx) { ... },
    on_error    => sub ($tx, $error) { ... },
);

my $body = $tx->request_body;
$body->write($bytes);
$body->complete;
```

Settled semantics on the branch:

1. Request remains the HTTP message; Transaction owns the writable producer.
2. `body` and `stream_body` are mutually exclusive.
3. `$tx->request_body` returns the stable `Body::Stream` producer while the
   exchange is active.
4. Request `is_complete` is false while production is unfinished and becomes
   true only after successful producer completion.
5. A supplied Content-Length is enforced exactly. Too many bytes or a final
   byte count that does not match are rejected without falsely completing the
   Request.
6. With no Content-Length, HTTP/1.1 automatically uses
   `Transfer-Encoding: chunked`.
7. HTTP/1.0 streaming requires Content-Length. Request bodies are never
   close-delimited.
8. `Body::Stream->write` writes directly through Linux::Event's normal ordered
   output queue. Its boolean return is the Linux::Event backpressure result.
9. False means bytes were accepted; producer pauses until `on_drain`.
10. Initial request-head output can itself put the producer into blocked state;
    the later Linux::Event low-watermark transition resumes it.
11. Client::Connection transport drain bookkeeping composes with a subclass or
    constructor `on_drain` rather than replacing it.
12. If a final Response arrives before the Request producer completes, the
    producer is cancelled and the HTTP/1 connection is made non-reusable. The
    Request remains incomplete while the Response/Transaction may complete.
13. Transaction cancellation/error also cancels an unfinished Request producer.
14. No second HTTP output queue and no new XS/C were added.

`Body::Stream` is now generic to outgoing Request or Response production.
Server-side Response production remains unchanged:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
```

## Important implementation details

- `Request` now privately tracks scalar vs incremental outgoing body mode and
  message completion state.
- `Transaction` owns `request_body` in addition to existing `response_body`.
- `Client::Connection` owns HTTP/1 Request framing:
  - exact Content-Length stream;
  - automatic chunked stream for unknown HTTP/1.1 length;
  - rejection of unknown-length HTTP/1.0 stream;
  - only plain `chunked` Transfer-Encoding is currently supported.
- Transport `on_drain` is internally intercepted only to wake a blocked Request
  producer, then composed with user/subclass drain behavior.
- High-level Client validates `stream_body` producer callbacks before Request
  creation.
- `Expect: 100-continue` is not automatic policy. Applications may set the
  header and choose to wait for `on_informational` before producing bytes.

## Validation

Initial PR #20 CI #329 exposed a test-only error: the early-response test called
`$tx->request_body` after the Transaction was terminal. The test was corrected
to retain the producer handle before completion.

CI #330 / run `34731728358` then passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- full test suite including streaming uploads;
- end-to-end server smoke;
- disttest / distribution integrity.

Focused streaming upload test:

```text
t/65-client-request-stream.t
```

Coverage includes scalar/stream conflict, HTTP/1.0 unknown-length rejection,
Content-Length underflow/overflow, known-length streaming, automatic chunked
streaming, Request completion state, actual high/low-watermark producer drain,
subclass `on_drain` composition, early final Response cancellation, and server
receipt of decoded body bytes.

A final full CI run must pass on the final documentation branch head before PR
#20 is considered review-ready.

## Server baseline

Server APIs are unchanged:

```perl
$res->body($bytes);

my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
$body->write($bytes);
$body->complete;
```

Deferred scalar Response uses `$tx->send_response`; server Upgrade remains
Transaction lifecycle.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path. Streaming Request output adds no
new native extension or transport queue.

The client response-head parser remains strict Perl. Benchmark before considering
client parser XS.

## Next work after PR #20

Keep PR #20 focused on streaming outgoing Request bodies. The next clean client
layer is redirects, modeled as a chain of distinct Transactions rather than one
Transaction silently replacing its Request/Response.

Richer pool policy, proxy/auth/cookies, CONNECT/client Upgrade, and parser
optimization remain later work.

## Parked core question

Do not reopen the Linux::Event paused-read / EPOLLRDHUP question absent a
concrete demonstrated protocol requirement. Do not add polling, duplicate
transport buffers, or a second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The available GitHub connector does not expose
branch deletion and GitHub has not auto-deleted merged feature refs. Merged
`feature/message-objects`, `feature/http-client-foundation`, and
`feature/client-buffered-response` may still need GitHub's normal manual
`Delete branch` action. Do not reuse them for new work.
