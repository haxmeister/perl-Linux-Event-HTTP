# Linux::Event::HTTP

Linux::Event::HTTP is a native HTTP protocol layer for Linux::Event.

Linux::Event owns sockets, TLS, readiness, buffering, backpressure, and ordered
byte output. Linux::Event::HTTP owns HTTP parsing, framing, persistence,
serialization, and transaction state. It is deliberately not a web framework.

## Quick start

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;

my $loop = Linux::Event::Loop->new;

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,

    on_request => sub ($conn, $req, $res) {
        $res->status(200);
        $res->header('Content-Type', 'text/plain');
        $res->body("hello\n");
    },
);

$loop->run;
```

The callback receives the persistent HTTP connection, one Request, and the
Response paired with that Request. The active one-request/one-response exchange
is available as `$conn->transaction` when lifecycle or incremental-body
operations are needed.

## Message and transaction model

`Request` and `Response` are HTTP message objects, not client/server role
objects. The same classes are intended to be used on both sides of an exchange:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Transaction = one Request + one Response + exchange lifecycle
```

A locally constructed message is mutable until committed. A received message
keeps the same public message API while its wire metadata is read-only.

`Request` and `Response` do not retain sockets, peer messages, or hidden
Connection back-references. `Transaction` owns exchange lifecycle such as
cancellation, response-output progress, protocol Upgrade, and outgoing
incremental body production. `Client` and `Server::Connection` own the
protocol/transport work that executes a Transaction.

## Response bodies

The public model is intentionally split by responsibility:

```text
Response       = HTTP response message
Transaction    = one HTTP exchange and its lifecycle
Body::Stream   = writable incremental body producer owned by Transaction
```

For an ordinary complete response, set the scalar body on the Response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->body("hello\n");
};
```

`body(...)` declares a complete scalar byte body. When it is called inside an
HTTP callback, it does not serialize in the middle of that callback. Response
metadata remains configurable until the callback returns:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');   # valid
```

The server automatically commits an ordinary scalar response after the HTTP
callback returns when transaction state permits.

A Response completed later from another event remains only a message; setting
its body does not secretly write to a socket. Retain the Transaction and send
the configured scalar response explicitly:

```perl
my $tx = $conn->transaction;

Linux::Event::Kernel::Timer->new(
    loop => $conn->loop,
    after => 0.1,
    on_timer => sub ($timer) {
        $tx->response->body("later\n");
        $tx->send_response;
    },
);
```

For a body produced over time, obtain the producer from the active Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain => sub ($body) {
        # resume the upstream producer
    },
    on_cancel => sub ($body) {
        # stop the upstream producer
    },
);

$body->write("one\n");
$body->write("two\n");
$body->complete;
```

Creating `response_body()` does not start output or freeze Response metadata.
The first `write()` or `complete()` on the producer commits the response head.
After that, status and headers are immutable.

A Response has either a complete scalar body or an incremental body producer,
never both. The producer is intentionally not a method or transport handle on
the Response message itself.

### Backpressure

`Body::Stream->write(...)` feeds HTTP-framed bytes into Linux::Event's existing
ordered-byte output machinery. Linux::Event remains the only output queue.

The return value preserves the Linux::Event flow-control contract:

```text
true  = bytes accepted and the producer may continue
false = bytes accepted, but stop producing until on_drain
```

`on_cancel` runs if the HTTP exchange abandons an unfinished producer.

## Message completion is not socket shutdown

`Request->is_complete` and `Response->is_complete` describe HTTP message
completion. `Transaction->is_complete` describes successful completion of the
whole exchange. None of these normally means the TCP/TLS connection should be
closed. HTTP/1.1 keep-alive can carry later transactions on the same connection.

Response-output start state also belongs to Transaction rather than Response:
`$tx->is_response_started` becomes true when protocol output commits the
Response message.

There is deliberately no Response `end` method. Transport shutdown remains a
Linux::Event stream concept rather than an HTTP Response concept.

## Request bodies

Request heads are dispatched as soon as they are validated. Request bodies are
incremental-first on the server:

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8080,

    on_request => sub ($conn, $req, $res) {
        $conn->data->{body} = '';
    },

    on_body => sub ($conn, $req, $res, $bytes) {
        $conn->data->{body} .= $bytes;
    },

    on_request_end => sub ($conn, $req, $res) {
        $res->body("received\n");
    },
);
```

Content-Length bodies are delivered incrementally. Chunked request bodies are
decoded before application delivery. If `on_body` is absent, body bytes are
drained rather than accumulated.

HTTP/1.1 `Expect: 100-continue` is supported for requests with bodies;
unsupported expectations are rejected with 417 before application dispatch.

## HTTP/1 response framing

The protocol layer chooses the correct HTTP/1 framing from the message and
transaction state:

- complete scalar bodies normally use Content-Length;
- incremental HTTP/1.1 bodies without Content-Length use chunked transfer coding;
- incremental HTTP/1.0 bodies with unknown length are close-delimited;
- declared Content-Length is enforced;
- HEAD and body-forbidden status semantics are enforced by the protocol layer.

These are HTTP/1 wire-framing decisions. Whether an application supplies or
consumes body bytes incrementally is a separate application-facing concern.

## Connection subclasses

Most programs can use constructor callbacks only. A custom
`Linux::Event::HTTP::Server::Connection` subclass is the advanced extension
point for reusable transport defaults, stream tuning, socket policy, or named
callbacks:

```perl
package MyHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';

sub stream_tuning ($class) {
    return read_budget_bytes => 262_144;
}

sub on_request ($self, $req, $res) {
    $res->body("hello\n");
}

package main;

my $server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    port             => 8080,
    connection_class => 'MyHTTP',
);
```

Constructor callbacks supplied to `Server->new` override same-named subclass
callbacks for accepted connections. HTTP's internal drain/close bookkeeping is
composed with Connection lifecycle callbacks rather than replacing them.

Deployment-specific tuning may be supplied directly to the Server and overrides
the configured Connection class defaults:

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8080,
    tuning => {
        read_size         => 131_072,
        read_budget_bytes => 524_288,
        idle_timeout      => 60,
    },
    on_request => sub ($conn, $req, $res) {
        $res->body("hello\n");
    },
);
```

Accepted-connection lifecycle callbacks are `on_ready`,
`on_transport_ready`, `on_drain`, `on_eof`, `on_error`, and `on_close`.
`on_listener_error` is the separate callback for listening and acceptance
failures. The advanced `on_accept($listener, $conn)` callback receives the
underlying Listener and each newly accepted HTTP Connection.

## TLS

HTTPS uses the same HTTP classes. TLS remains Linux::Event transport policy:

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8443,
    tls => {
        cert_file => '/etc/myapp/server-cert.pem',
        key_file  => '/etc/myapp/server-key.pem',
        alpn      => ['http/1.1'],
    },
    on_request => sub ($conn, $req, $res) {
        $res->body("secure\n");
    },
);
```

The TLS handshake completes before HTTP request dispatch. Negotiated ALPN,
protocol, and cipher remain available through the Linux::Event connection.
Connection subclasses may define `tls_defaults()` for reusable ALPN and timeout
defaults. A `tls` Server option is still required to activate TLS; this allows
the same Connection class to serve plain HTTP and HTTPS listeners.

## Upgrade

HTTP Upgrade is an exchange lifecycle operation on the same live transport. The
Response describes the 101 message; the Transaction requests the handoff:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Linux::Event::HTTP validates the HTTP/1.1 Upgrade, freezes the Response metadata,
queues the 101 response, completes the HTTP Transaction, and uses Linux::Event
`transition_to()` to hand the same stream object to the target protocol class.
Socket identity, TLS state, queued output, and already-read post-HTTP bytes are
preserved.

`$tx->is_upgrading` reports the pending handoff state. Upgrade is deliberately
not a method on Response because protocol transition is not a property of an
HTTP message.

WebSocket framing belongs in a separate `Linux::Event::WebSocket` distribution.

## Public modules

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Transaction
Linux::Event::HTTP::Body::Stream
```

Native client support is the next major layer and is reserved for:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet. `Request`, `Response`, and `Transaction` are
already shaped so the client can use the same message/exchange model as the
server.

## Native HTTP boundary

HTTP/1 native work is consolidated in one private extension:

```text
Linux::Event::HTTP::_HTTP1
```

It owns picohttpparser request-head parsing, native Request state, chunked
request decoding, response-head serialization, and a narrow eligible scalar
response builder. Applications do not select a special fast-path API;
`Response->body(...)` uses it transparently when eligible.

No second native transport or response-body queue is maintained by HTTP.

## Build and test

From a checkout:

```sh
perl Makefile.PL
make
make test
```

The distribution includes end-to-end, TLS, pipelining, Upgrade, request-body,
response-body, Transaction-lifecycle, and distribution-integrity coverage.

## Benchmarks

The repository keeps parser microbenchmarks separate from end-to-end server
benchmarks. See `docs/BENCHMARKING.md` before interpreting results.

Typical local smoke checks are:

```sh
perl -Mblib bench/run-http-end-to-end.pl --smoke
perl -Mblib bench/run-http-comparison.pl --smoke
```

Benchmark-only competitors are optional and are not distribution dependencies.

## Scope

Linux::Event::HTTP is the HTTP protocol layer. It does not include routing,
middleware, sessions, templates, PSGI, PAGI, or framework responsibilities.
Reusable low-level socket, buffering, backpressure, and transport performance
work belongs in Linux::Event core.
