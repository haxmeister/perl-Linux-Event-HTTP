#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

# HTTP/2 conformance fixture with NO Linux::Event dependency.
# Each TLS connection owns a standalone Unblock::HTTP2::Server, driven by
# ordinary blocking IO::Socket::SSL reads and the engine's public byte API.
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use IO::Socket::SSL;
use POSIX ();

use Unblock::HTTP2::Server;

my $host = '127.0.0.1';
my $port = 19400;
my ($cert, $key);
my $response_mode = 'headers';

GetOptions(
    'host=s'          => \$host,
    'port=i'          => \$port,
    'cert=s'          => \$cert,
    'key=s'           => \$key,
    'response-mode=s' => \$response_mode,
) or die "usage: $0 --cert FILE --key FILE [--response-mode headers|request]\n";

die "--response-mode must be headers or request\n"
    unless $response_mode eq 'headers' || $response_mode eq 'request';
die "--cert and --key are required\n" unless defined($cert) && defined($key);
die "--port must be 1..65535\n" unless $port > 0 && $port <= 65_535;

my $listener = IO::Socket::INET->new(
    LocalAddr => $host,
    LocalPort => $port,
    Proto     => 'tcp',
    ReuseAddr => 1,
    Listen    => 64,
) or die "listen $host:$port: $!\n";

$SIG{CHLD} = 'IGNORE';
$SIG{PIPE} = 'IGNORE';
$| = 1;
say "READY $host:$port";

while (my $socket = $listener->accept) {
    my $child = fork;
    die "fork: $!\n" unless defined $child;

    if ($child) {
        close $socket;
        next;
    }

    close $listener;
    $SIG{CHLD} = 'DEFAULT';
    $SIG{ALRM} = sub { die "per-connection timeout\n" };
    alarm 15;
    my $ok = eval { serve_client($socket); 1 };
    warn "standalone fixture: $@" unless $ok;
    alarm 0;
    close $socket;
    POSIX::_exit(0);
}

die "accept failed: $!\n";

sub serve_client {
    my ($tcp) = @_;

    my $socket = IO::Socket::SSL->start_SSL(
        $tcp,
        SSL_server         => 1,
        SSL_cert_file      => $cert,
        SSL_key_file       => $key,
        SSL_verify_mode    => 0,
        SSL_alpn_protocols => ['h2'],
    );
    if (!$socket) {
        warn "TLS handshake: " . IO::Socket::SSL::errstr() . "\n";
        return;
    }
    my $negotiated = $socket->alpn_selected;
    die "expected TLS ALPN h2, got " . ($negotiated // '(none)') . "\n"
        unless defined($negotiated) && $negotiated eq 'h2';

    my $engine = Unblock::HTTP2::Server->new(
        on_request => sub {
            my ($tx, $request) = @_;
            $tx->on_data(sub { });
            respond($tx) if $response_mode eq 'headers';
        },
        on_request_end => sub {
            my ($tx, $request) = @_;
            respond($tx) if $response_mode eq 'request';
        },
    );

    # Flush SETTINGS before the first read, just as a connected host does.
    flush_output($engine, $socket);

    while (1) {
        my $input = '';
        my $n = $socket->sysread($input, 65_536);
        if (!defined $n) {
            warn "TLS input failed: " . IO::Socket::SSL::errstr() . "\n";
            last;
        }
        last unless $n;

        my $ok = eval { $engine->input($input); 1 };
        my $error = $@;
        flush_output($engine, $socket);
        if (!$ok) {
            warn "HTTP2 input rejected: $error";
            last;
        }
        last if $engine->is_closed;
    }
    return;
}

sub respond {
    my ($tx) = @_;
    $tx->respond(
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => "ok\n",
    );
    return;
}

sub flush_output {
    my ($engine, $socket) = @_;
    while (!$engine->is_closed && $engine->want_write) {
        my $bytes = $engine->output;
        last unless length $bytes;

        my $offset = 0;
        while ($offset < length $bytes) {
            my $written = $socket->syswrite(
                $bytes, length($bytes) - $offset, $offset,
            );
            die "TLS output failed: " . IO::Socket::SSL::errstr() . "\n"
                unless defined($written) && $written > 0;
            $offset += $written;
        }
    }
    return;
}
