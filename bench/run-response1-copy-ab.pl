#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Net::HTTP::_Native::Response1 ();
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

my $iterations = 200_000;
my $warmup = 20_000;
my $repeats = 5;
my $sizes = '0,32,256,4096';
my $smoke = 0;
my $help = 0;

GetOptions(
    'iterations=i' => \$iterations,
    'warmup=i'     => \$warmup,
    'repeats=i'    => \$repeats,
    'sizes=s'      => \$sizes,
    'smoke'        => \$smoke,
    'help'         => \$help,
) or usage(2);

usage(0) if $help;
if ($smoke) {
    $iterations = 10_000;
    $warmup = 1_000;
    $repeats = 1;
    $sizes = '0,32';
}

die "iterations must be > 0\n" if $iterations <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "repeats must be > 0\n" if $repeats <= 0;

my @size = map {
    die "sizes must contain non-negative integers\n" if !/\A\d+\z/;
    0 + $_;
} split /,/, $sizes;
die "sizes must not be empty\n" if !@size;

my $parser = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $native = 'Linux::Event::Net::HTTP::_Native::Response1';
my $request = $parser->parse_request(
    "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n",
    0,
    100,
);
die "failed to parse benchmark request\n" if !defined $request;

my $no_copy = $native->can('build_default_final')
    or die "build_default_final is unavailable\n";
my $copy = $native->can('_build_default_final_copy_reference')
    or die "copy-reference builder is unavailable\n";

say 'Linux::Event::Net::HTTP native response body-copy A/B';
say "iterations=$iterations warmup=$warmup repeats=$repeats sizes=$sizes";
say 'no_copy = production builder after 2a04725';
say 'copy = temporary reference preserving the old unconditional newSVsv(body) path';
say '';

for my $size (@size) {
    my $body = 'x' x $size;
    my $expected = $no_copy->($native, $request, $body);
    my $reference = $copy->($native, $request, $body);
    die "builder outputs differ for body size $size\n"
        if !defined($expected) || !defined($reference) || $expected ne $reference;

    run_iterations($no_copy, $request, $body, $warmup) if $warmup;
    run_iterations($copy, $request, $body, $warmup) if $warmup;

    my %record;
    for my $repeat (1 .. $repeats) {
        my @order = $repeat % 2
            ? ([ no_copy => $no_copy ], [ copy => $copy ])
            : ([ copy => $copy ], [ no_copy => $no_copy ]);

        for my $case (@order) {
            my ($name, $code) = @$case;
            my ($elapsed, $checksum) = run_iterations(
                $code, $request, $body, $iterations,
            );
            my $ops = $iterations / $elapsed;
            my $ns = $elapsed * 1_000_000_000 / $iterations;
            push @{$record{$name}}, $ops;
            printf "size=%-5d %-8s repeat=%d %12.1f ops/s %8.1f ns/op checksum=%d\n",
                $size, $name, $repeat, $ops, $ns, $checksum;
        }
    }

    my $no_copy_ops = median(@{$record{no_copy}});
    my $copy_ops = median(@{$record{copy}});
    my $delta = ($no_copy_ops / $copy_ops - 1) * 100;
    printf "size=%-5d median no_copy=%12.1f copy=%12.1f delta=%+.2f%%\n\n",
        $size, $no_copy_ops, $copy_ops, $delta;
}

sub run_iterations ($code, $request, $body, $count) {
    return (0, 0) if !$count;
    my $checksum = 0;
    my $start = time;
    for (1 .. $count) {
        my $wire = $code->($native, $request, $body);
        $checksum += length($wire);
    }
    return (time - $start, $checksum);
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
usage: bench/run-response1-copy-ab.pl [options]

  --iterations=N  measured builder calls per case/repeat (default 200000)
  --warmup=N      warmup builder calls per case/size (default 20000)
  --repeats=N     alternating A/B repeats (default 5)
  --sizes=LIST    comma-separated body sizes (default 0,32,256,4096)
  --smoke         tiny correctness/performance smoke
  --help          show this help
USAGE
    exit $status;
}
