package Linux::Event::Net::HTTP::Response;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Response - HTTP response representation

=head1 DESCRIPTION

This module reserves the application-facing HTTP response representation.
Response serialization and body streaming belong to the HTTP protocol layer,
while transport buffering and backpressure remain Linux::Event concerns.

=cut
