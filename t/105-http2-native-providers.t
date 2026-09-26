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

use constant {
    H2_DATA       => 0,
    H2_HEADERS    => 1,
    H2_END_STREAM => 0x1,
};

sub pump ($left, $right) {
    my $moved = 0;

    for my $pair ([$left, $right], [$right, $left]) {
        my ($from, $to) = @$pair;
        while ($from->want_write) {
            my $bytes = $from->mem_send;
            last if !length $bytes;
            my $consumed = $to->mem_recv($bytes);
            die "native session did not consume complete pump input\n"
                if $consumed != length($bytes);
            ++$moved;
        }
    }

    return $moved;
}

sub pump_until_idle ($left, $right) {
    for (1 .. 100) {
        last if !pump($left, $right);
    }
    return;
}

my $request_body = '';
my $response_body = '';
my $response_status;
my $client_closed;
my $request_stream_id;

my @request_chunks;
my $request_eof = 0;
my @response_chunks;
my $response_eof = 0;
my $response_provider = {
    calls => 0,
};

my $server;
$server = Linux::Event::HTTP::_HTTP2::Native->new_server(
    callbacks => {
        on_header => sub ($stream_id, $name, $value, $flags) {
            return 0;
        },
        on_data_chunk_recv => sub ($stream_id, $data, $flags) {
            $request_body .= $data;
            return 0;
        },
        on_frame_recv => sub ($frame) {
            return 0 if !$frame->{stream_id};
            return 0 if !($frame->{flags} & H2_END_STREAM);
            return 0 if $frame->{type} != H2_DATA
                && $frame->{type} != H2_HEADERS;

            $request_stream_id = $frame->{stream_id};
            $server->submit_response(
                $frame->{stream_id},
                status  => 200,
                headers => [
                    [ 'content-type', 'text/plain' ],
                ],
                data_callback => sub ($stream_id, $max_length, $provider) {
                    ++$provider->{calls};
                    return if !@response_chunks;

                    my $chunk = shift @response_chunks;
                    my $eof = $response_eof && !@response_chunks ? 1 : 0;
                    return ($chunk, $eof);
                },
                callback_data => $response_provider,
            );
            return 0;
        },
        on_stream_close => sub ($stream_id, $error_code) {
            return 0;
        },
    },
);

my $client = Linux::Event::HTTP::_HTTP2::Native->new_client(
    callbacks => {
        on_header => sub ($stream_id, $name, $value, $flags) {
            $response_status = $value if $name eq ':status';
            return 0;
        },
        on_data_chunk_recv => sub ($stream_id, $data, $flags) {
            $response_body .= $data;
            return 0;
        },
        on_stream_close => sub ($stream_id, $error_code) {
            $client_closed = $error_code;
            return 0;
        },
    },
);

$server->send_connection_preface(
    max_concurrent_streams => 20,
    max_header_list_size   => 65_536,
);
$client->send_connection_preface(
    max_concurrent_streams => 20,
    max_header_list_size   => 65_536,
);

my $stream_id = $client->submit_request(
    method    => 'POST',
    scheme    => 'https',
    authority => 'native.test',
    path      => '/streaming',
    headers   => [
        [ 'content-type', 'text/plain' ],
    ],
    body => sub ($id, $max_length) {
        return if !@request_chunks;

        my $chunk = shift @request_chunks;
        my $eof = $request_eof && !@request_chunks ? 1 : 0;
        return ($chunk, $eof);
    },
);

pump_until_idle($client, $server);

ok($client->is_stream_deferred($stream_id),
    'empty streaming request provider defers the stream');
is($request_body, '',
    'server has not received request body while provider is deferred');

@request_chunks = ('hello ', 'world');
$request_eof = 1;
$client->resume_stream($stream_id);
pump_until_idle($client, $server);

is($request_stream_id, $stream_id,
    'server completed the resumed streaming request');
is($request_body, 'hello world',
    'streaming request provider delivered all request bytes');
ok($server->is_stream_deferred($stream_id),
    'empty streaming response provider defers the response');
ok($response_provider->{calls} >= 1,
    'streaming response callback was invoked before deferral');

@response_chunks = ('good', 'bye');
$response_eof = 1;
$server->resume_stream($stream_id);
pump_until_idle($client, $server);

is($response_status, '200',
    'client received response status through native provider path');
is($response_body, 'goodbye',
    'streaming response provider delivered all response bytes');
is($client_closed, 0,
    'stream closed cleanly after both streaming providers completed');

my $static_server;
my $static_request_body = '';
my $static_response_body = '';
my $static_closed;
$static_server = Linux::Event::HTTP::_HTTP2::Native->new_server(
    callbacks => {
        on_data_chunk_recv => sub ($id, $data, $flags) {
            $static_request_body .= $data;
            return 0;
        },
        on_frame_recv => sub ($frame) {
            return 0 if !$frame->{stream_id};
            return 0 if !($frame->{flags} & H2_END_STREAM);
            return 0 if $frame->{type} != H2_DATA
                && $frame->{type} != H2_HEADERS;
            $static_server->submit_response(
                $frame->{stream_id},
                status => 204,
                body   => 'static-response',
            );
            return 0;
        },
    },
);
my $static_client = Linux::Event::HTTP::_HTTP2::Native->new_client(
    callbacks => {
        on_data_chunk_recv => sub ($id, $data, $flags) {
            $static_response_body .= $data;
            return 0;
        },
        on_stream_close => sub ($id, $error_code) {
            $static_closed = $error_code;
            return 0;
        },
    },
);
$static_server->send_connection_preface;
$static_client->send_connection_preface;
$static_client->submit_request(
    method    => 'POST',
    scheme    => 'https',
    authority => 'native.test',
    path      => '/static',
    body      => 'static-request',
);
pump_until_idle($static_client, $static_server);

is($static_request_body, 'static-request',
    'static request body uses native data provider');
is($static_response_body, 'static-response',
    'static response body uses native data provider');
is($static_closed, 0,
    'static body stream closes cleanly');

done_testing;
