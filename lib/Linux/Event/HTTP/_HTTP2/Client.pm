package Linux::Event::HTTP::_HTTP2::Client;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(blessed refaddr weaken);

use Linux::Event::HTTP::_HTTP2;
use Linux::Event::HTTP::Transaction;

our $VERSION = '0.002';

use constant {
    H2_DATA       => 0,
    H2_HEADERS    => 1,
    H2_END_STREAM => 0x1,
    H2_INTERNAL_ERROR => 2,
    H2_CANCEL     => 8,
};

my $BODY_HIGH_WATER = 65_536;
my $BODY_LOW_WATER  = 32_768;

sub new ($class, %option) {
    my $stream = delete $option{stream};
    die 'new(): stream must be an object with write()'
        if !blessed($stream) || !$stream->can('write');
    my $autostart = exists($option{autostart})
        ? delete($option{autostart}) : 1;
    die 'new(): autostart must be zero or one'
        if !defined($autostart) || ref($autostart)
        || "$autostart" !~ /\A[01]\z/;
    die 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    require Net::HTTP2::nghttp2;
    require Net::HTTP2::nghttp2::Session;
    die 'new(): nghttp2 library is unavailable'
        if !Net::HTTP2::nghttp2->available;

    my $self = bless {
        stream            => $stream,
        session           => undef,
        streams           => {},
        tx_stream         => {},
        in_session_call   => 0,
        transport_blocked => 0,
        closed            => 0,
        started           => 0,
    }, $class;

    my $weak = $self;
    weaken($weak);

    my $session = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers => sub (@args) {
                my $self = $weak or return 0;
                return $self->_on_begin_headers(@args);
            },
            on_header => sub (@args) {
                my $self = $weak or return 0;
                return $self->_on_header(@args);
            },
            on_frame_recv => sub (@args) {
                my $self = $weak or return 0;
                return $self->_on_frame_recv(@args);
            },
            on_data_chunk_recv => sub (@args) {
                my $self = $weak or return 0;
                return $self->_on_data_chunk_recv(@args);
            },
            on_stream_close => sub (@args) {
                my $self = $weak or return 0;
                return $self->_on_stream_close(@args);
            },
        },
    );

    $self->{session} = $session;
    $self->start if $autostart;
    return $self;
}

sub start ($self) {
    die 'start(): executor is closed' if $self->{closed};
    return $self if $self->{started};
    $self->{started} = 1;
    $self->{session}->send_connection_preface(
        max_concurrent_streams => 100,
    );
    $self->flush;
    return $self;
}

sub started ($self) { !!$self->{started} }

sub session ($self) { $self->{session} }
sub stream  ($self) { $self->{stream} }

sub stream_count ($self) {
    return scalar keys %{$self->{streams}};
}

sub transaction_for_stream ($self, $stream_id) {
    my $state = $self->{streams}{$stream_id} or return undef;
    return $state->{transaction};
}

sub input ($self, $bytes) {
    die 'input(): executor is closed' if $self->{closed};
    die 'input(): executor is not started' if !$self->{started};
    die 'input(): bytes must be a scalar' if ref $bytes;
    return 0 if !defined($bytes) || $bytes eq '';

    my $consumed;
    {
        local $self->{in_session_call} = 1;
        $consumed = $self->{session}->mem_recv($bytes);
    }
    die 'input(): nghttp2 did not consume complete input'
        if !defined($consumed) || $consumed != length($bytes);

    $self->flush;
    return $consumed;
}

sub flush ($self) {
    return if $self->{closed};
    return if !$self->{started};
    return if $self->{in_session_call};
    return if $self->{transport_blocked};

    local $self->{in_session_call} = 1;
    while ($self->{session}->want_write) {
        my $bytes = $self->{session}->mem_send;
        last if !defined($bytes) || $bytes eq '';

        my $accepted = $self->{stream}->write($bytes);
        if (!$accepted) {
            $self->{transport_blocked} = 1;
            last;
        }
    }
    return;
}

sub transport_drain ($self) {
    return if $self->{closed};
    $self->{transport_blocked} = 0;
    $self->flush;

    for my $state (values %{$self->{streams}}) {
        my $provider = $state->{request_provider} or next;
        next if length($provider->{queue}) >= $BODY_LOW_WATER;
        my $tx = $state->{transaction} or next;
        my $body = $tx->_request_body_object or next;
        $body->_drain;
    }
    return;
}

sub close ($self, $error = 'HTTP/2 connection closed') {
    return if $self->{closed};
    $self->{closed} = 1;

    for my $state (values %{$self->{streams}}) {
        my $tx = $state->{transaction} or next;
        next if $tx->is_terminal;
        $tx->_fail($error);
        $self->_invoke_error($state, $error);
    }

    $self->{streams} = {};
    $self->{tx_stream} = {};
    $self->{session} = undef;
    return;
}

sub _buffer_limit ($value) {
    die 'request(): buffer_body must be a positive integer'
        if !defined($value) || ref($value)
        || "$value" !~ /\A[0-9]+\z/ || $value < 1;
    return 0 + $value;
}

sub request ($self, $request, %option) {
    die 'request(): executor is closed' if $self->{closed};
    die 'request(): executor is not started' if !$self->{started};
    die 'request(): requires a Linux::Event::HTTP::Request'
        if !blessed($request)
        || !$request->isa('Linux::Event::HTTP::Request');
    die 'request(): HTTP/2 executor requires Request version 2'
        if ($request->version // '') ne '2';
    die 'request(): HTTP/2 CONNECT requires future stream-tunnel support'
        if uc($request->method) eq 'CONNECT';

    my $stream_body = delete $option{stream_body};
    die 'request(): stream_body must be a hash reference'
        if defined($stream_body) && ref($stream_body) ne 'HASH';
    $stream_body = { %$stream_body } if $stream_body;

    my $buffer_limit = exists($option{buffer_body})
        ? _buffer_limit(delete $option{buffer_body})
        : undef;

    my %callback;
    my %known = map { $_ => 1 } qw(
        on_response on_body on_complete on_error on_informational
    );
    my @unknown = grep { !$known{$_} } keys %option;
    die 'request(): unknown options: ' . join(', ', sort @unknown)
        if @unknown;

    for my $name (keys %option) {
        my $cb = $option{$name};
        die "request(): $name must be a coderef"
            if defined($cb) && ref($cb) ne 'CODE';
        $callback{$name} = $cb if $cb;
    }

    die 'request(): buffer_body cannot be combined with on_body'
        if defined($buffer_limit) && $callback{on_body};

    my $body = $request->body;
    die 'request(): stream_body cannot be combined with a scalar Request body'
        if $stream_body && defined $body;

    my $block = Linux::Event::HTTP::_HTTP2->request_headers($request);
    my @normal = grep { substr($_->[0], 0, 1) ne ':' } @$block;

    my $tx = Linux::Event::HTTP::Transaction->_new(
        request    => $request,
        controller => $self,
    );
    $tx->_activate;

    my ($request_body, $provider, $provider_cb);
    if ($stream_body) {
        $request->_begin_stream_body;
        $request_body = $tx->request_body(%$stream_body);
        $provider = {
            queue       => '',
            eof         => 0,
            blocked     => 0,
            transaction => $tx,
        };
        weaken($provider->{transaction});
        $provider_cb = sub ($stream_id, $max_length) {
            return _request_data_provider(
                $stream_id, $max_length, $provider,
            );
        };
    }

    my $stream_id = $self->{session}->submit_request(
        method    => $request->method,
        path      => $request->target,
        scheme    => $request->scheme,
        authority => $request->authority,
        headers   => \@normal,
        body      => $stream_body ? $provider_cb : $body,
    );

    my $state = {
        transaction      => $tx,
        callback         => \%callback,
        buffer_limit     => $buffer_limit,
        buffered_body    => '',
        header_block     => [],
        response         => undef,
        response_done    => 0,
        request_provider => $provider,
    };
    $self->{streams}{$stream_id} = $state;
    $self->{tx_stream}{refaddr($tx)} = $stream_id;
    $request->_mark_committed;

    $self->flush;
    return $tx;
}

sub _request_data_provider ($stream_id, $max_length, $provider) {
    if (!length($provider->{queue})) {
        return ('', 1) if $provider->{eof};
        return;
    }

    my $take = length($provider->{queue}) < $max_length
        ? length($provider->{queue})
        : $max_length;
    my $chunk = substr($provider->{queue}, 0, $take, '');
    my $eof = $provider->{eof} && !length($provider->{queue}) ? 1 : 0;

    if ($provider->{blocked}
        && length($provider->{queue}) < $BODY_LOW_WATER) {
        $provider->{blocked} = 0;
        if (my $tx = $provider->{transaction}) {
            if (my $body = $tx->_request_body_object) {
                $body->_drain;
            }
        }
    }

    return ($chunk, $eof);
}

sub _on_begin_headers ($self, $stream_id, $frame_type, $flags) {
    my $state = $self->{streams}{$stream_id} or return 0;
    $state->{header_block} = [];
    return 0;
}

sub _on_header ($self, $stream_id, $name, $value, $flags) {
    my $state = $self->{streams}{$stream_id} or return 0;
    push @{$state->{header_block}}, [ $name, $value ];
    return 0;
}

sub _status_from_block ($block) {
    for my $pair (@$block) {
        return $pair->[1] if $pair->[0] eq ':status';
    }
    return undef;
}

sub _on_frame_recv ($self, $frame) {
    my $stream_id = $frame->{stream_id} // 0;
    return 0 if !$stream_id;
    my $state = $self->{streams}{$stream_id} or return 0;
    my $tx = $state->{transaction};

    if (($frame->{type} // -1) == H2_HEADERS) {
        if (!$state->{response}) {
            my $status = _status_from_block($state->{header_block});
            if (defined($status) && $status =~ /\A1[0-9][0-9]\z/) {
                my $response = eval {
                    Linux::Event::HTTP::_HTTP2->response_from_headers(
                        $state->{header_block},
                        end_stream => 1,
                    );
                };
                if (!$response) {
                    $self->_stream_failure($stream_id, "$@");
                    return 0;
                }
                if (my $cb = $state->{callback}{on_informational}) {
                    my $ok = eval { $cb->($tx, $response); 1 };
                    if (!$ok) {
                        $self->_stream_failure($stream_id, "$@");
                    }
                }
                return 0;
            }

            my $response = eval {
                Linux::Event::HTTP::_HTTP2->response_from_headers(
                    $state->{header_block},
                    end_stream => (($frame->{flags} // 0) & H2_END_STREAM)
                        ? 1 : 0,
                );
            };
            if (!$response) {
                $self->_stream_failure($stream_id, "$@");
                return 0;
            }

            $state->{response} = $response;
            $tx->_set_response($response);

            if (my $cb = $state->{callback}{on_response}) {
                my $ok = eval { $cb->($tx, $response); 1 };
                if (!$ok) {
                    $self->_stream_failure($stream_id, "$@");
                    return 0;
                }
            }

            if (($frame->{flags} // 0) & H2_END_STREAM) {
                $self->_finish_response($stream_id);
            }
            return 0;
        }

        # Later HEADERS are trailers. They are not folded into the initial
        # response field list while the public message model has no trailer API.
        if (($frame->{flags} // 0) & H2_END_STREAM) {
            $self->_finish_response($stream_id);
        }
        return 0;
    }

    if (($frame->{type} // -1) == H2_DATA
        && (($frame->{flags} // 0) & H2_END_STREAM)) {
        $self->_finish_response($stream_id);
    }

    return 0;
}

sub _on_data_chunk_recv ($self, $stream_id, $data, $flags) {
    my $state = $self->{streams}{$stream_id} or return 0;
    my $tx = $state->{transaction};
    my $response = $state->{response};
    if (!$response) {
        $self->_stream_failure(
            $stream_id, 'HTTP/2 DATA arrived before final Response headers',
        );
        return 0;
    }

    if (defined $state->{buffer_limit}) {
        if (length($state->{buffered_body}) + length($data)
            > $state->{buffer_limit}) {
            $self->_stream_failure(
                $stream_id, 'buffer_body limit exceeded', H2_CANCEL,
            );
            return 0;
        }
        $state->{buffered_body} .= $data;
    } elsif (my $cb = $state->{callback}{on_body}) {
        my $ok = eval { $cb->($tx, $response, $data); 1 };
        if (!$ok) {
            $self->_stream_failure($stream_id, "$@");
            return 0;
        }
    }

    return 0;
}

sub _finish_response ($self, $stream_id) {
    my $state = $self->{streams}{$stream_id} or return;
    return if $state->{response_done}++;

    my $tx = $state->{transaction};
    my $response = $state->{response};
    if (!$response) {
        $self->_stream_failure(
            $stream_id, 'HTTP/2 stream ended before final Response headers',
        );
        return;
    }

    if (defined $state->{buffer_limit}) {
        $response->_set_received_body($state->{buffered_body});
    }
    $response->_mark_complete;
    $tx->_mark_complete if !$tx->is_terminal;

    if (my $cb = $state->{callback}{on_complete}) {
        my $ok = eval { $cb->($tx); 1 };
        if (!$ok) {
            # Completion callbacks observe terminal Transactions, matching the
            # HTTP/1 client contract. An application exception after successful
            # protocol completion cannot retroactively turn the exchange into
            # a stream failure.
            $self->_invoke_error($state, "$@");
        }
    }

    return;
}

sub _on_stream_close ($self, $stream_id, $error_code) {
    my $state = delete $self->{streams}{$stream_id};
    return 0 if !$state;

    my $tx = $state->{transaction};
    delete $self->{tx_stream}{refaddr($tx)};

    if (!$tx->is_terminal) {
        if ($error_code) {
            my $error = "HTTP/2 stream closed with error $error_code";
            $tx->_fail($error);
            $self->_invoke_error($state, $error);
        } elsif ($state->{response}) {
            $self->_finish_detached_response($state);
        } else {
            my $error = 'HTTP/2 stream closed before final Response';
            $tx->_fail($error);
            $self->_invoke_error($state, $error);
        }
    }

    return 0;
}

sub _finish_detached_response ($self, $state) {
    my $tx = $state->{transaction};
    my $response = $state->{response};

    if (defined $state->{buffer_limit}
        && !$response->has_buffered_body) {
        $response->_set_received_body($state->{buffered_body});
    }
    $response->_mark_complete;
    $tx->_mark_complete if !$tx->is_terminal;
    return;
}

sub _invoke_error ($self, $state, $error) {
    my $cb = $state->{callback}{on_error} or return;
    eval { $cb->($state->{transaction}, $error) };
    return;
}

sub _stream_failure ($self, $stream_id, $error, $code = H2_INTERNAL_ERROR) {
    $error = 'HTTP/2 stream failure' if !defined($error) || $error eq '';
    my $state = $self->{streams}{$stream_id} or return;

    my $tx = $state->{transaction};
    if (!$tx->is_terminal) {
        $tx->_fail($error);
        $self->_invoke_error($state, $error);
    }

    eval { $self->{session}->submit_rst_stream($stream_id, $code) };
    $self->flush;
    return;
}

sub _stream_id_for_tx ($self, $tx, $operation) {
    my $stream_id = $self->{tx_stream}{refaddr($tx)};
    die "$operation: Transaction is not active on this HTTP/2 connection"
        if !defined $stream_id;
    return $stream_id;
}

sub _write_http_request_body ($self, $tx, $bytes, $final, $operation) {
    my $stream_id = $self->_stream_id_for_tx($tx, "$operation()");
    die "$operation(): body must be a scalar" if ref $bytes;
    $bytes = '' if !defined $bytes;

    my $state = $self->{streams}{$stream_id}
        or die "$operation(): HTTP/2 stream state disappeared";
    my $provider = $state->{request_provider}
        or die "$operation(): Request has no streaming HTTP/2 data provider";

    $provider->{queue} .= $bytes;
    $provider->{eof} = 1 if $final;

    if ($self->{session}->is_stream_deferred($stream_id)) {
        $self->{session}->resume_stream($stream_id);
    }

    my $blocked = $self->{transport_blocked}
        || length($provider->{queue}) >= $BODY_HIGH_WATER;
    $provider->{blocked} = 1 if $blocked;

    $self->flush;
    return $blocked ? 0 : 1;
}

sub _write_http_response_body ($self, $tx, $bytes, $final, $operation) {
    die "$operation(): client HTTP/2 executor cannot write a Response body";
}

sub _cancel_http_transaction ($self, $tx) {
    my $stream_id = $self->{tx_stream}{refaddr($tx)};
    return if !defined $stream_id;

    $self->{session}->submit_rst_stream($stream_id, H2_CANCEL);
    $tx->_mark_cancelled if !$tx->is_terminal;
    $self->flush;
    return;
}

sub _upgrade_http_transaction ($self, $tx, $target_class) {
    die 'upgrade(): HTTP/1 whole-transport Upgrade is not available on HTTP/2';
}

sub _tunnel_http_transaction ($self, $tx, $target_class) {
    die 'tunnel(): HTTP/2 CONNECT requires a stream-level tunnel abstraction';
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::_HTTP2::Client - private HTTP/2 client executor

=head1 DESCRIPTION

This private executor owns one nghttp2 client Session and maps concurrent
HTTP/2 streams to ordinary Linux::Event::HTTP::Transaction objects.

It is not the public high-level Client connection pool.

=cut
