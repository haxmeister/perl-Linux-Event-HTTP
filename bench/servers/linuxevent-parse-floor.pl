#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

my $port = $ENV{BENCH_PORT} // die "BENCH_PORT is required\n";
my $response_bytes = 0 + ($ENV{BENCH_RESPONSE_BYTES} // 32);
our $READ_BUDGET_BYTES = 0 + ($ENV{BENCH_READ_BUDGET_BYTES} // 0);
my $payload = 'x' x $response_bytes;
my $wire = "HTTP/1.1 200 OK\r\nContent-Length: $response_bytes\r\n\r\n$payload";

{
    package Linux::Event::Net::HTTP::Bench::ParseFloorConnection;
    use parent 'Linux::Event::IO::Sock::Stream';

    my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
    my $MAX_HEADERS = 100;

    sub stream_options ($class) {
        return read_budget_bytes => $main::READ_BUDGET_BYTES;
    }

    sub on_data ($self, $bytes) {
        ($self->{_bench_input} //= '') .= $bytes;

        while (length($self->{_bench_input})) {
            my $request = $PARSER->parse_request(
                $self->{_bench_input}, 0, $MAX_HEADERS,
            );
            last if !defined $request;

            my $consumed = $request->_consumed;
            substr($self->{_bench_input}, 0, $consumed, '');
            $self->write($self->data->{wire});
        }
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'Linux::Event::Net::HTTP::Bench::ParseFloorConnection',
    host         => '127.0.0.1',
    port         => 0 + $port,
    data         => { wire => $wire },
);

$loop->run;
