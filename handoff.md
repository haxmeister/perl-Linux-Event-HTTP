# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Active branch: `feature/client-upgrade`
- Draft PR: #22, client HTTP/1.1 Upgrade handoff.
- Do not merge PR #22 without explicit user authorization.
- PR #21, high-level redirect handling, was merged to `main` as
  `b036186d8c6bfec231360bef1dd9d06b20dfd865`.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

The core object identities remain settled:

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
  credential stripping.

Keep the client response-head parser in Perl unless measurement justifies XS.

## PR #22 - client HTTP Upgrade

The active branch adds client-side `101 Switching Protocols` handoff using the
same Linux::Event `transition_to()` mechanism already used by server Upgrade.
There is no new transport object, parser, XS extension, or output queue.

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

### Request requirements

- HTTP/1.1 only.
- Request body must be empty.
- Streaming Request bodies are not supported for Upgrade.
- Transfer-Encoding is not allowed.
- Content-Length may be absent or zero only.
- Request must advertise `Connection: Upgrade`.
- Request must contain at least one valid `Upgrade` protocol value.
- `upgrade_to` must name a `Linux::Event::IO::Sock::Stream` subclass.
- Invalid Upgrade requests fail before wire output.

### 101 response requirements

- HTTP/1.1 response.
- `Connection: Upgrade` required; `Connection: close` is not accepted.
- No Content-Length or Transfer-Encoding.
- Response must select a protocol offered by the Request.
- A bare/unexpected 101 without `upgrade_to` is a protocol error and closes the
  HTTP connection.

### Handoff lifecycle

On a valid 101:

1. The 101 Response is attached to the Transaction and `on_response` runs.
2. The Response and Transaction are marked complete.
3. The HTTP parser stops owning subsequent input.
4. Linux::Event `transition_to($target, input => $already_read_bytes)` reblesses
   the same live stream object into the target protocol class.
5. Any bytes already read after the 101 head become target-protocol input.
6. Low-level `on_upgrade($tx,$res,$connection)` runs after transition.
7. Low-level `on_complete($tx)` then runs.
8. At high level, Client::Operation is complete before
   `on_upgrade($operation,$tx,$res,$connection)` runs.
9. A transitioned connection is never returned to the HTTP idle pool.

Target-protocol `on_data` may run inside `transition_to()` before the user
`on_upgrade` callback if post-101 bytes were already buffered. This is correct:
HTTP is complete and target-protocol ownership has already begun.

### Redirect plus Upgrade

Redirects may precede the successful 101. Each redirect remains a separate
Transaction in Client::Operation history.

Because Connection and Upgrade are hop-by-hop handshake fields, redirect logic
removes the previous connection-specific headers and then explicitly regenerates
`Connection: Upgrade` plus the originally offered `Upgrade` values for the next
hop. Cross-origin Authorization/Cookie stripping remains unchanged.

## Implementation files

New private helper:

`lib/Linux/Event/HTTP/_ClientUpgrade.pm`

It owns request/101 validation and the deferred live transition. It is private
because this is HTTP execution machinery, not a public protocol object.

Updated:

- `lib/Linux/Event/HTTP/Client/Connection.pm`
- `lib/Linux/Event/HTTP/Client.pm`
- `MANIFEST`
- README / top-level POD / architecture / Changes

Focused tests:

- `t/67-client-upgrade.t` - low-level Client::Connection handoff, same-read
  post-101 bytes, object identity, bare 101 failure, invalid protocol selection,
  and invalid request rejection before wire output.
- `t/68-client-upgrade-high-level.t` - high-level Client::Operation handoff,
  redirect-to-Upgrade regeneration, final callback lifecycle, same-read target
  input, and proof that a later ordinary request uses a different HTTP
  connection rather than the transitioned stream.

## Validation checkpoints

Low-level/high-level foundation head
`f861a1e3627f493faf00038a9e39f691cbaa5ff5` passed CI #352 / run
`34735999742` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

The stronger high-level behavioral head
`b451352681b94d426bbe577f2bbcd03adb0f797d` passed CI #354 / run
`34736098458` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

Commits after that checkpoint are documentation/handoff alignment only. Run a
final branch-head CI after this handoff update before presenting PR #22 as ready
for review.

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

Deferred scalar Response uses `$tx->send_response`. Server Upgrade remains
`$tx->upgrade($target_class)` and transitions the same live stream object after
validated 101 output.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Client Upgrade policy/validation is Perl-side control flow around Linux::Event's
existing transition primitive. It does not justify another XS extension.

## Next work after PR #22

Do not mix another subsystem into PR #22. After explicit approval/merge, reassess
which actual protocol capability is still important. Candidates include:

- CONNECT tunneling;
- proxy support;
- authentication helpers;
- cookie policy/jar;
- richer connection-pool policy only when a real workload justifies it.

Client parser XS remains measurement-driven, not a default next step.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The GitHub connector currently exposes branch
creation/update but not branch deletion. Merged feature refs such as
`feature/message-objects`, `feature/http-client-foundation`,
`feature/client-buffered-response`, `feature/client-streaming-request-body`, and
`feature/client-redirects` may still require GitHub's normal `Delete branch`
control. Do not reuse them for new work.
