#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(strftime uname);
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);

use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::Response;
use Linux::Event::Net::HTTP::_Parser::HTTP1;

my $iterations = 200_000;
my $warmup = 20_000;
my $repeats = 7;
my $response_bytes = 32;
my $json_path;
my $help = 0;

GetOptions(
    'iterations=i'     => \$iterations,
    'warmup=i'         => \$warmup,
    'repeats=i'        => \$repeats,
    'response-bytes=i' => \$response_bytes,
    'json=s'           => \$json_path,
    'help'             => \$help,
) or usage(2);

usage(0) if $help;
die "iterations must be > 0\n" if $iterations <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "repeats must be > 0\n" if $repeats <= 0;
die "response-bytes must be >= 0\n" if $response_bytes < 0;

my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $REQUEST_WIRE = "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n";
our $PAYLOAD = 'x' x $response_bytes;
our $WIRE = "HTTP/1.1 200 OK\r\nContent-Length: $response_bytes\r\n\r\n$PAYLOAD";
our $SINK = 0;

{
    package Linux::Event::Net::HTTP::Bench::HotPathConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';

    sub is_closed ($self) { 0 }

    sub is_read_paused ($self) {
        return $self->{_bench_read_paused} ? 1 : 0;
    }

    sub pause_read ($self) {
        $self->{_bench_read_paused} = 1;
        return $self;
    }

    sub resume_read ($self) {
        $self->{_bench_read_paused} = 0;
        return $self;
    }

    sub write ($self, $bytes) {
        $self->{_bench_wire_bytes} += length($bytes);
        return 1;
    }

    sub end ($self, $bytes = '') {
        $self->{_bench_wire_bytes} += length($bytes);
        return 1;
    }

    sub bench_on_request ($self, $request, $response) {
        return;
    }

    sub bench_on_request_end ($self, $request, $response) {
        $response->end($main::PAYLOAD);
        return;
    }

    # This benchmark object intentionally bypasses Stream construction and has
    # no native transport state. Do not inherit the real Stream destructor.
    sub DESTROY ($self) { return }
}

my $template_request = $PARSER->parse_request($REQUEST_WIRE, 0, 100)
    or die "failed to parse benchmark request\n";
my $fake = new_fake_connection();
my $noop_response = Linux::Event::Net::HTTP::Response->_new_bound(
    $fake, $template_request,
);

my @case = (
    {
        name => 'pico_probe',
        description => 'pico parse only; no HTTP semantic validation or Request allocation',
        code => sub {
            $SINK += $PARSER->probe_request($REQUEST_WIRE, 0, 100);
        },
    },
    {
        name => 'parse_request',
        description => 'parse, HTTP semantic validation, native Request allocation/head copy, Perl Request wrapper',
        code => sub {
            my $request = $PARSER->parse_request($REQUEST_WIRE, 0, 100);
            $SINK += $request->_consumed;
        },
    },
    {
        name => 'request_hot_access',
        description => 'Request metadata accesses used by the common GET response path',
        code => sub {
            my $request = $template_request;
            my $consumed = $request->_consumed;
            my $body_mode = $request->body_mode;
            my @expect = $request->header_values('Expect');
            my $version = $request->http_version;
            my $method = $request->method;
            my $keep_alive_a = $request->keep_alive;
            my $keep_alive_b = $request->keep_alive;
            $SINK += $consumed + length($body_mode) + @expect
                + length($version) + length($method)
                + $keep_alive_a + $keep_alive_b;
        },
    },
    {
        name => 'request_state',
        description => 'Per-request Perl transaction-state allocation',
        code => sub {
            my $state = Linux::Event::Net::HTTP::Connection::_new_request_state(
                $template_request,
            );
            $SINK += length($state->{mode}) + $state->{body_done};
        },
    },
    {
        name => 'response_new_bound',
        description => 'Per-request Response hash allocation plus weak connection binding',
        code => sub {
            my $response = Linux::Event::Net::HTTP::Response->_new_bound(
                $fake, $template_request,
            );
            $SINK += $response->status;
        },
    },
    {
        name => 'callback_pair',
        description => 'Two guarded HTTP callback invocations through _invoke_http_callback',
        code => sub {
            Linux::Event::Net::HTTP::Connection::_invoke_http_callback(
                $fake,
                \&Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request,
                $template_request,
                $noop_response,
            );
            Linux::Event::Net::HTTP::Connection::_invoke_http_callback(
                $fake,
                \&Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request,
                $template_request,
                $noop_response,
            );
            $SINK += 1;
        },
    },
    {
        name => 'callback_pair_fused',
        description => 'Two HTTP callbacks under one localized dispatch flag and eval boundary',
        code => sub {
            my $ok;
            {
                local $fake->{_http_dispatching} = 1;
                $ok = eval {
                    Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request(
                        $fake, $template_request, $noop_response,
                    );
                    Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request(
                        $fake, $template_request, $noop_response,
                    );
                    1;
                };
            }
            die "fused callback pair unexpectedly failed\n" if !$ok;
            $SINK += 1;
        },
    },
    {
        name => 'response_serialize',
        description => 'Response allocation, Content-Length header creation, and XS response-head serialization',
        code => sub {
            my $response = Linux::Event::Net::HTTP::Response->_new;
            $response->header('Content-Length', length($PAYLOAD));
            my $head = $response->_serialize_head('1.1');
            $SINK += length($head);
        },
    },
    {
        name => 'native_commit_base',
        description => 'Active transaction preparation, prebuilt response write, and transaction clear',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            $fake->write($WIRE);
            Linux::Event::Net::HTTP::Connection::_clear_transaction($fake);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'native_eligibility',
        description => 'Commit base plus native-default response and active-transaction eligibility checks',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            my $response = $fake->{_http_active_response};
            native_default_context($fake, $response)
                or die "native default response unexpectedly ineligible\n";
            $fake->write($WIRE);
            Linux::Event::Net::HTTP::Connection::_clear_transaction($fake);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'native_wire_build',
        description => 'Native eligibility plus Response1 build_default_final',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            my $response = $fake->{_http_active_response};
            my $request = native_default_context($fake, $response)
                or die "native default response unexpectedly ineligible\n";
            my $wire = Linux::Event::Net::HTTP::_Native::Response1
                ->build_default_final($request, $PAYLOAD);
            die "native default response build unexpectedly failed\n"
                if !defined $wire;
            $fake->write($wire);
            Linux::Event::Net::HTTP::Connection::_clear_transaction($fake);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'native_response_mark',
        description => 'Native wire build plus Response started/ended marking',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            my $response = $fake->{_http_active_response};
            my $request = native_default_context($fake, $response)
                or die "native default response unexpectedly ineligible\n";
            my $wire = Linux::Event::Net::HTTP::_Native::Response1
                ->build_default_final($request, $PAYLOAD);
            die "native default response build unexpectedly failed\n"
                if !defined $wire;
            $response->{started} = 1;
            $response->{ended} = 1;
            $fake->{_http_response_state} = undef;
            $fake->write($wire);
            Linux::Event::Net::HTTP::Connection::_clear_transaction($fake);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'native_transaction_commit',
        description => 'Response marking plus write-before-clear transaction commit and read-resume check',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            my $response = $fake->{_http_active_response};
            my $request = native_default_context($fake, $response)
                or die "native default response unexpectedly ineligible\n";
            my $wire = Linux::Event::Net::HTTP::_Native::Response1
                ->build_default_final($request, $PAYLOAD);
            die "native default response build unexpectedly failed\n"
                if !defined $wire;
            $response->{started} = 1;
            $response->{ended} = 1;
            $fake->{_http_response_state} = undef;
            $fake->write($wire);
            $fake->{_http_active_request} = undef;
            $fake->{_http_active_response} = undef;
            $fake->{_http_request_state} = undef;
            $fake->{_http_response_state} = undef;
            $fake->resume_read if $fake->is_read_paused;
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'response_end_path',
        description => 'Response/request-state allocation through public Response->end, excluding request parsing and real transport',
        code => sub {
            prepare_active_transaction($fake, $template_request, 1);
            my $response = $fake->{_http_active_response};
            $response->end($PAYLOAD);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'full_transaction_cpu',
        description => 'HTTP on_data through parse, Request/Response lifecycle, callbacks, serialization, and stub write; no socket/reactor cost',
        code => sub {
            reset_fake_connection($fake);
            $fake->on_data($REQUEST_WIRE);
            $SINK += $fake->{_bench_wire_bytes};
            $fake->{_bench_wire_bytes} = 0;
        },
    },
);

say 'Linux::Event::Net::HTTP hot-path decomposition';
say "picohttpparser=" . $PARSER->pico_version
    . " perl=$^V iterations=$iterations warmup=$warmup repeats=$repeats"
    . " request_bytes=" . length($REQUEST_WIRE)
    . " response_bytes=$response_bytes";
say 'full_transaction_cpu excludes socket syscalls and Linux::Event reactor dispatch';

for my $entry (@case) {
    run_iterations($entry->{code}, $warmup) if $warmup;
}

my @records;
for my $repeat (1 .. $repeats) {
    for my $entry (rotated_cases($repeat, @case)) {
        my $elapsed = run_iterations($entry->{code}, $iterations);
        my $ops = $iterations / $elapsed;
        my $us = $elapsed * 1_000_000 / $iterations;
        push @records, {
            case => $entry->{name},
            repeat => $repeat,
            iterations => $iterations,
            wall_seconds => $elapsed,
            operations_per_second => $ops,
            microseconds_per_operation => $us,
        };
        printf "%-22s repeat=%d %12.1f ops/s %9.3f us/op\n",
            $entry->{name}, $repeat, $ops, $us;
    }
}

say '';
say 'Median decomposition';
printf "%-22s %14s %12s\n", 'case', 'ops/s', 'us/op';
my @summary;
for my $entry (@case) {
    my @set = grep { $_->{case} eq $entry->{name} } @records;
    my $row = {
        case => $entry->{name},
        description => $entry->{description},
        operations_per_second => median(
            map { $_->{operations_per_second} } @set,
        ),
        microseconds_per_operation => median(
            map { $_->{microseconds_per_operation} } @set,
        ),
    };
    push @summary, $row;
    printf "%-22s %14.1f %12.3f\n",
        $row->{case},
        $row->{operations_per_second},
        $row->{microseconds_per_operation};
}

if (defined $json_path) {
    my ($sysname, $nodename, $release, $version, $machine) = uname();
    my $report = {
        benchmark => 'linux-event-net-http-hotpath',
        benchmark_contract_version => 1,
        generated_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        environment => {
            perl => "$^V",
            picohttpparser => $PARSER->pico_version,
            os => $sysname,
            kernel => $release,
            machine => $machine,
        },
        configuration => {
            iterations => $iterations,
            warmup => $warmup,
            repeats => $repeats,
            request_bytes => length($REQUEST_WIRE),
            response_bytes => $response_bytes,
            transport => 'stub-write-no-reactor',
        },
        summary => \@summary,
        records => \@records,
    };

    my $dir = dirname($json_path);
    make_path($dir) if $dir ne '.' && !-d $dir;
    open my $fh, '>', $json_path or die "open $json_path: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($report);
    close $fh or die "close $json_path: $!\n";
    say "json=$json_path";
}

END { $SINK = 0 if $SINK < 0 }

sub new_fake_connection () {
    return bless {
        _http_on_request => \&Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request,
        _http_on_body => undef,
        _http_on_request_end => \&Linux::Event::Net::HTTP::Bench::HotPathConnection::bench_on_request_end,
        _http_input => '',
        _http_active_request => undef,
        _http_active_response => undef,
        _http_request_state => undef,
        _http_response_state => undef,
        _http_driving => 0,
        _http_dispatching => 0,
        _http_closing => 0,
        _bench_read_paused => 0,
        _bench_wire_bytes => 0,
    }, 'Linux::Event::Net::HTTP::Bench::HotPathConnection';
}

sub reset_fake_connection ($connection) {
    $connection->{_http_input} = '';
    $connection->{_http_active_request} = undef;
    $connection->{_http_active_response} = undef;
    $connection->{_http_request_state} = undef;
    $connection->{_http_response_state} = undef;
    $connection->{_http_driving} = 0;
    $connection->{_http_dispatching} = 0;
    $connection->{_http_closing} = 0;
    $connection->{_bench_read_paused} = 0;
    return;
}

sub prepare_active_transaction ($connection, $request, $body_done) {
    reset_fake_connection($connection);
    my $response = Linux::Event::Net::HTTP::Response->_new_bound(
        $connection, $request,
    );
    my $request_state
        = Linux::Event::Net::HTTP::Connection::_new_request_state($request);
    $request_state->{body_done} = $body_done ? 1 : 0;
    $connection->{_http_active_request} = $request;
    $connection->{_http_active_response} = $response;
    $connection->{_http_request_state} = $request_state;
    return;
}

sub native_default_context ($connection, $response) {
    return if ref($response) ne 'Linux::Event::Net::HTTP::Response';
    return if $response->{status} != 200 || defined($response->{reason});
    return if @{$response->{headers}};
    return if $connection->{_http_closing} || $connection->is_closed;
    return if $connection->{_http_response_state};

    my $active = $connection->{_http_active_response} or return;
    return if refaddr($active) != refaddr($response);

    my $request = $connection->{_http_active_request} or return;
    return if !defined($response->{request})
        || refaddr($request) != refaddr($response->{request});

    my $request_state = $connection->{_http_request_state} or return;
    return if !$request_state->{body_done};
    return $request;
}

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
usage: bench/run-http-hotpath.pl [options]

  --iterations=N       measured iterations per case/repeat (default 200000)
  --warmup=N           warmup iterations per case (default 20000)
  --repeats=N          rotated repeats (default 7)
  --response-bytes=N   final response body bytes (default 32)
  --json=PATH          write machine-readable report
  --help               show this help
USAGE
    exit $status;
}
