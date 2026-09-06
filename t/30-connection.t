use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::Response;

{
    package T::HTTPConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';
    use Linux::Event::Net::HTTP::Response;

    sub on_request ($self, $request) {
        push @{$self->data->{targets}}, $request->target;

        my $body = $request->target eq '/one' ? "one\n" : "two\n";
        my $response = Linux::Event::Net::HTTP::Response->new(
            status => 200,
            headers => [
                [ 'Content-Type', 'text/plain' ],
            ],
        );
        $self->respond($response, $body);
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    targets  => [],
    response => '',
    eof      => 0,
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
ok($state->{eof}, 'Connection close request drains responses then ends stream');

my $wire = $state->{response};
my @status = $wire =~ /HTTP\/1\.1 200 OK\r\n/g;
is(scalar @status, 2, 'two HTTP responses were serialized on one connection');

like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nContent-Length: 4\r\n\r\none\n/s,
    'first response has automatic Content-Length and body',
);
like(
    $wire,
    qr/HTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntwo\n\z/s,
    'second response advertises close and drains final body',
);

{
    package T::DeferredHTTPConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';
    use Linux::Event::Kernel::Timer;
    use Linux::Event::Net::HTTP::Response;

    sub on_request ($self, $request) {
        $self->data->{connection} = $self;
        $self->data->{request} = $request;

        Linux::Event::Kernel::Timer->new(
            loop  => $self->loop,
            after => 0.02,
            data  => $self,
            on_timer => sub ($timer) {
                my $connection = $timer->data;
                $connection->data->{paused_before_response}
                    = $connection->is_read_paused ? 1 : 0;
                my $response = Linux::Event::Net::HTTP::Response->new(
                    status => 200,
                );
                $connection->respond($response, "later\n");
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
    'Connection pauses reads while an application response is pending',
);
is(
    $deferred->{request}->target,
    '/later',
    'deferred callback retains stable Request object',
);
like(
    $deferred->{response},
    qr/Content-Length: 6\r\nConnection: close\r\n\r\nlater\n\z/s,
    'respond can complete a request from a later event',
);

done_testing;
