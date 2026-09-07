package Linux::Event::HTTP::Server;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Net::HTTP::Server';

use Carp qw(croak);
use Linux::Event::HTTP::Connection ();

our $VERSION = '0.001';

sub _load_public_connection_class ($class) {
    croak 'new(): connection_class must be a package name'
        if !defined($class) || ref($class)
        || $class !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    if (!$class->can('new')) {
        (my $file = "$class.pm") =~ s{::}{/}g;
        require $file;
    }

    croak 'new(): connection_class must inherit Linux::Event::HTTP::Connection'
        if !$class->isa('Linux::Event::HTTP::Connection');
    croak 'new(): on_request_final is not part of the Linux::Event::HTTP public API; use on_request and Response'
        if $class->can('on_request_final');

    return $class;
}

sub new ($class, %option) {
    croak 'new(): on_request_final is not part of the Linux::Event::HTTP public API; use on_request and Response'
        if exists $option{on_request_final};

    my $connection_class = _load_public_connection_class(
        $option{connection_class} // 'Linux::Event::HTTP::Connection',
    );
    $option{connection_class} = $connection_class;

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

C<connection_class> defaults to L<Linux::Event::HTTP::Connection> and must name
one of its subclasses. This keeps the supported HTTP namespace coherent while
the older Net-prefixed engine is removed internally.

The supported response path is the ordinary C<on_request> callback with its
paired L<Linux::Event::HTTP::Response>. Benchmark-specific final-response
callbacks are not part of this public API.

=head1 METHODS

The server exposes its underlying listener and the ordinary listener lifecycle
operations C<pause>, C<resume>, and C<close>. Listener address and state
accessors are delegated to Linux::Event.

=head1 SEE ALSO

L<Linux::Event::HTTP>, L<Linux::Event::HTTP::Connection>,
L<Linux::Event::IO::Sock::Listener>.

=cut
