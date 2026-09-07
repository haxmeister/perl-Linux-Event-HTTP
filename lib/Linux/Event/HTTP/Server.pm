package Linux::Event::HTTP::Server;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

use Linux::Event::IO::Sock::Listener;
use Linux::Event::HTTP::Server::Connection;
use Linux::Event::HTTP::_ServerConnection ();

our $VERSION = '0.001';

my $ADAPTER = 'Linux::Event::HTTP::_ServerConnection';

sub _load_connection_class ($class) {
    croak 'new(): connection_class must be a package name'
        if !defined($class) || ref($class)
        || $class !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    if (!$class->can('new')) {
        (my $file = "$class.pm") =~ s{::}{/}g;
        require $file;
    }

    croak 'new(): connection_class must inherit Linux::Event::HTTP::Server::Connection'
        if !$class->isa('Linux::Event::HTTP::Server::Connection');
    croak 'new(): connection_class cannot name the private Server adapter'
        if $class eq $ADAPTER;

    $class->_validate_accepted_configuration;
    return $class;
}

sub _take_callback ($name, $option) {
    return undef if !exists $option->{$name};
    my $callback = delete $option->{$name};
    croak "new(): $name must be a coderef" if ref($callback) ne 'CODE';
    return $callback;
}

sub new ($class, %option) {
    croak 'new(): stream_class is internal; use connection_class'
        if exists $option{stream_class};
    croak 'new(): HTTP Server owns on_data; use on_request/on_body callbacks'
        if exists $option{on_data};
    croak 'new(): HTTP Server cannot use message framing callbacks'
        if exists($option{on_message}) || exists($option{on_messages});
    croak 'new(): on_request_final was removed; use on_request and Response->complete'
        if exists $option{on_request_final};

    my $connection_class = _load_connection_class(
        delete($option{connection_class})
            // 'Linux::Event::HTTP::Server::Connection',
    );

    my %callbacks;
    for my $name (qw(on_request on_body on_request_end)) {
        my $callback = _take_callback($name, \%option);
        $callbacks{$name} = $callback if $callback;
    }

    croak 'new(): HTTP Server requires on_request callback or connection_class method'
        if !$callbacks{on_request} && !$connection_class->can('on_request');

    my $data = delete $option{data};
    my $state = {
        _http_server_state => 1,
        connection_class   => $connection_class,
        callbacks          => \%callbacks,
        data               => $data,
    };

    my $listener = Linux::Event::IO::Sock::Listener->new(
        %option,
        stream_class => $ADAPTER,
        data         => $state,
    );

    return bless {
        listener         => $listener,
        connection_class => $connection_class,
        data             => $data,
        state            => $state,
    }, $class;
}

sub listener         ($self) { $self->{listener} }
sub connection_class ($self) { $self->{connection_class} }
sub data             ($self) { $self->{data} }
sub loop             ($self) { $self->{listener}->loop }
sub fh               ($self) { $self->{listener}->fh }
sub fd               ($self) { $self->{listener}->fd }
sub host             ($self) { $self->{listener}->host }
sub port             ($self) { $self->{listener}->port }
sub path             ($self) { $self->{listener}->path }
sub family           ($self) { $self->{listener}->family }
sub family_number    ($self) { $self->{listener}->family_number }
sub is_tcp           ($self) { $self->{listener}->is_tcp }
sub is_unix          ($self) { $self->{listener}->is_unix }
sub state            ($self) { $self->{listener}->state }

sub pause ($self) {
    $self->{listener}->pause;
    return $self;
}

sub resume ($self) {
    $self->{listener}->resume;
    return $self;
}

sub close ($self) {
    $self->{listener}->close;
    return $self;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Server - HTTP server endpoint

=head1 SYNOPSIS

    use v5.36;
    use Linux::Event::Loop;
    use Linux::Event::HTTP::Server;

    my $loop = Linux::Event::Loop->new;

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 8080,
        on_request => sub ($conn, $req, $res) {
            $res->header('Content-Type', 'text/plain');
            $res->complete("hello\n");
        },
    );

    $loop->run;

=head1 DESCRIPTION

C<Linux::Event::HTTP::Server> is the ordinary entry point for an HTTP server.
It listens using Linux::Event and invokes C<on_request> whenever a validated
request head is available.

The callback receives:

=over 4

=item * C<$conn> - the persistent HTTP connection

=item * C<$req> - the current L<Linux::Event::HTTP::Request>

=item * C<$res> - the L<Linux::Event::HTTP::Response> for that request

=back

Completing a Response does not normally close the connection. HTTP keep-alive
may reuse the same connection for later requests.

=head1 REQUEST BODIES

Request bodies are streaming-first. Add C<on_body> when body bytes are needed,
and C<on_request_end> when work should happen after the complete request input
has arrived:

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        port => 8080,

        on_request => sub ($conn, $req, $res) {
            $conn->data->{body} = '';
        },

        on_body => sub ($conn, $req, $res, $bytes) {
            $conn->data->{body} .= $bytes;
        },

        on_request_end => sub ($conn, $req, $res) {
            $res->complete("received\n");
        },
    );

If C<on_body> is absent, the server drains request-body bytes without building a
whole-body scalar.

=head1 CONNECTION SUBCLASSES

Most applications do not need to subclass the HTTP connection. Use
C<connection_class> when reusable TLS, stream tuning, socket policy, or callback
methods belong on a class:

    package MyHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $req, $res) {
        $res->complete("hello\n");
    }

    package main;

    my $server = Linux::Event::HTTP::Server->new(
        loop             => $loop,
        port             => 8080,
        connection_class => 'MyHTTP',
    );

C<connection_class> defaults to
L<Linux::Event::HTTP::Server::Connection>.

=head1 TLS

HTTPS uses the same Server API. TLS remains Linux::Event transport policy on a
Connection subclass:

    package SecureHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';
    use Linux::Event::TLS
        cert_file => '/etc/myapp/server-cert.pem',
        key_file  => '/etc/myapp/server-key.pem',
        alpn      => ['http/1.1'];

    sub on_request ($self, $req, $res) {
        $res->complete("secure\n");
    }

=head1 METHODS

=head2 listener

Returns the underlying L<Linux::Event::IO::Sock::Listener> for advanced use.

=head2 connection_class

Returns the configured HTTP Connection class name.

=head2 data

Returns the application data supplied to the Server.

=head2 loop, fh, fd, host, port, path, family, family_number, is_tcp, is_unix, state

Delegate to the underlying Listener.

=head2 pause

Pauses acceptance and returns the Server.

=head2 resume

Resumes acceptance and returns the Server.

=head2 close

Closes the listening endpoint and returns the Server. Existing accepted HTTP
connections keep their independent lifecycles.

=head1 SEE ALSO

L<Linux::Event::HTTP::Server::Connection>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::TLS>.

=cut
