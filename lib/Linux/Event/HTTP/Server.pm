package Linux::Event::HTTP::Server;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

use Linux::Event::IO::Sock::Listener;
use Linux::Event::HTTP::Server::Connection;

our $VERSION = '0.002';

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
    return $class;
}

sub _take_callback ($name, $option) {
    return undef if !exists $option->{$name};
    my $callback = delete $option->{$name};
    croak "new(): $name must be a coderef" if ref($callback) ne 'CODE';
    return $callback;
}

sub _http2_available ($session_class = undef) {
    return 0 if !eval {
        require Linux::Event::HTTP::_HTTP2::Server;
        require Linux::Event::HTTP::_HTTP2::ServerConnection;
        if (defined $session_class) {
            (my $file = "$session_class.pm") =~ s{::}{/}g;
            require $file;
            die "$session_class does not provide new_server()"
                if !$session_class->can('new_server');
            die "$session_class reports HTTP/2 unavailable"
                if $session_class->can('available')
                && !$session_class->available;
        } else {
            require Net::HTTP2::nghttp2;
            Net::HTTP2::nghttp2->VERSION('0.011');
            require Net::HTTP2::nghttp2::Session;
            die 'nghttp2 library is unavailable'
                if !Net::HTTP2::nghttp2->available;
        }
        1;
    };
    return 1;
}

sub _http2_ready (
    $conn, $user_ready, $max_header_list_size, $session_class = undef,
) {
    if (($conn->selected_alpn // '') ne 'h2') {
        $user_ready->($conn) if $user_ready;
        return;
    }

    $conn->pause_read;
    $conn->loop->defer(sub {
        return if $conn->is_closed;

        my $executor = Linux::Event::HTTP::_HTTP2::Server->new(
            stream         => $conn,
            connection     => $conn,
            autostart      => 0,
            on_request     => $conn->{_http_on_request},
            on_body        => $conn->{_http_on_body},
            on_request_end => $conn->{_http_on_request_end},
            max_header_list_size => $max_header_list_size,
            (defined($session_class)
                ? (_session_class => $session_class) : ()),
        );
        $conn->{_http2_executor} = $executor;

        my $target = 'Linux::Event::HTTP::_HTTP2::ServerConnection';
        if ($executor->session->isa('Linux::Event::HTTP::_HTTP2::Native')) {
            require Linux::Event::HTTP::_HTTP2::NativeConnection;
            $conn->{_http2_native_session} = $executor->session;
            $target = 'Linux::Event::HTTP::_HTTP2::NativeConnection';
        }
        $conn->transition_to($target);
        $executor->start;

        $user_ready->($conn) if $user_ready;
        $conn->resume_read if $conn->is_read_paused;
    });
    return;
}

sub new ($class, %option) {
    croak 'new(): stream_class is internal; use connection_class'
        if exists $option{stream_class};
    croak 'new(): stream is internal; use connection_class, tuning, tls, and callbacks'
        if exists $option{stream};
    croak 'new(): HTTP Server owns on_data; use on_request/on_body callbacks'
        if exists $option{on_data};
    croak 'new(): HTTP Server cannot use message framing callbacks'
        if exists($option{on_message}) || exists($option{on_messages});
    croak 'new(): on_request_final was removed; use on_request and Response->body or Transaction->response_body'
        if exists $option{on_request_final};

    my $connection_class_option = delete $option{connection_class};
    my $connection_class = _load_connection_class(
        $connection_class_option
            // 'Linux::Event::HTTP::Server::Connection',
    );

    my $http2 = exists($option{http2}) ? delete($option{http2}) : 0;
    my $http2_session_class = delete $option{_http2_session_class};
    croak 'new(): _http2_session_class must be a package name'
        if defined($http2_session_class)
        && (ref($http2_session_class) || $http2_session_class eq '');
    my $has_http2_max_header_list_size =
        exists $option{http2_max_header_list_size};
    my $http2_max_header_list_size =
        $has_http2_max_header_list_size
            ? delete($option{http2_max_header_list_size})
            : 65_536;
    croak 'new(): http2 must be zero or one'
        if !defined($http2) || ref($http2)
        || ("$http2" ne '0' && "$http2" ne '1');
    $http2 = $http2 ? 1 : 0;
    croak 'new(): http2_max_header_list_size must be a positive integer'
        if ref($http2_max_header_list_size)
        || "$http2_max_header_list_size" !~ /\A[0-9]+\z/
        || $http2_max_header_list_size < 1;
    croak 'new(): http2_max_header_list_size requires http2 => 1'
        if !$http2 && $has_http2_max_header_list_size;

    my %callbacks;
    for my $name (qw(on_request on_body on_request_end)) {
        my $callback = _take_callback($name, \%option);
        $callbacks{$name} = $callback if $callback;
    }

    my %stream_callback;
    for my $name (qw(
        on_ready on_transport_ready on_drain on_eof on_error on_close
    )) {
        my $callback = _take_callback($name, \%option);
        $stream_callback{$name} = $callback if $callback;
    }

    my $listener_error = _take_callback('on_listener_error', \%option);

    my $tuning = exists($option{tuning}) ? delete($option{tuning}) : {};
    croak 'new(): tuning must be a hash reference'
        if ref($tuning) ne 'HASH';

    my $tls_enabled = exists $option{tls};
    my $tls = delete $option{tls};
    croak 'new(): tls must be a hash reference'
        if $tls_enabled && ref($tls) ne 'HASH';
    $tls = { %$tls } if $tls_enabled;

    if ($http2) {
        croak 'new(): http2 requires tls'
            if !$tls_enabled;
        croak 'new(): http2 currently requires the default connection_class'
            if defined($connection_class_option);
        croak 'new(): http2 owns TLS ALPN selection; do not supply tls => { alpn => ... }'
            if exists $tls->{alpn};
        croak 'new(): HTTP/2 session backend is unavailable'
            if !_http2_available($http2_session_class);
        $tls->{alpn} = [ 'h2', 'http/1.1' ];

        my $user_on_ready = $stream_callback{on_ready};
        $stream_callback{on_ready} = sub ($conn) {
            _http2_ready(
                $conn, $user_on_ready, 0 + $http2_max_header_list_size,
                $http2_session_class,
            );
        };
    }

    croak 'new(): HTTP Server requires on_request callback or connection_class method'
        if !$callbacks{on_request} && !$connection_class->can('on_request');

    my $data = delete $option{data};
    my $state = bless {
        callbacks => \%callbacks,
        data      => $data,
    }, 'Linux::Event::HTTP::Server::_ConnectionState';

    my %stream = (
        class  => $connection_class,
        data   => $state,
        tuning => $tuning,
        %stream_callback,
    );
    $stream{tls} = $tls if $tls_enabled;

    my $listener = Linux::Event::IO::Sock::Listener->new(
        %option,
        stream => \%stream,
        (defined($listener_error) ? (on_error => $listener_error) : ()),
    );

    return bless {
        listener         => $listener,
        connection_class => $connection_class,
        data             => $data,
        state            => $state,
        http2            => $http2,
        http2_session_class => $http2_session_class,
        http2_max_header_list_size => 0 + $http2_max_header_list_size,
    }, $class;
}

sub listener         ($self) { $self->{listener} }
sub connection_class ($self) { $self->{connection_class} }
sub data             ($self) { $self->{data} }
sub http2            ($self) { !!$self->{http2} }
sub http2_max_header_list_size ($self) {
    return $self->{http2_max_header_list_size};
}
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
            $res->body("hello\n");
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

Request and Response are HTTP message objects. The one-request/one-response
exchange is represented by L<Linux::Event::HTTP::Transaction> and is available
as C<< $conn->transaction >> while active. Response does not retain a hidden
Connection or peer-Request back-reference.

A complete scalar response body is configured on the Response:

    $res->body("hello\n");

For an incremental outgoing body, use the active Transaction:

    on_request => sub ($conn, $req, $res) {
        $res->header('Content-Type', 'text/plain');
        my $body = $conn->transaction->response_body;
        $body->write("one\n");
        $body->complete("two\n");
    },

Completing an HTTP response does not normally close the connection. HTTP
keep-alive may reuse the same connection for later Transactions.

=head1 DEFERRED RESPONSES

Inside an HTTP callback, C<< $res->body(...) >> is committed after callback
return when protocol state permits. This allows metadata to be configured in
any natural order before output begins.

If another event completes the Response later, retain the Transaction and send
the complete scalar message explicitly:

    my $tx = $conn->transaction;

    Linux::Event::Kernel::Timer->new(
        loop => $conn->loop,
        after => 0.1,
        on_timer => sub ($timer) {
            $tx->response->body("later\n");
            $tx->send_response;
        },
    );

The explicit C<send_response> call is intentional. Response remains a
transport-independent message and setting C<body> later does not secretly write
to a socket.

=head1 REQUEST BODIES

Request bodies are incremental-first. Add C<on_body> when body bytes are needed,
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
            $res->body("received\n");
        },
    );

If C<on_body> is absent, the server drains request-body bytes without building a
whole-body scalar. C<Request-E<gt>is_complete> becomes true at the actual
request-body boundary.

=head1 UPGRADE

HTTP Upgrade is an exchange operation owned by Transaction. Configure the
Response switching metadata and ask the active Transaction to hand off the live
transport:

    $res->header('Upgrade', 'my-protocol');
    $conn->transaction->upgrade('MyProtocolConnection');

The server validates the HTTP/1.1 Upgrade, queues the 101 response, completes
the HTTP Transaction, and then uses Linux::Event C<transition_to()> on the same
stream object. Response itself has no C<upgrade> method.

=head1 CONNECTION SUBCLASSES

Most applications do not need to subclass the HTTP connection. Use
C<connection_class> when reusable transport defaults, stream tuning, socket
policy, or callback methods belong on a class:

    package MyHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub stream_tuning ($class) {
        return read_budget_bytes => 262_144;
    }

    sub on_request ($self, $req, $res) {
        $res->body("hello\n");
    }

    package main;

    my $server = Linux::Event::HTTP::Server->new(
        loop             => $loop,
        port             => 8080,
        connection_class => 'MyHTTP',
    );

C<connection_class> defaults to
L<Linux::Event::HTTP::Server::Connection>.

=head1 MANAGED PRE-FORK SERVERS

Linux::Event 0.117 provides a Loop-aware C<fork> operation. A plain HTTP server
can participate without a separate worker API because C<listener> exposes the
underlying L<Linux::Event::IO::Sock::Listener>:

    my $pid = $loop->fork(
        share => [ $server->listener ],
    );

The Listener remains active in both processes. Each process has its own rebuilt
Loop reactor and may accept connections from the intentionally shared listening
socket.

Call C<< $loop->fork(...) >> only while the Loop is quiescent, as required by
Linux::Event. Worker creation, supervision, restart policy, privilege changes,
and process shutdown remain application concerns rather than HTTP protocol
features.

This shared-Listener pattern is covered for plain HTTP. Do not assume the same
deployment recipe for a TLS Listener until the TLS case has been validated
separately.

=head1 TUNING AND CONNECTION CALLBACKS

Supply deployment-specific Stream tuning directly to the Server. These values
override C<stream_tuning()> defaults on the configured Connection class:

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        port => 8080,
        tuning => {
            read_size         => 131_072,
            read_budget_bytes => 524_288,
            idle_timeout      => 60,
        },
        on_request => sub ($conn, $req, $res) {
            $res->body("hello\n");
        },
    );

Accepted-connection lifecycle callbacks are C<on_ready>,
C<on_transport_ready>, C<on_drain>, C<on_eof>, C<on_error>, and C<on_close>.
C<on_listener_error> is the distinct callback for listening and acceptance
failures. The advanced C<on_accept($listener, $conn)> callback receives the
underlying Listener and each newly accepted HTTP Connection.

=head1 TLS

HTTPS uses the same Server API. Activate Linux::Event TLS transport policy with
the Server C<tls> option:

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        port => 8443,
        tls => {
            cert_file => '/etc/myapp/server-cert.pem',
            key_file  => '/etc/myapp/server-key.pem',
        },
        on_request => sub ($conn, $req, $res) {
            $res->body("secure\n");
        },
    );

Without C<http2>, HTTPS retains the existing HTTP/1 behavior.

Enable HTTP/2 negotiation explicitly with:

    my $server = Linux::Event::HTTP::Server->new(
        loop  => $loop,
        port  => 8443,
        http2 => 1,
        tls => {
            cert_file => '/etc/myapp/server-cert.pem',
            key_file  => '/etc/myapp/server-key.pem',
        },
        on_request => sub ($conn, $req, $res) {
            $res->body("same callback API\n");
        },
    );

The Server then advertises C<h2> before C<http/1.1>. When C<h2> is selected,
the live TLS connection is changed to the private HTTP/2 executor before any
HTTP/2 preface or SETTINGS bytes are emitted. If C<http/1.1> is selected, the
existing HTTP/1 connection remains unchanged.

C<http2 =E<gt> 1> currently requires the default connection class and owns the
TLS ALPN list. A custom C<connection_class> remains HTTP/1-only for now rather
than having its application-defined class identity silently replaced during an
HTTP/2 transition.

HTTP/2 currently requires the optional L<Net::HTTP2::nghttp2> 0.011 or newer
binding and the underlying nghttp2 library. They are not yet normal distribution
prerequisites.
Constructing a Server with C<http2 =E<gt> 1> fails explicitly when that
capability is unavailable.

Decoded HTTP/2 request and trailer header lists default to a 65,536-byte limit,
using the HTTP/2 accounting rule of name bytes + value bytes + 32 bytes per
field. Override it with C<http2_max_header_list_size>. The same value is
advertised to the peer through SETTINGS_MAX_HEADER_LIST_SIZE and enforced again
after HPACK decoding.

A Connection subclass may define C<tls_defaults()> for reusable HTTP/1 ALPN and
timeout defaults. The Server C<tls> option is still required to activate TLS,
so the same Connection class may be used for plain HTTP and HTTPS listeners.

=head1 METHODS

=head2 listener

Returns the underlying L<Linux::Event::IO::Sock::Listener> for advanced use.

=head2 connection_class

Returns the configured HTTP Connection class name.

=head2 http2

Returns true when this Server was constructed with C<http2 =E<gt> 1>.

=head2 http2_max_header_list_size

Returns the decoded HTTP/2 request/trailer header-list limit. The default is
65,536 bytes.

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

L<Linux::Event::HTTP::Server::Connection>, L<Linux::Event::HTTP::Transaction>,
L<Linux::Event::HTTP::Request>, L<Linux::Event::HTTP::Response>,
L<Linux::Event::HTTP::Body::Stream>, L<Linux::Event::TLS>.

=cut
