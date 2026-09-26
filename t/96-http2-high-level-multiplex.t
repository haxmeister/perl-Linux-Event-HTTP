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
        1;
    } or plan skip_all => 'Net::HTTP2::nghttp2 is not installed';

    Net::HTTP2::nghttp2->available
        or plan skip_all => 'nghttp2 library is not available';
}

use Linux::Event::HTTP::Client;
use Linux::Event::HTTP::Server;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

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
plan skip_all => 'openssl command is required for HTTP/2 multiplex test'
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

my $loop = Linux::Event::Loop->new;
my $state = {
    server_connections => {},
    server_targets     => [],
    max_server_streams => 0,
    warmup_complete    => 0,
    multiplex_complete => 0,
    response_body      => {},
    errors             => [],
};
my @response_timers;
my @operations;

my $server = Linux::Event::HTTP::Server->new(
    loop  => $loop,
    host  => '127.0.0.1',
    port  => 0,
    http2 => 1,
    tls   => {
        cert_file => $cert,
        key_file  => $key,
    },
    on_request => sub ($conn, $req, $res) {
        $state->{server_connections}{refaddr($conn)} = 1;
        push @{$state->{server_targets}}, $req->target;

        my $executor = $conn->{_http2_executor};
        my $count = $executor ? $executor->stream_count : 0;
        $state->{max_server_streams} = $count
            if $count > $state->{max_server_streams};

        if ($req->target eq '/warmup') {
            $res->body("warmup\n");
            return;
        }

        if ($req->target =~ m{\A/multiplex/([1-6])\z}) {
            my $number = 0 + $1;
            my $tx = $conn->transaction;
            my $timer;
            $timer = Linux::Event::Kernel::Timer->new(
                loop  => $loop,
                after => 0.03 + ($number * 0.002),
                on_timer => sub ($self) {
                    $res->body("response-$number\n");
                    $tx->send_response;
                    $timer = undef;
                },
            );
            push @response_timers, $timer;
            return;
        }

        die 'unexpected multiplex test target ' . $req->target;
    },
    on_error => sub ($conn, $error) {
        push @{$state->{errors}}, "server: $error";
        $loop->stop;
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop  => $loop,
    after => 10,
    on_timer => sub ($timer) {
        die "high-level HTTP/2 multiplex test timed out\n";
    },
);

my $client = Linux::Event::HTTP::Client->new(
    loop  => $loop,
    http2 => 1,
    tls   => {
        verify => 0,
        handshake_timeout => 2,
        shutdown_timeout  => 1,
    },
);

my $base = 'https://localhost:' . $server->port;

my $warmup = $client->get(
    "$base/warmup",
    on_response => sub ($tx, $res) {
        return if $state->{multiplex_started}++;

        for my $number (1 .. 6) {
            my $path = "/multiplex/$number";
            my $operation = $client->get(
                "$base$path",
                on_response => sub ($stream_tx, $stream_res) {
                    $state->{status}{$number} = $stream_res->status;
                },
                on_body => sub ($stream_tx, $stream_res, $bytes) {
                    $state->{response_body}{$number} .= $bytes;
                },
                on_complete => sub ($stream_tx) {
                    ++$state->{multiplex_complete};
                    if ($state->{multiplex_complete} == 6
                        && $state->{warmup_complete}) {
                        $guard->cancel;
                        $client->close;
                        $server->close;
                        $loop->stop;
                    }
                },
                on_error => sub ($stream_tx, $error) {
                    push @{$state->{errors}},
                        "multiplex $number: $error";
                    $loop->stop;
                },
            );

            push @operations, $operation;
            $state->{immediate_version}{$number} =
                $operation->request->version;
        }
    },
    on_body => sub ($tx, $res, $bytes) {
        $state->{warmup_body} .= $bytes;
    },
    on_complete => sub ($tx) {
        $state->{warmup_complete} = 1;
        if ($state->{multiplex_complete} == 6) {
            $guard->cancel;
            $client->close;
            $server->close;
            $loop->stop;
        }
    },
    on_error => sub ($tx, $error) {
        push @{$state->{errors}}, "warmup: $error";
        $loop->stop;
    },
);

is($warmup->request->version, '1.1',
    'first operation is provisional before ALPN selection');

$loop->run;

is_deeply($state->{errors}, [], 'multiplexed high-level Client has no errors');
ok($state->{warmup_complete}, 'warmup stream completes');
is($state->{warmup_body}, "warmup\n", 'warmup body is delivered');
is($state->{multiplex_complete}, 6,
    'all six concurrent high-level operations complete');

is(scalar(keys %{$state->{server_connections}}), 1,
    'all requests use one HTTP/2 TLS connection');
cmp_ok($state->{max_server_streams}, '>=', 6,
    'server observes at least six simultaneously active HTTP/2 streams');

for my $number (1 .. 6) {
    is($state->{immediate_version}{$number}, '2',
        "request $number is immediately H2 on selected connection");
    is($state->{status}{$number}, 200,
        "request $number receives status 200");
    is($state->{response_body}{$number}, "response-$number\n",
        "request $number receives its independent body");
}

is_deeply(
    [ sort @{$state->{server_targets}} ],
    [
        '/multiplex/1',
        '/multiplex/2',
        '/multiplex/3',
        '/multiplex/4',
        '/multiplex/5',
        '/multiplex/6',
        '/warmup',
    ],
    'server receives every multiplexed target exactly once',
);

done_testing;
