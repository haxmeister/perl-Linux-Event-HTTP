#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);

use Linux::Event::HTTP::Server;
use Linux::Event::Loop;

my $host = '127.0.0.1';
my $port = 18443;
my ($cert, $key);
my $native = 1;

GetOptions(
    'host=s' => \$host,
    'port=i' => \$port,
    'cert=s' => \$cert,
    'key=s'  => \$key,
    'native-input!' => \$native,
) or die "usage: $0 --cert FILE --key FILE [--host HOST] [--port PORT]\n";

die "--cert is required\n" if !defined($cert) || $cert eq '';
die "--key is required\n" if !defined($key) || $key eq '';
die "--port must be between 1 and 65535\n"
    if $port < 1 || $port > 65_535;

my $loop = Linux::Event::Loop->new;

my $server = Linux::Event::HTTP::Server->new(
    loop  => $loop,
    host  => $host,
    port  => $port,
    http2 => 1,
    native_input => $native,
    tls   => {
        cert_file => $cert,
        key_file  => $key,
    },
    # Match the original conformance fixture: respond at headers while
    # draining any incoming body. Some tests deliberately leave it open.
    on_headers => sub ($tx, $request) {
        $tx->on_data(sub { });
        $tx->respond(status => 200,
            headers => [['content-type', 'text/plain']], body => "ok\n");
    },
    on_request => sub { },
);

$| = 1;
say "READY " . $server->host . ":" . $server->port;

$loop->run;
