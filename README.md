# Linux::Event::Net::HTTP

Native high-performance HTTP protocol support for [Linux::Event](https://github.com/haxmeister/perl-linux-event).

## Status

Early development. The initial target is HTTP/1.1 server protocol support.

This distribution is intended to provide the HTTP protocol layer, not a web
framework. Linux::Event remains responsible for transport, TLS, buffering,
backpressure, deadlines, and event dispatch.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design constraints and
initial implementation order.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please do not report security vulnerabilities through public issues. See
[SECURITY.md](SECURITY.md) for private reporting instructions.

## License

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.
