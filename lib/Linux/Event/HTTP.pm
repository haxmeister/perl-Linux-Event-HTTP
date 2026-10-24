package Linux::Event::HTTP;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.003';

1;

__END__

=head1 NAME

Linux::Event::HTTP - Linux-native integration of Unblock HTTP

=head1 SYNOPSIS

    use Linux::Event::Loop;
    use Linux::Event::HTTP::Server;

    my $loop = Linux::Event::Loop->new;
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop, port => 8080,
        on_request => sub ($tx, $request) {
            $tx->respond(status => 200, body => "Hello\n");
        },
    );
    $loop->run;

=head1 DESCRIPTION

This development branch reconstructs the distribution around Unblock::HTTP.
Server and Client currently support HTTP/1 over TCP/TLS. They expose real
Unblock transactions and Uniform messages. Linux::Event owns sockets, TLS,
timers and backpressure; Unblock owns protocol behavior and client pooling.

No compatibility with the former public API is promised. HTTP/2, HTTP/3,
WebSocket and generic Upgrade/CONNECT remain planned. HTTP/1 server shutdown
drains admitted requests and enforces a seconds-based grace deadline.
The native HTTP/1 input bridge is implemented, but the original server's
performance has not yet been recovered. This is not a release candidate.

See L<Linux::Event::HTTP::Server>, L<Linux::Event::HTTP::Client> and the
repository's F<docs/UNBLOCK-REBUILD-STATUS.md> for current implementation and
verification. No web framework or user-agent policy is provided.

=cut
