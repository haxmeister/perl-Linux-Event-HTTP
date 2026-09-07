#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Errno qw(EINTR);
use Getopt::Long qw(GetOptions);
use IO::Select;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::_Native::Response1 ();
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

$SIG{PIPE} = 'IGNORE';

my $requests = 20_000;
my $warmup = 2_000;
my $connections = 100;
my $pipeline = 1;
my $response_bytes = 32;
my $repeats = 5;
my $timeout = 120;
my $smoke = 0;
my $help = 0;

GetOptions(
    'requests=i'       => \$requests,
    'warmup=i'         => \$warmup,
    'connections=i'    => \$connections,
    'pipeline=i'       => \$pipeline,
    'response-bytes=i' => \$response_bytes,
    'repeats=i'        => \$repeats,
    'timeout=f'        => \$timeout,
    'smoke'            => \$smoke,
    'help'             => \$help,
) or usage(2);

usage(0) if $help;
if ($smoke) {
    $requests = 500;
    $warmup = 100;
    $connections = 4;
    $pipeline = 1;
    $response_bytes = 8;
    $repeats = 1;
    $timeout = 15;
}

die "requests must be > 0\n" if $requests <= 0;
die "warmup must be >= 0\n" if $warmup < 0;
die "connections must be > 0\n" if $connections <= 0;
die "pipeline must be > 0\n" if $pipeline <= 0;
die "response-bytes must be >= 0\n" if $response_bytes < 0;
die "repeats must be > 0\n" if $repeats <= 0;
die "timeout must be > 0\n" if $timeout <= 0;

our $STAGE = 'direct';

{
    package Linux::Event::Net::HTTP::Bench::DirectAPIConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';

    my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
    my $MAX_HEADERS = 100;
    my $MAX_REQUEST_HEAD = 65_536;

    # Parent construction requires an HTTP application callback. This benchmark
    # overrides on_data and dispatches its deliberately narrower request-only
    # callback itself so that the measured shape is explicit.
    sub on_request ($self, $request, $response) { return }

    sub _dispatch_direct ($self, $request) {
        my $ok;
        {
            local $self->{_http_dispatching} = 1;
            $ok = eval {
                my $wire = Linux::Event::Net::HTTP::_Native::Response1
                    ->build_default_final($request, $self->data->{payload});
                die "direct benchmark response unexpectedly ineligible\n"
                    if !defined $wire;
                $self->write($wire);
                1;
            };
        }

        return 1 if $ok;
        $self->_protocol_error(500, $request->http_version);
        return 0;
    }

    sub on_data ($self, $bytes) {
        return if $self->{_http_closing} || $self->is_closed;
        $self->{_bench_input} = '' if !defined $self->{_bench_input};
        $self->{_bench_input} .= $bytes;

        return if $self->{_http_driving};
        local $self->{_http_driving} = 1;

        while (!$self->{_http_closing} && !$self->is_closed) {
            last if !length($self->{_bench_input});

            my $request;
            if ($main::STAGE eq 'checked') {
                my $parsed = eval {
                    $request = $PARSER->parse_request(
                        $self->{_bench_input}, 0, $MAX_HEADERS,
                    );
                    1;
                };
                if (!$parsed) {
                    my $failure = "$@";
                    my $status = $failure =~ /semantic error \(501\)/ ? 501 : 400;
                    $self->_protocol_error($status);
                    last;
                }
                if (!defined $request) {
                    if (length($self->{_bench_input}) > $MAX_REQUEST_HEAD) {
                        $self->_protocol_error(431);
                    }
                    last;
                }
            } else {
                $request = $PARSER->parse_request(
                    $self->{_bench_input}, 0, $MAX_HEADERS,
                );
                last if !defined $request;
            }

            my $consumed = $request->_consumed;
            if ($main::STAGE eq 'checked' && $consumed > $MAX_REQUEST_HEAD) {
                $self->_protocol_error(431, $request->http_version);
                last;
            }
            substr($self->{_bench_input}, 0, $consumed, '');

            # This experiment intentionally models a complete bodyless request
            # callback. A future production API would need a generic fallback
            # for body-bearing or non-fast-final transactions.
            my $body_mode = $request->body_mode;
            die "direct benchmark unexpectedly parsed $body_mode request\n"
                if $body_mode ne 'none';

            if ($main::STAGE eq 'checked') {
                my $expect = Linux::Event::Net::HTTP::Connection
                    ::_expect_continue($request);
                if ($expect < 0) {
                    $self->_protocol_error(417, $request->http_version);
                    last;
                }
            }

            last if !$self->_dispatch_direct($request);
        }
        return;
    }
}

my $request_wire = "GET /bench HTTP/1.1\r\nHost: benchmark.test\r\n\r\n";
my @stage = qw(direct checked);
my %label = (
    direct  => 'request-only direct final',
    checked => 'request-only checked final',
);
my %records;

say 'Linux::Event::Net::HTTP direct API-shape experiment';
say "requests=$requests warmup=$warmup connections=$connections pipeline=$pipeline response_bytes=$response_bytes repeats=$repeats";
say 'direct = parse + bodyless eligibility + one guarded Perl callback + native default-final write';
say 'checked = direct + production parser eval/error boundary + head-size guard + Expect validation';

for my $repeat (1 .. $repeats) {
    my @order = $repeat % 2 ? @stage : reverse @stage;
    for my $stage (@order) {
        $STAGE = $stage;
        my $row = run_case($stage, $request_wire);
        push @{$records{$stage}}, $row;
        printf "%-28s repeat=%d %10.1f req/s p50=%8.1f us p95=%8.1f us p99=%8.1f us max=%8.1f us\n",
            $label{$stage}, $repeat,
            @{$row}{qw(requests_per_second latency_us_p50 latency_us_p95 latency_us_p99 latency_us_max)};
    }
}

say '';
say 'Median comparison';
printf "%-28s %12s %12s %12s %12s %12s\n",
    'stage', 'req/s', 'p50 us', 'p95 us', 'p99 us', 'max us';
for my $stage (@stage) {
    my @set = @{$records{$stage}};
    printf "%-28s %12.1f %12.1f %12.1f %12.1f %12.1f\n",
        $label{$stage},
        median(map { $_->{requests_per_second} } @set),
        median(map { $_->{latency_us_p50} } @set),
        median(map { $_->{latency_us_p95} } @set),
        median(map { $_->{latency_us_p99} } @set),
        median(map { $_->{latency_us_max} } @set);
}

sub run_case ($stage, $wire) {
    my $port = free_port();
    my ($pid, $stdout_path, $stderr_path) = start_server($stage, $port);
    wait_ready($stage, $pid, $port, $stdout_path, $stderr_path);

    my (@socket, $latency, $wall);
    my $ok = eval {
        @socket = open_clients($port, $connections);
        drive_phase(\@socket, $wire, $warmup, $pipeline, 0, $timeout)
            if $warmup;
        my $start = time;
        $latency = drive_phase(
            \@socket, $wire, $requests, $pipeline, 1, $timeout,
        );
        $wall = time - $start;
        1;
    };
    my $error = $@;

    close $_ for @socket;
    stop_server($pid);

    if (!$ok) {
        my $detail = slurp_log('stdout', $stdout_path)
            . slurp_log('stderr', $stderr_path);
        unlink $stdout_path;
        unlink $stderr_path;
        die "$label{$stage} failed: $error$detail";
    }

    unlink $stdout_path;
    unlink $stderr_path;
    return {
        requests_per_second => $requests / $wall,
        latency_us_p50 => percentile_us($latency, 50),
        latency_us_p95 => percentile_us($latency, 95),
        latency_us_p99 => percentile_us($latency, 99),
        latency_us_max => max_us($latency),
    };
}

sub start_server ($stage, $port) {
    my $stdout_path = "/tmp/le-http-direct-$stage-$$-out.log";
    my $stderr_path = "/tmp/le-http-direct-$stage-$$-err.log";
    my $pid = fork();
    die "fork $stage: $!\n" if !defined $pid;

    if ($pid == 0) {
        $STAGE = $stage;
        open STDOUT, '>', $stdout_path or POSIX::_exit(126);
        open STDERR, '>', $stderr_path or POSIX::_exit(126);

        my $loop = Linux::Event::Loop->new;
        my $listener = Linux::Event::IO::Sock::Listener->new(
            loop => $loop,
            stream_class => 'Linux::Event::Net::HTTP::Bench::DirectAPIConnection',
            host => '127.0.0.1',
            port => $port,
            data => { payload => 'x' x $response_bytes },
        );
        $loop->run;
        POSIX::_exit(0);
    }

    return ($pid, $stdout_path, $stderr_path);
}

sub wait_ready ($stage, $pid, $port, $stdout_path, $stderr_path) {
    my $deadline = time + $timeout;
    while (time < $deadline) {
        my $fh = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto => 'tcp',
            Timeout => 0.1,
        );
        if ($fh) {
            close $fh;
            return;
        }
        my $done = waitpid($pid, WNOHANG);
        die server_failure($stage, $stdout_path, $stderr_path)
            if $done == $pid;
        sleep 0.01;
    }
    stop_server($pid);
    die "benchmark server $stage did not listen on port $port\n"
        . slurp_log('stdout', $stdout_path)
        . slurp_log('stderr', $stderr_path);
}

sub server_failure ($stage, $stdout_path, $stderr_path) {
    return "benchmark server $stage exited before becoming ready\n"
        . slurp_log('stdout', $stdout_path)
        . slurp_log('stderr', $stderr_path);
}

sub slurp_log ($label_name, $path) {
    return '' if !-e $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh> // '';
    close $fh;
    return $text eq '' ? '' : "$label_name:\n$text\n";
}

sub stop_server ($pid) {
    return if !defined $pid || $pid <= 0;
    kill 'TERM', $pid;
    my $deadline = time + 1;
    while (time < $deadline) {
        my $done = waitpid($pid, WNOHANG);
        return if $done == $pid || $done == -1;
        sleep 0.01;
    }
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

sub free_port () {
    my $fh = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto => 'tcp',
        Listen => 1,
        ReuseAddr => 1,
    ) or die "allocate benchmark port: $!\n";
    my $port = $fh->sockport;
    close $fh;
    return $port;
}

sub open_clients ($port, $count) {
    my @socket;
    for (1 .. $count) {
        my $fh = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto => 'tcp',
        ) or die "connect 127.0.0.1:$port: $!\n";
        $fh->autoflush(1);
        push @socket, $fh;
    }
    return @socket;
}

sub drive_phase ($socket, $wire, $count, $depth, $measure, $phase_timeout) {
    return [] if $count == 0;

    my $select = IO::Select->new;
    my %state;
    my $base = int($count / @$socket);
    my $extra = $count % @$socket;
    for my $i (0 .. $#$socket) {
        my $quota = $base + ($i < $extra ? 1 : 0);
        next if !$quota;
        my $fh = $socket->[$i];
        $state{fileno($fh)} = {
            fh => $fh,
            quota => $quota,
            sent => 0,
            received => 0,
            buffer => '',
            sent_at => [],
        };
        $select->add($fh);
    }

    my @latency;
    my $received = 0;
    my $deadline = time + $phase_timeout;
    fill_pipeline($_, $wire, $depth, $measure) for values %state;

    while ($received < $count) {
        my $remaining = $deadline - time;
        die "benchmark client timed out after $phase_timeout seconds\n"
            if $remaining <= 0;
        my @ready = $select->can_read($remaining);
        die "benchmark client timed out after $phase_timeout seconds\n"
            if !@ready;

        for my $fh (@ready) {
            my $s = $state{fileno($fh)} or next;
            my $chunk = '';
            my $n = sysread($fh, $chunk, 65_536);
            if (!defined $n) {
                next if $! == EINTR;
                die "client read failed: $!\n";
            }
            die "server closed connection before benchmark phase completed\n"
                if $n == 0;
            $s->{buffer} .= $chunk;

            while (1) {
                my $head_end = index($s->{buffer}, "\r\n\r\n");
                last if $head_end < 0;
                my $head_len = $head_end + 4;
                my $head = substr($s->{buffer}, 0, $head_len);
                die "benchmark response was not HTTP 200\n"
                    if $head !~ /\AHTTP\/1\.[01] 200\b/;
                die "benchmark response missing Content-Length\n"
                    if $head !~ /\r\nContent-Length:\s*(\d+)\r\n/i;
                my $body_len = 0 + $1;
                last if length($s->{buffer}) < $head_len + $body_len;

                substr($s->{buffer}, 0, $head_len + $body_len, '');
                ++$s->{received};
                ++$received;
                if ($measure) {
                    my $sent_at = shift @{$s->{sent_at}};
                    push @latency, time - $sent_at;
                }
                fill_pipeline($s, $wire, $depth, $measure);
            }
        }
    }
    return \@latency;
}

sub fill_pipeline ($state, $wire, $depth, $measure) {
    while ($state->{sent} < $state->{quota}
        && $state->{sent} - $state->{received} < $depth) {
        write_all($state->{fh}, $wire);
        push @{$state->{sent_at}}, time if $measure;
        ++$state->{sent};
    }
}

sub write_all ($fh, $bytes) {
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $n = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
        if (!defined $n) {
            next if $! == EINTR;
            die "client write failed: $!\n";
        }
        die "client write returned zero bytes\n" if $n == 0;
        $offset += $n;
    }
}

sub percentile_us ($values, $percent) {
    return 0 if !@$values;
    my @sorted = sort { $a <=> $b } @$values;
    my $index = int(($percent * @sorted + 99) / 100) - 1;
    $index = 0 if $index < 0;
    $index = $#sorted if $index > $#sorted;
    return $sorted[$index] * 1_000_000;
}

sub max_us ($values) {
    return 0 if !@$values;
    my $max = 0;
    for my $value (@$values) {
        $max = $value if $value > $max;
    }
    return $max * 1_000_000;
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
usage: bench/run-http-direct-api-experiment.pl [options]

  --requests=N        measured requests per stage/repeat (default 20000)
  --warmup=N          warmup requests per stage/repeat (default 2000)
  --connections=N     concurrent TCP connections (default 100)
  --pipeline=N        max outstanding requests per connection (default 1)
  --response-bytes=N  fixed response body bytes (default 32)
  --repeats=N         rotated benchmark repeats (default 5)
  --timeout=SECONDS   server/client phase timeout (default 120)
  --smoke             tiny keep-alive correctness workload
  --help              show this help
USAGE
    exit $status;
}
