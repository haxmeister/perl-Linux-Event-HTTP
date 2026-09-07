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
    if $STAGE !~ /\A(?:parse|bound|state|callbacks|fused|eligibility|build|mark|commit|end|checked)\z/;

my $payload = 'x' x $response_bytes;
my $wire = "HTTP/1.1 200 OK\r\nContent-Length: $response_bytes\r\n\r\n$payload";

{
    package Linux::Event::Net::HTTP::Bench::TransactionStageConnection;
    use parent 'Linux::Event::Net::HTTP::Connection';
    use Scalar::Util qw(refaddr);

    my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
    my $MAX_HEADERS = 100;
    my $MAX_REQUEST_HEAD = 65_536;
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

    sub native_default_context ($self, $response) {
        return if ref($response) ne 'Linux::Event::Net::HTTP::Response';
        return if $response->{status} != 200 || defined($response->{reason});
        return if @{$response->{headers}};
        return if $self->{_http_closing} || $self->is_closed;
        return if $self->{_http_response_state};

        my $active = $self->{_http_active_response} or return;
        return if refaddr($active) != refaddr($response);

        my $request = $self->{_http_active_request} or return;
        return if !defined($response->{request})
            || refaddr($request) != refaddr($response->{request});

        my $request_state = $self->{_http_request_state} or return;
        return if !$request_state->{body_done};
        return $request;
    }

    sub on_data ($self, $bytes) {
        $self->{_bench_input} = '' if !defined $self->{_bench_input};
        $self->{_bench_input} .= $bytes;

        while (length($self->{_bench_input})) {
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

            my $expect = 0;
            if ($main::STAGE eq 'checked') {
                $expect = Linux::Event::Net::HTTP::Connection::_expect_continue(
                    $request,
                );
                if ($expect < 0) {
                    $self->_protocol_error(417, $request->http_version);
                    last;
                }
            }

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

            # Mirror Connection::_drive_http1 exactly for the benchmark's
            # bodyless GET request. The production path reuses one per-
            # connection state hash instead of allocating _new_request_state
            # for every bodyless transaction.
            my $body_mode = $request->body_mode;
            my $bodyless = $body_mode eq 'none';
            my $request_state;
            if ($bodyless) {
                $request_state = $self->{_http_bodyless_state} //= {
                    mode      => 'none',
                    body_done => 0,
                };
                $request_state->{body_done} = 0;
                delete $request_state->{close_after_response};
            } else {
                $request_state
                    = Linux::Event::Net::HTTP::Connection::_new_request_state(
                        $request, $body_mode,
                    );
            }

            $self->{_http_active_request} = $request;
            $self->{_http_active_response} = $response;
            $self->{_http_request_state} = $request_state;
            $self->{_http_response_state} = undef;

            if ($expect && Linux::Event::Net::HTTP::Connection::_body_pending($request_state)) {
                $self->write("HTTP/1.1 100 Continue\r\n\r\n");
            }

            if ($main::STAGE eq 'state') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
                next;
            }

            my $handler
                = ($main::STAGE eq 'end' || $main::STAGE eq 'checked')
                ? $END : $NOOP;
            if ($main::STAGE eq 'callbacks'
                || $main::STAGE eq 'end'
                || $main::STAGE eq 'checked') {
                last if !$self->_invoke_http_callback(
                    $NOOP, $request, $response,
                );
                $request_state->{body_done} = 1;
                last if !$self->_invoke_http_callback(
                    $handler, $request, $response,
                );
            } else {
                my $ok;
                {
                    local $self->{_http_dispatching} = 1;
                    $ok = eval {
                        $NOOP->($self, $request, $response);
                        $request_state->{body_done} = 1;
                        $handler->($self, $request, $response);
                        1;
                    };
                }
                if (!$ok) {
                    $self->_fail_active_transaction(
                        500, $request, $response,
                    );
                    last;
                }
            }

            if ($main::STAGE eq 'callbacks') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
                next;
            }

            if ($main::STAGE eq 'fused') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
                next;
            }

            next if $main::STAGE eq 'end' || $main::STAGE eq 'checked';

            my $native_request = $self->native_default_context($response)
                or die "native default response unexpectedly ineligible\n";

            if ($main::STAGE eq 'eligibility') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($self->data->{wire});
                next;
            }

            my $native_wire = Linux::Event::Net::HTTP::_Native::Response1
                ->build_default_final(
                    $native_request, $self->data->{payload},
                );
            die "native default response build unexpectedly failed\n"
                if !defined $native_wire;

            if ($main::STAGE eq 'build') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($native_wire);
                next;
            }

            $response->{started} = 1;
            $response->{ended} = 1;
            $self->{_http_response_state} = undef;

            if ($main::STAGE eq 'mark') {
                Linux::Event::Net::HTTP::Connection::_clear_transaction($self);
                $self->write($native_wire);
                next;
            }

            $self->write($native_wire);
            $self->{_http_active_request} = undef;
            $self->{_http_active_response} = undef;
            $self->{_http_request_state} = undef;
            $self->{_http_response_state} = undef;
            $self->resume_read if $self->is_read_paused;
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
