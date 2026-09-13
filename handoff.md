# Linux::Event::HTTP handoff

Updated: 2026-09-12 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- PR #17, `Refactor Request and Response as shared message objects`, was merged
  into `main` as commit `33d326348c2358d8d0d23ddc22b2cc0843c7fa34`.
- Final branch-head CI run `34728494947` (#304) passed Perl 5.36, latest Perl,
  latest threaded Perl, the full suite, end-to-end smoke, and distribution
  integrity.
- Linux::Event minimum prerequisite is `0.113`.
- Linux::Event::HTTP is still `0.001 UNRELEASED`.
- The next major implementation target is the native HTTP client.

The message/Transaction architecture is now the mainline baseline. Do not move
server lifecycle back into Request or Response merely for convenience.

## Settled object model

### Request and Response are HTTP messages

`Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response` are
endpoint-neutral HTTP message types:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

Do not introduce `Client::Request`, `Client::Response`, `Server::Request`, or
`Server::Response` just to encode endpoint direction.

Common message concepts are:

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
Client URL parsing, authority selection, redirect resolution, and destination
policy belong to Client.

Do not add HTTP::Request / HTTP::Response conversion adapters now. Familiar
method names are useful where semantics genuinely match, but this distribution
keeps its richer event-driven message model.

### Response is transport-independent

Response owns message data only: status, reason, version, headers, complete
scalar-body state, message completion, and a private message-commit flag.

Response does not retain or expose:

```text
Connection
peer Request
output-start/output-complete state
writable producer
Upgrade state or operation
transport shutdown
```

Do not restore public Response methods such as:

```text
connection
request
is_started
is_upgrading
upgrade
stream_body
write
complete
end
is_ended
```

The private commit flag exists only so protocol execution can freeze message
metadata once output starts. Message completion and message commit are separate.

### Native received Request remains lazy

Parsed server Requests remain XS-backed and lazily materialize method, target,
and headers. Locally constructed Requests use the same public class with mutable
Perl state.

HTTP/1-only body-framing and persistence decisions remain private protocol state
(`_http1_body_mode`, `_http1_keep_alive`) rather than generic message methods.

### Transaction is exactly one HTTP exchange

`Linux::Event::HTTP::Transaction` owns the lifecycle pairing one Request with one
Response:

```text
Transaction
    Request
    Response
    state / error
    cancel
    is_complete
    response output progress
    outgoing body producer
    deferred scalar send
    protocol Upgrade lifecycle
```

A redirect is another HTTP exchange and therefore another Transaction.
Transaction does not own a socket, parser, pool, redirect chain, or transport
queue. Its current Client/Connection controller performs protocol execution.

The server callback remains:

```perl
on_request => sub ($conn, $req, $res) {
    ...
}
```

The active exchange is available through:

```perl
my $tx = $conn->transaction;
```

Do not add a fourth Transaction callback argument without a concrete need.

## Body and output semantics

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

That makes `Response->is_complete` true because the whole message body is known.
It does not mean the bytes have been written to a socket.

Inside an HTTP callback, scalar output remains deferred until callback return so
metadata order remains intuitive:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

A scalar Response completed later from another event uses explicit Transaction
output:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Do not reintroduce a hidden Connection back-reference in Response merely so
`body()` can acquire transport side effects.

Incremental outgoing response production belongs to Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

`Transaction->response_body` creates one stable `Body::Stream` producer. Merely
creating it does not commit the Response. First write/complete commits Response
metadata.

A complete scalar Response body and an incremental producer are mutually
exclusive.

`Body::Stream->write` preserves Linux::Event flow control:

```text
true  = bytes accepted; producer may continue
false = bytes accepted; producer should pause until on_drain
```

Linux::Event remains the only transport-output queue and owns watermarks,
pending bytes, drain signaling, TLS progress, and actual writes.

## Completion meanings

```text
Request->is_complete
    complete Request message body boundary

Response->is_complete
    complete Response message body boundary

Transaction->is_response_started
    protocol committed and began response output

Transaction->is_complete
    successful completion of the whole exchange

Transaction->is_upgrading
    protocol handoff is pending
```

Server::Connection may track finer HTTP/1 phases privately.

## Upgrade

Upgrade is Transaction lifecycle:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Transaction validates the active Request/Response pair and HTTP/1.1 constraints,
queues the 101 response, completes the HTTP Transaction, and Linux::Event
`transition_to()` hands the same live stream object to the next protocol class.

WebSocket remains a separate `Linux::Event::WebSocket` distribution.

## HTTP/1 framing policy

Application incremental delivery/production is distinct from wire framing.

- scalar HTTP/1 bodies normally use Content-Length;
- unknown-length incremental HTTP/1.1 output uses chunked transfer coding;
- unknown-length incremental HTTP/1.0 output is close-delimited;
- declared Content-Length is enforced;
- HEAD and body-forbidden status semantics are enforced.

Do not expose these HTTP/1 execution details as generic message identity.

## Native HTTP boundary

Keep the single private native extension unless measurement proves otherwise:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns pico request parsing/lazy Request accessors, chunked request decoding,
response-head serialization, and the narrow default scalar-response builder.

Do not add HTTP-specific XS merely to win benchmarks. Reusable low-level socket,
buffer, backpressure, and byte-stream performance work belongs in Linux::Event.

## Parked Linux::Event terminal-read question

Linux::Event can receive EPOLLERR/HUP/RDHUP while application reads are paused,
but its normal terminal-read handling does not consume application input while
`read_paused` is true.

Current decision:

1. this is not established as a Linux::Event correctness bug;
2. `pause_read()` deliberately pauses application input consumption/delivery;
3. forcing reads while paused risks consuming application payload;
4. TCP FIN/RDHUP does not imply the peer stopped reading our outgoing response;
5. peer read-side EOF alone is not reason to cancel an outgoing body producer;
6. do not add HTTP polling, duplicate buffering, or a second queue.

Reopen only for a concrete protocol requirement or demonstrated failure.

## Client direction

The next major layer is:

```text
Client
    configuration
    destination parsing
    connection ownership / selection / reuse
    redirects and richer policy later

Client::Connection
    HTTP/1 client wire execution
    request serialization
    response parsing/framing
    persistent connection mechanics

Transaction
    one Request/Response exchange

Request / Response
    shared message classes
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

Client methods return Transaction, not Request. Request is the outgoing HTTP
message; Transaction is the asynchronous/cancellable exchange.

Implement client work in layers:

1. basic `Client::Connection` HTTP/1 request serialization and response parsing;
2. one-connection Transaction lifecycle and incremental incoming-body delivery;
3. `Client` URL/destination parsing, connection ownership, and persistent reuse;
4. convenience verbs;
5. bounded buffered-body convenience built on incremental delivery;
6. redirects, richer pooling, proxy/auth/cookie conveniences only after the core
   client is correct.

Do not make Future/Promise/async-await abstractions central. The primary API is
OO + callbacks + Transaction lifecycle.

## Branch state

PR #17 is merged. At merge time the repository contained only `main` and the
merged `feature/message-objects` head branch. The available GitHub connector can
create/update branch refs but does not expose branch deletion, so that merged
head may still need deletion through GitHub's normal branch-delete control.

Do not preserve merged/abandoned feature branches intentionally. New client work
should start from merged `main` and should not reuse the old message-object branch
name.
