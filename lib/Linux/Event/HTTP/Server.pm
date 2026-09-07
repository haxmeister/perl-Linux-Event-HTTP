package Linux::Event::HTTP::Server;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Net::HTTP::Server';
use Linux::Event::HTTP::Connection ();

our $VERSION = '0.001';

sub new ($class, %option) {
    $option{connection_class} //= 'Linux::Event::HTTP::Connection';
    return $class->SUPER::new(%option);
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Server - HTTP server endpoint convenience

=head1 SYNOPSIS

    use v5.36;
    use Linux::Event::Loop;
    use Linux::Event::HTTP::Server;

    my $loop = Linux::Event::Loop->new;

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 8080,
        on_request => sub ($connection, $request, $response) {
            $response->header('Content-Type', 'text/plain');
            $response->end("hello\n");
        },
    );

    $loop->run;

=head1 DESCRIPTION

Server is a convenience around L<Linux::Event::IO::Sock::Listener>. It accepts
HTTP connections without introducing a web framework or prescribing application
architecture.

C<connection_class> defaults to L<Linux::Event::HTTP::Connection> and may name a
subclass for reusable socket, TLS, tuning, and callback policy.

=head1 METHODS

The server exposes its underlying listener and the ordinary listener lifecycle
operations C<pause>, C<resume>, and C<close>. Listener address and state
accessors are delegated to Linux::Event.

=head1 SEE ALSO

L<Linux::Event::HTTP>, L<Linux::Event::HTTP::Connection>,
L<Linux::Event::IO::Sock::Listener>.

=cut
