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

use Linux::Event::Framer ();
use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

{
    package T::NativeH1Source;
    use parent 'Linux::Event::IO::Sock::Stream';

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );
}

{
    package T::NativeH2RawStream;
    use parent 'Linux::Event::IO::Sock::Stream';

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::HTTP::_HTTP2::Native->_raw_consumer_definition,
    );
}

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
my $expected = 8;
my %server_request;
my %response;
my %closed;
my %path_by_id;
my @errors;
my $server_closed = 0;
my $server_stream;
my $client_stream;

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::NativeH1Source',
        on_ready => sub ($stream) {
            $server_stream = $stream;

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
                        $session->submit_response(
                            $stream_id,
                            [
                                [ ':status', '200' ],
                                [ 'x-native-path', $path ],
                            ],
                        );
                    },
                    on_stream_close => sub ($stream_id, $error_code) {
                        ++$server_closed;
                    },
                },
            );

            $stream->{_http2_native_session} = $session;
            $session->start(100);
            flush_session($stream, $session);
            $stream->transition_to('T::NativeH2RawStream');
        },
        on_error => sub ($stream, $error) {
            push @errors, "server transport: $error";
            $loop->stop;
        },
    },
);

$client_stream = T::NativeH1Source->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        my $session;
        $session = Linux::Event::HTTP::_HTTP2::Native->new_client(
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
                        $listener->close;
                        $loop->stop;
                    }
                },
            },
        );

        $stream->{_http2_native_session} = $session;
        $session->start(100);

        for my $number (1 .. $expected) {
            my $path = "/raw-native/$number";
            my $stream_id = $session->submit_request([
                [ ':method', 'GET' ],
                [ ':scheme', 'http' ],
                [ ':authority', 'native.test' ],
                [ ':path', $path ],
                [ 'x-request-number', "$number" ],
            ]);
            $path_by_id{$stream_id} = $path;
        }

        flush_session($stream, $session);
        $stream->transition_to('T::NativeH2RawStream');
    },
    on_error => sub ($stream, $error) {
        push @errors, "client transport: $error";
        $loop->stop;
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 5,
    on_timer => sub ($timer) {
        die "native raw-input HTTP/2 bridge spike timed out\n";
    },
);

$loop->run;
$guard->cancel;

$client_stream->close
    if $client_stream && !$client_stream->is_closed;
$server_stream->close
    if $server_stream && !$server_stream->is_closed;
$listener->close if !$listener->is_closed;

is_deeply(\@errors, [],
    'native raw-input HTTP/2 exchange has no transport errors');
is(ref($client_stream), 'T::NativeH2RawStream',
    'client replaced its HTTP/1 native consumer with the HTTP/2 consumer');
is(ref($server_stream), 'T::NativeH2RawStream',
    'server replaced its HTTP/1 native consumer with the HTTP/2 consumer');
is(scalar(keys %closed), $expected,
    'all native raw-input client streams closed');
is($server_closed, $expected,
    'native raw-input server observed every stream close');

for my $stream_id (sort { $a <=> $b } keys %path_by_id) {
    my $path = $path_by_id{$stream_id};
    is($closed{$stream_id}, 0, "$path closed without HTTP/2 error");
    is($response{$stream_id}{':status'}, '200',
        "$path received status 200 through native input");
    is($response{$stream_id}{'x-native-path'}, $path,
        "$path retained independent multiplexed state");
}

done_testing;
