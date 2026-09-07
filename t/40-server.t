use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::HTTP::Server::Connection;
use Linux::Event::HTTP::Server;

sub run_client ($loop, $server, $wire, $state) {
    my $guard = Linux::Event::Kernel::Timer->new(
        loop  => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "HTTP Server integration test timed out\n";
        },
    );

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write($wire);
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
        },
        on_eof => sub ($stream) {
            $guard->cancel;
            $stream->close;
            $server->close;
            $loop->stop;
        },
        on_error => sub ($stream, $error) {
            die "HTTP Server client failed: $error\n";
        },
    );

    $loop->run;
    return;
}

my $loop = Linux::Event::Loop->new;
my $state = {
    body => '',
    wire => '',
};
my $prefix = 'body=';

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    data => $state,
    on_request => sub ($conn, $req, $res) {
        $state->{request_class} = ref($req);
        $state->{response_class} = ref($res);
        $state->{connection_class} = ref($conn);
        $state->{same_data} = $conn->data == $state ? 1 : 0;
        $res->header('Content-Type', 'text/plain');
    },
    on_body => sub ($conn, $req, $res, $bytes) {
        $state->{body} .= $bytes;
    },
    on_request_end => sub ($conn, $req, $res) {
        $res->complete($prefix . $state->{body} . "\n");
    },
);

ok($server->is_tcp, 'Server exposes underlying TCP listener identity');
ok($server->port > 0, 'Server reports kernel-selected listener port');
is(
    $server->connection_class,
    'Linux::Event::HTTP::Server::Connection',
    'Server defaults to HTTP Connection class',
);
is($server->data, $state, 'Server exposes application data, not private accept state');

run_client(
    $loop,
    $server,
    "POST /upload HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Content-Length: 4\r\n" .
        "Connection: close\r\n" .
        "\r\n" .
        "data",
    $state,
);

is($state->{body}, 'data', 'Server forwards request body callback directly');
ok($state->{same_data}, 'accepted Connection receives Server application data');
is(
    $state->{connection_class},
    'Linux::Event::HTTP::Server::Connection',
    'private acceptance adapter returns the configured Connection object',
);
is(
    $state->{request_class},
    'Linux::Event::HTTP::Request',
    'Server callback receives Request object',
);
is(
    $state->{response_class},
    'Linux::Event::HTTP::Response',
    'Server callback receives bound Response object',
);
like(
    $state->{wire},
    qr/\AHTTP\/1\.1 200 OK\r\nContent-Type: text\/plain\r\nContent-Length: 10\r\nConnection: close\r\n\r\nbody=data\n\z/s,
    'simple Server callback form produces complete HTTP response',
);

{
    package T::ServerConnection;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $req, $res) {
        $self->data->{class_method_hits}++;
        $self->data->{actual_class} = ref($self);
        $res->complete("class\n");
    }
}

$loop = Linux::Event::Loop->new;
my $custom = {
    wire => '',
    class_method_hits => 0,
};

$server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    host             => '127.0.0.1',
    port             => 0,
    data             => $custom,
    connection_class => 'T::ServerConnection',
);

run_client(
    $loop,
    $server,
    "GET /class HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Connection: close\r\n" .
        "\r\n",
    $custom,
);

is($custom->{class_method_hits}, 1,
    'custom connection_class method handles accepted request');
is($custom->{actual_class}, 'T::ServerConnection',
    'accepted object is the configured custom Connection class');
like($custom->{wire}, qr/\r\n\r\nclass\n\z/s,
    'custom Connection response is delivered through Server');

$loop = Linux::Event::Loop->new;
my $override = {
    wire => '',
    class_method_hits => 0,
    callback_hits => 0,
};

$server = Linux::Event::HTTP::Server->new(
    loop             => $loop,
    host             => '127.0.0.1',
    port             => 0,
    data             => $override,
    connection_class => 'T::ServerConnection',
    on_request => sub ($conn, $req, $res) {
        $override->{callback_hits}++;
        $override->{actual_class} = ref($conn);
        $res->complete("override\n");
    },
);

run_client(
    $loop,
    $server,
    "GET /override HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Connection: close\r\n" .
        "\r\n",
    $override,
);

is($override->{callback_hits}, 1,
    'Server constructor callback runs on custom connection_class');
is($override->{class_method_hits}, 0,
    'constructor callback overrides same-named Connection method');
is($override->{actual_class}, 'T::ServerConnection',
    'callback override retains configured Connection subclass');
like($override->{wire}, qr/\r\n\r\noverride\n\z/s,
    'callback override response is delivered');

my $ok = eval {
    Linux::Event::HTTP::Server->new(
        loop => Linux::Event::Loop->new,
        host => '127.0.0.1',
        port => 0,
    );
    1;
};
ok(!$ok, 'default Server requires on_request callback');
like($@, qr/requires on_request/, 'missing handler error is clear');

$ok = eval {
    Linux::Event::HTTP::Server->new(
        loop => Linux::Event::Loop->new,
        host => '127.0.0.1',
        port => 0,
        on_request => sub ($conn, $req, $res) { $res->complete("ok\n") },
        on_request_final => sub { return "old\n" },
    );
    1;
};
ok(!$ok, 'Server rejects removed on_request_final option');
like($@, qr/on_request_final was removed/, 'Server gives migration guidance');

$ok = eval {
    Linux::Event::HTTP::Server->new(
        loop => Linux::Event::Loop->new,
        host => '127.0.0.1',
        port => 0,
        on_request => sub { },
        on_data => sub { },
    );
    1;
};
ok(!$ok, 'Server rejects raw on_data callback');
like($@, qr/owns on_data/, 'raw callback rejection explains HTTP ownership');

done_testing;
