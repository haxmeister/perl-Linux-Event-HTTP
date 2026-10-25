#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;

my $port = $ENV{BENCH_PORT} // die "BENCH_PORT required\n";
my $body_bytes = 0 + ($ENV{BENCH_RESPONSE_BYTES} // 32);
my $payload = 'x' x $body_bytes;
my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    on_request => sub ($tx, $request) {
        # The complete request body has already been received by Unblock.
        # Each response is constructed through the documented public API,
        # without caching, parser shortcuts or benchmark-only optimizations.
        $tx->respond(
            status => 200,
            headers => [
                [ 'Content-Type', 'application/octet-stream' ],
                [ 'Content-Length', length($payload) ],
            ],
            body => $payload,
        );
    },
);
$loop->run;
