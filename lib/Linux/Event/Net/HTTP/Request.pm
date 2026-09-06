package Linux::Event::Net::HTTP::Request;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Request - HTTP request representation

=head1 DESCRIPTION

This module reserves the application-facing HTTP request representation.
Request semantics should not expose HTTP/1-specific parser state unless the
wire protocol requires it.

Bodies are fundamentally streamed by the protocol layer. Any eventual scalar
body convenience API must be layered on top of that streaming primitive.

=cut
