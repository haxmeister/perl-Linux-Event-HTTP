#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use EV ();
use Feersum;
use IO::Socket::INET;

my $port = $ENV{BENCH_PORT} // die "BENCH_PORT is required\n";
my $response_bytes = $ENV{BENCH_RESPONSE_BYTES} // 32;
my $payload = 'x' x $response_bytes;

my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0 + $port,
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen 127.0.0.1:$port: $!\n";

my $engine = Feersum->endjinn;
$engine->use_socket($listener);
$engine->request_handler(sub ($request) {
    $request->send_response(
        200,
        ['Content-Type' => 'application/octet-stream'],
        \$payload,
    );
    return;
});

EV::run;
