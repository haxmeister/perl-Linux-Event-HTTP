package Linux::Event::Net::HTTP::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';

use Carp qw(croak);
use Scalar::Util qw(refaddr);
use utf8 ();

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();
use Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked ();
use Linux::Event::Net::HTTP::Response;

our $VERSION = '0.001';

my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $CHUNKED = 'Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked';
my $MAX_REQUEST_HEAD = 65_536;
my $MAX_HEADERS = 100;
my %CLASS_HANDLER;

sub _class_handler ($class, $name) {
    my $key = "$class\0$name";
    return $CLASS_HANDLER{$key} if exists $CLASS_HANDLER{$key};
    return $CLASS_HANDLER{$key} = $class->can($name);
}

sub _take_http_handler ($class, $name, $option) {
    if (exists $option->{$name}) {
        my $handler = delete $option->{$name};
        croak "new(): $name must be a coderef" if ref($handler) ne 'CODE';
        return $handler;
    }
    return _class_handler($class, $name);
}

sub new ($class, %option) {
    croak 'new(): Connection owns on_data; use on_request for HTTP requests'
        if exists $option{on_data};
    croak 'new(): Connection cannot use message framing callbacks'
        if exists($option{on_message}) || exists($option{on_messages});

    my $loop = delete $option{loop};
    my $on_request = _take_http_handler($class, 'on_request', \%option);
    my $on_body = _take_http_handler($class, 'on_body', \%option);
    my $on_body_end = _take_http_handler($class, 'on_body_end', \%option);

    croak 'new(): HTTP Connection requires on_request callback or method'
        if !$on_request;

    my $self = $class->SUPER::new(%option);
    $self->{_http_on_request} = $on_request;
    $self->{_http_on_body} = $on_body;
    $self->{_http_on_body_end} = $on_body_end;
    $self->{_http_input} = '';
    $self->{_http_active_request} = undef;
    $self->{_http_active_response} = undef;
    $self->{_http_request_state} = undef;
    $self->{_http_response_state} = undef;
    $self->{_http_driving} = 0;
    $self->{_http_dispatching} = 0;
    $self->{_http_closing} = 0;

    $self->_attach_to_loop($loop) if $loop;
    return $self;
}

sub connect ($class, %option) {
    croak 'connect(): HTTP client support is not implemented by Linux::Event::Net::HTTP::Connection';
}

sub on_data ($self, $bytes) {
    return if $self->{_http_closing} || $self->is_closed;
    $self->{_http_input} .= $bytes;
    $self->_drive_http1;
    return;
}

sub _new_request_state ($request) {
    my $mode = $request->body_mode;
    my $state = {
        mode      => $mode,
        body_done => 0,
    };

    if ($mode eq 'content-length') {
        $state->{remaining} = $request->content_length // 0;
    } elsif ($mode eq 'chunked') {
        $state->{decoder} = $CHUNKED->new;
    }

    return $state;
}

sub _body_pending ($state) {
    return 0 if $state->{body_done};
    return 0 if $state->{mode} eq 'none';
    return $state->{remaining} > 0 if $state->{mode} eq 'content-length';
    return 1;
}

sub _expect_continue ($request) {
    my @values = $request->header_values('Expect');
    return 0 if !@values;
    return -1 if $request->http_version ne '1.1';

    my $count = 0;
    for my $value (@values) {
        for my $member (split /,/, $value, -1) {
            $member =~ s/\A[ \t]+//;
            $member =~ s/[ \t]+\z//;
            return -1 if $member eq '' || lc($member) ne '100-continue';
            ++$count;
        }
    }

    return $count ? 1 : -1;
}

sub _invoke_http_callback ($self, $handler, $request, $response, @extra) {
    return 1 if !$handler;

    my $ok;
    {
        local $self->{_http_dispatching} = 1;
        $ok = eval {
            $handler->($self, $request, $response, @extra);
            1;
        };
    }

    return 1 if $ok;
    $self->_fail_active_transaction(500, $request, $response);
    return 0;
}

sub _clear_transaction ($self) {
    $self->{_http_active_request} = undef;
    $self->{_http_active_response} = undef;
    $self->{_http_request_state} = undef;
    $self->{_http_response_state} = undef;
    return;
}

sub _abort_started_response ($self, $response) {
    return if $self->{_http_closing} || $self->is_closed;

    $response->_mark_ended if $response && !$response->is_ended;
    $self->_clear_transaction;
    $self->{_http_input} = '';
    $self->{_http_closing} = 1;
    $self->pause_read if !$self->is_read_paused;
    $self->end;
    return;
}

sub _fail_active_transaction ($self, $status, $request, $response) {
    return if $self->{_http_closing} || $self->is_closed;

    if ($response && $response->is_started) {
        $self->_abort_started_response($response);
    } else {
        $self->_protocol_error($status, $request->http_version);
    }
    return;
}

sub _finish_request_body ($self) {
    my $request = $self->{_http_active_request} or return;
    my $response = $self->{_http_active_response} or return;
    my $state = $self->{_http_request_state} or return;
    return if $state->{body_done};

    $state->{body_done} = 1;
    delete $state->{decoder};
    delete $state->{remaining};

    return if !$self->_invoke_http_callback(
        $self->{_http_on_body_end}, $request, $response,
    );
    return if $self->{_http_closing} || $self->is_closed;
    return if !$self->{_http_active_request};

    if ($response->is_ended) {
        $self->_finalize_transaction;
    } else {
        $self->pause_read if !$self->is_read_paused;
    }
    return;
}

sub _consume_request_body ($self) {
    my $request = $self->{_http_active_request} or return 0;
    my $response = $self->{_http_active_response} or return 0;
    my $state = $self->{_http_request_state} or return 0;
    return 0 if $state->{body_done};

    if ($state->{mode} eq 'content-length') {
        if (($state->{remaining} // 0) == 0) {
            $self->_finish_request_body;
            return 1;
        }
        return 0 if !length($self->{_http_input});

        my $available = length($self->{_http_input});
        my $take = $available < $state->{remaining}
            ? $available : $state->{remaining};

        my $chunk;
        if ($self->{_http_on_body}) {
            $chunk = substr($self->{_http_input}, 0, $take, '');
        } else {
            substr($self->{_http_input}, 0, $take, '');
        }
        $state->{remaining} -= $take;

        if (defined($chunk) && length($chunk)) {
            return 1 if !$self->_invoke_http_callback(
                $self->{_http_on_body}, $request, $response, $chunk,
            );
            return 1 if $self->{_http_closing} || $self->is_closed;
            return 1 if !$self->{_http_active_request};
        }

        $self->_finish_request_body if $state->{remaining} == 0;
        return 1;
    }

    if ($state->{mode} eq 'chunked') {
        return 0 if !length($self->{_http_input});

        my ($done, $decoded);
        my $ok = eval {
            ($done, $decoded) = $state->{decoder}->feed(
                $self->{_http_input}, $self->{_http_on_body} ? 1 : 0,
            );
            1;
        };
        if (!$ok) {
            $self->_fail_active_transaction(400, $request, $response);
            return 1;
        }

        if (defined($decoded) && length($decoded)) {
            return 1 if !$self->_invoke_http_callback(
                $self->{_http_on_body}, $request, $response, $decoded,
            );
            return 1 if $self->{_http_closing} || $self->is_closed;
            return 1 if !$self->{_http_active_request};
        }

        $self->_finish_request_body if $done;
        return 1;
    }

    $self->_finish_request_body;
    return 1;
}

sub _finalize_transaction ($self) {
    return if $self->{_http_closing} || $self->is_closed;
    $self->_clear_transaction;
    $self->resume_read if $self->is_read_paused;
    $self->_drive_http1
        if !$self->{_http_driving} && !$self->{_http_dispatching};
    return;
}

sub _drive_http1 ($self) {
    return if $self->{_http_driving} || $self->{_http_closing}
        || $self->is_closed;

    local $self->{_http_driving} = 1;

    while (!$self->{_http_closing} && !$self->is_closed) {
        if (my $request = $self->{_http_active_request}) {
            my $response = $self->{_http_active_response};
            my $state = $self->{_http_request_state};

            if (!$state->{body_done}) {
                if (!_body_pending($state)) {
                    $self->_finish_request_body;
                    next;
                }

                last if !length($self->{_http_input});
                $self->_consume_request_body;
                next;
            }

            if ($response && $response->is_ended) {
                $self->_finalize_transaction;
                next;
            }

            $self->pause_read if $response && !$self->is_read_paused;
            last;
        }

        last if !length($self->{_http_input});

        my $request;
        my $parsed = eval {
            $request = $PARSER->parse_request(
                $self->{_http_input}, 0, $MAX_HEADERS,
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
            if (length($self->{_http_input}) > $MAX_REQUEST_HEAD) {
                $self->_protocol_error(431);
            }
            last;
        }

        my $consumed = $request->_consumed;
        if ($consumed > $MAX_REQUEST_HEAD) {
            $self->_protocol_error(431, $request->http_version);
            last;
        }

        substr($self->{_http_input}, 0, $consumed, '');

        my $expect = _expect_continue($request);
        if ($expect < 0) {
            $self->_protocol_error(417, $request->http_version);
            last;
        }

        my $response
            = Linux::Event::Net::HTTP::Response->_new_bound($self, $request);
        my $request_state = _new_request_state($request);

        $self->{_http_active_request} = $request;
        $self->{_http_active_response} = $response;
        $self->{_http_request_state} = $request_state;
        $self->{_http_response_state} = undef;

        if ($expect && _body_pending($request_state)) {
            $self->write("HTTP/1.1 100 Continue\r\n\r\n");
        }

        if (!$self->_invoke_http_callback(
            $self->{_http_on_request}, $request, $response,
        )) {
            last;
        }
        last if $self->{_http_closing} || $self->is_closed;
        next if !$self->{_http_active_request};

        if (!_body_pending($request_state)) {
            $self->_finish_request_body;
        }
    }

    return;
}

sub _body_bytes ($operation, $body) {
    croak "$operation(): body must be a scalar byte string" if ref($body);

    my $bytes = defined($body) ? "$body" : '';
    if (utf8::is_utf8($bytes)) {
        croak "$operation(): body contains wide characters; encode it to bytes first"
            if !utf8::downgrade($bytes, 1);
    }
    return $bytes;
}

sub _canonical_decimal ($value) {
    return undef if !defined($value) || $value !~ /\A\d+\z/;
    my $decimal = "$value";
    $decimal =~ s/\A0+(?=\d)//;
    return $decimal;
}

sub _compare_count ($count, $decimal) {
    my $actual = "$count";
    return length($actual) <=> length($decimal)
        || $actual cmp $decimal;
}

sub _response_start ($self, $response, $bytes, $final) {
    my $request = $self->{_http_active_request};
    my $version = $request->http_version;
    my $method = $request->method;
    my $status = $response->status;
    my $operation = $final ? 'end' : 'write';

    croak "$operation(): informational responses require a future interim-response API"
        if $status >= 100 && $status < 200;

    my $body_forbidden = $status == 204 || $status == 304;
    croak "$operation(): this response status cannot carry a message body"
        if $body_forbidden && length($bytes);

    my @transfer_encoding = $response->header_values('Transfer-Encoding');
    croak "$operation(): Transfer-Encoding response bodies are not implemented yet"
        if @transfer_encoding;

    my @content_length = $response->header_values('Content-Length');
    my $head_request = $method eq 'HEAD';

    croak 'write(): HEAD responses must be completed with end()'
        if !$final && $head_request;
    croak 'write(): this response status cannot use body streaming'
        if !$final && $body_forbidden;

    if (!@content_length && !$body_forbidden) {
        if ($final) {
            $response->header('Content-Length', length($bytes));
            @content_length = $response->header_values('Content-Length');
        } else {
            croak 'write(): set Content-Length before starting a streaming response';
        }
    }

    my $expected;
    if (@content_length == 1) {
        $expected = _canonical_decimal($content_length[0]);
        croak "$operation(): Content-Length must be a decimal number"
            if !defined $expected;
    }

    if ($final && !$head_request && !$body_forbidden && defined $expected) {
        croak 'end(): Content-Length does not match scalar body length'
            if _compare_count(length($bytes), $expected) != 0;
    }

    if (!$final && defined $expected
        && _compare_count(length($bytes), $expected) > 0) {
        croak 'write(): response body exceeds Content-Length';
    }

    my @connection = $response->header_values('Connection');
    my $close_after = !$request->keep_alive
        || _has_connection_token(\@connection, 'close');

    if (!$request->keep_alive && $version eq '1.1') {
        $response->header('Connection', 'close');
        $close_after = 1;
    } elsif ($request->keep_alive && $version eq '1.0' && !@connection) {
        $response->header('Connection', 'keep-alive');
    }

    my $head = $response->_serialize_head($version);
    $response->_mark_started;

    return (
        {
            expected      => $expected,
            sent          => 0,
            suppress_body => $head_request || $body_forbidden ? 1 : 0,
            close_after   => $close_after ? 1 : 0,
        },
        $head,
    );
}

sub _write_response ($self, $response, $body, $final) {
    my $operation = $final ? 'end' : 'write';

    croak "$operation(): connection is closing or closed"
        if $self->{_http_closing} || $self->is_closed;

    my $active = $self->{_http_active_response};
    croak "$operation(): this Response is not the active HTTP transaction"
        if !$active || refaddr($active) != refaddr($response);

    my $bytes = _body_bytes($operation, $body);
    my $state = $self->{_http_response_state};

    if (!$state) {
        my ($created, $head) = $self->_response_start(
            $response, $bytes, $final,
        );
        $state = $self->{_http_response_state} = $created;

        if ($final) {
            my $wire_body = $state->{suppress_body} ? '' : $bytes;
            return $self->_complete_response(
                $response, $head . $wire_body, $state->{close_after},
            );
        }

        $state->{sent} = length($bytes);
        return $self->write($head . $bytes);
    }

    my $new_sent = $state->{sent} + length($bytes);
    if (defined($state->{expected})
        && _compare_count($new_sent, $state->{expected}) > 0) {
        croak "$operation(): response body exceeds Content-Length";
    }
    if ($final && defined($state->{expected})
        && _compare_count($new_sent, $state->{expected}) != 0) {
        croak 'end(): response body length does not match Content-Length';
    }

    $state->{sent} = $new_sent;

    if ($final) {
        return $self->_complete_response(
            $response, $bytes, $state->{close_after},
        );
    }

    return length($bytes) ? $self->write($bytes) : 1;
}

sub _complete_response ($self, $response, $wire, $close_after) {
    $response->_mark_ended;
    $self->{_http_response_state} = undef;

    if ($close_after) {
        $self->_clear_transaction;
        $self->{_http_closing} = 1;
        $self->{_http_input} = '';
        $self->pause_read if !$self->is_read_paused;
        $self->end($wire);
        return 1;
    }

    my $accepted = length($wire) ? $self->write($wire) : 1;
    my $request_state = $self->{_http_request_state};
    if ($request_state && $request_state->{body_done}) {
        $self->_finalize_transaction;
    } else {
        $self->resume_read if $self->is_read_paused;
    }
    return $accepted;
}

sub _has_connection_token ($values, $wanted) {
    for my $value (@$values) {
        for my $token (split /,/, $value) {
            $token =~ s/\A[ \t]+//;
            $token =~ s/[ \t]+\z//;
            return 1 if lc($token) eq $wanted;
        }
    }
    return 0;
}

sub _protocol_error ($self, $status, $version = '1.1') {
    return if $self->{_http_closing} || $self->is_closed;

    $version = '1.1' if $version ne '1.0' && $version ne '1.1';

    my $response = Linux::Event::Net::HTTP::Response->_new(
        status => $status,
        headers => [
            [ 'Content-Length', '0' ],
            [ 'Connection', 'close' ],
        ],
    );

    my $head = $response->_serialize_head($version);
    if (my $active = $self->{_http_active_response}) {
        $active->_mark_ended if !$active->is_ended;
    }
    $self->_clear_transaction;
    $self->{_http_input} = '';
    $self->{_http_closing} = 1;
    $self->pause_read if !$self->is_read_paused;
    $self->end($head);
    return;
}

sub CLONE ($class) {
    %CLASS_HANDLER = ();
    Linux::Event::_Socket::Stream::CLONE($class);
    return;
}

sub CLONE_SKIP ($class) { 1 }

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Connection - HTTP/1 connection protocol state

=head1 SYNOPSIS

    package UploadHTTP;
    use parent 'Linux::Event::Net::HTTP::Connection';

    sub on_request ($self, $request, $response) {
        $self->data->{body} = '';
        $response->header('Content-Type', 'text/plain');
    }

    sub on_body ($self, $request, $response, $bytes) {
        $self->data->{body} .= $bytes;
    }

    sub on_body_end ($self, $request, $response) {
        $response->end("received " . length($self->data->{body}) . " bytes\n");
    }

    package main;
    use Linux::Event::Loop;
    use Linux::Event::IO::Sock::Listener;

    my $loop = Linux::Event::Loop->new;
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop         => $loop,
        stream_class => 'UploadHTTP',
        host         => '127.0.0.1',
        port         => 8080,
    );

    $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Net::HTTP::Connection> is a
L<Linux::Event::IO::Sock::Stream> subclass. Linux::Event continues to own the
socket, TLS transport, readiness, ordered-byte reads and writes, buffering, and
backpressure. Connection owns HTTP/1 request boundaries, request-body framing,
request sequencing, response serialization, and persistence policy.

C<on_data> is the cached Linux::Event Stream callback for the protocol engine.
Applications use C<on_request>, optional C<on_body>, and optional C<on_body_end>
instead. Named methods are resolved and cached by connection class. Direct
construction may supply the same names as constructor callbacks when lexical
application scope is preferable.

Every successfully dispatched Request is paired with one
L<Linux::Event::Net::HTTP::Response> created by Connection. The same Request and
Response objects are passed to all callbacks for that transaction.

=head1 REQUEST BODY STREAMING

Request bodies are streaming-first. Connection never accumulates an entire
request body merely to dispatch it. C<Content-Length> bodies are delivered as
bytes become available. C<Transfer-Encoding: chunked> is decoded with the
vendored picohttpparser chunked decoder before application delivery.

Chunk extensions are accepted by pico. Trailer sections are consumed as part of
the chunked framing boundary but are not yet exposed as Request fields. The next
pipelined request remains in the connection input buffer and is parsed only
after the current request body and response have both completed.

If C<on_body> is absent, request body bytes are drained and discarded without
being accumulated. C<on_body_end>, when present, still runs when the complete
request has been consumed. It also runs for requests with no body or
C<Content-Length: 0>, immediately after C<on_request> returns.

=head1 CALLBACKS

=head2 on_request

    sub on_request ($connection, $request, $response) {
        ...
    }

Runs once after a validated request head has been parsed. A body-bearing request
may continue delivering C<on_body> calls after this callback. The Response may
be written immediately or retained for completion after the body or another
event.

=head2 on_body

    sub on_body ($connection, $request, $response, $bytes) {
        ...
    }

Receives decoded request-body byte strings. Fixed-length bytes are delivered
without whole-body accumulation. Chunked framing bytes are never exposed to the
application.

=head2 on_body_end

    sub on_body_end ($connection, $request, $response) {
        $response->end("ok\n");
    }

Runs once when the complete request body boundary has been reached. If the
Response has already ended, the transaction becomes eligible for the next
pipelined request. If the Response is still active, Connection pauses reads so
a later request cannot overtake it.

A direct/adopted connection may use constructor callbacks instead:

    my $connection = Linux::Event::Net::HTTP::Connection->new(
        fh => $connected_socket,
        on_request => sub ($connection, $request, $response) {
            ...
        },
        on_body => sub ($connection, $request, $response, $bytes) {
            ...
        },
        on_body_end => sub ($connection, $request, $response) {
            $response->end("done\n");
        },
    );

=head1 EXPECT: 100-CONTINUE

For an HTTP/1.1 request with a body and C<Expect: 100-continue>, Connection
emits C<100 Continue> after validating the request head so clients waiting to
send the body can proceed. Unsupported expectations are answered with 417 and
the connection is closed.

=head1 RESPONSE FLOW

The Response object owns status, headers, body output, and transaction
completion:

    $response->status(200);
    $response->header('Content-Type', 'text/plain');
    $response->end("hello\n");

For fixed-length response streaming, declare the final length before output
starts:

    $response->header('Content-Length', 12);
    my $accepted = $response->write("hello ");
    $response->end("world\n");

The first C<write> commits the HTTP response head, after which status and
headers are immutable. C<write> returns Linux::Event Stream backpressure status.
C<end> marks the response half complete. A persistent connection advances to
the next request only after both the request body and response are complete.

HEAD responses suppress body bytes while retaining the representation length
used for automatic Content-Length. Status 204 and 304 reject supplied body
bytes. Automatic chunked response streaming remains a later protocol milestone.

=head1 LIMITS

The current connection request-head limit is 65,536 bytes and the parser header
count limit is 100 fields. Request bodies are streamed and therefore do not
inherit the request-head memory limit. Explicit body-size policy will be part of
HTTP protocol tuning rather than implicit accumulation.

=head1 SEE ALSO

L<Linux::Event::Net::HTTP::Request>, L<Linux::Event::Net::HTTP::Response>,
L<Linux::Event::IO::Sock::Stream>, L<Linux::Event::IO::Sock::Listener>.

=cut
