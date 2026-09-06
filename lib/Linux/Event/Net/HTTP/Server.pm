package Linux::Event::Net::HTTP::Server;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Server - HTTP server endpoint

=head1 DESCRIPTION

This module reserves the public server namespace for the HTTP protocol layer.
The server API will remain small and will delegate transport behavior to
L<Linux::Event> rather than duplicating listener or socket policy.

=cut
