#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::HTTP::Server::Connection;

# Diagnostic bodyless stages only. The endpoint is the unmodified production
# driver. No replacement parser, legacy Transaction setup, or generic serializer.
my $port = $ENV{BENCH_PORT} // die "BENCH_PORT is required\n";
my $size = 0 + ($ENV{BENCH_RESPONSE_BYTES} // 32);
our $BUDGET = 0 + ($ENV{BENCH_READ_BUDGET_BYTES} // 0);
our $STAGE = $ENV{BENCH_TRANSACTION_STAGE} // '';
die "unknown production stage $STAGE\n"
    if $STAGE !~ /\Aprod_(?:api|wire|active|dispatch|connection)\z/;
my $payload = 'x' x $size;
my $wire = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
    . "Content-Length: $size\r\n\r\n$payload";

{
    package Linux::Event::HTTP::Bench::ProductionStage;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub stream_tuning ($class) { return read_budget_bytes => $main::BUDGET }

    sub on_request ($self, $request, $response) {
        $response->header('Content-Type', 'application/octet-stream');
        $response->body($self->data->{payload});
        return;
    }

    sub on_data ($self, $bytes) {
        return $self->SUPER::on_data($bytes)
            if $main::STAGE eq 'prod_connection';
        $self->{_http_input} .= $bytes;
        while (length $self->{_http_input}) {
            my $request = Linux::Event::HTTP::_HTTP1->_parse_server_request(
                $self->{_http_input}, 65_536, 100,
            );
            last if !defined $request;
            die "diagnostic requires valid bodyless requests\n"
                if !ref($request) || $request->_consumed > 65_536
                || $request->_expect_continue < 0
                || $request->_http1_body_mode ne 'none';
            substr($self->{_http_input}, 0, $request->_consumed, '');
            my $response = Linux::Event::HTTP::Response
                ->_new_server_default($request);

            if ($main::STAGE eq 'prod_active' || $main::STAGE eq 'prod_dispatch') {
                my $state = $self->{_http_bodyless_state};
                if (!$state) {
                    $state = $self->{_http_bodyless_state} = {
                        mode => 'none', body_done => 1,
                    };
                }
                $self->{_http_active_request} = $request;
                $self->{_http_active_response} = $response;
                $self->{_http_request_state} = $state;
            }

            if ($main::STAGE eq 'prod_dispatch') {
                die "production callback failed\n" if !$self->_invoke_http_callback(
                    $self->{_http_on_request}, $request, $response,
                );
                die "production scalar response did not retire exchange\n"
                    if $self->{_http_active_request};
                next;
            }

            # Inline the same public application operations until the dispatch
            # stage introduces the actual guarded production callback/send path.
            $response->header('Content-Type', 'application/octet-stream');
            $response->body($self->data->{payload});
            my $wire = $main::STAGE eq 'prod_api' ? $self->data->{wire}
                : Linux::Event::HTTP::_HTTP1->build_simple_scalar_final(
                    $request, $response, $response->{body},
                );
            die "native scalar builder declined diagnostic response\n"
                if !defined $wire;
            $self->write($wire);
            if ($main::STAGE eq 'prod_active') {
                $self->{_http_active_request} = undef;
                $self->{_http_active_response} = undef;
                $self->{_http_request_state} = undef;
            }
        }
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop, host => '127.0.0.1', port => 0 + $port,
    stream => {
        class => 'Linux::Event::HTTP::Bench::ProductionStage',
        data => { payload => $payload, wire => $wire },
    },
);
$loop->run;
