use v5.36;
use strict;
use warnings;

use Test::More;
use Scalar::Util ();

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::HTTP::Server::Connection;

{
    package T::BodyStreamHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $req, $res) {
        push @{$self->data->{targets}}, $req->target;

        if ($req->target eq '/scalar') {
            $res->body("hello\n");
            $res->header('X-After-Body', 'yes');
            return;
        }

        if ($req->target eq '/stream') {
            $res->header('Content-Type', 'text/plain');
            my $body = $res->stream_body(
                on_cancel => sub ($body) {
                    ++$self->data->{unexpected_cancel};
                },
            );
            $self->data->{same_stream}
                = Scalar::Util::refaddr($body)
                == Scalar::Util::refaddr($res->stream_body) ? 1 : 0;
            $self->data->{started_after_stream_body}
                = $res->is_started ? 1 : 0;
            $res->header('X-After-Stream-Body', 'yes');
            push @{$self->data->{write_status}}, $body->write("one\n");
            $self->data->{started_after_stream_write}
                = $res->is_started ? 1 : 0;
            my $late_metadata = eval {
                $res->header('X-Too-Late', 'no');
                1;
            };
            $self->data->{metadata_locked_after_stream_write}
                = $late_metadata ? 0 : 1;
            $body->complete("two\n");
            return;
        }

        if ($req->target eq '/async') {
            my $timer;
            $timer = Linux::Event::Kernel::Timer->new(
                loop  => $self->loop,
                after => 0.01,
                on_timer => sub ($timer_object) {
                    $res->header('X-Async', 'yes');
                    $res->body("later\n");
                    $self->data->{async_timer} = undef;
                },
            );
            $self->data->{async_timer} = $timer;
            return;
        }

        $res->body("done\n");
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    targets                            => [],
    write_status                       => [],
    wire                               => '',
    same_stream                        => 0,
    unexpected_cancel                  => 0,
    started_after_stream_body          => 1,
    started_after_stream_write         => 0,
    metadata_locked_after_stream_write => 0,
};

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::BodyStreamHTTP',
        data  => $state,
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop  => $loop,
    after => 2,
    on_timer => sub ($timer) {
        die "response body/stream integration test timed out\n";
    },
);

my $client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $stream->write(
            "GET /scalar HTTP/1.1\r\nHost: example.test\r\n\r\n" .
            "GET /stream HTTP/1.1\r\nHost: example.test\r\n\r\n" .
            "GET /async HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
        );
    },
    on_data => sub ($stream, $bytes) {
        $state->{wire} .= $bytes;
    },
    on_eof => sub ($stream) {
        $guard->cancel;
        $stream->close;
        $listener->close;
        $loop->stop;
    },
    on_error => sub ($stream, $error) {
        die "response body/stream client failed: $error\n";
    },
);

$loop->run;

is_deeply(
    $state->{targets},
    [ '/scalar', '/stream', '/async' ],
    'body and stream responses preserve pipelined request order',
);
ok($state->{same_stream}, 'stream_body returns one stable stream object');
ok(!$state->{started_after_stream_body},
    'selecting stream_body does not start response output');
ok($state->{started_after_stream_write},
    'first stream write starts response output');
ok($state->{metadata_locked_after_stream_write},
    'response metadata locks after first stream write');
ok($state->{write_status}[0], 'stream_body write exposes Linux::Event flow-control return');
is($state->{unexpected_cancel}, 0, 'normally completed stream is not cancelled');

my $wire = $state->{wire};
like(
    $wire,
    qr/\AHTTP\/1\.1 200 OK\r\nX-After-Body: yes\r\nContent-Length: 6\r\n\r\nhello\n/s,
    'scalar body commits after callback so later metadata changes are retained',
);
like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nX-After-Stream-Body: yes\r\nTransfer-Encoding: chunked\r\n\r\n4\r\none\n\r\n4\r\ntwo\n\r\n0\r\n\r\n/s,
    'stream_body stays configurable until first write then uses HTTP chunk framing',
);
like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nX-Async: yes\r\nContent-Length: 6\r\nConnection: close\r\n\r\nlater\n\z/s,
    'body set from a later event callback commits the waiting response',
);

{
    package T::CancelBodyHTTP;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $req, $res) {
        $self->data->{connection} = $self;
        $res->stream_body(
            on_cancel => sub ($body) {
                ++$self->data->{cancelled};
                $self->data->{guard}->cancel;
                $self->data->{listener}->close;
                $self->data->{loop}->stop;
            },
        );
        $self->data->{body} = $res->stream_body;
    }

    sub on_close ($self) {
        ++$self->data->{user_close};
    }
}

$loop = Linux::Event::Loop->new;
my $cancel_state = {
    loop       => $loop,
    cancelled  => 0,
    user_close => 0,
};

$listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::CancelBodyHTTP',
        data  => $cancel_state,
    },
);
$cancel_state->{listener} = $listener;

$guard = Linux::Event::Kernel::Timer->new(
    loop  => $loop,
    after => 2,
    on_timer => sub ($timer) {
        die "stream body cancellation test timed out\n";
    },
);
$cancel_state->{guard} = $guard;

my $cancel_timer;
$client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $stream->write("GET /cancel HTTP/1.1\r\nHost: example.test\r\n\r\n");
        $cancel_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop,
            after => 0.05,
            on_timer => sub ($timer) {
                my $connection = $cancel_state->{connection};
                $connection->close if $connection && !$connection->is_closed;
            },
        );
    },
    on_data => sub ($stream, $bytes) { },
    on_eof => sub ($stream) {
        $stream->close;
    },
    on_error => sub ($stream, $error) {
        die "stream body cancellation client failed: $error\n";
    },
);

$loop->run;

is($cancel_state->{cancelled}, 1,
    'closing the HTTP connection cancels an unfinished stream body exactly once');
ok($cancel_state->{body}->is_cancelled,
    'cancelled stream body exposes terminal cancellation state');
is($cancel_state->{user_close}, 1,
    'custom Connection on_close composes with stream-body cancellation');

done_testing;
