#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::Response;
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

my $port = $ENV{BENCH_PORT} // die "BENCH_PORT is required\n";
my $response_bytes = 0 + ($ENV{BENCH_RESPONSE_BYTES} // 32);
our $READ_BUDGET_BYTES = 0 + ($ENV{BENCH_READ_BUDGET_BYTES} // 0);
our $STAGE = $ENV{BENCH_TRANSACTION_STAGE} // die "BENCH_TRANSACTION_STAGE is required\n";
die "unknown BENCH_TRANSACTION_STAGE=$STAGE\n"
    if $STAGE !~ /\A(?:parse|bound|state|callbacks|end)\z/;

my $payload = 'x' x $response_bytes;
my $wire = "HTTP/1.1 200 OK\r\nContent-Length: $response_bytes\r\n\r\n$payload";

{
    package Linux::Event::Net::HTTP::Bench::TransactionStageConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';

    my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
    my $MAX_HEADERS = 100;
    my $NOOP = sub ($connection, $request, $response) { return };
    my $END = sub ($connection, $request, $response) {
        $response->end($connection->data->{payload});
        return;
    };

    sub stream_options ($class) {
        return read_budget_bytes => $main::READ_BUDGET_BYTES;
    }

    # Connection->new requires an application request handler. The benchmark
    # invokes the cached benchmark handlers explicitly below so each stage can
    # add exactly the intended lifecycle work.
    sub on_request ($self, $request, $response) { return }

    sub on_data ($self, $bytes) {
        $self->{_bench_input} = '' if !defined $self->{_bench_input};
        $self->{_bench_input} .= $bytes;

        while (length($self->{_bench_input})) {
            my $request = $PARSER->parse_request(
                $self->{_bench_input}, 0, $MAX_HEADERS,
            );
            last if !defined $request;

            my $consumed = $request->_consumed;
            substr($self->{_bench_input}, 0, $consumed, '');

            if ($main::STAGE eq 'parse') {
                $self->write($self->data->{wire});
                next;
            }

            my $response = Linux::Event::Net::HTTP::Response->_new_bound(
                $self, $request,
            );

            if ($main::STAGE eq 'bound') {
                $self->write($self->data->{wire});
                next;
            }

            my $request_state
                = Linux::Event::Net::HTTP::Connection::_new_request_state(
                    $request,
                );
            $self->{_http_active_request} = $request;
            $self->{_http_active_response} = $response;
            $self->{_http_request_state} = $request_state;
            $self->{_http_response_state} = undef;

            if ($main::STAGE eq 'state') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
                next;
            }

            last if !$self->_invoke_http_callback(
                $NOOP, $request, $response,
            );
            $request_state->{body_done} = 1;

            my $handler = $main::STAGE eq 'end' ? $END : $NOOP;
            last if !$self->_invoke_http_callback(
                $handler, $request, $response,
            );

            if ($main::STAGE eq 'callbacks') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
            }
        }
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'Linux::Event::Net::HTTP::Bench::TransactionStageConnection',
    host         => '127.0.0.1',
    port         => 0 + $port,
    data         => {
        wire    => $wire,
        payload => $payload,
    },
);

$loop->run;
