#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(strftime uname);
use Time::HiRes qw(time);

use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::Response;
use Linux::Event::Net::HTTP::_Parser::HTTP1;

my $iterations = 200_000;
my $warmup = 20_000;
my $repeats = 7;
my $response_bytes = 32;
my $json_path;

GetOptions(
    'iterations=i'     => \$iterations,
    'warmup=i'         => \$warmup,
    'repeats=i'        => \$repeats,
    'response-bytes=i' => \$response_bytes,
    'json=s'           => \$json_path,
) or die "invalid options\n";

die "iterations must be > 0\n" if $iterations <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "repeats must be > 0\n" if $repeats <= 0;
die "response-bytes must be >= 0\n" if $response_bytes < 0;

my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $REQUEST_WIRE = "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n";
our $PAYLOAD = 'x' x $response_bytes;
our $STATIC_HEAD = "HTTP/1.1 200 OK\r\nContent-Length: "
    . length($PAYLOAD) . "\r\n\r\n";
our $SINK = 0;

{
    package Linux::Event::Net::HTTP::Bench::ResponsePathConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';

    sub DESTROY ($self) { return }
    sub is_closed ($self) { 0 }
    sub is_read_paused ($self) { $self->{_bench_read_paused} ? 1 : 0 }
    sub pause_read ($self) { $self->{_bench_read_paused} = 1; return $self }
    sub resume_read ($self) { $self->{_bench_read_paused} = 0; return $self }
    sub write ($self, $bytes) {
        $self->{_bench_wire_bytes} += length($bytes);
        return 1;
    }
    sub end ($self, $bytes = '') {
        $self->{_bench_wire_bytes} += length($bytes);
        return 1;
    }
}

{
    package Linux::Event::Net::HTTP::Bench::NoSerializeResponse;
    use parent 'Linux::Event::Net::HTTP::Response';

    sub _serialize_head ($self, $version = '1.1') {
        return $main::STATIC_HEAD;
    }
}

my $request = $PARSER->parse_request($REQUEST_WIRE, 0, 100)
    or die "failed to parse benchmark request\n";
my $connection = new_fake_connection();

my @case = (
    {
        name => 'prepare_transaction',
        description => 'Response binding plus Perl request-state allocation and active-transaction assignment',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request, 'Linux::Event::Net::HTTP::Response',
            );
            $SINK += $response->status;
        },
    },
    {
        name => 'response_start_final',
        description => '_response_start for a final scalar body, including automatic Content-Length and XS head serialization',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request, 'Linux::Event::Net::HTTP::Response',
            );
            my ($state, $head)
                = $connection->_response_start($response, $PAYLOAD, 1);
            $SINK += length($head) + $state->{sent};
        },
    },
    {
        name => 'response_start_precl',
        description => '_response_start with Content-Length pre-populated directly, avoiding automatic header insertion work',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request, 'Linux::Event::Net::HTTP::Response',
            );
            $response->{headers} = [
                [ 'Content-Length', '' . length($PAYLOAD) ],
            ];
            my ($state, $head)
                = $connection->_response_start($response, $PAYLOAD, 1);
            $SINK += length($head) + $state->{sent};
        },
    },
    {
        name => 'response_complete_only',
        description => '_complete_response transaction cleanup plus stub write with an already-built wire scalar',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request, 'Linux::Event::Net::HTTP::Response',
            );
            $response->{started} = 1;
            $connection->{_http_response_state} = {
                expected => length($PAYLOAD),
                sent => 0,
                suppress_body => 0,
                close_after => 0,
                chunked => 0,
            };
            $connection->_complete_response(
                $response, $STATIC_HEAD . $PAYLOAD, 0,
            );
            $SINK += $connection->{_bench_wire_bytes};
            $connection->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'response_end_no_serialize',
        description => 'Public Response->end path with serializer replaced by a static response head',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request,
                'Linux::Event::Net::HTTP::Bench::NoSerializeResponse',
            );
            $response->end($PAYLOAD);
            $SINK += $connection->{_bench_wire_bytes};
            $connection->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'response_end_full',
        description => 'Full public Response->end path with normal response semantics and XS serialization',
        code => sub {
            my $response = prepare_transaction(
                $connection, $request, 'Linux::Event::Net::HTTP::Response',
            );
            $response->end($PAYLOAD);
            $SINK += $connection->{_bench_wire_bytes};
            $connection->{_bench_wire_bytes} = 0;
        },
    },
    {
        name => 'wire_concat_stub_write',
        description => 'Idealized final wire concatenation plus stub transport write only',
        code => sub {
            reset_fake_connection($connection);
            $connection->write($STATIC_HEAD . $PAYLOAD);
            $SINK += $connection->{_bench_wire_bytes};
            $connection->{_bench_wire_bytes} = 0;
        },
    },
);

say 'Linux::Event::Net::HTTP response-path decomposition';
say "perl=$^V iterations=$iterations warmup=$warmup repeats=$repeats"
    . " response_bytes=$response_bytes";
say 'transport is a stub; results measure HTTP response CPU only';

run_iterations($_->{code}, $warmup) for grep { $warmup } @case;

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
        printf "%-27s repeat=%d %12.1f ops/s %9.3f us/op\n",
            $entry->{name}, $repeat, $ops, $us;
    }
}

say '';
say 'Median response-path decomposition';
printf "%-27s %14s %12s\n", 'case', 'ops/s', 'us/op';
my @summary;
for my $entry (@case) {
    my @set = grep { $_->{case} eq $entry->{name} } @records;
    my $row = {
        case => $entry->{name},
        description => $entry->{description},
        operations_per_second => median(map { $_->{operations_per_second} } @set),
        microseconds_per_operation => median(map { $_->{microseconds_per_operation} } @set),
    };
    push @summary, $row;
    printf "%-27s %14.1f %12.3f\n",
        $row->{case}, $row->{operations_per_second},
        $row->{microseconds_per_operation};
}

if (defined $json_path) {
    my ($sysname, $nodename, $release, $version, $machine) = uname();
    my $report = {
        benchmark => 'linux-event-net-http-response-path',
        benchmark_contract_version => 1,
        generated_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        environment => {
            perl => "$^V",
            os => $sysname,
            kernel => $release,
            machine => $machine,
        },
        configuration => {
            iterations => $iterations,
            warmup => $warmup,
            repeats => $repeats,
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
    }, 'Linux::Event::Net::HTTP::Bench::ResponsePathConnection';
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

sub prepare_transaction ($connection, $request, $response_class) {
    reset_fake_connection($connection);
    my $response = $response_class->_new_bound($connection, $request);
    my $request_state
        = Linux::Event::Net::HTTP::Connection::_new_request_state($request);
    $request_state->{body_done} = 1;
    $connection->{_http_active_request} = $request;
    $connection->{_http_active_response} = $response;
    $connection->{_http_request_state} = $request_state;
    return $response;
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
