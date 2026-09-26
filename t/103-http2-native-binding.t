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
    H2_HEADERS       => 1,
    H2_SETTINGS      => 4,
    H2_GOAWAY        => 7,
    H2_END_STREAM    => 0x1,
    H2_END_HEADERS   => 0x4,
    H2_PROTOCOL_ERROR => 1,
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

my $received_goaway;
my $goaway_client = Linux::Event::HTTP::_HTTP2::Native->new_client(
    callbacks => {
        on_frame_recv => sub ($frame) {
            $received_goaway = $frame
                if ($frame->{type} // -1) == H2_GOAWAY;
        },
    },
);
$goaway_client->send_connection_preface(max_concurrent_streams => 100);
my $goaway_stream_id = $goaway_client->submit_request(
    method    => 'GET',
    path      => '/goaway-metadata',
    scheme    => 'http',
    authority => 'native.test',
);
is($goaway_stream_id, 1,
    'native client allocates expected first stream before GOAWAY');

my $settings_wire = pack('C C C C C N', 0, 0, 0, 4, 0, 0);
my $goaway_wire = pack(
    'C C C C C N N N',
    0, 0, 8, H2_GOAWAY, 0, 0, $goaway_stream_id, 0,
);
my $goaway_input = $settings_wire . $goaway_wire;
is(
    $goaway_client->mem_recv($goaway_input),
    length($goaway_input),
    'native client consumes SETTINGS plus GOAWAY input',
);
is($received_goaway->{last_stream_id}, $goaway_stream_id,
    'native GOAWAY callback exposes last_stream_id');
is($received_goaway->{error_code}, 0,
    'native GOAWAY callback exposes error_code');
$goaway_client->close;

sub h2_frame ($type, $flags, $stream_id, $payload = '') {
    my $length = length($payload);
    die 'test frame payload is too large' if $length > 0x00ff_ffff;
    return pack(
        'C C C C C N',
        ($length >> 16) & 0xff,
        ($length >> 8) & 0xff,
        $length & 0xff,
        $type,
        $flags,
        $stream_id,
    ) . $payload;
}

sub first_goaway ($wire) {
    my $offset = 0;
    while ($offset + 9 <= length($wire)) {
        my ($l1, $l2, $l3, $type, $flags, $stream_id) =
            unpack('C C C C C N', substr($wire, $offset, 9));
        my $length = ($l1 << 16) | ($l2 << 8) | $l3;
        last if $offset + 9 + $length > length($wire);
        my $payload = substr($wire, $offset + 9, $length);
        if ($type == H2_GOAWAY && $length >= 8) {
            my ($last_stream_id, $error_code) = unpack('N N', $payload);
            return {
                last_stream_id => $last_stream_id & 0x7fff_ffff,
                error_code     => $error_code,
            };
        }
        $offset += 9 + $length;
    }
    return undef;
}

my @strict_seen;
my $strict_server = Linux::Event::HTTP::_HTTP2::Native->new_server(
    callbacks => {
        on_begin_headers => sub ($stream_id, $type, $flags) {
            push @strict_seen, $stream_id;
        },
    },
);
$strict_server->send_connection_preface(max_concurrent_streams => 100);
$strict_server->mem_send;

my $client_magic = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
my $empty_settings = h2_frame(H2_SETTINGS, 0, 0);
my $static_request_headers = pack('C C C', 0x82, 0x86, 0x84);
my $stream5 = h2_frame(
    H2_HEADERS,
    H2_END_STREAM | H2_END_HEADERS,
    5,
    $static_request_headers,
);
my $first_input = $client_magic . $empty_settings . $stream5;
is(
    $strict_server->mem_recv($first_input),
    length($first_input),
    'native server accepts a first peer request on stream 5',
);
$strict_server->mem_send;

my $stream3 = h2_frame(
    H2_HEADERS,
    H2_END_STREAM | H2_END_HEADERS,
    3,
    $static_request_headers,
);
is(
    $strict_server->mem_recv($stream3),
    length($stream3),
    'native server consumes lower-numbered peer stream input before termination',
);
is_deeply(
    \@strict_seen,
    [5],
    'lower-numbered new stream is not exposed to HTTP callbacks',
);
my $strict_goaway = first_goaway($strict_server->mem_send);
ok($strict_goaway, 'lower-numbered new stream queues GOAWAY');
is(
    $strict_goaway->{error_code},
    H2_PROTOCOL_ERROR,
    'lower-numbered new stream terminates with PROTOCOL_ERROR',
);
$strict_server->close;

done_testing;
