package Linux::Event::HTTP::Client;
use v5.36;
use parent 'Unblock::HTTP::Client';
use Linux::Event::HTTP::_Config;
use Linux::Event::HTTP::_Stream;
use Linux::Event::Kernel::Timer;
use Carp qw(croak);
use Scalar::Util qw(weaken refaddr);

our $VERSION = '0.004';

sub new ($class, %option) {
    my $loop = delete $option{loop};
    Linux::Event::HTTP::_Config::loop($loop);
    my $stream_class = Linux::Event::HTTP::_Config::stream_class(\%option);
    my %protocols = Linux::Event::HTTP::_Config::protocols(\%option);
    my $tls = delete($option{tls}) // {};
    croak 'new(): tls must be a hash reference' unless ref($tls) eq 'HASH';
    croak 'new(): HTTP Client owns TLS server_name and alpn'
        if exists($tls->{server_name}) || exists($tls->{alpn});
    $tls = { %$tls };
    my $quic = delete($option{quic}) // {};
    croak 'new(): quic must be a hash reference' unless ref($quic) eq 'HASH';
    croak 'new(): quic requires http3 => 1' if %$quic && !$protocols{http3};
    for my $key (keys %$quic) {
        croak "new(): unknown quic option $key"
            unless $key =~ /\A(?:ca_file|transport|version)\z/;
    }
    $quic = { %$quic };
    $quic->{ca_file} = $tls->{ca_file}
        if !exists($quic->{ca_file}) && exists($tls->{ca_file});
    my %quic_connections;
    for my $name (qw(connect_stream connect_quic defer schedule_timer release_connection)) {
        die "new(): $name is owned by Linux::Event::HTTP\n" if exists $option{$name};
    }
    my $self = $class->SUPER::new(%option, %protocols,
        defer => sub ($callback) { $loop->defer($callback); return },
        schedule_timer => sub ($seconds, $callback) {
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $loop, after => $seconds,
                on_timer => sub ($timer) { $callback->() },
            );
            return sub { $timer->cancel };
        },
        connect_stream => sub ($origin, $alpn, $ready) {
            my %transport;
            my $verified = 0;
            if ($origin->{scheme} eq 'https') {
                require Linux::Event::TLS;
                $transport{transport} = Linux::Event::TLS->client(
                    %$tls, server_name => $origin->{host}, alpn => $alpn,
                );
                $verified = exists($tls->{verify}) ? $tls->{verify} : 1;
            }
            my $stream = $stream_class->connect(
                loop => $loop, host => $origin->{host}, port => $origin->{port},
                %transport, data => { ready => $ready, verified_origin => $verified },
            );
            return sub { $stream->close };
        },
        ($protocols{http3} ? (
            connect_quic => sub ($origin, $ready) {
                require Net::QUIC::Driver;
                require Linux::Event::HTTP::_QUICSocket;
                my $record = { cancelled => 0, completed => 0 };
                my $weak = $record;
                weaken($weak);
                my $fail = sub ($error) {
                    my $state = $weak or return;
                    return if $state->{cancelled} || $state->{completed}++;
                    $state->{socket}->close if $state->{socket};
                    $ready->(error => "$error");
                };
                my $socket = Linux::Event::HTTP::_QUICSocket->connect(
                    loop => $loop,
                    host => ($origin->{alternative_host} // $origin->{host}),
                    port => ($origin->{alternative_port} // $origin->{port}),
                    on_ready => sub ($bridge) {
                        my $state = $weak or return;
                        return if $state->{cancelled};
                        my $ok = eval {
                            my $driver = Net::QUIC::Driver->client(
                                local => $bridge->local, peer => $bridge->peer,
                                server_name => $origin->{host}, alpn => 'h3',
                                %$quic,
                                send => $bridge->send_callback,
                                set_timeout => $bridge->set_timeout_callback,
                            );
                            my $connection = $driver->connection;
                            $state->{driver} = $driver;
                            $state->{connection} = $connection;
                            $bridge->start($driver);
                            1;
                        };
                        $fail->("$@") unless $ok;
                    },
                    on_progress => sub {
                        my $state = $weak or return;
                        return if $state->{cancelled} || $state->{completed};
                        my $connection = $state->{connection} or return;
                        if ($connection->ready && !$connection->closed) {
                            $state->{completed} = 1;
                            $quic_connections{refaddr($connection)} = $state;
                            $ready->(connection => $connection, verified_origin => 1);
                        } elsif ($connection->closed) {
                            $fail->('QUIC connection closed before authentication');
                        }
                    },
                    on_error => sub ($udp, $error) { $fail->("$error") },
                );
                $record->{socket} = $socket;
                return sub {
                    return if $record->{cancelled}++;
                    delete $quic_connections{refaddr($record->{connection})}
                        if $record->{connection};
                    $record->{connection}->close
                        if $record->{connection} && !$record->{connection}->closed;
                    $record->{socket}->close if $record->{socket};
                };
            },
        ) : ()),
        release_connection => sub ($host, $engine, $protocol, $reason) {
            if ($protocol eq 'h3') {
                my $record = delete $quic_connections{refaddr($host)};
                $host->close unless $host->closed;
                $record->{socket}->close if $record && $record->{socket};
            } else {
                $host->close;
            }
        },
    );
    $self->{linux_event_loop} = $loop;
    return $self;
}

sub _release_transport ($stream, $engine, $protocol, $reason) {
    $stream->close;
    return;
}

sub loop ($self) { $self->{linux_event_loop} }
sub get ($self, $url, %option) { $self->request(%option, method => 'GET', url => $url) }
sub head ($self, $url, %option) { $self->request(%option, method => 'HEAD', url => $url) }
sub post ($self, $url, %option) { $self->request(%option, method => 'POST', url => $url) }
sub put ($self, $url, %option) { $self->request(%option, method => 'PUT', url => $url) }
sub delete ($self, $url, %option) { $self->request(%option, method => 'DELETE', url => $url) }

1;

__END__

=head1 NAME

Linux::Event::HTTP::Client - Make HTTP requests with Linux::Event

=head1 SYNOPSIS

    use v5.36;
    use Linux::Event::Loop;
    use Linux::Event::HTTP::Client;

    my $loop = Linux::Event::Loop->new;
    my $client = Linux::Event::HTTP::Client->new(loop => $loop);

    $client->get(
        'https://example.com/',
        timeout => 15,

        on_response => sub ($tx, $res) {
            say "Status: ", $res->status;
            say $res->body;
        },

        on_error => sub ($object, $error, @details) {
            warn "Request failed: $error\n";
        },

        on_finish => sub { $loop->stop },
    );

    $loop->run;

=head1 DESCRIPTION

This module makes HTTP requests without blocking the Linux::Event loop.
It handles connections, TLS, and HTTP messages for you.

Create one Client and reuse it for as many requests as you need.
HTTP/1.1 works by default. HTTP/2 and HTTP/3 are optional.

=head1 MAKING REQUESTS

=head2 GET, POST, and other methods

    $client->get($url, %options);
    $client->post($url, %options);
    $client->put($url, %options);
    $client->head($url, %options);
    $client->delete($url, %options);

For any other HTTP method:

    $client->request(
        method => 'PATCH',
        url    => 'https://example.com/item/1',
        body   => 'updated',
        on_response => sub ($tx, $res) {
            say $res->status;
        },
    );

These calls return immediately. The request proceeds while the event
loop runs. You can start several requests before calling C<$loop-E<gt>run>.

=head2 Sending a body and headers

    $client->post(
        'https://example.com/messages',
        headers => [
            ['content-type', 'text/plain'],
            ['accept', 'text/plain'],
        ],
        body => "Hello\n",
        timeout => 15,
        on_response => sub ($tx, $res) {
            say $res->status;
            say $res->body;
        },
    );

Headers are an array reference of name/value pairs. You can supply
the same header name more than once.

=head2 Reading a response

C<on_response> receives an HTTP transaction (C<$tx>) and a response
(C<$res>). Most applications only need the response:

    $res->status;                   # 200, 404, 500, ...
    $res->body;                     # Response body
    $res->header('content-type');   # One header value
    $res->header_values('set-cookie'); # Array reference of values

Header names are case-insensitive. The response is a
L<Uniform::HTTP::Response> object.

B<HTTP error status codes are still responses.> A server returning
404 or 500 normally triggers C<on_response>, not C<on_error>.
Check C<$res-E<gt>status> when it matters.

=head1 CALLBACKS

=head2 Normal requests: the full response

For an ordinary request, C<on_response($tx, $res)> runs B<after the
whole response body has been received>. You can read C<$res-E<gt>body>
right away.

=head2 Streaming: receive chunks as they arrive

To process a large response without collecting it in memory, add
C<on_data>:

    $client->get(
        'https://example.com/large-file',
        timeout => 30,

        on_response => sub ($tx, $res) {
            say "Status: ", $res->status;
        },

        on_data => sub ($tx, $bytes) {
            print $bytes;
        },

        on_end => sub ($tx) {
            say "\nBody complete";
        },

        on_error => sub ($object, $error, @details) {
            warn "Request failed: $error\n";
        },

        on_finish => sub { $loop->stop },
    );

B<Adding C<on_data> changes when C<on_response> runs.>

=over 4

=item * Without C<on_data>, C<on_response> runs after the full body.

=item * With C<on_data>, C<on_response> runs when headers arrive.

=item * C<on_data($tx, $bytes)> runs for each incoming body chunk.

=item * C<on_end($tx)> runs when a streamed body completes successfully.

=back

By default, non-streamed responses are limited to 1 MiB. Streaming
is the usual choice for large downloads.

=head2 Errors and completion

C<on_error($object, $error, @details)> reports failures such as
connection errors, TLS verification failures, or a timeout.

C<on_finish> runs when the operation ends, whether it succeeded,
failed, or was cancelled. In a one-request script, use
C<on_finish =E<gt> sub { $loop-E<gt>stop }> so the program also
stops after an error. For an application making ongoing requests,
normally leave the loop running.

C<timeout =E<gt> 15> sets a 15-second deadline for the request,
including time spent waiting for a connection.

=head1 UPLOADING A LARGE BODY

For a body you want to produce in pieces, use C<stream_body> and
C<on_transaction>. This callback runs when the request is ready
to start sending:

    $client->post(
        'https://example.com/upload',
        stream_body => 1,

        on_transaction => sub ($tx) {
            $tx->write("First part\n");
            $tx->end("Last part\n");
        },

        on_response => sub ($tx, $res) {
            say $res->status;
        },
    );

Use the transaction passed into C<on_transaction>; it may run
before the call returning the operation handle has finished.
For a producer that sends many chunks, respect C<write>'s
backpressure result and resume with C<on_drain>. A false C<write>
return means the chunk was accepted: do not send it again.

=head1 REQUEST CONTROL

Each request returns an operation handle:

    my $op = $client->get(
        'https://example.com/',
        on_response => sub ($tx, $res) {
            say $res->status;
        },
    );

    $op->cancel;        # Stop the request if no longer needed
    $op->state;         # Current lifecycle state
    $op->error;         # Error, if one occurred
    $op->is_terminal;   # True after it has ended
    $op->transaction;   # Available once the request starts

The transaction may be undefined while a request is queued.

=head1 CLIENT OPTIONS

Pass these to C<new>:

=over 4

=item * C<loop =E<gt> $loop>

Required. The L<Linux::Event::Loop> to use.

=item * C<tls =E<gt> { ca_file =E<gt> $path }>

Trust a private certificate authority when connecting with HTTPS.
Certificates and hostnames are checked by default.

=item * C<http2 =E<gt> 1> or C<http3 =E<gt> 1>

Enable optional HTTP versions. See L</HTTP VERSIONS>.

=item * C<max_connections_per_origin =E<gt> 4>

Limit simultaneous connections to one destination. The default is 4.

=item * C<max_pending_requests =E<gt> 128>

Limit requests waiting to be sent. The default is 128.

=item * C<idle_timeout =E<gt> $seconds>

Optional timeout for unused pooled connections.

=back

C<pool_stats> returns connection-pool counts, and C<pending_count>
returns the number of requests waiting in the Client. Call
C<$client-E<gt>shutdown> to stop accepting new work, cancel queued
requests, and allow active requests to finish.

The Client does not automatically follow redirects or manage
cookies or authentication retries.

=head1 HTTP VERSIONS

HTTP/1.1 is enabled by default and supports both HTTP and HTTPS.

For HTTP/2, install L<Unblock::HTTP2> 0.13 or newer and create
the Client with C<http2 =E<gt> 1>. HTTPS negotiates HTTP/2 using
TLS; HTTP/1.1 can remain available as a fallback.

For HTTP/3, install L<Unblock::HTTP3> 0.14 or newer and
L<Net::QUIC> 0.06 or newer, then set C<http3 =E<gt> 1>.
HTTP/3 uses HTTPS. C<quic =E<gt> { ca_file =E<gt> $path }>
configures a private CA for QUIC.

To require a particular version on one request:

    $client->get(
        'https://example.com/',
        http_version => '2',  # Or '1.1' or '3'
        on_response => sub ($tx, $res) {
            say $res->status;
        },
    );

If the required version cannot be used, the request fails rather
than silently falling back.

=head1 WEBSOCKETS AND CONNECT

The Client also supports WebSocket connections through
C<connect_websocket>. Enable the chosen HTTP version's
WebSocket feature, for example C<http1 =E<gt> { websocket =E<gt> 1 }>.
See L<Unblock::HTTP::Client> for WebSocket callback options.

Advanced protocol handoff through C<request(on_handoff =E<gt> ...)>
is described in C<docs/CONNECT.md> in the distribution. HTTP/1
handoff transfers the socket; HTTP/2 and HTTP/3 handoff transfers
an individual stream. These are not needed for normal HTTP requests.

=head1 SEE ALSO

L<Linux::Event::HTTP::Server>, L<Linux::Event::Loop>,
L<Uniform::HTTP::Response>, L<Unblock::HTTP::Client>.

The distribution's C<docs/GETTING-STARTED.md> has more examples.

=cut
