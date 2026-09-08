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
Response paired with that Request.

## Response bodies

The public model is intentionally split by responsibility:

```text
Response     = HTTP response message
Body::Stream = streaming body producer
```

For an ordinary complete response, set the scalar body on the Response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->body("hello\n");
};
```

`body(...)` selects a complete scalar byte body. When it is called inside an
HTTP callback, it does not serialize in the middle of that callback. Response
metadata remains configurable until the callback returns:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');   # valid
```

If a waiting Response receives `body(...)` later from an asynchronous event
callback, the complete response is committed immediately.

For a body produced over time, obtain the Response's stable body stream:

```perl
my $body = $res->stream_body(
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

Creating `stream_body()` does not start output or freeze Response metadata. The
first `write()` or `complete()` on the body stream commits the response head.
After that, status and headers are immutable.

A Response has either a scalar body or a streaming body, never both.

### Backpressure

`Body::Stream->write(...)` feeds HTTP-framed bytes into Linux::Event's existing
ordered-byte output machinery. Linux::Event remains the only output queue.

The return value preserves the Linux::Event flow-control contract:

```text
true  = bytes accepted and the producer may continue
false = bytes accepted, but stop producing until on_drain
```

`on_cancel` runs if the HTTP connection abandons an unfinished streaming body.

## Response completion is not socket shutdown

`Response->is_complete` describes the HTTP message lifecycle. Completing a body
does not normally close the TCP/TLS connection. HTTP/1.1 keep-alive can carry
later requests on the same connection.

There is deliberately no Response `end` method. Transport shutdown remains a
Linux::Event stream concept rather than an HTTP Response concept.

## Request bodies

Request heads are dispatched as soon as they are validated. Request bodies are
streaming-first:

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

The protocol layer chooses the correct HTTP/1 framing from the Response and
request semantics:

- complete scalar bodies normally use Content-Length;
- streaming HTTP/1.1 bodies without Content-Length use chunked transfer coding;
- streaming HTTP/1.0 bodies with unknown length are close-delimited;
- declared Content-Length is enforced;
- HEAD and body-forbidden status semantics are enforced by the protocol layer.

The first actual stream output is the commit point for a streaming Response.

## Connection subclasses

Most programs can use constructor callbacks only. A custom
`Linux::Event::HTTP::Server::Connection` subclass is the advanced extension
point for reusable transport policy, TLS, stream tuning, socket policy, or named
callbacks:

```perl
package MyHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';

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

## TLS

HTTPS uses the same HTTP classes. TLS remains Linux::Event transport policy:

```perl
package SecureHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';
use Linux::Event::TLS
    cert_file => '/etc/myapp/server-cert.pem',
    key_file  => '/etc/myapp/server-key.pem',
    alpn      => ['http/1.1'];

sub on_request ($self, $req, $res) {
    $res->body("secure\n");
}
```

The TLS handshake completes before HTTP request dispatch. Negotiated ALPN,
protocol, and cipher remain available through the Linux::Event connection.

## Upgrade

HTTP Upgrade is a protocol handoff on the same live transport:

```perl
$res->header('Upgrade', 'my-protocol');
$res->upgrade('MyProtocolConnection');
```

Linux::Event::HTTP validates the HTTP/1.1 Upgrade, queues the 101 response, and
uses Linux::Event `transition_to()` to hand the same stream object to the target
protocol class. Socket identity, TLS state, queued output, and already-read
post-HTTP bytes are preserved.

WebSocket framing belongs in a separate `Linux::Event::WebSocket` distribution.

## Public server modules

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Body::Stream
```

Future native client support is reserved for:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented yet.

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
response-streaming, and distribution-integrity coverage.

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
