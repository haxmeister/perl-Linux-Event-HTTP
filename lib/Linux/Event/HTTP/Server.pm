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
    croak 'new(): on_request_final was removed; use on_request and Response->end'
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
        on_request => sub ($conn, $req, $res) {
            $res->header('Content-Type', 'text/plain');
            $res->end("hello\n");
        },
    );

    $loop->run;

=head1 DESCRIPTION

C<Linux::Event::HTTP::Server> is a small convenience layer around
L<Linux::Event::IO::Sock::Listener>. It owns no socket or HTTP transport engine
of its own. The Listener accepts connections and the configured
L<Linux::Event::HTTP::Server::Connection> subclass owns each HTTP connection.

The callback form retains each configured CV once and reuses it for every
accepted Connection. No wrapper closure is created per connection and no extra
Server dispatch is inserted into the per-request callback path.

The object relationship is:

    HTTP::Server
        -> Linux::Event::IO::Sock::Listener
            -> HTTP::Server::Connection
                -> Request + Response

=head1 CONSTRUCTION

=head2 Callback form

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '0.0.0.0',
        port => 8080,
        data => $application_state,
        on_request => sub ($conn, $req, $res) {
            $res->end("ok\n");
        },
    );

C<on_request> is required unless C<connection_class> provides an
C<on_request> method. Optional C<on_body> and C<on_request_end> callbacks use
the same signatures and semantics as L<Linux::Event::HTTP::Server::Connection>
and are retained once by the Server.

C<data> becomes the C<data> value of each accepted HTTP Connection. The private
Server acceptance state is not exposed through C<< $conn->data >>.

=head2 Connection subclass form

    package MyHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $req, $res) {
        $res->end("hello\n");
    }

    package main;

    my $server = Linux::Event::HTTP::Server->new(
        loop             => $loop,
        host             => '127.0.0.1',
        port             => 8080,
        connection_class => 'MyHTTP',
    );

C<connection_class> defaults to L<Linux::Event::HTTP::Server::Connection> and must
name one of its subclasses. Constructor callbacks may still be supplied; as on
direct Connection construction, they override same-named class methods for
accepted instances.

The configured class continues to own C<stream_options>, socket policy, TLS,
and other Connection subclass policy. Server validates that accepted-connection
policy when it is constructed, then leaves the policy on the Connection class
rather than copying settings into the Server object.

=head1 TLS

HTTPS uses the same Server and Connection classes. Declare TLS on the configured
Connection subclass using L<Linux::Event::TLS>:

    package SecureHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';
    use Linux::Event::TLS
        cert_file => '/etc/myapp/server-cert.pem',
        key_file  => '/etc/myapp/server-key.pem',
        alpn      => ['http/1.1'];

    sub on_request ($self, $req, $res) {
        $res->end("secure\n");
    }

    package main;

    my $server = Linux::Event::HTTP::Server->new(
        loop             => $loop,
        host             => '0.0.0.0',
        port             => 443,
        connection_class => 'SecureHTTP',
    );

Accepted TLS Connections automatically use Linux::Event server-handshake
semantics. Server validates the configured Connection TLS declaration at
construction time, including the requirement for a server certificate and key.
The HTTP layer does not create a separate HTTPS Connection type and does not
reimplement TLS state.

C<on_ready> for a TLS Connection runs only after handshake and verification have
completed. HTTP request parsing therefore sees decrypted application bytes, and
Response output travels through the established TLS transport. Negotiated
C<selected_alpn>, C<tls_protocol>, C<tls_cipher>, and C<tls_stats> remain
available directly from the Connection through Linux::Event.

=head1 LISTENER OPTIONS

Socket-source and listener-tuning options are passed to
L<Linux::Event::IO::Sock::Listener>. This includes C<loop>, C<host>/C<port>,
C<unix>, adopted C<fh>, C<backlog>, C<max_accept_per_tick>, C<edge_triggered>,
C<reuseaddr>, C<reuseport>, C<v6only>, C<bind_device>, and Unix ownership
options.

The ordinary accepted-Stream lifecycle callbacks such as C<on_ready>,
C<on_drain>, C<on_eof>, C<on_error>, and C<on_close> may also be supplied and
are forwarded by Linux::Event to the accepted HTTP Connection. C<on_data>,
C<on_message>, and C<on_messages> are reserved because HTTP Connection owns its
input protocol engine.

=head1 METHODS

=head2 listener

Returns the underlying L<Linux::Event::IO::Sock::Listener> for advanced
inspection. Application code normally does not need it.

=head2 connection_class

Returns the configured HTTP Connection class name.

=head2 data

Returns the application data supplied to the Server.

=head2 loop, fh, fd, host, port, path, family, family_number, is_tcp, is_unix, state

Delegate to the underlying Listener. C<port> is useful when C<port =E<gt> 0>
asks the kernel to select an available TCP port.

=head2 pause

Pauses acceptance and returns the Server.

=head2 resume

Resumes acceptance and returns the Server.

=head2 close

Closes the underlying Listener and returns the Server. Existing accepted HTTP
Connections retain their independent lifecycles.

=head1 SEE ALSO

L<Linux::Event::HTTP::Server::Connection>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::IO::Sock::Listener>,
L<Linux::Event::TLS>.

=cut
