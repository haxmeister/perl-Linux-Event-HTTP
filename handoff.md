# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main currently includes client CONNECT through merge commit
  `bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
- Active branch: `feature/server-connect-tunnel`
- Draft PR: #24, `Add server CONNECT tunnel handoff`.
- Do not merge PR #24 without explicit user authorization.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Core object identities remain settled:

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response HTTP exchange
    owns exchange lifecycle and explicit protocol handoff operations

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    HTTP protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, pool, socket, or endpoint-role lifecycle into
Request/Response. Do not redefine Transaction to span redirects. Linux::Event
remains the only transport-output queue.

## Merged client baseline

Main includes:

- high-level HTTP/HTTPS Client and low-level Client::Connection;
- scalar and streaming Request bodies;
- incremental Response delivery plus explicit bounded `buffer_body`;
- strict Perl client response-head parsing and shared native chunked decoding;
- one active Transaction per HTTP/1 connection and bounded persistent reuse;
- Client::Operation with bounded 301/302/303/307/308 redirect following;
- client HTTP/1.1 Upgrade through Linux::Event `transition_to()`;
- explicit client HTTP/1.1 CONNECT tunnel establishment.

Client CONNECT was implemented by PR #23 and merged as
`bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
Its final documentation-complete head
`fd9f719cc218b7b9b8bbb3447380a7a2b69b6a87` passed CI #374 / run
`34737821960` across Perl 5.36, latest Perl, and latest threaded Perl; latest
Perl also passed end-to-end smoke and distribution integrity.

High-level client CONNECT API:

```perl
my $operation = $client->connect_tunnel(
    'http://proxy.example:3128',
    'target.example:443',
    tunnel_to => 'MyTunnelProtocol',
    on_tunnel => sub ($operation, $tx, $res, $connection) { ... },
);
```

Low-level client CONNECT uses a normal CONNECT Request plus
`tunnel_to`/`on_tunnel` on Client::Connection->request(). Any 2xx response forms
the tunnel boundary. Content-Length and Transfer-Encoding on that successful
response are ignored. Non-2xx CONNECT remains ordinary HTTP and can retain a
persistent proxy connection.

Keep the client response-head parser in Perl unless measurement justifies XS.

## PR #24 - server CONNECT handoff

Server CONNECT deliberately uses the ordinary server request callback. There is
no new CONNECT-specific callback or public message type.

Application API:

```perl
on_request => sub ($conn, $req, $res) {
    if ($req->method eq 'CONNECT') {
        authorize_target($req->target) or do {
            $res->status(403);
            $res->body('forbidden');
            return;
        };

        $res->header('X-Proxy', 'accepted');
        $conn->transaction->tunnel('MyTunnelProtocol');
        return;
    }

    ...;
},
```

`Transaction->tunnel($target_class)` means only: validate and complete the HTTP
CONNECT exchange, then hand the same accepted Linux::Event stream to
`$target_class`.

It does **not**:

- authorize the requested authority;
- open the upstream target connection;
- relay bytes between two sockets;
- implement proxy authentication policy;
- create a second output queue or transport object.

Those are application or higher protocol-bridge responsibilities.

Rejecting CONNECT requires no special API. Configure an ordinary non-2xx
Response; normal body framing, persistence, and later requests remain HTTP.

## Server CONNECT validation rules

A successful `Transaction->tunnel()` currently requires:

- active nonterminal server Transaction;
- response output not already started;
- no pending Upgrade or another CONNECT tunnel handoff;
- HTTP/1.1 CONNECT Request;
- authority-form `host:port` target, including bracketed IPv6 support;
- port 1..65535;
- exactly one Host field matching the authority target case-insensitively;
- no Request Content-Length field, including `Content-Length: 0`;
- no Request Transfer-Encoding field;
- no Request message body;
- mutable incomplete Response;
- 2xx Response status;
- no scalar or incremental Response body;
- no Response Content-Length;
- no Response Transfer-Encoding;
- no `Connection: close` on the successful Response;
- target class inheriting `Linux::Event::IO::Sock::Stream` and differing from
  the active HTTP connection class.

Private helper:

`lib/Linux/Event/HTTP/_ServerConnect.pm`

Transaction now exposes `is_tunneling` and keeps Upgrade/CONNECT pending states
mutually exclusive.

## Server CONNECT handoff lifecycle

Successful server CONNECT is deliberately parallel to server Upgrade but follows
CONNECT-specific HTTP semantics:

1. `on_request($conn,$req,$res)` receives CONNECT normally.
2. Application configures optional 2xx metadata and calls `$tx->tunnel($class)`.
3. The Transaction is marked tunnel-pending; no response bytes are written in
   the middle of the callback.
4. Normal `on_request_end` lifecycle completes first.
5. A zero-delay handoff validates that the Request boundary is complete.
6. Only the successful Response head is serialized; no Content-Length,
   Transfer-Encoding, or HTTP body is generated.
7. Response output is marked started/complete and the Response is complete.
8. The Transaction is completed.
9. Any already-read bytes following the CONNECT head are removed from HTTP
   parsing state.
10. HTTP transaction state is cleared.
11. Linux::Event `transition_to($target, input => $already_read_bytes)` gives
    the same live accepted stream object to the target class.
12. Preserved post-head bytes are target-protocol input.

The successful 2xx response head is queued before target-protocol output. Object
identity is retained across the transition.

## Rejected CONNECT behavior

A CONNECT that is not accepted with `Transaction->tunnel()` remains ordinary
HTTP.

Focused coverage proves that a server can return:

```text
407 + Proxy-Authenticate + response body
```

and then parse/respond to a later pipelined HTTP request on the same persistent
connection. CONNECT therefore does not poison or consume the connection merely
because the method was received.

## Focused server CONNECT test

`t/72-server-connect.t` covers:

- successful authority-form CONNECT through ordinary `on_request`;
- tunnel-pending state during `on_request` and `on_request_end`;
- no mid-callback successful response write;
- Request/Response/Transaction completion before target ownership;
- same-read post-CONNECT bytes preserved as tunnel input;
- same live object identity across transition;
- successful response head queued before target output;
- no automatic Content-Length or Transfer-Encoding on successful CONNECT;
- ordinary persistent 407 rejection with body;
- later pipelined GET after rejected CONNECT on the same connection;
- invalid method/target/Host/version/request framing fields;
- invalid successful-response body/framing/Connection: close/status cases.

## PR #24 validation checkpoints

Initial executable head `f8e42f97fc18155313719cf9fd8cd9a330b0665f`
ran CI #376 / run `34740380345`. All pre-existing tests and server CONNECT
mechanics worked; the only failure was a test assertion that assumed status 407
would automatically serialize reason phrase `Proxy Authentication Required`.
The actual Response serializer correctly emitted status 407 with the unset
reason phrase left empty. This was a test-policy mistake, not a CONNECT failure.

After changing that assertion to validate the status without inventing reason
phrase policy, head `5bb4540a2cbfffa0af9060176ed84a7449ca2359`
passed CI #377 / run `34740465706` across Perl 5.36, latest Perl, and latest
threaded Perl; latest Perl also passed end-to-end smoke and distribution
integrity.

Documentation commits after that green checkpoint align README, Changes,
architecture, Transaction/Server::Connection/top-level POD, MANIFEST, and this
handoff. Run one final branch-head CI before presenting PR #24 for merge.

## Existing server response / Upgrade baseline

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

Deferred scalar Response uses `$tx->send_response`.
Server Upgrade remains `$tx->upgrade($target_class)`.
Server CONNECT is the sibling `$tx->tunnel($target_class)` operation.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Upgrade and CONNECT handoff policy remain Perl-side control flow around
Linux::Event's existing `transition_to()` primitive. Neither justifies another
XS extension.

## After PR #24

Do not add automatic upstream relay behavior to `Transaction->tunnel()`.
If proxy behavior is pursued, keep HTTP handshake/policy separate from a
reusable stream-bridging abstraction so that bridging work can benefit other
Linux::Event protocols too.

Other later client layers remain:

- automatic forward-proxy policy for ordinary HTTP requests;
- proxy/authentication helpers;
- cookie policy/jar;
- richer connection-pool policy only when a real workload justifies it.

Client parser XS remains measurement-driven, not a default next step.
HTTP/2 is future protocol work. WebSocket remains a separate protocol
distribution.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup limitation

The user dislikes stale branches. The GitHub connector currently does not expose
branch deletion. Merged feature refs may require GitHub's normal `Delete branch`
control. Do not reuse stale merged branches for new work.
