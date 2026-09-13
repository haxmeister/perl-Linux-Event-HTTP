package Linux::Event::HTTP;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::HTTP - native HTTP protocol support for Linux::Event

=head1 VERSION

Version 0.001

=head1 DESCRIPTION

Linux::Event::HTTP is an HTTP communications layer built on L<Linux::Event>.
It provides native event-driven HTTP server and client APIs while deliberately
remaining a protocol layer rather than a web framework.

The public model separates HTTP messages from exchange and transport lifecycle:

=over 4

=item * L<Linux::Event::HTTP::Request> and L<Linux::Event::HTTP::Response>
represent endpoint-neutral HTTP messages.

=item * L<Linux::Event::HTTP::Transaction> represents exactly one
Request/Response exchange.

=item * L<Linux::Event::HTTP::Server> and
L<Linux::Event::HTTP::Server::Connection> execute inbound HTTP.

=item * L<Linux::Event::HTTP::Client> and
L<Linux::Event::HTTP::Client::Connection> execute outbound HTTP.

=back

Linux::Event continues to own sockets, TLS, readiness, buffering, backpressure,
connection acquisition, and ordered byte output.

The initial protocol executor targets HTTP/1.x. Server request-head parsing uses
vendored picohttpparser with lazy native Request state. The first client
response-head parser is deliberately strict Perl code so correctness and actual
workload cost can be measured before adding more HTTP-specific XS. The existing
native chunked decoder is shared by client and server.

Incoming bodies are incremental-first and are not implicitly accumulated into
unbounded whole-body scalars. Complete scalar message bodies remain available as
a convenience when the application already owns all bytes. Outgoing incremental
Client Request and Server Response bodies use Transaction-owned
L<Linux::Event::HTTP::Body::Stream> producers and Linux::Event's existing
ordered-byte backpressure machinery rather than a second HTTP output queue.

=head1 DESIGN

See F<README.md> for ordinary Client and Server examples and
F<docs/ARCHITECTURE.md> for ownership, lifecycle, framing, pooling, and native
boundary details. F<docs/PICOHTTPPARSER-EXPERIMENT.md> records server parser
provenance, correctness policy, and representation benchmarks.

=head1 THIRD-PARTY CODE

The distribution includes picohttpparser by Kazuho Oku and contributors. The
vendored source and upstream license are under F<vendor/picohttpparser/>.

The high-level Client uses the established L<URI> distribution for URL parsing;
full URLs remain Client destination policy rather than Request message state.

=head1 SECURITY

Security vulnerabilities should not be reported through the public issue
tracker. See F<SECURITY.md> for private reporting instructions.

=head1 AUTHOR

Joshua S. Day E<lt>hax@cpan.orgE<gt>

=head1 LICENSE

Copyright (C) 2026 Joshua S. Day.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.

The vendored picohttpparser source retains its upstream license in
F<vendor/picohttpparser/LICENSE>.

=cut
