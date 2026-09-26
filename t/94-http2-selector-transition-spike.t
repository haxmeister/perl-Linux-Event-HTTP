use v5.36;
use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);

BEGIN {
    eval {
        require Net::HTTP2::nghttp2;
        require Net::HTTP2::nghttp2::Session;
        1;
    } or plan skip_all => 'Net::HTTP2::nghttp2 is not installed';

    Net::HTTP2::nghttp2->available
        or plan skip_all => 'nghttp2 library is not available';
}

use Linux::Event::HTTP::Client::Connection;
use Linux::Event::HTTP::Request;
use Linux::Event::HTTP::Server::Connection;
use Linux::Event::HTTP::_HTTP2::Client;
use Linux::Event::HTTP::_HTTP2::ClientConnection;
use Linux::Event::HTTP::_HTTP2::Server;
use Linux::Event::HTTP::_HTTP2::ServerConnection;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::TLS ();

my $openssl = -x '/usr/bin/openssl' ? '/usr/bin/openssl' : undef;
if (!defined $openssl) {
    for my $dir (File::Spec->path) {
        my $candidate = File::Spec->catfile($dir, 'openssl');
        if (-x $candidate) {
            $openssl = $candidate;
            last;
        }
    }
}
plan skip_all => 'openssl command is required for HTTP/2 selector spike'
    if !defined $openssl;

my $temp = tempdir(CLEANUP => 1);
my $cert = File::Spec->catfile($temp, 'server-cert.pem');
my $key = File::Spec->catfile($temp, 'server-key.pem');

my $generated;
{
    local $ENV{OPENSSL_CONF};
    delete $ENV{OPENSSL_CONF};
    $generated = system(
        $openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', $key,
        '-out', $cert,
        '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost',
        '-days', '1',
    );
}
plan skip_all => 'openssl could not generate temporary TLS certificate'
    if $generated != 0 || !-s $cert || !-s $key;


{
    package T::HTTP2DebugServerExecutor;
    use parent -norequire, 'Linux::Event::HTTP::_HTTP2::Server';

    sub input ($self, $bytes) {
        warn "T94 SERVER J before executor input\n";
        my $consumed = $self->SUPER::input($bytes);
        warn "T94 SERVER K after executor input\n";
        return $consumed;
    }
}

{
    package T::HTTP2DebugClientExecutor;
    use parent -norequire, 'Linux::Event::HTTP::_HTTP2::Client';

    sub input ($self, $bytes) {
        warn "T94 CLIENT J before executor input\n";
        my $consumed = $self->SUPER::input($bytes);
        warn "T94 CLIENT K after executor input\n";
        return $consumed;
    }
}

{
    package T::HTTP2ServerTarget;
    use parent -norequire, 'Linux::Event::HTTP::_HTTP2::ServerConnection';

    sub on_data ($conn, $bytes) {
        warn "T94 SERVER G first/raw H2 on_data\n"
            if !$conn->{_t94_seen_h2_data}++;
        my $result = $conn->SUPER::on_data($bytes);
        warn "T94 SERVER L after target on_data
";
        return $result;
    }
}

{
    package T::HTTP2ClientTarget;
    use parent -norequire, 'Linux::Event::HTTP::_HTTP2::ClientConnection';

    sub on_data ($conn, $bytes) {
        warn "T94 CLIENT G first/raw H2 on_data\n"
            if !$conn->{_t94_seen_h2_data}++;
        my $result = $conn->SUPER::on_data($bytes);
        warn "T94 CLIENT L after target on_data
";
        return $result;
    }
}

{
    package T::HTTP2SelectorSource;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_ready ($conn) {
        my $state = $conn->data;
        my $entry = {
            alpn          => $conn->selected_alpn,
            before_class  => ref($conn),
            before_id     => Scalar::Util::refaddr($conn),
            fd            => $conn->fd,
            transport     => $conn->transport_name,
        };

        if (($conn->selected_alpn // '') eq 'h2') {
            $conn->pause_read;
            $conn->loop->defer(sub {
                warn "T94 SERVER A before executor construction\n";
                my $executor = T::HTTP2DebugServerExecutor->new(
                    stream         => $conn,
                    connection     => $conn,
                    autostart      => 0,
                    on_request     => $conn->{_http_on_request},
                    on_body        => $conn->{_http_on_body},
                    on_request_end => $conn->{_http_on_request_end},
                );
                warn "T94 SERVER B after passive executor construction\n";
                $conn->{_http2_executor} = $executor;

                warn "T94 SERVER D immediately before transition_to\n";
                $conn->transition_to(
                    'T::HTTP2ServerTarget',
                );
                warn "T94 SERVER E immediately after transition_to\n";

                $entry->{after_class} = ref($conn);
                $entry->{after_id} = Scalar::Util::refaddr($conn);
                $entry->{after_transport} = $conn->transport_name;
                push @{$state->{server_ready}}, $entry;

                warn "T94 SERVER H before executor start/preface flush\n";
                $executor->start;
                warn "T94 SERVER I after executor start/preface flush\n";

                warn "T94 SERVER F immediately before resume_read\n";
                $conn->resume_read if $conn->is_read_paused;
            });
            return;
        }

        push @{$state->{server_ready}}, $entry;
        return;
    }

    sub on_request ($conn, $req, $res) {
        my $state = $conn->data;
        my $tx = $conn->transaction;
        push @{$state->{server_request}}, {
            class      => ref($conn),
            alpn       => $conn->selected_alpn,
            version    => $req->version,
            target     => $req->target,
            authority  => $req->authority,
            tx_match   => defined($tx)
                && Scalar::Util::refaddr($tx->request)
                    == Scalar::Util::refaddr($req) ? 1 : 0,
        };

        if ($req->version eq '2') {
            $res->header('x-protocol', 'h2');
            $res->body("h2\n");
        } else {
            $res->header('x-protocol', 'http/1.1');
            $res->body("h1\n");
        }
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    server_ready          => [],
    server_request        => [],
    h2_client_response    => '',
    h1_client_response    => '',
    h2_client_complete    => 0,
    h1_client_complete    => 0,
    errors                => [],
};

my $listener;
$listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::HTTP2SelectorSource',
        data  => $state,
        tls   => {
            cert_file => $cert,
            key_file  => $key,
            alpn      => [ 'h2', 'http/1.1' ],
        },
        on_error => sub ($conn, $error) {
            push @{$state->{errors}}, "server: $error";
            $loop->stop;
        },
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 10,
    on_timer => sub ($timer) {
        die "HTTP/2 ALPN selector transition spike timed out\n";
    },
);

my $start_h1;
$start_h1 = sub {
    my $wire = '';
    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $listener->port,
        transport => Linux::Event::TLS->client(
            server_name => 'localhost',
            verify      => 0,
            alpn        => [ 'http/1.1' ],
        ),
        on_ready => sub ($stream) {
            $state->{h1_client_alpn} = $stream->selected_alpn;
            $stream->write(
                "GET /fallback HTTP/1.1\r\n" .
                "Host: localhost\r\n" .
                "Connection: close\r\n" .
                "\r\n"
            );
        },
        on_data => sub ($stream, $bytes) {
            $wire .= $bytes;
        },
        on_eof => sub ($stream) {
            $state->{h1_client_response} = $wire;
            $state->{h1_client_complete} = 1;
            $guard->cancel;
            $stream->close if !$stream->is_closed;
            $listener->close;
            $loop->stop;
        },
        on_error => sub ($stream, $error) {
            push @{$state->{errors}}, "h1 client: $error";
            $loop->stop;
        },
    );
};

my $h2_executor;
my $h2_client = Linux::Event::HTTP::Client::Connection->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    transport => Linux::Event::TLS->client(
        server_name => 'localhost',
        verify      => 0,
        alpn        => [ 'h2', 'http/1.1' ],
    ),
    on_ready => sub ($conn) {
        $state->{h2_client_before_class} = ref($conn);
        $state->{h2_client_before_id} = refaddr($conn);
        $state->{h2_client_fd} = $conn->fd;
        $state->{h2_client_alpn} = $conn->selected_alpn;

        $conn->pause_read;
        $conn->loop->defer(sub {
            warn "T94 CLIENT A before executor construction\n";
            $h2_executor = T::HTTP2DebugClientExecutor->new(
                stream    => $conn,
                autostart => 0,
            );
            warn "T94 CLIENT B after passive executor construction\n";
            $conn->{_http2_executor} = $h2_executor;

            warn "T94 CLIENT D immediately before transition_to\n";
            $conn->transition_to(
                'T::HTTP2ClientTarget',
            );
            warn "T94 CLIENT E immediately after transition_to\n";

            $state->{h2_client_after_class} = ref($conn);
            $state->{h2_client_after_id} = refaddr($conn);
            $state->{h2_client_transport} = $conn->transport_name;

            warn "T94 CLIENT H before executor start/preface flush\n";
            $h2_executor->start;
            warn "T94 CLIENT I after executor start/preface flush\n";

            my $request = Linux::Event::HTTP::Request->new(
                method    => 'GET',
                target    => '/selected',
                version   => '2',
                scheme    => 'https',
                authority => 'localhost',
            );

            $conn->request(
                $request,
                on_response => sub ($tx, $res) {
                    $state->{h2_status} = $res->status;
                    $state->{h2_protocol_header} = $res->header('x-protocol');
                },
                on_body => sub ($tx, $res, $bytes) {
                    $state->{h2_client_response} .= $bytes;
                },
                on_complete => sub ($tx) {
                    $state->{h2_client_complete} = 1;
                    $state->{h2_tx_complete_in_callback} =
                        $tx->is_complete ? 1 : 0;
                    # Keep the negotiated H2 TLS connection alive while the
                    # second client verifies HTTP/1.1 fallback. Closing it here
                    # would intentionally omit a TLS close_notify and make the
                    # server-side transport error stop this selector test.
                    $start_h1->();
                },
                on_error => sub ($tx, $error) {
                    push @{$state->{errors}}, "h2 client: $error";
                    $loop->stop;
                },
            );
            warn "T94 CLIENT F immediately before resume_read
";
            $conn->resume_read if $conn->is_read_paused;
        });
    },
);

$loop->run;

$h2_client->close if !$h2_client->is_closed;

is_deeply($state->{errors}, [], 'selector spike has no transport/protocol errors');
is($state->{h2_client_alpn}, 'h2', 'client TLS selects h2');
is($state->{h2_client_before_class}, 'Linux::Event::HTTP::Client::Connection',
    'h2 client begins as existing native HTTP/1 connection class');
is($state->{h2_client_after_class},
    'T::HTTP2ClientTarget',
    'h2 client transitions to private raw HTTP/2 connection');
is($state->{h2_client_before_id}, $state->{h2_client_after_id},
    'client transition retains object identity');
is($state->{h2_client_transport}, 'tls',
    'client transition retains TLS transport');
is($state->{h2_status}, 200, 'transitioned H2 client receives response');
is($state->{h2_protocol_header}, 'h2',
    'transitioned H2 response came through HTTP/2 server executor');
is($state->{h2_client_response}, "h2\n",
    'transitioned H2 client receives response body');
ok($state->{h2_client_complete}, 'H2 client Transaction completes');
ok($state->{h2_tx_complete_in_callback},
    'H2 on_complete observes terminal Transaction');

is($state->{h1_client_alpn}, 'http/1.1',
    'second TLS client negotiates HTTP/1.1 fallback');
like($state->{h1_client_response}, qr{\AHTTP/1\.1 200 OK\r\n}s,
    'HTTP/1.1 fallback still uses existing serializer');
like($state->{h1_client_response}, qr{x-protocol: http/1\.1}i,
    'HTTP/1.1 fallback reaches the same application callback');
like($state->{h1_client_response}, qr{\r\n\r\nh1\n\z}s,
    'HTTP/1.1 fallback receives correct body');
ok($state->{h1_client_complete}, 'HTTP/1.1 fallback connection completes');

is(scalar(@{$state->{server_ready}}), 2,
    'server accepted one H2 and one HTTP/1.1 TLS connection');
my ($h2_ready) = grep { ($_->{alpn} // '') eq 'h2' }
    @{$state->{server_ready}};
my ($h1_ready) = grep { ($_->{alpn} // '') eq 'http/1.1' }
    @{$state->{server_ready}};

is($h2_ready->{before_class}, 'T::HTTP2SelectorSource',
    'server H2 socket begins as configured native HTTP/1 subclass');
is($h2_ready->{after_class},
    'T::HTTP2ServerTarget',
    'server H2 socket transitions to private raw HTTP/2 connection');
is($h2_ready->{before_id}, $h2_ready->{after_id},
    'server transition retains object identity');
is($h2_ready->{transport}, 'tls',
    'server source connection is TLS');
is($h2_ready->{after_transport}, 'tls',
    'server H2 target retains TLS transport');
is($h1_ready->{before_class}, 'T::HTTP2SelectorSource',
    'HTTP/1.1 fallback remains on configured native HTTP/1 subclass');
ok(!exists($h1_ready->{after_class}),
    'HTTP/1.1 fallback performs no protocol transition');

is(scalar(@{$state->{server_request}}), 2,
    'same server callback receives H2 and HTTP/1.1 requests');
my ($h2_request) = grep { $_->{version} eq '2' }
    @{$state->{server_request}};
my ($h1_request) = grep { $_->{version} eq '1.1' }
    @{$state->{server_request}};

is($h2_request->{class}, 'T::HTTP2ServerTarget',
    'H2 callback receives the live transitioned connection object');
is($h2_request->{alpn}, 'h2', 'H2 callback can inspect negotiated ALPN');
is($h2_request->{target}, '/selected', 'H2 callback sees mapped Request target');
is($h2_request->{authority}, 'localhost',
    'H2 callback sees mapped Request authority');
ok($h2_request->{tx_match},
    'H2 conn->transaction is callback-scoped to the current stream');

is($h1_request->{class}, 'T::HTTP2SelectorSource',
    'HTTP/1.1 callback receives configured HTTP/1 subclass');
is($h1_request->{alpn}, 'http/1.1',
    'HTTP/1.1 callback sees negotiated fallback ALPN');
is($h1_request->{target}, '/fallback',
    'HTTP/1.1 callback sees ordinary Request target');
is($h1_request->{authority}, 'localhost',
    'HTTP/1.1 Request derives authority from Host');
ok($h1_request->{tx_match},
    'HTTP/1.1 conn->transaction retains ordinary semantics');

done_testing;
