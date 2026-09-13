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

The message/Transaction architecture is now intentionally client-ready. Do not
move server lifecycle back into Request or Response merely for convenience.

## Settled object model

### Request and Response are HTTP messages

`Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response` describe HTTP
messages, not client/server roles:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

Do not introduce `Client::Request`, `Client::Response`, `Server::Request`, or
`Server::Response` merely to encode endpoint direction.

Both message classes use familiar names where semantics genuinely match:

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
considered later if a real interoperability need appears.

### Response is now transport-independent

Response owns only response-message concepts:

```text
status
reason
version
headers
complete scalar body / incremental-body selection state
message completion
private message-commit flag
```

It does NOT retain:

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
metadata once output begins. Message completion and message commit are separate.

### Native received Request remains lazy

Parsed server Requests remain XS-backed and lazily materialize method, target,
and headers. Locally constructed Requests use the same public class with a
mutable Perl representation.

HTTP/1-only parser decisions such as body framing and persistence remain private
protocol-execution state (`_http1_body_mode`, `_http1_keep_alive`) rather than
public generic message methods.

### Transaction is one HTTP exchange

`Linux::Event::HTTP::Transaction` represents exactly one Request/Response
exchange:

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

One redirect is another HTTP exchange and therefore another Transaction.
Transaction does not own a socket, parser, connection pool, or transport queue.
Its current Client/Connection controller performs protocol execution.

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

Do not add a fourth Transaction callback argument unless a concrete later need
proves the accessor insufficient.

## Body API and output semantics

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

That makes `Response->is_complete` true immediately because the message body is
known. It does not mean bytes have been written to a socket.

Inside an HTTP callback, scalar output remains deferred until callback return so
metadata order stays intuitive:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

For a scalar Response completed later from another event callback, retain the
Transaction and explicitly send the now-configured message:

```perl
my $tx = $conn->transaction;

$timer = Linux::Event::Kernel::Timer->new(
    loop => $conn->loop,
    after => 0.1,
    on_timer => sub ($timer) {
        $tx->response->body("later\n");
        $tx->send_response;
    },
);
```

This explicit `send_response` is intentional. Do not reintroduce a hidden weak
Connection back-reference in Response just so `body()` can have transport side
effects later.

An incremental outgoing response body belongs to Transaction:

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

`Transaction->response_body` creates one stable `Body::Stream` producer. Merely
creating it does not commit response output. The first producer `write` or
`complete` commits the Response and freezes its metadata.

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

## Completion and output state

Keep these meanings distinct:

```text
Request->is_complete
    complete Request message body boundary

Response->is_complete
    complete Response message body boundary

Transaction->is_response_started
    protocol has committed and begun response output

Transaction->is_complete
    successful completion of the whole HTTP exchange

Transaction->is_upgrading
    HTTP protocol handoff is pending
```

Server::Connection privately tracks any finer HTTP/1 output/framing phase needed
for serialization and persistent ordering.

## Upgrade

Upgrade is a Transaction lifecycle operation:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

`Transaction->upgrade` validates the active request/response pair, HTTP/1.1
requirements, response/body state, and target class before freezing Response
metadata. The 101 response is queued, the HTTP Transaction is marked complete,
and Linux::Event `transition_to()` hands the same live stream object to the
next protocol class.

Socket identity, TLS state, queued output, backpressure, deadlines, application
data, watcher state, and post-HTTP bytes already read from the same TCP read are
preserved.

WebSocket framing belongs in a separate `Linux::Event::WebSocket` distribution.

## Server integration

`Server::Connection` creates one Transaction for every HTTP exchange and keeps
the existing `$conn, $req, $res` callback ergonomics.

The Transaction/controller boundary handles:

- deferred scalar Response send;
- incremental body producer writes;
- response-output start/completion state;
- producer drain and cancellation;
- Transaction cancellation and terminal errors;
- protocol Upgrade handoff.

The native default scalar-response fast path remains enabled. It now updates the
same Response commit and Transaction output/completion lifecycle as the general
serializer. Do not put this optimization back into Response.

## HTTP/1 private state

Generic Request/Response API must not expose HTTP/1 framing policy as message
identity.

Wire framing remains protocol-version-specific:

- scalar HTTP/1 bodies normally use Content-Length;
- unknown-length incremental HTTP/1.1 output uses chunked transfer coding;
- unknown-length incremental HTTP/1.0 output is close-delimited;
- declared Content-Length is enforced;
- HEAD and body-forbidden response semantics are enforced.

Application incremental delivery/production is separate from those wire-framing
choices.

## Linux::Event paused-read / terminal-readiness question (parked)

Earlier testing found that Linux::Event can receive EPOLLERR/HUP/RDHUP while
application reads are paused, but its normal terminal-read handling does not
consume application input while `read_paused` is true.

Current decision remains:

1. This is not established as a Linux::Event correctness bug.
2. `pause_read()` deliberately pauses application input consumption/delivery.
3. Forcing a read while paused can consume or expose unread application payload
   and violate pause semantics.
4. TCP FIN/RDHUP says the peer finished sending; it does not say the peer stopped
   reading our outgoing response.
5. Peer read-side EOF alone is therefore not a reason to cancel an outgoing HTTP
   body producer.
6. Do not add HTTP polling, duplicate buffering, or a second queue as a workaround.

Reopen only if a concrete protocol requirement or failing real-world case needs
terminal transport observation independent of application read pause.

## CI / tests

Code checkpoint CI run `34728237116` (PR run #297), after moving all remaining
server lifecycle state off Response and migrating Upgrade/deferred output to
Transaction, passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- full test suite;
- end-to-end benchmark smoke;
- `make disttest` / distribution integrity.

The subsequent full branch validation run `34728398800` (PR run #302), after the
README, architecture, Changes, handoff, and public Server POD were aligned with
that model, also passed the same test matrix. A later documentation-only
benchmarking clarification does not alter executable code or the validated
message/Transaction boundary.

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

`t/23-server-transaction.t` deliberately no longer builds a synthetic bound
Response to unit-test the native fast path. The real fast path is covered through
Server::Connection by `t/50-final-response.t`.

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

Once PR #17 is reviewed/merged with explicit user authorization, move to the
native HTTP client rather than redesigning the server again.

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

Implement client work in layers:

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
