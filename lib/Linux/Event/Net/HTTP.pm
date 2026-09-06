package Linux::Event::Net::HTTP;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP - native high-performance HTTP protocol support for Linux::Event

=head1 VERSION

Version 0.001

=head1 DESCRIPTION

Linux::Event::Net::HTTP is an HTTP protocol distribution built on
L<Linux::Event>. It is intentionally a protocol layer rather than a web
framework.

The initial implementation targets HTTP/1.1 while keeping application-facing
request and response concepts separate from HTTP/1-specific wire details.

=head1 DESIGN

See F<docs/ARCHITECTURE.md> for the current design constraints and development
plan.

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.

=cut
