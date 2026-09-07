# Linux::Event::HTTP

Native high-performance HTTP protocol support for [Linux::Event](https://github.com/haxmeister/perl-linux-event).

## Status

Early development. The initial target is HTTP/1.1 server protocol support.

This distribution is intended to provide the HTTP protocol layer, not a web
framework. Linux::Event remains responsible for transport, TLS, buffering,
backpressure, deadlines, and event dispatch.

The simplest server form hides Listener plumbing while retaining the same
cached callback model used by Linux::Event:

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
        $res->header('Content-Type', 'text/plain');
        $res->end("hello\n");
    },
);

$loop->run;
```

`HTTP::Server` is a thin convenience over `Linux::Event::IO::Sock::Listener`.
It retains one callback CV and reuses it for accepted HTTP connections; it does
not create a wrapper closure per connection or add another per-request dispatch
layer.

Scalar `Response->end(...)` is also the complete-response path for simple
bodyless requests. Eligible default scalar responses may use a private native
finalization path internally; applications use the same `on_request`/`Response`
API whether that optimization applies or not.

A Connection subclass remains the declarative form for reusable protocol,
tuning, socket, and TLS policy:

```perl
package HelloHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';

sub on_request ($self, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->end("hello\n");
}

package main;

my $server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    host             => '127.0.0.1',
    port             => 8080,
    connection_class => 'HelloHTTP',
);
```

HTTPS uses the same HTTP classes. TLS remains Linux::Event transport policy on
the accepted Connection subclass rather than a separate HTTPS protocol class:

```perl
package SecureHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';
use Linux::Event::TLS
    cert_file => '/etc/myapp/server-cert.pem',
    key_file  => '/etc/myapp/server-key.pem',
    alpn      => ['http/1.1'];

sub on_request ($self, $req, $res) {
    $res->end("secure\n");
}

package main;

my $server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    host             => '0.0.0.0',
    port             => 443,
    connection_class => 'SecureHTTP',
);
```

Accepted TLS Connections use Linux::Event server-handshake semantics
automatically. `on_ready` fires after the TLS handshake, and HTTP parsing sees
only decrypted application bytes. The Connection can inspect negotiated
`selected_alpn`, `tls_protocol`, and `tls_cipher` through Linux::Event.

HTTP Upgrade hands the same live stream socket to another Linux::Event protocol
class. HTTP performs the switching response and transport handoff; the target
protocol remains a separate distribution or application class:

```perl
sub on_request ($self, $req, $res) {
    return $res->end("not an upgrade\n")
        if ($req->header('Upgrade') // '') ne 'my-protocol';

    $res->header('Upgrade', 'my-protocol');
    $res->upgrade('MyProtocolConnection');
}
```

`upgrade()` sends a validated HTTP/1.1 `101 Switching Protocols` response and
uses Linux::Event `transition_to()` after the HTTP request lifecycle has
finished. The target retains the same socket, TLS transport, output queue,
backpressure, deadlines, and application data. Bytes already read after the HTTP
request head are preserved and become the target protocol's first input. This
is the boundary intended for a separate `Linux::Event::WebSocket`
distribution.

Applications use the Response object but do not construct it or pass it back to
the Connection. Response is the writable handle for a server transaction and may
be retained and completed from a later event.

Streaming response output uses the same `write`/`end` shape. HTTP/1.1 adds
chunked transfer coding automatically when no Content-Length was declared:

```perl
sub on_request ($self, $req, $res) {
    $res->header('Content-Type', 'text/plain');
    $res->write("one\n");
    $res->write("two\n");
    $res->end("three\n");
}
```

Request bodies are also streaming-first. Fixed-length and chunked bodies are
delivered without whole-request accumulation:

```perl
sub on_body ($self, $req, $res, $bytes) {
    process_bytes($bytes);
}

sub on_request_end ($self, $req, $res) {
    $res->end("done\n");
}
```

If no `on_body` callback is installed, the protocol engine drains the body so
framing and keep-alive remain correct without building an unused body scalar.
`on_request_end` runs once when the complete request input boundary has been
consumed, including for requests with no body.

HTTP/1 request-head parsing and chunked request decoding use
[picohttpparser](https://github.com/h2o/picohttpparser), vendored directly in
this distribution at a recorded upstream revision. Builds and installations do
not depend on the upstream repository or any network fetch.
Linux::Event::HTTP keeps parsed request metadata in native state and
materializes Perl strings only when application code asks for them.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design constraints,
[docs/BENCHMARKING.md](docs/BENCHMARKING.md) for the end-to-end benchmark and
profiling contract, and
[docs/PICOHTTPPARSER-EXPERIMENT.md](docs/PICOHTTPPARSER-EXPERIMENT.md) for parser
provenance, design details, and parser microbenchmark results.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please do not report security vulnerabilities through public issues. See
[SECURITY.md](SECURITY.md) for private reporting instructions.

## License

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.

The vendored picohttpparser source retains its upstream license in
`vendor/picohttpparser/LICENSE`.
