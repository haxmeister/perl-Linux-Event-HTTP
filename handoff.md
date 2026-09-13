# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical release branch: `main`
- Active branch: `feature/client-buffered-response`
- Draft PR: #19, `Add bounded buffered client responses`
- Do not merge PR #19 without explicit user authorization.
- PR #18, `Add HTTP client connection foundation`, was merged to `main` as
  `13a20e9633ca75a5ac5c5bedb951e129f9d67c7c`.
- Main handoff refresh after that merge is
  `326f44914c7240edc85f39b15de779a6ddd09e20`.
- Linux::Event minimum prerequisite is `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Request/Response/Transaction identity and the HTTP client foundation are settled.
Do not move URL, pool, socket, or endpoint-role lifecycle into Request/Response.

## Settled client foundation

`Linux::Event::HTTP::Client::Connection` is one HTTP/1 Linux::Event Stream and
executes one Transaction at a time. Client pipelining is disabled. It supports
scalar outgoing Request bodies plus Content-Length, chunked, bodyless, and
close-delimited incoming Response framing. Informational 1xx is supported except
client 101 handoff. Cancellation closes the connection.

`Linux::Event::HTTP::Client` owns absolute http/https URL parsing, Host synthesis,
TLS transport creation, connection selection/reuse, and convenience verbs:

```text
request
get
head
post
put
delete
```

All return Transaction. Client keeps at most one idle connection per origin,
allows extra same-origin connections for concurrency, and does not pipeline.
HTTPS uses the same Client::Connection class with Linux::Event TLS and
`http/1.1` ALPN.

The client response-head parser remains strict Perl. Do not add client parser XS
without measurement.

## Bounded buffered Response convenience - implemented

PR #19 adds explicit whole-response buffering on the same incremental body path:

```perl
$client->get(
    $url,
    buffer_body => 1_048_576,
    on_response => sub ($tx, $res) {
        # final head is available; body may still be incomplete
    },
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
    on_error => sub ($tx, $error) { ... },
);
```

Settled semantics:

1. `buffer_body => $max_bytes` is opt-in; there is no implicit/unbounded buffer.
2. The limit must be a positive integer byte count.
3. `buffer_body` and user `on_body` are mutually exclusive.
4. The limit counts exactly the bytes `on_body` would receive after HTTP/1
   transfer framing has been removed. Content-Encoding is not decoded here.
5. `on_response` still runs immediately after the final head is validated.
6. A validated Content-Length above the limit fails after `on_response` and
   before body accumulation.
7. Chunked, close-delimited, or otherwise unknown-size bodies fail when adding
   delivered bytes would cross the bound.
8. Buffer-limit failure is a Transaction error and closes the HTTP/1 connection.
9. On successful completion, `$tx->response->body` returns the complete scalar.
10. A bodyless buffered Response returns the empty string.
11. Received Response metadata remains committed/read-only.
12. Buffered bytes are attached through private `Response->_set_received_body`,
    not through the public mutable-body setter.

The optional buffer is retained application/message data, not a second transport
queue. Linux::Event still owns transport buffering/backpressure.

## Implementation commits

- `f77f78ae2583a350ab0f323b89533728eeffd101`
  - private received-body attachment on Response.
- `0157fe830240c8469ed2d2bb19e124c7f88661bf`
  - bounded buffering in Client::Connection framing paths.
- `398752e0d55012c8afddf3b3adb46004321ab9fc`
  - high-level Client `buffer_body` option.
- `9b4c15f340023a400c1bdbe398aeb1b4f2951106`
  - focused buffering tests.
- `2344389bf13912d78f547c8008afccec4e7d24fe`
  - add buffering test to MANIFEST; implementation checkpoint.
- Later documentation commits align README, Changes, architecture, and handoff.

## Validation

PR #19 implementation checkpoint CI #323 / run `34730190464` passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- full test suite including bounded buffering;
- end-to-end server smoke;
- disttest / distribution integrity.

Focused buffering test:

```text
t/64-client-buffered-response.t
```

It covers fixed-length buffering, chunked decoding before buffering,
close-delimited HTTP/1.0 completion, bodyless HEAD, known-size overflow,
dynamic chunked overflow, metadata immutability, and buffer/on_body option
conflict.

A final full CI run must pass on the final documentation branch head before PR
#19 is considered review-ready.

Previous client checkpoints:

- PR #18 CI #307: low-level client foundation passed.
- PR #18 CI #309: raw framing/cancellation coverage passed.
- PR #18 CI #315: high-level Client + HTTPS passed.
- PR #18 CI #320: final client-foundation branch head passed.

## Server baseline remains unchanged

Ordinary scalar Response:

```perl
$res->body($bytes);
```

Incremental outgoing Response:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
$body->write($bytes);
$body->complete;
```

Deferred scalar Response:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Server Upgrade remains Transaction lifecycle.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path. Bounded client buffering requires
no new XS/C.

## Next work after PR #19

The next sensible client layer is **streaming outgoing Request bodies with
Linux::Event backpressure**. Preserve the same responsibility split:

- Request remains the message;
- Transaction owns one exchange and outgoing body-production lifecycle;
- Client::Connection performs HTTP/1 framing;
- Linux::Event owns the actual ordered output queue and backpressure.

Do not start redirects, a large pool redesign, proxy/auth/cookies, or client
Upgrade in the same PR as request streaming. Redirects should later be chains of
distinct Transactions.

## Parked core question

Do not reopen the Linux::Event paused-read / EPOLLRDHUP question absent a
concrete demonstrated protocol requirement. Do not add polling, duplicate
transport buffers, or a second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The available GitHub connector does not expose
branch deletion, and GitHub did not auto-delete merged
`feature/http-client-foundation`. The older merged `feature/message-objects` may
also still exist. Delete those through GitHub's normal branch-delete control when
available; do not reuse them for new work.
