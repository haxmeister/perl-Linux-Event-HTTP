# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical release branch: `main`
- Current architecture branch: `feature/message-objects`
- Draft PR: #17, `Refactor Request and Response as shared message objects`
- Do not merge PR #17 without explicit user authorization.
- Linux::Event minimum prerequisite is `0.113`.
- CI prefers CPAN `Linux::Event@0.113` and temporarily falls back to the immutable
  GitHub `v.113` release tag if CPAN file propagation is incomplete.
- No CPAN release of Linux::Event::HTTP has been made yet; distribution version
  remains `0.001 UNRELEASED`.

## Architectural decisions now treated as settled

### Request and Response are HTTP messages

`Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response` describe HTTP
messages, not client/server roles.

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

Do not introduce `Client::Request`, `Client::Response`, `Server::Request`, or
`Server::Response` merely to encode endpoint direction.

Both message classes use familiar CPAN-style names where the semantics genuinely
match, while retaining richer/protocol-correct concepts where needed. In
particular:

```text
Request                         Response
-------                         --------
method                          status
target                          reason
version                         version
header                          header
add_header                      add_header
remove_header                   remove_header
header_values                   header_values
header_count                    header_count
header_name                     header_name
header_value                    header_value
content_length                  content_length
body                            body
is_complete                     is_complete
```

Use `target`, not `uri`, because the HTTP message contains a request-target.
Client URL parsing/resolution is a Client concern.

Do not add conversion to/from `HTTP::Request` / `HTTP::Response` now. That can be
considered later if real interoperability needs justify it.

### Native received Request remains lazy

The message refactor must not turn every parsed server request into eager Perl
hash/header objects.

Native parsed Requests remain XS-backed and lazily materialize method, target,
and header strings. Locally constructed Requests use the same public class with
a mutable Perl representation.

`lib/Linux/Event/HTTP/_HTTP1.pm` ensures the public Request class is loaded when
native parsing returns a Request object without moving message API ownership
back into XS.

### Transaction is one HTTP exchange

`Linux::Event::HTTP::Transaction` represents exactly one Request/Response
exchange:

```text
Transaction
    Request
    Response
    state
    cancel
    is_complete
    error
    outgoing body producer
```

One redirect is another HTTP exchange and therefore another Transaction.
Transaction does not own a socket, parser, connection pool, or transport queue.
Its current Client/Connection controller performs protocol execution.

The server callback remains intentionally simple:

```perl
on_request => sub ($conn, $req, $res) {
    ...
}
```

The active Transaction is available through:

```perl
my $tx = $conn->transaction;
```

Do not add a Transaction callback argument unless a concrete need later proves
that accessor insufficient.

### Body handling and HTTP framing are different concerns

Headers/framing answer how the protocol knows which bytes belong to a body.
Application body handling answers whether bytes are buffered, incrementally
produced/consumed, written to disk, parsed, discarded, forwarded, etc.

Do not equate application streaming with `Transfer-Encoding: chunked`.
A known Content-Length body may still be produced/consumed incrementally, and
future HTTP versions use different wire framing.

Linux::Event::HTTP is the protocol communication layer. It exposes status,
headers, content length when known, body bytes, completion, errors, and lifecycle
information. The application decides whether data belongs in RAM, a file, a
parser, another protocol connection, or nowhere.

Never make unbounded implicit body buffering the default.

## Current body API

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

That means the Response message body itself is complete. Message completion is
separate from server transport-output completion.

An incremental outgoing body belongs to Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain => sub ($body) {
        # resume upstream production
    },
    on_cancel => sub ($body) {
        # stop upstream work
    },
);

$body->write($bytes);
$body->complete;
```

`Response->stream_body` has been removed. Do not restore it as an alias.
Response also deliberately has no public `write`, `complete`, `end`, or
`is_ended` compatibility aliases.

`Transaction->response_body` creates one stable `Body::Stream` producer. Merely
creating it does not commit response output. The first producer `write` or
`complete` commits the response head and freezes Response metadata.

A complete scalar Response body and an incremental response producer are
mutually exclusive.

`Body::Stream->write` preserves Linux::Event flow control:

```text
true  = bytes accepted; producer may continue
false = bytes accepted; producer should stop until on_drain
```

There is no second HTTP output queue. Linux::Event owns queued bytes,
watermarks, drain signaling, pending-byte limits, TLS progression, and actual
transport writes.

## Completion semantics

These are deliberately distinct:

```text
Request->is_complete
    complete incoming/outgoing Request message body boundary

Response->is_complete
    complete Response message body boundary

Transaction->is_complete
    successful completion of the whole HTTP exchange

private Response output state
    server has finished writing this Response to its transport
```

For a received server Request, `is_complete` becomes true at the actual body
boundary. For an outgoing scalar Response, `body(...)` makes the message complete
immediately even though output may not yet have committed. For an incremental
Response producer, the message becomes complete when the producer completes.

## Server integration

`Server::Connection` now creates one Transaction for each exchange and preserves
the existing `$conn, $req, $res` public callbacks.

The Transaction controller path handles:

- response body producer writes;
- producer drain signaling;
- producer cancellation when the Transaction/connection is abandoned;
- Transaction cancellation;
- terminal success/error state.

The native default scalar-response fast path remains enabled and now terminates
the same Transaction lifecycle instead of bypassing it.

Current server-specific lifecycle still present on Response includes Upgrade and
some private/bound-connection machinery. Do not broaden cleanup of those pieces
unless needed by the next client work. Upgrade ownership can move toward
Transaction later as a focused change.

## HTTP/1 private state

Generic Request/Response API must not expose HTTP/1 framing policy as message
identity. Server HTTP/1 execution uses private accessors/state such as request
body mode and keep-alive decisions.

Wire framing remains protocol-version-specific:

- scalar HTTP/1 bodies normally use Content-Length;
- unknown-length incremental HTTP/1.1 output uses chunked transfer coding;
- unknown-length incremental HTTP/1.0 output is close-delimited;
- declared Content-Length is enforced;
- HEAD and body-forbidden response semantics are enforced.

## CI / tests

The message/Transaction refactor has been repeatedly validated on:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- end-to-end benchmark smoke;
- `make disttest` / distribution integrity.

CI run `34727574293` (PR run 281) passed after moving writable response-body
ownership from Response to Transaction.

Important focused tests include:

```text
t/19-request-message.t
t/20-response.t
t/21-response-body-stream-unit.t
t/22-transaction.t
t/23-server-transaction.t
t/30-connection.t
t/31-request-body.t
t/32-request-body-lifecycle.t
t/33-response-chunked.t
t/34-response-body-stream.t
t/42-upgrade.t
t/50-final-response.t
```

Coverage includes locally constructed messages, lazy native Requests, exact
header semantics, message completion, Transaction pairing/lifecycle,
cancellation, incremental body production, backpressure, chunked/close-delimited
framing, pipelining, deferred scalar responses, TLS, Upgrade, and the native
scalar fast path.

## Project charter

Linux::Event is the Linux-native communications engine. Reusable low-level
performance work belongs in Linux::Event core when it benefits multiple protocol
layers.

Linux::Event::HTTP is the HTTP protocol layer. Priorities are:

1. correctness
2. ease of correct use
3. coherent/simple API
4. maintainability
5. composability
6. performance without unnecessary HTTP-specific native complexity

Do not add PSGI, PAGI, routing/framework responsibilities, middleware, sessions,
or templates to this distribution.

Prefer established CPAN/community libraries for standards/utilities where
appropriate. Do not add HTTP-specific XS merely to win benchmarks.

Keep the single private native HTTP extension unless a measured reason requires
otherwise:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns pico request parsing/lazy Request accessors, chunked request decoding,
response-head serialization, and the narrow default scalar response builder.

## Next major work

Once PR #17 is reviewed/merged with user authorization, move to the native HTTP
client rather than redesigning the server again.

Client design already agreed in principle:

```text
Client
    configuration
    connection pool / connection selection
    redirects and destination policy later

Client::Connection
    HTTP/1 client wire execution
    ordering
    persistence/reuse mechanics

Transaction
    one Request/Response exchange

Request / Response
    shared HTTP message classes
```

Likely Client convenience surface:

```text
request
get
head
post
put
delete
```

Client methods should return Transaction, not Request. A Request is the HTTP
message; Transaction is the cancellable asynchronous exchange.

Before broad client features, implement in layers:

1. basic `Client::Connection` HTTP/1 request serialization/response parsing;
2. one-connection Transaction lifecycle and incremental incoming body delivery;
3. `Client` destination parsing, connection ownership, and reuse;
4. convenience verbs;
5. bounded buffered-body convenience on top of incremental delivery;
6. redirects, richer pooling policy, proxy/auth/cookie conveniences only after
   the basic protocol client is correct.

Do not make a Future/Promise abstraction central. Linux::Event::HTTP uses its
OO/callback Transaction model; awaitable adapters can remain separate concerns.

## Branch policy

The user dislikes stale branches. Keep `feature/message-objects` only while PR
#17 contains active unmerged work. After authorized merge, delete the branch if
it has no unique remaining work.
