# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- No active development branch after the client Upgrade merge.
- PR #22, client HTTP/1.1 Upgrade handoff, was merged to `main` as
  `f430a779ee9f9855a291fd6fc10059d2727cbfaf`.
- PR #21, high-level redirect handling, was merged as
  `b036186d8c6bfec231360bef1dd9d06b20dfd865`.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Core object identities are settled:

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response HTTP exchange

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    HTTP protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, pool, socket, or endpoint-role lifecycle into
Request/Response. Do not redefine Transaction to span redirects.

## Merged client baseline

Main now includes:

- HTTP/HTTPS high-level Client and low-level Client::Connection;
- scalar and streaming Request bodies;
- Linux::Event backpressure with no second HTTP output queue;
- incremental Response delivery plus explicit bounded `buffer_body`;
- strict Perl client response-head parsing and shared native chunked decoding;
- one active Transaction per HTTP/1 connection, sequential keep-alive reuse,
  and at most one retained idle connection per origin;
- Client::Operation as the high-level handle;
- bounded 301/302/303/307/308 redirect following with distinct Transactions;
- redirect method/body policy, relative Location resolution, and cross-origin
  credential stripping;
- client-side HTTP/1.1 `101 Switching Protocols` handoff using the same live
  Linux::Event stream object and `transition_to()` mechanism as server Upgrade.

Keep the client response-head parser in Perl unless measurement justifies XS.

## Client Upgrade baseline

Low-level API:

```perl
my $tx = $connection->request(
    $request,
    upgrade_to => 'MyProtocolConnection',
    on_upgrade => sub ($tx, $res, $connection) { ... },
);
```

High-level API:

```perl
my $operation = $client->get(
    $url,
    headers => [
        [ Connection => 'Upgrade' ],
        [ Upgrade    => 'my-protocol' ],
    ],
    upgrade_to => 'MyProtocolConnection',
    on_upgrade => sub ($operation, $tx, $res, $connection) { ... },
);
```

Rules:

- HTTP/1.1 only.
- Request body must be empty.
- Streaming Request bodies are rejected for Upgrade.
- Transfer-Encoding is not allowed.
- Content-Length may be absent or zero only.
- Request must advertise `Connection: Upgrade` and at least one Upgrade token.
- Invalid Upgrade requests fail before wire output.
- A valid 101 must be HTTP/1.1, contain `Connection: Upgrade`, omit
  Content-Length/Transfer-Encoding, and select a protocol offered by the Request.
- A bare/unexpected 101 without `upgrade_to` is a terminal protocol error.
- The Response and Transaction complete before protocol handoff callbacks.
- Bytes already read after the 101 head are preserved and become target-protocol
  input during `transition_to()`.
- Stream object identity is retained across the handoff.
- A transitioned connection is never returned to the HTTP idle pool.
- Redirects may precede the 101; each redirect remains a separate Transaction.
  Redirect logic regenerates the hop-by-hop Upgrade handshake for each hop.

Private helper:

`lib/Linux/Event/HTTP/_ClientUpgrade.pm`

Focused tests:

- `t/67-client-upgrade.t` - low-level handoff, same-read bytes, object identity,
  bare 101 failure, protocol-selection validation, and request validation.
- `t/68-client-upgrade-high-level.t` - Client::Operation integration,
  redirect-to-Upgrade regeneration, high-level lifecycle, same-read target
  input, and proof that a later ordinary request uses a different HTTP
  connection rather than the transitioned stream.

## Client Upgrade validation

Foundation head `f861a1e3627f493faf00038a9e39f691cbaa5ff5` passed CI #352 / run
`34735999742` across Perl 5.36, latest Perl, and latest threaded Perl.

Behavioral head `b451352681b94d426bbe577f2bbcd03adb0f797d` passed CI #354 / run
`34736098458`, including redirect-to-Upgrade and HTTP-pool isolation coverage.

Final documentation-complete head
`fdd49af712cb7ea24e875e5d9a022557f00b75cf` passed CI #359 / run
`34736289765` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

PR #22 then merged to main as
`f430a779ee9f9855a291fd6fc10059d2727cbfaf`.

## Server baseline

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

Deferred scalar Response uses `$tx->send_response`. Server Upgrade remains
`$tx->upgrade($target_class)` and transitions the same live stream object after
validated 101 output.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Client Upgrade policy/validation is Perl-side control flow around Linux::Event's
existing transition primitive. It does not justify another XS extension.

## Next work

The next substantive HTTP protocol capability to evaluate is CONNECT tunneling.
Do not jump to sophisticated pool policy unless a real workload demonstrates a
need. Other later layers include proxy support, authentication helpers, and
cookie policy/jar.

CONNECT design should preserve the same ownership rules used by Upgrade:
HTTP owns the CONNECT request/response exchange, then a successful tunnel hands
the same live Linux::Event transport to the caller/next protocol without adding
a second queue or duplicate transport object.

Client parser XS remains measurement-driven, not a default next step.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The GitHub connector currently does not expose
branch deletion. Merged feature refs such as `feature/message-objects`,
`feature/http-client-foundation`, `feature/client-buffered-response`,
`feature/client-streaming-request-body`, `feature/client-redirects`, and
`feature/client-upgrade` may still require GitHub's normal `Delete branch`
control. Do not reuse them for new work.
