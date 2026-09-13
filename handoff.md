# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical release branch: `main`
- PR #18, `Add HTTP client connection foundation`, was merged to `main` as
  `13a20e9633ca75a5ac5c5bedb951e129f9d67c7c`.
- Final PR #18 head `59dff03119f38b63c841914c1d56354818681144`
  passed CI #320 / run `34729690624`: Perl 5.36, latest Perl, latest threaded
  Perl, full suite, HTTPS client coverage, server smoke, and disttest.
- Linux::Event minimum prerequisite is `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.
- Next active work: explicit bounded whole-response buffering layered on the
  incremental client body path.

The Request/Response/Transaction architecture and native client foundation are
now mainline. Do not move URL, pool, transport, or role-specific lifecycle into
Request or Response for convenience.

## Settled object model

Request and Response are endpoint-neutral HTTP message types:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Transaction = exactly one Request + one Response + exchange lifecycle
```

Request stores a request-target, not a full URL. Client owns URL parsing,
scheme/authority, destination selection, Host synthesis, redirects, and pool
policy.

Response is transport-independent. Do not restore Connection/request
back-references, output state, Upgrade, stream_body, write, complete, end, or
is_ended on Response.

Transaction is the cancellable exchange. It does not own the socket or pool.

## Server baseline

Ordinary callback:

```perl
on_request => sub ($conn, $req, $res) {
    $res->body("hello\n");
}
```

The active exchange is `$conn->transaction`.

Incremental outgoing body:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
$body->write($bytes);
$body->complete;
```

Deferred scalar response:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Upgrade is Transaction lifecycle:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Linux::Event remains the only transport-output queue.

## Client::Connection baseline

`Linux::Event::HTTP::Client::Connection` subclasses
`Linux::Event::IO::Sock::Stream` and executes one HTTP/1 Transaction at a time.
HTTP/1 client pipelining is deliberately disabled.

```perl
my $tx = $conn->request($request,
    on_response      => sub ($tx, $res) { ... },
    on_body          => sub ($tx, $res, $bytes) { ... },
    on_complete      => sub ($tx) { ... },
    on_error         => sub ($tx, $error) { ... },
    on_informational => sub ($tx, $res) { ... },
);
```

Request support:

- HTTP/1.0 and HTTP/1.1;
- complete scalar Request body;
- automatic/matched Content-Length;
- HTTP/1.1 Host enforcement;
- no outgoing Transfer-Encoding/streaming Request body yet;
- CONNECT deferred.

Response support:

- strict Perl HTTP/1 response-head parser;
- 1xx informational callbacks except client 101 handoff;
- HEAD/204/304 bodyless semantics;
- exact Content-Length framing;
- chunked decoding through existing native `_HTTP1::Chunked`;
- close-delimited completion at EOF;
- TE+CL ambiguity rejection;
- incremental decoded body delivery;
- absent `on_body` drains/discards instead of buffering.

Cancellation closes the HTTP/1 connection because unfinished response bytes make
safe reuse impossible.

Do not add response-head XS merely for symmetry. Benchmark before changing the
current Perl parser boundary.

## High-level Client baseline

`Linux::Event::HTTP::Client` is the normal outbound API:

```perl
my $client = Linux::Event::HTTP::Client->new(loop => $loop);

my $tx = $client->get(
    'https://example.com/path?x=1',
    on_response => sub ($tx, $res) { ... },
    on_body     => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error    => sub ($tx, $error) { ... },
);
```

Methods are `request`, `get`, `head`, `post`, `put`, and `delete`; all return
Transaction.

Client uses the established `URI` distribution. URL policy is absolute http/https
only, fragments are not sent, path+query becomes Request target, Host is
synthesized if absent, explicit Host is preserved, and URL userinfo is rejected.

Initial pool policy:

- one active Transaction per Client::Connection;
- no HTTP/1 pipelining;
- at most one idle connection retained per origin;
- concurrent same-origin work may create extra connections;
- one idle connection is retained and extras close when they later become idle.

HTTPS uses the same Client::Connection class with runtime Linux::Event TLS,
URL host as server_name, and `http/1.1` as the only offered ALPN protocol.
`connection_class` is the advanced subclassing hook.

## Next work: bounded buffered Response convenience

This must remain explicit and built on the incremental body machinery. The
planned API is:

```perl
$client->get(
    $url,
    buffer_body => 1_048_576,
    on_response => sub ($tx, $res) { ... },
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
    on_error => sub ($tx, $error) { ... },
);
```

Design rules:

1. `buffer_body => $max_bytes` is opt-in; there is no implicit unbounded body
   buffering.
2. The limit applies to decoded application body bytes, not HTTP chunk framing.
3. `on_response` still runs when the final response head is validated.
4. Successful `on_complete` sees the complete scalar through `Response->body`.
5. Known Content-Length above the limit fails before body accumulation.
6. Unknown/chunked/close-delimited bodies fail as soon as decoded bytes exceed
   the limit.
7. Limit failure is a Transaction error and closes the HTTP/1 connection safely.
8. Keep buffered mode distinct from user `on_body`; applications needing custom
   simultaneous streaming/buffering can do so themselves in `on_body`.
9. Received Response metadata remains committed/read-only. Attaching the final
   buffered scalar body is private protocol/convenience state, not a public
   metadata mutation.

After bounded buffering, sensible next layers remain streaming outgoing Request
bodies, redirect chains of distinct Transactions, richer pool limits only if
workloads need them, and proxy/auth/cookie/CONNECT conveniences later.

## Native boundary

Keep one private native extension unless measurement proves otherwise:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns pico server request parsing/lazy Request accessors, chunked decoding
(shared by server/client), server response-head serialization, and the narrow
server scalar-response fast path.

## Validation checkpoints

- PR #17 message/Transaction refactor: final CI #304 passed.
- PR #18 low-level client foundation: CI #307 passed.
- PR #18 raw framing/cancellation coverage: CI #309 passed.
- PR #18 high-level Client + HTTPS: CI #315 passed.
- PR #18 final branch head: CI #320 passed.

Important client tests currently include:

```text
t/60-client-connection.t
t/61-client-response-framing.t
t/62-client.t
t/63-client-tls.t
```

## Parked core question

Do not reopen the earlier Linux::Event paused-read / EPOLLRDHUP question absent
a concrete protocol requirement or demonstrated failure. Do not add polling,
duplicate buffering, or a second output queue.

## Branch cleanup

The user dislikes stale branches. PR #18 is merged. The GitHub connector
available in this chat exposes branch creation/update but not branch deletion,
and GitHub did not auto-delete `feature/http-client-foundation`; delete that ref
through GitHub's normal branch-delete control when available. The older merged
`feature/message-objects` ref may also still need the same manual deletion.

New work must branch from merged `main`, not reuse either merged feature branch.
