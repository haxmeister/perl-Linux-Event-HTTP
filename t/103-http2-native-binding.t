use v5.36;
use strict;
use warnings;

use Test::More;

BEGIN {
    eval {
        require Linux::Event::HTTP::_HTTP2::Native;
        Linux::Event::HTTP::_HTTP2::Native->available;
        1;
    } or plan skip_all => 'native libnghttp2 bridge is not built';
}

use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

use constant {
    H2_HEADERS    => 1,
    H2_END_STREAM => 0x1,
};

sub flush_session ($stream, $session) {
    while ($session->want_write) {
        my $bytes = $session->mem_send;
        last if !length $bytes;
        $stream->write($bytes);
    }
    return;
}

my $loop = Linux::Event::Loop->new;
my %server_session;
my %server_request;
my $server_closed = 0;
my $expected = 8;
my ($reentrant_send_error, $reentrant_recv_error, $reentrant_checked);

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        on_ready => sub ($stream) {
            my $session;
            $session = Linux::Event::HTTP::_HTTP2::Native->new_server(
                callbacks => {
                    on_begin_headers => sub ($stream_id, $type, $flags) {
                        $server_request{$stream_id} //= {};
                    },
                    on_header => sub ($stream_id, $name, $value, $flags) {
                        $server_request{$stream_id}{$name} = $value;
                    },
                    on_frame_recv => sub ($frame) {
                        return if $frame->{type} != H2_HEADERS;
                        return if !($frame->{flags} & H2_END_STREAM);
                        return if !$frame->{stream_id};

                        my $stream_id = $frame->{stream_id};
                        my $path = $server_request{$stream_id}{':path'} // '';

                        if (!$reentrant_checked++) {
                            my $send_ok = eval {
                                $session->mem_send;
                                1;
                            };
                            $reentrant_send_error = "$@" if !$send_ok;

                            my $recv_ok = eval {
                                $session->mem_recv('');
                                1;
                            };
                            $reentrant_recv_error = "$@" if !$recv_ok;
                        }

                        $session->submit_response(
                            $stream_id,
                            status  => 200,
                            headers => [
                                [ 'x-native-path', $path ],
                            ],
                        );
                    },
                    on_stream_close => sub ($stream_id, $error_code) {
                        ++$server_closed;
                    },
                },
            );
            $server_session{$stream->fd} = $session;
            $session->send_connection_preface(max_concurrent_streams => 100);
            flush_session($stream, $session);
        },
        on_data => sub ($stream, $bytes) {
            my $session = $server_session{$stream->fd}
                or die "server native HTTP/2 session is unavailable\n";
            my $consumed = $session->mem_recv($bytes);
            die "server native HTTP/2 session left input unconsumed\n"
                if $consumed != length($bytes);
            flush_session($stream, $session);
        },
        on_close => sub ($stream) {
            delete $server_session{$stream->fd};
        },
    },
);

my %response;
my %closed;
my %path_by_id;
my $client_session;

my $client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $client_session = Linux::Event::HTTP::_HTTP2::Native->new_client(
            callbacks => {
                on_begin_headers => sub ($stream_id, $type, $flags) {
                    $response{$stream_id} //= {};
                },
                on_header => sub ($stream_id, $name, $value, $flags) {
                    $response{$stream_id}{$name} = $value;
                },
                on_stream_close => sub ($stream_id, $error_code) {
                    $closed{$stream_id} = $error_code;
                    if (keys(%closed) == $expected) {
                        $stream->close if !$stream->is_closed;
                        $listener->close;
                        $loop->stop;
                    }
                },
            },
        );
        $client_session->start(100);

        for my $number (1 .. $expected) {
            my $path = "/native/$number";
            my $stream_id = $client_session->submit_request(
                method    => 'GET',
                scheme    => 'http',
                authority => 'native.test',
                path      => $path,
                headers   => [
                    [ 'x-request-number', "$number" ],
                ],
            );
            $path_by_id{$stream_id} = $path;
        }

        flush_session($stream, $client_session);
    },
    on_data => sub ($stream, $bytes) {
        my $consumed = $client_session->mem_recv($bytes);
        die "client native HTTP/2 session left input unconsumed\n"
            if $consumed != length($bytes);
        flush_session($stream, $client_session);
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 5,
    on_timer => sub ($timer) {
        die "native libnghttp2 bridge spike timed out\n";
    },
);

$loop->run;
$guard->cancel;

is(scalar(keys %closed), $expected,
    'all native HTTP/2 client streams closed');
is($server_closed, $expected,
    'native server observed every stream close');
like($reentrant_send_error // '', qr/reentrant nghttp2 session call/,
    'native mem_send rejects reentrant use from an nghttp2 callback');
like($reentrant_recv_error // '', qr/reentrant nghttp2 session call/,
    'native mem_recv rejects reentrant use from an nghttp2 callback');

for my $stream_id (sort { $a <=> $b } keys %path_by_id) {
    my $path = $path_by_id{$stream_id};
    is($closed{$stream_id}, 0, "$path closed without HTTP/2 error");
    is($response{$stream_id}{':status'}, '200',
        "$path received status 200");
    is($response{$stream_id}{'x-native-path'}, $path,
        "$path kept independent multiplexed state");
}

like(
    Linux::Event::HTTP::_HTTP2::Native->library_version,
    qr/\A\d+\.\d+/,
    'native bridge reports linked libnghttp2 version',
);

done_testing;
