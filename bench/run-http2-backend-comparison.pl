use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);

use Linux::Event::Framer ();
use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::Request;
use Linux::Event::HTTP::_HTTP2::Client;
use Linux::Event::HTTP::_HTTP2::Server;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

{
    package Bench::H2RawSource;
    use parent 'Linux::Event::IO::Sock::Stream';

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );
}

my $backend = 'both';
my $requests = 20_000;
my $warmup = 2_000;
my $concurrency = 100;
my $response_bytes = 32;
my $repeats = 3;

GetOptions(
    'backend=s'        => \$backend,
    'requests=i'       => \$requests,
    'warmup=i'         => \$warmup,
    'concurrency=i'    => \$concurrency,
    'response-bytes=i' => \$response_bytes,
    'repeats=i'        => \$repeats,
) or die "invalid benchmark options\n";

die "--backend must be external, native, or both\n"
    if $backend ne 'external' && $backend ne 'native' && $backend ne 'both';
die "--requests must be positive\n" if $requests < 1;
die "--warmup must be zero or positive\n" if $warmup < 0;
die "--concurrency must be between 1 and 100\n"
    if $concurrency < 1 || $concurrency > 100;
die "--response-bytes must be zero or positive\n" if $response_bytes < 0;
die "--repeats must be positive\n" if $repeats < 1;

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $count = @values;
    return $values[int($count / 2)] if $count % 2;
    return ($values[$count / 2 - 1] + $values[$count / 2]) / 2;
}

sub session_class ($which) {
    if ($which eq 'native') {
        require Linux::Event::HTTP::_HTTP2::Native;
        require Linux::Event::HTTP::_HTTP2::NativeConnection;
        Linux::Event::HTTP::_HTTP2::Native->available
            or die "native HTTP/2 backend is unavailable\n";
        return 'Linux::Event::HTTP::_HTTP2::Native';
    }

    require Net::HTTP2::nghttp2;
    Net::HTTP2::nghttp2->VERSION('0.011');
    require Net::HTTP2::nghttp2::Session;
    Net::HTTP2::nghttp2->available
        or die "external nghttp2 backend is unavailable\n";
    return 'Net::HTTP2::nghttp2::Session';
}

sub run_once ($which) {
    my $session_class = session_class($which);
    my $native = $which eq 'native' ? 1 : 0;
    my $loop = Linux::Event::Loop->new;
    my $body = 'x' x $response_bytes;

    my %server_executor;
    my @errors;
    my $client_executor;
    my $client_stream;
    my $elapsed;
    my $sequence = 0;

    my ($phase, $goal, $submitted, $completed, $inflight);
    $phase = $warmup ? 'warmup' : 'measure';
    $goal = $warmup ? $warmup : $requests;
    ($submitted, $completed, $inflight) = (0, 0, 0);
    my $started = $phase eq 'measure' ? time : undef;

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 30,
        on_timer => sub ($timer) {
            die "HTTP/2 backend benchmark timed out for $which\n";
        },
    );

    my $finish = sub {
        $guard->cancel;
        $client_stream->close
            if $client_stream && !$client_stream->is_closed;
        $_->stream->close
            for grep { $_ && $_->stream && !$_->stream->is_closed }
                values %server_executor;
        return;
    };

    my $server_ready = sub ($stream) {
        my $executor = Linux::Event::HTTP::_HTTP2::Server->new(
            stream         => $stream,
            autostart      => 0,
            _session_class => $session_class,
            on_request => sub ($h2, $request, $response) {
                $response->body($body);
            },
            on_error => sub ($h2, $stream_id, $error) {
                push @errors, "server stream $stream_id: $error";
            },
        );

        $server_executor{refaddr($stream)} = $executor;
        if ($native) {
            $stream->{_http2_executor} = $executor;
            $stream->{_http2_native_session} = $executor->session;
            $stream->transition_to(
                'Linux::Event::HTTP::_HTTP2::NativeConnection',
            );
        }
        $executor->start;
    };

    my %server_stream = (
        ($native ? (class => 'Bench::H2RawSource') : ()),
        on_ready => $server_ready,
        (!$native ? (
            on_data => sub ($stream, $bytes) {
                my $executor = $server_executor{refaddr($stream)}
                    or die "server executor is unavailable\n";
                my $consumed = $executor->input($bytes);
                die "server executor left input unconsumed\n"
                    if $consumed != length($bytes);
            },
        ) : ()),
        on_drain => sub ($stream) {
            my $executor = $server_executor{refaddr($stream)} or return;
            $executor->transport_drain;
        },
        on_error => sub ($stream, $error) {
            push @errors, "server transport: $error";
            $loop->stop;
        },
        on_close => sub ($stream) {
            my $executor = delete $server_executor{refaddr($stream)};
            $executor->close if $executor;
        },
    );

    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        stream => \%server_stream,
    );

    my $submit_more;
    $submit_more = sub {
        while ($inflight < $concurrency && $submitted < $goal) {
            ++$submitted;
            ++$inflight;
            my $id = ++$sequence;

            my $request = Linux::Event::HTTP::Request->new(
                method    => 'GET',
                target    => "/bench/$id",
                version   => '2',
                scheme    => 'http',
                authority => 'benchmark.test',
            );

            $client_executor->request(
                $request,
                on_complete => sub ($tx) {
                    if (($tx->response->status // 0) != 200) {
                        push @errors, "unexpected response status";
                    }

                    --$inflight;
                    ++$completed;

                    if ($completed == $goal) {
                        if ($phase eq 'warmup') {
                            $phase = 'measure';
                            $goal = $requests;
                            ($submitted, $completed, $inflight) = (0, 0, 0);
                            $started = time;
                            $submit_more->();
                            return;
                        }

                        $elapsed = time - $started;
                        $finish->();
                        $listener->close;
                        $loop->stop;
                        return;
                    }

                    $submit_more->();
                },
                on_error => sub ($tx, $error) {
                    push @errors, "client request: $error";
                    $loop->stop;
                },
            );
        }
        return;
    };

    my %client_option = (
        loop => $loop,
        host => '127.0.0.1',
        port => $listener->port,
        ($native ? (class => 'Bench::H2RawSource') : ()),
        on_ready => sub ($stream) {
            $client_stream = $stream;
            $client_executor = Linux::Event::HTTP::_HTTP2::Client->new(
                stream         => $stream,
                autostart      => 0,
                _session_class => $session_class,
            );

            if ($native) {
                $stream->{_http2_executor} = $client_executor;
                $stream->{_http2_native_session} = $client_executor->session;
                $stream->transition_to(
                    'Linux::Event::HTTP::_HTTP2::NativeConnection',
                );
            }

            $client_executor->start;
            $submit_more->();
        },
        (!$native ? (
            on_data => sub ($stream, $bytes) {
                my $consumed = $client_executor->input($bytes);
                die "client executor left input unconsumed\n"
                    if $consumed != length($bytes);
            },
        ) : ()),
        on_drain => sub ($stream) {
            $client_executor->transport_drain if $client_executor;
        },
        on_error => sub ($stream, $error) {
            push @errors, "client transport: $error";
            $loop->stop;
        },
        on_close => sub ($stream) {
            $client_executor->close if $client_executor;
        },
    );

    my $connecting = Linux::Event::IO::Sock::Stream->connect(%client_option);
    $loop->run;

    $finish->();
    $listener->close;

    die join("\n", @errors) . "\n" if @errors;
    die "benchmark did not finish measurement phase\n"
        if !defined($elapsed) || $elapsed <= 0;

    return $requests / $elapsed;
}

my @backends = $backend eq 'both'
    ? qw(external native)
    : ($backend);

say "HTTP/2 backend comparison";
say "requests=$requests warmup=$warmup concurrency=$concurrency "
    . "response_bytes=$response_bytes repeats=$repeats";

my %result;
for my $which (@backends) {
    my @rate;
    for my $repeat (1 .. $repeats) {
        my $rate = run_once($which);
        push @rate, $rate;
        printf "%-8s run %d: %.1f req/s\n", $which, $repeat, $rate;
    }
    $result{$which} = median(@rate);
    printf "%-8s median: %.1f req/s\n", $which, $result{$which};
}

if (exists($result{external}) && exists($result{native})) {
    my $change = 100 * ($result{native} / $result{external} - 1);
    printf "native vs external: %+.1f%%\n", $change;
}
