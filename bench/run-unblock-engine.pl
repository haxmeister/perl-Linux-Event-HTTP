#!/usr/bin/env perl
use v5.36;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);
use JSON::PP;
use Unblock::HTTP::Server;
use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP1::_Wire;

# No sockets and no Linux::Event code. This isolates the engine/response
# cost; it is diagnostic, not an alternative end-to-end throughput claim.
package BenchSink;
sub new { bless { bytes => 0 }, shift }
sub unblock_send ($self, $bytes) { $self->{bytes} += length($bytes); return 1 }
sub unblock_finish { }
sub unblock_abort { die $_[1] }
package main;
my $requests = 100_000;
my $json;
GetOptions('requests=i' => \$requests, 'json=s' => \$json) or die 'bad options';
die 'requests must be positive' unless $requests > 0;
my $body = 'x' x 32;
my $wire = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
my $sink = BenchSink->new;
my $definition = Unblock::HTTP::Server->new(http1 => {},
    on_request => sub ($tx, $request) { $tx->respond(status => 200, body => $body) });
my $engine = $definition->attach_stream(transport => $sink);
my $request = Uniform::HTTP::Request->new(method => 'GET', target => '/', version => '1.1');
my @rows;
for my $case (
    ['engine_input_and_response', sub { $engine->input($wire) }],
    ['response_construction', sub { Uniform::HTTP::Response->new(status => 200, body => $body) }],
    ['response_construction_and_wire_plan', sub {
        Unblock::HTTP1::_Wire::response_plan($request,
            Uniform::HTTP::Response->new(status => 200, body => $body));
    }],
) {
    my ($name, $run) = @$case;
    $run->() for 1 .. 1000;
    my $start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    $run->() for 1 .. $requests;
    my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $start;
    push @rows, { name => $name, iterations => $requests, cpu_seconds => $cpu,
        cpu_us_per_iteration => $cpu * 1_000_000 / $requests };
    printf "%s %.3f CPU us/iteration\n", $name, $cpu * 1_000_000 / $requests;
}
if ($json) {
    open my $fh, '>', $json or die "$json: $!";
    print {$fh} JSON::PP->new->canonical->pretty->encode(\@rows);
    close $fh or die $!;
}
