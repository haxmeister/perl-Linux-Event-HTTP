package Linux::Event::HTTP;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::HTTP - native high-performance HTTP protocol support for Linux::Event

=head1 VERSION

Version 0.001

=head1 DESCRIPTION

Linux::Event::HTTP is an HTTP protocol distribution built on
L<Linux::Event>. It is intentionally a protocol layer rather than a web
framework.

The initial implementation targets HTTP/1.1 while keeping application-facing
request and response concepts separate from HTTP/1-specific wire details.

HTTP/1 request-head parsing uses picohttpparser. Its source is vendored in this
distribution at a recorded upstream revision, so configuration, building,
installation, and runtime do not depend on the upstream repository or a network
fetch.

Parsed request metadata remains in native state. Method, target, and header
strings are materialized as Perl scalars only when application code requests
them. This preserves substantially more of the native parser's performance than
eagerly constructing Perl structures for every parsed field.

=head1 DESIGN

See F<docs/ARCHITECTURE.md> for the current design constraints and development
plan. F<docs/PICOHTTPPARSER-EXPERIMENT.md> records the parser provenance,
correctness policy, and representation benchmarks.

=head1 THIRD-PARTY CODE

The distribution includes picohttpparser by Kazuho Oku and contributors. The
vendored source and upstream license are under F<vendor/picohttpparser/>.

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
