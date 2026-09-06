use v5.36;
use strict;
use warnings;

use Benchmark qw(cmpthese);
use Getopt::Long qw(GetOptions);
use Linux::Event::Net::HTTP::_Parser::HTTP1;

my $iterations = 500_000;
GetOptions(
    'iterations=i' => \$iterations,
) or die "usage: $0 [--iterations=N]\n";

die "--iterations must be positive\n" if $iterations < 1;

my $parser = 'Linux::Event::Net::HTTP::_Parser::HTTP1';

say "picohttpparser ", $parser->pico_version;
say "iterations=$iterations";

for my $header_count (4, 16, 64) {
    my @lines = (
        "GET /api/resource?x=1 HTTP/1.1\r\n",
        "Host: example.test\r\n",
        "User-Agent: Linux-Event-Net-HTTP-Bench\r\n",
        "Accept: */*\r\n",
        "Connection: keep-alive\r\n",
    );

    for my $i (5 .. $header_count) {
        push @lines, "X-Bench-$i: value-$i\r\n";
    }
    push @lines, "\r\n";

    my $request = join '', @lines;

    say '';
    say "headers=$header_count bytes=", length($request);

    cmpthese(
        $iterations,
        {
            pico_probe => sub {
                $parser->probe_request($request, 0, 100);
            },
            pico_offsets => sub {
                $parser->parse_request_offsets($request, 0, 100);
            },
            pico_materialize => sub {
                my $parsed = $parser->parse_request_offsets($request, 0, 100);
                substr($request, $parsed->[2], $parsed->[3]);
                substr($request, $parsed->[4], $parsed->[5]);
                for my $header (@{$parsed->[6]}) {
                    substr($request, $header->[0], $header->[1]);
                    substr($request, $header->[2], $header->[3]);
                }
            },
        },
    );
}
