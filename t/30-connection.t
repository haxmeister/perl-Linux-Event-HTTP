use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Net::HTTP::Connection;

{
    package T::HTTPConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';

    sub on_request ($self, $request, $response) {
        push @{$self->data->{targets}}, $request->target;
        push @{$self->data->{responses}}, $response;
        push @{$self->data->{paired}},
            $response->request == $request
            && $response->connection == $self ? 1 : 0;

        $response->status(200);
        $response->header('Content-Type', 'text/plain');

        if ($request->target eq '/one') {
            $response->header('Content-Length', 4);
            push @{$self->data->{write_status}}, $response->write('on');
            $response->end("e\n");
        } else {
            $response->end("two\n");
        }
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    targets      => [],
    responses    => [],
    paired       => [],
    write_status => [],
    response     => '',
    eof          => 0,
};

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'T::HTTPConnection',
    host         => '127.0.0.1',
    port         => 0,
    data         => $state,
);

my $client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $stream->write(
            "GET /one HTTP/1.1\r\n" .
            "Host: example.test\r\n" .
            "\r\n" .
            "GET /two HTTP/1.1\r\n" .
            "Host: example.test\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );
    },
    on_data => sub ($stream, $bytes) {
        $state->{response} .= $bytes;
    },
    on_eof => sub ($stream) {
        $state->{eof} = 1;
        $stream->close;
        $listener->close;
        $loop->stop;
    },
    on_error => sub ($stream, $error) {
        die "HTTP test client failed: $error\n";
    },
);

$loop->run;

is_deeply(
    $state->{targets},
    [ '/one', '/two' ],
    'one accepted HTTP connection dispatches pipelined requests in order',
);
is_deeply(
    $state->{paired},
    [ 1, 1 ],
    'each request receives a Response bound to the same transaction',
);
ok($state->{write_status}[0], 'Response write exposes Stream backpressure status');
ok(
    $state->{responses}[0]->is_ended && $state->{responses}[1]->is_ended,
    'each Response is ended when its transaction completes',
);
my $mutation_ok = eval { $state->{responses}[0]->status(201); 1 };
ok(!$mutation_ok, 'completed Response metadata is immutable');
like($@, qr/cannot change|already ended/, 'completed metadata rejection is clear');
ok($state->{eof}, 'Connection close request drains responses then ends stream');

my $wire = $state->{response};
my @status = $wire =~ /HTTP\/1\.1 200 OK\r\n/g;
is(scalar @status, 2, 'two HTTP responses were serialized on one connection');

like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nContent-Length: 4\r\n\r\none\n/s,
    'fixed-length Response write/end emits first body without buffering it whole',
);
like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntwo\n\z/s,
    'Response end adds Content-Length and drains close response',
);

{
    package T::DeferredHTTPConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';
    use Linux::Event::Kernel::Timer;

    sub on_request ($self, $request, $response) {
        $self->data->{request} = $request;
        $self->data->{bound_response} = $response;

        Linux::Event::Kernel::Timer->new(
            loop  => $self->loop,
            after => 0.02,
            data  => $response,
            on_timer => sub ($timer) {
                my $response = $timer->data;
                my $connection = $response->connection;
                $connection->data->{paused_before_response}
                    = $connection->is_read_paused ? 1 : 0;
                $response->end("later\n");
            },
        );
        return;
    }
}

$loop = Linux::Event::Loop->new;
my $deferred = {
    response => '',
};

$listener = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'T::DeferredHTTPConnection',
    host         => '127.0.0.1',
    port         => 0,
    data         => $deferred,
);

$client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $stream->write(
            "GET /later HTTP/1.1\r\n" .
            "Host: example.test\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );
    },
    on_data => sub ($stream, $bytes) {
        $deferred->{response} .= $bytes;
    },
    on_eof => sub ($stream) {
        $stream->close;
        $listener->close;
        $loop->stop;
    },
    on_error => sub ($stream, $error) {
        die "deferred HTTP test client failed: $error\n";
    },
);

$loop->run;

ok(
    $deferred->{paused_before_response},
    'Connection pauses reads while its bound Response is pending',
);
is(
    $deferred->{request}->target,
    '/later',
    'deferred callback retains stable Request object',
);
is(
    $deferred->{bound_response}->request,
    $deferred->{request},
    'deferred Response retains its paired Request',
);
ok(
    $deferred->{bound_response}->is_ended,
    'deferred Response records transaction completion',
);
like(
    $deferred->{response},
    qr/Content-Length: 6\r\nConnection: close\r\n\r\nlater\n\z/s,
    'Response can complete its request from a later event',
);

done_testing;
