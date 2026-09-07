package Linux::Event::HTTP::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Net::HTTP::Connection';

use Linux::Event::HTTP::Request ();
use Linux::Event::HTTP::Response ();

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::HTTP::Connection - HTTP connection over Linux::Event streams

=head1 SYNOPSIS

    package MyHTTP;
    use parent 'Linux::Event::HTTP::Connection';

    sub on_request ($self, $request, $response) {
        $response->header('Content-Type', 'text/plain');
        $response->end("hello\n");
    }

=head1 DESCRIPTION

Connection owns the HTTP protocol state for one accepted stream. Linux::Event
continues to own the transport, buffering, backpressure, deadlines, TLS, and
event dispatch below it.

The supported application callback is C<on_request>. Optional C<on_body> and
C<on_request_end> callbacks provide streaming request-body handling. Response
output is written through the paired L<Linux::Event::HTTP::Response> object.

Protocol-specific benchmark shortcuts are not part of the supported public API.
If realistic workloads expose a material bottleneck, optimization should first
be considered in reusable Linux::Event primitives.

=head1 SEE ALSO

L<Linux::Event::HTTP>, L<Linux::Event::HTTP::Server>,
L<Linux::Event::HTTP::Request>, L<Linux::Event::HTTP::Response>.

=cut
