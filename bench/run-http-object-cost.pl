#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Scalar::Util qw(weaken);
use Time::HiRes qw(time);

use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::Response;
use Linux::Event::Net::HTTP::_Parser::HTTP1;

my $iterations = 500_000;
my $warmup = 50_000;
my $repeats = 7;
my $help = 0;

GetOptions(
    'iterations=i' => \$iterations,
    'warmup=i'     => \$warmup,
    'repeats=i'    => \$repeats,
    'help'         => \$help,
) or usage(2);
usage(0) if $help;
die "iterations must be > 0\n" if $iterations <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "repeats must be > 0\n" if $repeats <= 0;

my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $REQUEST_WIRE = "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n";
my $request = $PARSER->parse_request($REQUEST_WIRE, 0, 100)
    or die "failed to parse benchmark request\n";
my $empty_headers = [];
my $sink = 0;

{
    package Linux::Event::Net::HTTP::Bench::ObjectCostConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';
    sub DESTROY ($self) { return }
}

{
    package Linux::Event::Net::HTTP::Bench::ArrayResponse;
}

my $connection = bless {},
    'Linux::Event::Net::HTTP::Bench::ObjectCostConnection';
my $cached_state = {
    mode      => 'none',
    body_done => 0,
};
my $cached_response = Linux::Event::Net::HTTP::Response->_new_bound(
    $connection, $request,
);

my @case = (
    {
        name => 'noop',
        description => 'benchmark loop/sub-call floor',
        code => sub { $sink += 1 },
    },
    {
        name => 'parse_direct',
        description => 'pico parse_request/native Request construction without Perl eval boundary',
        code => sub {
            my $parsed = $PARSER->parse_request($REQUEST_WIRE, 0, 100);
            $sink += defined($parsed) ? 1 : 0;
        },
    },
    {
        name => 'parse_eval',
        description => 'same parse_request call inside the production-style Perl eval boundary',
        code => sub {
            my $parsed;
            my $ok = eval {
                $parsed = $PARSER->parse_request($REQUEST_WIRE, 0, 100);
                1;
            };
            die "benchmark parse unexpectedly failed\n" if !$ok;
            $sink += defined($parsed) ? 1 : 0;
        },
    },
    {
        name => 'request_consumed',
        description => 'Request->_consumed accessor',
        code => sub {
            $sink += $request->_consumed;
        },
    },
    {
        name => 'request_body_mode',
        description => 'Request->body_mode accessor on bodyless GET',
        code => sub {
            $sink += $request->body_mode eq 'none' ? 1 : 0;
        },
    },
    {
        name => 'request_http_version',
        description => 'Request->http_version accessor on HTTP/1.1 GET',
        code => sub {
            $sink += $request->http_version eq '1.1' ? 1 : 0;
        },
    },
    {
        name => 'expect_header_values',
        description => q{Request->header_values('Expect') on request without Expect},
        code => sub {
            my @values = $request->header_values('Expect');
            $sink += scalar @values;
        },
    },
    {
        name => 'expect_continue',
        description => 'Production _expect_continue check on request without Expect',
        code => sub {
            $sink += Linux::Event::Net::HTTP::Connection::_expect_continue(
                $request,
            );
        },
    },
    {
        name => 'response_hash_strong',
        description => 'Response-shaped blessed hash allocation with strong connection reference',
        code => sub {
            my $response = bless {
                status          => 200,
                reason          => undef,
                headers         => $empty_headers,
                connection      => $connection,
                request         => $request,
                started         => 0,
                ended           => 0,
                upgrade_pending => 0,
            }, 'Linux::Event::Net::HTTP::Response';
            $sink += $response->{status};
        },
    },
    {
        name => 'response_hash_weak',
        description => 'Same Response-shaped blessed hash plus weaken(connection)',
        code => sub {
            my $response = bless {
                status          => 200,
                reason          => undef,
                headers         => $empty_headers,
                connection      => $connection,
                request         => $request,
                started         => 0,
                ended           => 0,
                upgrade_pending => 0,
            }, 'Linux::Event::Net::HTTP::Response';
            weaken($response->{connection});
            $sink += $response->{status};
        },
    },
    {
        name => 'response_new_bound',
        description => 'Production Response->_new_bound constructor',
        code => sub {
            my $response = Linux::Event::Net::HTTP::Response->_new_bound(
                $connection, $request,
            );
            $sink += $response->{status};
        },
    },
    {
        name => 'response_array_strong',
        description => 'Eight-slot blessed array proxy with strong connection reference',
        code => sub {
            my $response = bless [
                200,
                undef,
                $empty_headers,
                $connection,
                $request,
                0,
                0,
                0,
            ], 'Linux::Event::Net::HTTP::Bench::ArrayResponse';
            $sink += $response->[0];
        },
    },
    {
        name => 'response_array_weak',
        description => 'Eight-slot blessed array proxy plus weaken(connection)',
        code => sub {
            my $response = bless [
                200,
                undef,
                $empty_headers,
                $connection,
                $request,
                0,
                0,
                0,
            ], 'Linux::Event::Net::HTTP::Bench::ArrayResponse';
            weaken($response->[3]);
            $sink += $response->[0];
        },
    },
    {
        name => 'request_state_alloc',
        description => 'Production _new_request_state allocation for the bodyless GET',
        code => sub {
            my $state = Linux::Event::Net::HTTP::Connection::_new_request_state(
                $request,
            );
            $sink += $state->{body_done};
        },
    },
    {
        name => 'bodyless_state_reuse',
        description => 'Production-style cached bodyless state reset',
        code => sub {
            $cached_state->{body_done} = 0;
            delete $cached_state->{close_after_response};
            $sink += $cached_state->{body_done};
        },
    },
    {
        name => 'active_assign_clear',
        description => 'Assign and clear active transaction references using cached state/response',
        code => sub {
            $connection->{_http_active_request} = $request;
            $connection->{_http_active_response} = $cached_response;
            $connection->{_http_request_state} = $cached_state;
            $connection->{_http_response_state} = undef;
            Linux::Event::Net::HTTP::Connection::_clear_transaction($connection);
            $sink += 1;
        },
    },
);

say 'Linux::Event::Net::HTTP object/request cost benchmark';
say "perl=$^V iterations=$iterations warmup=$warmup repeats=$repeats";
say 'array cases are representation proxies only; they do not exercise Response methods';

for my $entry (@case) {
    run_iterations($entry->{code}, $warmup) if $warmup;
}

my @record;
for my $repeat (1 .. $repeats) {
    for my $entry (rotated_cases($repeat, @case)) {
        my $elapsed = run_iterations($entry->{code}, $iterations);
        my $ops = $iterations / $elapsed;
        my $ns = $elapsed * 1_000_000_000 / $iterations;
        push @record, {
            case => $entry->{name},
            repeat => $repeat,
            operations_per_second => $ops,
            nanoseconds_per_operation => $ns,
        };
        printf "%-24s repeat=%d %12.1f ops/s %9.1f ns/op\n",
            $entry->{name}, $repeat, $ops, $ns;
    }
}

say '';
say 'Median comparison';
printf "%-24s %14s %12s\n", 'case', 'ops/s', 'ns/op';
for my $entry (@case) {
    my @set = grep { $_->{case} eq $entry->{name} } @record;
    printf "%-24s %14.1f %12.1f\n",
        $entry->{name},
        median(map { $_->{operations_per_second} } @set),
        median(map { $_->{nanoseconds_per_operation} } @set);
}

END { $sink = 0 if $sink < 0 }

sub run_iterations ($code, $count) {
    my $start = time;
    $code->() for 1 .. $count;
    my $elapsed = time - $start;
    return $elapsed > 0 ? $elapsed : 1e-9;
}

sub rotated_cases ($repeat, @list) {
    return @list if @list < 2;
    my $offset = ($repeat - 1) % @list;
    return (@list[$offset .. $#list], @list[0 .. $offset - 1]);
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
usage: bench/run-http-object-cost.pl [options]

  --iterations=N   measured iterations per case/repeat (default 500000)
  --warmup=N       warmup iterations per case (default 50000)
  --repeats=N      rotated repeats (default 7)
  --help           show this help
USAGE
    exit $status;
}
