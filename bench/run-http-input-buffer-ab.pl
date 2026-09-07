#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

my $requests = 300_000;
my $warmup = 30_000;
my $repeats = 5;
my $smoke = 0;
my $help = 0;

GetOptions(
    'requests=i' => \$requests,
    'warmup=i'   => \$warmup,
    'repeats=i'  => \$repeats,
    'smoke'      => \$smoke,
    'help'       => \$help,
) or usage(2);

usage(0) if $help;
if ($smoke) {
    $requests = 4_000;
    $warmup = 400;
    $repeats = 1;
}

die "requests must be > 0\n" if $requests <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "repeats must be > 0\n" if $repeats <= 0;

my $parser = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $wire = "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n";
my $split_at = int(length($wire) / 2);
my $split_a = substr($wire, 0, $split_at);
my $split_b = substr($wire, $split_at);
my $coalesced = $wire x 4;

my @case = (
    {
        name => 'single',
        description => 'one complete request per incoming chunk',
        chunks => [ $wire ],
        requests_per_batch => 1,
    },
    {
        name => 'coalesced4',
        description => 'four complete requests in one incoming chunk',
        chunks => [ $coalesced ],
        requests_per_batch => 4,
    },
    {
        name => 'split2',
        description => 'one request split across two incoming chunks',
        chunks => [ $split_a, $split_b ],
        requests_per_batch => 1,
    },
);

say 'Linux::Event::Net::HTTP input-buffer strategy A/B';
say "requests=$requests warmup=$warmup repeats=$repeats request_bytes=" . length($wire);
say 'legacy = always append with .= and always remove consumed prefix with substr';
say 'adopt = assign an incoming chunk when input is empty and assign empty string when parser consumed all input';
say '';

for my $case (@case) {
    my $measured = normalized_request_count(
        $requests, $case->{requests_per_batch},
    );
    my $warm = normalized_request_count(
        $warmup, $case->{requests_per_batch},
    );

    run_case('legacy', $case, $warm) if $warm;
    run_case('adopt', $case, $warm) if $warm;

    my %record;
    for my $repeat (1 .. $repeats) {
        my @order = $repeat % 2 ? qw(legacy adopt) : qw(adopt legacy);
        for my $strategy (@order) {
            my ($elapsed, $parsed) = run_case(
                $strategy, $case, $measured,
            );
            die "$case->{name}/$strategy parsed $parsed requests, expected $measured\n"
                if $parsed != $measured;

            my $rate = $parsed / $elapsed;
            my $ns = $elapsed * 1_000_000_000 / $parsed;
            push @{$record{$strategy}}, $rate;
            printf "%-10s %-7s repeat=%d %12.1f req/s %8.1f ns/req\n",
                $case->{name}, $strategy, $repeat, $rate, $ns;
        }
    }

    my $legacy = median(@{$record{legacy}});
    my $adopt = median(@{$record{adopt}});
    my $delta = ($adopt / $legacy - 1) * 100;
    printf "%-10s median legacy=%12.1f adopt=%12.1f delta=%+.2f%%  # %s\n\n",
        $case->{name}, $legacy, $adopt, $delta, $case->{description};
}

sub normalized_request_count ($wanted, $per_batch) {
    return 0 if !$wanted;
    return int($wanted / $per_batch) * $per_batch || $per_batch;
}

sub run_case ($strategy, $case, $target_requests) {
    my $input = '';
    my $parsed = 0;
    my $batches = int($target_requests / $case->{requests_per_batch});

    my $start = time;
    for (1 .. $batches) {
        for my $chunk (@{$case->{chunks}}) {
            if ($strategy eq 'adopt' && !length($input)) {
                $input = $chunk;
            } else {
                $input .= $chunk;
            }

            while (length($input)) {
                my $request = $parser->parse_request($input, 0, 100);
                last if !defined $request;

                my $consumed = $request->_consumed;
                if ($strategy eq 'adopt' && $consumed == length($input)) {
                    $input = '';
                } else {
                    substr($input, 0, $consumed, '');
                }
                ++$parsed;
            }
        }
    }
    my $elapsed = time - $start;

    die "$case->{name}/$strategy left " . length($input) . " unconsumed bytes\n"
        if length($input);
    return ($elapsed, $parsed);
}

sub median (@values) {
    return 0 if !@values;
    @values = sort { $a <=> $b } @values;
    my $mid = int(@values / 2);
    return @values % 2
        ? $values[$mid]
        : ($values[$mid - 1] + $values[$mid]) / 2;
}

sub usage ($status) {
    print <<'USAGE';
usage: bench/run-http-input-buffer-ab.pl [options]

  --requests=N  target parsed requests per strategy/case/repeat (default 300000)
  --warmup=N    warmup parsed requests per strategy/case (default 30000)
  --repeats=N   alternating A/B repeats (default 5)
  --smoke       tiny correctness/performance smoke
  --help        show this help
USAGE
    exit $status;
}
