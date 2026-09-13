# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical release branch: `main`
- Active branch: `feature/http-client-foundation`
- Draft PR: #18, `Add HTTP client connection foundation`
- Do not merge PR #18 without explicit user authorization.
- PR #17 (`Refactor Request and Response as shared message objects`) was merged
  to `main` as `33d326348c2358d8d0d23ddc22b2cc0843c7fa34`.
- `main` handoff refresh after that merge is
  `2956437b8dbb946c1722e6dcc3c9cf961653a417`.
- Linux::Event minimum prerequisite is `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

The client foundation is implemented and validated. Do not redesign Request,
Response, or Transaction to make client destination/pool work easier.

## Settled message/exchange model

Request and Response are endpoint-neutral HTTP messages:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Transaction = exactly one Request + one Response + exchange lifecycle
```

Do not add Client::Request/Response or Server::Request/Response role classes.

Request contains a request-target, not a full URL. Full URL parsing, scheme,
authority, destination selection, Host synthesis, redirects, and pooling belong
to Client.

Response remains transport-independent. Do not restore Connection/request
back-references, output state, Upgrade, stream_body, write, complete, end, or
is_ended on Response.

No HTTP::Request / HTTP::Response conversion adapters are planned now.

## Server baseline

The server callback remains:

```perl
on_request => sub ($conn, $req, $res) {
    ...
}
```

The active exchange is `$conn->transaction`.

Complete scalar Response body:

```perl
$res->body($bytes);
```

Incremental outgoing Response body:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
$body->write($bytes);
$body->complete;
```

Deferred scalar response from another event:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Server Upgrade is Transaction lifecycle:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Linux::Event remains the only transport output queue.

## Client::Connection foundation

New public module:

```text
Linux::Event::HTTP::Client::Connection
```

It subclasses `Linux::Event::IO::Sock::Stream` and owns one HTTP/1 client socket.
It executes one Transaction at a time; HTTP/1 pipelining is deliberately not
enabled.

Low-level use:

```perl
my $conn = Linux::Event::HTTP::Client::Connection->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,
);

my $tx = $conn->request($request,
    on_response => sub ($tx, $res) { ... },
    on_body => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error => sub ($tx, $error) { ... },
    on_informational => sub ($tx, $res) { ... },
);
```

Current Request support:

- HTTP/1.0 and HTTP/1.1;
- complete scalar Request body;
- automatic Content-Length if body is supplied without one;
- explicit Content-Length must match scalar body;
- HTTP/1.1 requires exactly one Host;
- outgoing Transfer-Encoding/streaming Request body is deliberately deferred;
- CONNECT is deliberately deferred.

Current Response support:

- strict HTTP/1 response-head parsing;
- informational 1xx callbacks except 101 handoff;
- HEAD/204/304 bodyless semantics;
- exact Content-Length framing;
- chunked transfer decoding using existing native `_HTTP1::Chunked`;
- close-delimited responses completed at EOF;
- TE+CL ambiguity rejection;
- only plain chunked Transfer-Encoding in this first stage;
- no implicit whole-body Response buffer.

If `on_body` is absent, body bytes are drained/discarded.

Cancellation closes the HTTP/1 connection. Do not attempt to reuse a socket with
an unfinished response still on its ordered byte stream.

The response-head parser is intentionally Perl first. Do not add client response
parser XS merely for symmetry. Benchmark before changing that boundary.

## High-level Client

New public module:

```text
Linux::Event::HTTP::Client
```

Ordinary API:

```perl
my $client = Linux::Event::HTTP::Client->new(loop => $loop);

my $tx = $client->get(
    'https://example.com/path?x=1',
    on_response => sub ($tx, $res) { ... },
    on_body => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error => sub ($tx, $error) { ... },
);
```

Generic and convenience methods:

```text
request
get
head
post
put
delete
```

Client methods return Transaction. `$tx->request` is the canonical outgoing
Request and `$tx->response` becomes available when the final response head
arrives.

Client uses the established `URI` CPAN distribution. `URI => 0` is now a runtime
prerequisite.

URL policy:

- absolute http/https only;
- fragment is not sent;
- path+query becomes Request target, default `/`;
- Host is synthesized if absent;
- non-default port is included in synthesized Host;
- explicit caller Host is preserved;
- userinfo is rejected rather than becoming hidden authentication policy.

Initial reuse policy is intentionally bounded/simple:

- one active Transaction per Client::Connection;
- no HTTP/1 pipelining;
- at most one idle connection retained per origin;
- a concurrent same-origin request creates another connection rather than
  queueing behind a busy one;
- when extras later become idle, one is retained and extras close.

HTTPS uses the same Client::Connection class with a runtime
`Linux::Event::TLS->client` transport. URL host is TLS server_name and Client
offers only `http/1.1` ALPN. Client constructor accepts TLS verify/CA and
handshake/shutdown timeout options.

`connection_class` is the advanced Client hook, symmetric with Server, for a
Client::Connection subclass with reusable stream/socket policy.

## Validation

Low-level client foundation checkpoint:

- PR CI #307 / run `34729218261` passed Perl 5.36, latest Perl, latest threaded
  Perl, full suite, end-to-end server smoke, and disttest.

Raw response framing/cancellation checkpoint:

- PR CI #309 / run `34729277508` passed the same matrix after adding tests for
  100 Continue, true close-delimited completion, TE+CL rejection, and explicit
  cancellation.

High-level Client + HTTPS checkpoint:

- PR CI #315 / run `34729522825` passed Perl 5.36, latest Perl, latest threaded
  Perl, the full suite including Client HTTPS, end-to-end server smoke, and
  disttest.

Important client tests:

```text
t/60-client-connection.t
t/61-client-response-framing.t
t/62-client.t
t/63-client-tls.t
```

Coverage includes scalar Request bodies, fixed/chunked/close-delimited Response
bodies, informational responses, invalid framing, cancellation, no implicit
body buffering, URL/Host policy, concurrent same-origin connections, idle reuse,
common verbs, and HTTPS.

## Native boundary

Keep the single private extension unless measurement proves otherwise:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns pico server request parsing/lazy Request accessors, chunked decoding
(shared by server/client), server response-head serialization, and the narrow
server default scalar-response builder.

The new client response-head parser is Perl. Measure before moving any of it to
XS/C.

## Parked Linux::Event terminal-read question

Do not reopen the earlier paused-read/EPOLLRDHUP question absent a concrete
protocol requirement or demonstrated failure. Do not add HTTP polling, duplicate
buffering, or a second output queue as a workaround.

## Next client work

Keep PR #18 focused on the now-working client foundation. Do not mix redirects,
proxy/auth/cookies, or a large pooling redesign into this PR.

After PR #18 is reviewed/merged, sensible next layers are:

1. bounded whole-body convenience built on incremental `on_body` delivery;
2. streaming outgoing Request bodies with Linux::Event backpressure;
3. redirects as chains of distinct Transactions;
4. richer connection-pool limits/policy if real workloads need them;
5. proxy/auth/cookie conveniences later;
6. CONNECT/client 101 protocol handoff when a concrete consumer needs it;
7. benchmark client response-head parsing before considering native optimization.

Do not make Future/Promise/async-await abstractions central. Primary API remains
OO + callbacks + Transaction lifecycle.

## Branch state

Active work is `feature/http-client-foundation` / draft PR #18.

The merged `feature/message-objects` branch may still exist remotely because the
available GitHub connector exposes branch creation/update but no branch deletion.
Do not intentionally preserve it; delete it through GitHub's normal branch-delete
control when available.

The user dislikes stale branches. After authorized merge of PR #18, delete
`feature/http-client-foundation` as well if no unique work remains.
