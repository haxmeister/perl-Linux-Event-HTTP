package Linux::Event::Net::HTTP::Connection;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Connection - HTTP connection protocol state

=head1 DESCRIPTION

This module reserves the connection layer that will bind HTTP protocol state to
a L<Linux::Event> byte stream. Transport ownership, buffering, backpressure,
TLS, and readiness remain Linux::Event responsibilities.

=cut
