# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Active branch: `feature/client-redirects`
- Draft PR: #21, `Add high-level client redirect handling`
- Do not merge PR #21 without explicit user authorization.
- PR #20, `Add streaming client Request bodies`, was merged to `main` as
  `8642f43c4742b8daa37d87a274096c15f1508bb9`.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

The core object identities are settled:

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response HTTP exchange

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, pool, socket, or endpoint-role lifecycle into
Request/Response. Do not redefine Transaction to span redirects.

## Merged client baseline

The merged Client supports:

- absolute `http` / `https` URL parsing through URI;
- Host synthesis and HTTP/HTTPS destination acquisition;
- one active Transaction per HTTP/1 client connection;
- bounded same-origin idle connection reuse with no HTTP/1 pipelining;
- scalar Request bodies with Content-Length;
- Transaction-owned streaming Request bodies with exact known length or
  automatic HTTP/1.1 chunked framing;
- Linux::Event backpressure and `on_drain` without a second HTTP queue;
- strict client Response-head parsing in Perl;
- Content-Length, chunked, bodyless, and close-delimited Response framing;
- incremental Response delivery and drain/discard by default;
- explicit bounded `buffer_body` whole-response accumulation;
- HTTPS through Linux::Event TLS using the same Client::Connection class.

Keep the client response-head parser in Perl unless measurement justifies XS.

## PR #21 - high-level redirect operations

Initial redirect implementation commit:

`ad4fc134e589b50c600228aabf5e0d870568df45`

The important architectural change is the addition of
`Linux::Event::HTTP::Client::Operation`. High-level Client methods now return an
Operation. Low-level `Client::Connection->request()` still returns exactly one
Transaction.

A non-redirected Operation normally contains one Transaction. Each followed
redirect appends another Transaction. Operation exposes:

```text
transaction
transactions
transaction_count
initial_url
url
urls
redirect_count
max_redirects
request
response
request_body
cancel
state
error
is_complete
is_cancelled
is_terminal
```

`request`, `response`, `request_body`, and cancellation are convenient delegates
to the current/final Transaction; body producer ownership remains on
Transaction.

## Redirect policy on the branch

- Client default `max_redirects` is 5; it may be overridden per operation.
- `max_redirects => 0` disables redirect interpretation completely. A 3xx is a
  normal final Response; duplicate Location fields remain ordinary metadata.
- Automatically recognized statuses: 301, 302, 303, 307, 308.
- Relative Location values resolve against the current absolute URL.
- When Location omits a fragment, the current fragment is inherited for client
  URL processing. Fragments never enter the HTTP request-target.
- 301/302 change POST to GET and discard the body.
- 303 uses GET, except HEAD remains HEAD, and discards the body.
- 307/308 preserve method and body.
- Complete scalar bodies are replayable for method-preserving redirects.
- Streaming Request producers are not assumed rewindable. A method-preserving
  redirect for one fails the Operation clearly instead of replaying unsafe data.
- Redirects that change streamed POST to GET may proceed because the next hop has
  no body.
- Host and HTTP framing/connection-specific fields are regenerated/removed for
  every hop.
- Cross-origin redirects remove caller-supplied Authorization and Cookie.
- Proxy-Authorization is never propagated automatically.
- Each redirect hop independently selects a connection for its target origin.

High-level callback behavior:

```perl
on_redirect => sub ($operation, $tx, $res, $next_url) { ... }
```

runs after an intermediate redirect Transaction completes and before the next
hop begins.

`on_response`, `on_body`, and `on_complete` describe the final response only.
`on_informational` remains per-Transaction and can run on any hop. Intermediate
redirect bodies are still consumed through correct HTTP framing but are not
emitted through the final `on_body` callback.

## Redirect tests and validation

Focused test:

`t/66-client-redirects.t`

Coverage includes:

- Client returns Client::Operation;
- relative Location resolution and inherited fragments;
- distinct Transaction history for redirect hops;
- final-only `on_response` / `on_body`;
- 302 POST-to-GET;
- 303 POST-to-GET;
- 307 scalar method/body replay;
- cross-origin Authorization/Cookie stripping and Host regeneration;
- redirect-count failure;
- `max_redirects => 0` final 3xx handling, including duplicate Location fields;
- safe refusal to replay a non-rewindable streaming body.

First implementation CI #341 / run `34733086338` passed on commit
`ad4fc134e589b50c600228aabf5e0d870568df45` across Perl 5.36, latest Perl, and
latest threaded Perl.

Documentation-complete redirect head `9873b5acb3759962913f20bf7145224446730503`
passed final CI #348 / run `34733424818` across:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- full test suite;
- end-to-end server smoke on latest Perl;
- distribution integrity on latest Perl.

A final lifecycle review also confirmed that an early final Response during a
streaming upload marks the old Client::Connection non-reusable and closes it
before the high-level redirect controller attempts to release the connection.
An interrupted upload therefore cannot be returned to the idle pool.

The only change after CI #348 is this handoff validation note. PR #21 should
remain draft/unmerged until explicit authorization.

## Server baseline remains unchanged

Scalar Response:

```perl
$res->body($bytes);
```

Incremental Response:

```perl
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
the narrow server scalar-response fast path.

Redirect handling is high-level Client policy and adds no native code or output
queue.

## Next work after PR #21

Do not mix another client subsystem into PR #21. After redirect approval/merge,
choose one clean layer separately. Candidates are:

- richer connection-pool policy;
- proxy support;
- authentication helpers;
- cookie policy/jar;
- CONNECT and client-side Upgrade.

Client parser XS remains measurement-driven, not a default next step.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The GitHub connector currently exposes branch
creation/update but not branch deletion. Merged feature refs such as
`feature/message-objects`, `feature/http-client-foundation`,
`feature/client-buffered-response`, and `feature/client-streaming-request-body`
may still require GitHub's normal `Delete branch` control. Do not reuse them for
new work.
