# Linux::Event::Net::HTTP

Native high-performance HTTP protocol support for [Linux::Event](https://github.com/haxmeister/perl-linux-event).

## Status

Early development. The initial target is HTTP/1.1 server protocol support.

This distribution is intended to provide the HTTP protocol layer, not a web
framework. Linux::Event remains responsible for transport, TLS, buffering,
backpressure, deadlines, and event dispatch.

A server connection uses the same subclass/cached-callback model as
Linux::Event itself. Each validated request is paired with a Response created by
the protocol engine:

```perl
package HelloHTTP;
use parent 'Linux::Event::Net::HTTP::Connection';

sub on_request ($connection, $request, $response) {
    $response->status(200);
    $response->header('Content-Type', 'text/plain');
    $response->end("hello\n");
}
```

Applications use the Response object but do not construct it or pass it back to
the Connection. A response may also be retained and completed from a later
event.

Request bodies are streaming-first. Fixed-length and chunked bodies are
delivered without whole-request accumulation:

```perl
sub on_body ($connection, $request, $response, $bytes) {
    process_bytes($bytes);
}

sub on_body_end ($connection, $request, $response) {
    $response->end("done\n");
}
```

If no `on_body` callback is installed, the protocol engine drains the body so
framing and keep-alive remain correct without building an unused body scalar.

HTTP/1 request-head parsing and chunked request decoding use
[picohttpparser](https://github.com/h2o/picohttpparser), vendored directly in
this distribution at a recorded upstream revision. Builds and installations do
not depend on the upstream repository or any network fetch.
Linux::Event::Net::HTTP keeps parsed request metadata in native state and
materializes Perl strings only when application code asks for them.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design constraints and
[docs/PICOHTTPPARSER-EXPERIMENT.md](docs/PICOHTTPPARSER-EXPERIMENT.md) for parser
provenance, design details, and benchmark results.

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
