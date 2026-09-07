# Linux::Event::HTTP

HTTP protocol support for [Linux::Event](https://github.com/haxmeister/perl-linux-event).

## Status

Early development. The current implementation provides HTTP/1.1 server support.

Linux::Event::HTTP is a protocol layer, not a web framework. Routing,
middleware, sessions, templates, and PSGI/PAGI integration belong elsewhere.

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
        $res->header('Content-Type', 'text/plain');
        $res->complete("hello\n");
    },
);

$loop->run;
```

That is the normal server API.

The callback receives three objects:

- `$conn` is the persistent HTTP connection.
- `$req` is the current request.
- `$res` is the response for that request.

`$res->complete(...)` completes **that HTTP response**. It does not mean close
the socket. With normal HTTP/1.1 keep-alive, the same connection can carry more
requests after the response is complete.

## Requests

Request metadata is available from `$req`:

```perl
my $method = $req->method;
my $target = $req->target;
my $host   = $req->header('Host');
```

Useful methods include:

```text
method
target
http_version
header
header_values
body_mode
content_length
keep_alive
```

Header names are matched case-insensitively without rewriting the original wire
names.

## Responses

Set response metadata before output begins:

```perl
$res->status(404);
$res->header('Content-Type', 'text/plain');
$res->complete("Not found\n");
```

For a simple response, `complete($bytes)` sends the optional final body bytes and
marks the HTTP response complete.

For streaming output, use `write` and then `complete`:

```perl
$res->header('Content-Type', 'text/plain');
$res->write("one\n");
$res->write("two\n");
$res->complete;
```

`write($bytes)` means body bytes are being written. `complete()` means no more
bytes belong to this HTTP response. It normally does **not** close the
connection.

HTTP/1.1 automatically uses chunked transfer coding for streaming responses
when no Content-Length was declared. If Content-Length is declared, the emitted
body length must match it.

## Request bodies

Request bodies are streaming-first. `on_request` runs after the validated
request head is available. Body bytes can arrive afterward through `on_body`.
`on_request_end` runs when the complete request input boundary has been consumed.

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8080,
    data => { body => '' },

    on_request => sub ($conn, $req, $res) {
        $conn->data->{body} = '';
    },

    on_body => sub ($conn, $req, $res, $bytes) {
        $conn->data->{body} .= $bytes;
    },

    on_request_end => sub ($conn, $req, $res) {
        $res->complete("received " . length($conn->data->{body}) . " bytes\n");
    },
);
```

If no `on_body` callback is installed, the protocol layer drains the request
body without accumulating it into a whole-body scalar.

## Connection subclasses

Most applications can stay with the callback form above.

Subclass `Linux::Event::HTTP::Server::Connection` when reusable connection
policy belongs on a class, such as TLS, stream tuning, socket policy, or named
callback methods:

```perl
package MyHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';

sub on_request ($self, $req, $res) {
    $res->complete("hello\n");
}

package main;

my $server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    port             => 8080,
    connection_class => 'MyHTTP',
);
```

This is an advanced extension point, not a separate competing server API.

## HTTPS

HTTPS uses the same HTTP Server API. TLS remains Linux::Event transport policy
on the Connection subclass:

```perl
package SecureHTTP;
use parent 'Linux::Event::HTTP::Server::Connection';
use Linux::Event::TLS
    cert_file => '/etc/myapp/server-cert.pem',
    key_file  => '/etc/myapp/server-key.pem',
    alpn      => ['http/1.1'];

sub on_request ($self, $req, $res) {
    $res->complete("secure\n");
}
```

## Protocol Upgrade

HTTP/1.1 Upgrade can hand the same live Linux::Event stream to another protocol
class:

```perl
$res->header('Upgrade', 'my-protocol');
$res->upgrade('MyProtocolConnection');
```

HTTP owns validation and the `101 Switching Protocols` transaction. The target
protocol owns everything after the handoff. This is the intended boundary for a
separate `Linux::Event::WebSocket` distribution.

## Public modules

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
```

Native client support is planned under:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

It is not implemented yet.

## More detail

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes protocol and transport boundaries.
- [docs/BENCHMARKING.md](docs/BENCHMARKING.md) describes the benchmark contract.
- [docs/PICOHTTPPARSER-EXPERIMENT.md](docs/PICOHTTPPARSER-EXPERIMENT.md) records parser provenance and measurements.
- Module POD documents the complete public methods and advanced behavior.

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
