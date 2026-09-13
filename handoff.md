# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Active branch: `feature/http-connect-tunnel`
- Draft PR: #23, `Add client CONNECT tunneling`.
- Do not merge PR #23 without explicit user authorization.
- PR #22, client HTTP/1.1 Upgrade handoff, was merged to `main` as
  `f430a779ee9f9855a291fd6fc10059d2727cbfaf`.
- Main handoff refresh after that merge: `c5caa2b57991f7be5830e7ba23db23d81a8b098d`.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Core object identities remain settled:

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

Main already includes:

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

## PR #23 - client CONNECT tunneling

The active branch adds explicit HTTP/1.1 CONNECT tunnel establishment without
making ordinary Client requests implicitly proxy-aware.

Low-level API:

```perl
my $tx = $connection->request(
    Linux::Event::HTTP::Request->new(
        method  => 'CONNECT',
        target  => 'target.example:443',
        headers => [ [ Host => 'target.example:443' ] ],
    ),
    tunnel_to => 'MyTunnelProtocol',
    on_tunnel => sub ($tx, $res, $connection) { ... },
);
```

High-level API:

```perl
my $operation = $client->connect_tunnel(
    'http://proxy.example:3128',
    'target.example:443',
    tunnel_to => 'MyTunnelProtocol',
    headers => [
        [ 'Proxy-Authorization' => $value ],
    ],
    on_tunnel => sub ($operation, $tx, $res, $connection) { ... },
);
```

The high-level API deliberately separates:

```text
proxy URL          = where the HTTP/TLS connection is made
target authority   = what CONNECT asks the proxy to open
tunnel_to          = which Linux::Event stream class owns the socket afterward
```

`connect_tunnel` accepts `http` or `https` proxy endpoints. An HTTPS proxy means
TLS is established to the proxy before CONNECT. It does not imply TLS to the
CONNECT target; the target protocol class owns whatever happens inside the
resulting byte tunnel.

## CONNECT request rules

- HTTP/1.1 only.
- Method must be CONNECT when `tunnel_to` is used.
- Low-level CONNECT requires explicit `tunnel_to`.
- Request target must be authority-form `host:port`.
- Port must be 1..65535.
- Exactly one Host field is required and must match the authority target apart
  from case.
- Request body is forbidden.
- Streaming Request body is forbidden.
- Content-Length is forbidden by field presence, including `Content-Length: 0`.
- Transfer-Encoding is forbidden by field presence.
- `upgrade_to` and `tunnel_to` are mutually exclusive.
- Invalid CONNECT configurations fail before protocol execution/wire output.

Private validation/handoff helper:

`lib/Linux/Event/HTTP/_ClientConnect.pm`

CONNECT control flow remains Perl-side and uses existing Linux::Event transport
primitives. No new XS extension, output queue, or transport object was added.

## Successful CONNECT response lifecycle

Any 2xx response establishes the tunnel.

On a successful CONNECT:

1. The response head is parsed as the final Response.
2. `on_response($tx,$res)` runs while the Response is attached to the active
   Transaction.
3. The Response is marked complete at the response-head boundary.
4. The HTTP connection becomes permanently non-reusable.
5. A zero-delay handoff leaves the HTTP parser before any post-head bytes are
   interpreted as HTTP content.
6. The Transaction is marked complete.
7. Linux::Event `transition_to($target, input => $already_read_bytes)` hands the
   same live stream object to `tunnel_to`.
8. Already-read bytes after the successful CONNECT head become tunnel input.
9. Low-level `on_tunnel($tx,$res,$connection)` runs after transition.
10. Low-level `on_complete($tx)` follows.
11. At high level, Client::Operation is complete before
    `on_tunnel($operation,$tx,$res,$connection)` runs.
12. The transitioned stream never returns to the HTTP idle pool.

Per RFC 9110/9112 semantics, Content-Length and Transfer-Encoding on a successful
2xx CONNECT response are ignored. They do not frame HTTP content after the
successful response head.

## Non-2xx CONNECT behavior

A non-2xx CONNECT does not establish a tunnel and remains an ordinary HTTP
response.

That means:

- `on_response`, `on_body`, or explicit bounded `buffer_body` work normally;
- a 407 body can be inspected by the application;
- normal HTTP framing/persistence rules apply;
- a persistent proxy connection can be returned to the proxy-origin idle pool
  and reused by a later request;
- `on_tunnel` does not run.

High-level `connect_tunnel` intentionally does not follow redirects and does not
implement automatic proxy authentication. Caller-supplied Proxy-Authorization
is passed through as an ordinary header.

## Focused tests

- `t/69-client-connect.t`
  - low-level authority-form request serialization;
  - same-live-object 2xx handoff;
  - same-read post-head tunnel bytes;
  - deliberate Content-Length + Transfer-Encoding on 2xx proving those fields
    are ignored at the tunnel boundary;
  - callback order response -> tunnel -> complete;
  - non-2xx 407 body delivery and persistent low-level connection reuse;
  - invalid CONNECT configurations rejected before Transaction creation.
- `t/70-client-connect-high-level.t`
  - proxy endpoint and CONNECT target are distinct;
  - Client::Operation lifecycle;
  - synthesized target Host and caller Proxy-Authorization;
  - Operation/Transaction complete before high-level on_tunnel;
  - same-read target input and object identity;
  - successful tunnel excluded from HTTP pool;
  - non-2xx high-level CONNECT returned to the proxy-origin pool and reused.
- `t/71-client-connect-validation.t`
  - `Content-Length: 0` rejected by field presence;
  - Transfer-Encoding rejected by field presence.

## Validation checkpoints

Initial low-level CI #362 / run `34737313826` reached the new CONNECT test but
failed because the validation-only test listener used an invalid empty raw
Stream recipe. Linux::Event correctly requires `on_data`; this was a test-harness
mistake, not an implementation failure.

After fixing that harness only, head
`0a9286ea8565a063d018738544f2dfbb0445fa1d` passed CI #363 / run
`34737397121` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

The complete low/high-level executable head including `connect_tunnel`, pool
isolation/reuse tests, and the exact framing-field presence fix passed CI #367 /
run `34737613279` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

The commits after CI #367 add the focused field-presence regression test and
align README, Changes, architecture, top-level POD, MANIFEST, and this handoff.
Run one final branch-head CI before presenting PR #23 as ready for review.

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

Server-side CONNECT tunnel handoff has not been implemented yet. If symmetry for
proxy-server use is desired, it should be a separate feature branch/PR rather
than being mixed into client PR #23.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Client Upgrade and CONNECT are Perl-side execution policy around Linux::Event's
existing transition primitive. Neither justifies another XS extension.

## Next work after PR #23

Do not mix another subsystem into PR #23.

The next protocol capability worth evaluating is server-side successful CONNECT
handoff so Linux::Event::HTTP can also serve as the HTTP boundary of a proxy or
other tunnel-accepting protocol bridge. Keep that separate from general forward
proxy client policy.

Other later client layers include:

- automatic forward-proxy policy for ordinary HTTP requests;
- proxy/authentication helpers;
- cookie policy/jar;
- richer connection-pool policy only when a real workload justifies it.

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
