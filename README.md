# Linux::Event::HTTP

HTTP protocol support for [Linux::Event](https://github.com/haxmeister/perl-linux-event).

## Status

Early development. The current implementation focuses on HTTP/1.1 server
support.

This distribution follows the Linux::Event ecosystem charter: protocol layers
prioritize correctness, ease of correct use, a clear API, maintainability,
composability, and then good performance. Linux::Event core remains the place
for aggressive reusable performance work.

Linux::Event::HTTP is a communications library, not a web framework. It does
not provide routing frameworks, templates, controllers, ORMs, or an application
architecture.

## Simple server

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;

my $loop = Linux::Event::Loop->new;

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,
    on_request => sub ($connection, $request, $response) {
        $response->header('Content-Type', 'text/plain');
        $response->end("hello\n");
    },
);

$loop->run;
```

`Linux::Event::HTTP::Server` is a small convenience over
`Linux::Event::IO::Sock::Listener`. A reusable connection subclass remains
available when an application wants declarative socket, TLS, tuning, or callback
policy:

```perl
package MyHTTP;
use parent 'Linux::Event::HTTP::Connection';

sub on_request ($self, $request, $response) {
    $response->status(200);
    $response->header('Content-Type', 'text/plain');
    $response->end("hello\n");
}

package main;

my $server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    host             => '127.0.0.1',
    port             => 8080,
    connection_class => 'MyHTTP',
);
```

## Request bodies

Request input is streaming-first. `on_request` receives the request head and its
paired response object. Optional `on_body` callbacks receive body bytes, and
`on_request_end` marks the complete request boundary.

```perl
sub on_body ($self, $request, $response, $bytes) {
    process_bytes($bytes);
}

sub on_request_end ($self, $request, $response) {
    $response->end("done\n");
}
```

If no body callback is installed, the protocol engine drains the body so message
framing and keep-alive remain correct without forcing whole-body accumulation.

## Response streaming

The same Response object handles complete and streamed replies:

```perl
sub on_request ($self, $request, $response) {
    $response->header('Content-Type', 'text/plain');
    $response->write("one\n");
    $response->write("two\n");
    $response->end("three\n");
}
```

HTTP/1.1 transfer framing is selected by the protocol layer. Applications should
not have to manage chunk syntax themselves.

## TLS

HTTPS uses the same HTTP classes. TLS remains transport policy supplied by
Linux::Event:

```perl
package SecureHTTP;
use parent 'Linux::Event::HTTP::Connection';
use Linux::Event::TLS
    cert_file => '/etc/myapp/server-cert.pem',
    key_file  => '/etc/myapp/server-key.pem',
    alpn      => ['http/1.1'];

sub on_request ($self, $request, $response) {
    $response->end("secure\n");
}
```

HTTP parsing sees decrypted application bytes after the Linux::Event TLS
handshake. The HTTP distribution does not create a separate HTTPS object model.

## Protocol handoff

HTTP Upgrade is a bridge to another communication protocol, not an excuse to
fold that protocol into this distribution. A validated upgrade can transfer the
same live Linux::Event stream to another compatible protocol class while
preserving the transport and already-read bytes.

This is the intended boundary for distributions such as
`Linux::Event::WebSocket`.

## Implementation policy

The public API belongs to Linux::Event::HTTP. Internal parsers, serializers, and
other third-party libraries are implementation details. Applications should not
need to change merely because an implementation dependency changes.

The current HTTP/1 request parser uses vendored picohttpparser plus additional
HTTP framing and security validation. Its continued use is evaluated under the
same ecosystem policy as any other dependency: correctness and API fit come
before small benchmark differences.

Protocol-specific benchmark shortcuts are not part of the supported public API.
When a realistic workload exposes a material bottleneck, the first question is
whether the improvement belongs in a reusable Linux::Event primitive instead.

See [docs/PROJECT-POLICY.md](docs/PROJECT-POLICY.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and
[docs/HTTP1-PARSER.md](docs/HTTP1-PARSER.md).

## Benchmarking

Competitive and exploratory server benchmarking lives in the separate
[perl-Benchmark-Web](https://github.com/haxmeister/perl-Benchmark-Web)
repository. This repository keeps correctness and regression tests focused on
the HTTP protocol library itself.

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
