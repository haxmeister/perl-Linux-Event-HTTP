package Linux::Event::Net::HTTP::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';

use Carp qw(croak);
use Scalar::Util qw(refaddr);
use utf8 ();

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();
use Linux::Event::Net::HTTP::Response;

our $VERSION = '0.001';

my $PARSER = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $MAX_REQUEST_HEAD = 65_536;
my $MAX_HEADERS = 100;
my %CLASS_HANDLER;

sub _class_handler ($class) {
    return $CLASS_HANDLER{$class} if exists $CLASS_HANDLER{$class};
    return $CLASS_HANDLER{$class} = $class->can('on_request');
}

sub new ($class, %option) {
    croak 'new(): Connection owns on_data; use on_request for HTTP requests'
        if exists $option{on_data};
    croak 'new(): Connection cannot use message framing callbacks'
        if exists($option{on_message}) || exists($option{on_messages});

    my $loop = delete $option{loop};
    my $handler = delete $option{on_request};
    croak 'new(): on_request must be a coderef'
        if defined($handler) && ref($handler) ne 'CODE';

    $handler //= _class_handler($class);
    croak 'new(): HTTP Connection requires on_request callback or method'
        if !$handler;

    my $self = $class->SUPER::new(%option);
    $self->{_http_on_request} = $handler;
    $self->{_http_input} = '';
    $self->{_http_active_request} = undef;
    $self->{_http_active_response} = undef;
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

sub _drive_http1 ($self) {
    return if $self->{_http_driving} || $self->{_http_closing}
        || $self->is_closed;

    local $self->{_http_driving} = 1;

    while (!$self->{_http_active_request}
        && length($self->{_http_input})
        && !$self->{_http_closing}
        && !$self->is_closed) {

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

        if ($request->body_mode eq 'chunked'
            || ($request->body_mode eq 'content-length'
                && ($request->content_length // 0) > 0)) {
            # Request body streaming is the next protocol milestone. Refuse it
            # rather than consuming bytes with semantics we do not yet expose.
            $self->_protocol_error(501, $request->http_version);
            last;
        }

        my $response
            = Linux::Event::Net::HTTP::Response->_new_bound($self, $request);

        $self->{_http_active_request} = $request;
        $self->{_http_active_response} = $response;
        $self->{_http_response_state} = undef;
        $self->{_http_dispatching} = 1;

        my $handled = eval {
            $self->{_http_on_request}->($self, $request, $response);
            1;
        };
        my $failure = $@;
        $self->{_http_dispatching} = 0;

        if (!$handled) {
            if ($self->{_http_active_response}) {
                if ($self->{_http_active_response}->is_started) {
                    # A response head may already be on the wire, so a second
                    # HTTP response cannot be substituted safely.
                    $self->{_http_active_response}->_mark_ended;
                    $self->{_http_active_request} = undef;
                    $self->{_http_active_response} = undef;
                    $self->{_http_response_state} = undef;
                    $self->{_http_input} = '';
                    $self->{_http_closing} = 1;
                    $self->pause_read if !$self->is_read_paused;
                    $self->end;
                } else {
                    $self->_protocol_error(500, $request->http_version);
                }
            } elsif (!$self->{_http_closing} && !$self->is_closed) {
                $self->pause_read;
                $self->end;
                $self->{_http_closing} = 1;
            }
            last;
        }

        if ($self->{_http_active_response}) {
            # A callback may intentionally finish later. Stop accepting more
            # request bytes until Response->end completes this transaction.
            $self->pause_read if !$self->is_read_paused;
            last;
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
            expected       => $expected,
            sent           => 0,
            suppress_body  => $head_request || $body_forbidden ? 1 : 0,
            close_after    => $close_after ? 1 : 0,
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
    $self->{_http_active_request} = undef;
    $self->{_http_active_response} = undef;
    $self->{_http_response_state} = undef;

    if ($close_after) {
        $self->{_http_closing} = 1;
        $self->{_http_input} = '';
        $self->pause_read if !$self->is_read_paused;
        $self->end($wire);
        return 1;
    }

    my $accepted = length($wire) ? $self->write($wire) : 1;
    $self->resume_read if $self->is_read_paused;
    $self->_drive_http1 if !$self->{_http_dispatching};
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
        $active->_mark_ended;
    }
    $self->{_http_active_request} = undef;
    $self->{_http_active_response} = undef;
    $self->{_http_response_state} = undef;
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

    package HelloHTTP;
    use parent 'Linux::Event::Net::HTTP::Connection';

    sub on_request ($self, $request, $response) {
        $response->status(200);
        $response->header('Content-Type', 'text/plain');
        $response->end("hello\n");
    }

    package main;
    use Linux::Event::Loop;
    use Linux::Event::IO::Sock::Listener;

    my $loop = Linux::Event::Loop->new;
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop         => $loop,
        stream_class => 'HelloHTTP',
        host         => '127.0.0.1',
        port         => 8080,
    );

    $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Net::HTTP::Connection> is a
L<Linux::Event::IO::Sock::Stream> subclass. Linux::Event continues to own the
socket, TLS transport, readiness, ordered-byte reads and writes, buffering, and
backpressure. Connection owns the HTTP/1 request boundary, request sequencing,
response serialization, and persistence policy.

C<on_data> is the cached Linux::Event Stream callback for the protocol engine;
an application supplies C<on_request> instead. A named C<on_request> method is
resolved when each connection is constructed, not for every request. Direct
construction can alternatively supply C<on_request =E<gt> sub {...}>. The
future Server convenience layer will retain one constructor callback for all
accepted connections so lexical scope does not require one closure per accept.

Every successfully dispatched Request is paired with one
L<Linux::Event::Net::HTTP::Response> created by Connection. Applications mutate
and finish that object directly; they do not construct a Response or pass it
back to Connection.

=head1 CURRENT BODY SUPPORT

This connection milestone dispatches requests with no message body or an
explicit C<Content-Length: 0>. A positive Content-Length or chunked request is
answered with 501 and the connection is closed. This is deliberate: request
body streaming is the next protocol state rather than an implicit whole-body
buffer.

C<< $response->end($bytes) >> supports ordinary scalar response bodies and
automatically supplies Content-Length. Fixed-length response streaming is also
available by setting Content-Length before the first C<write>. Automatic
chunked response streaming is the next transfer-coding milestone.

=head1 CALLBACKS

=head2 on_request

    sub on_request ($connection, $request, $response) {
        ...
    }

Receives one validated L<Linux::Event::Net::HTTP::Request> and its bound
L<Linux::Event::Net::HTTP::Response>. The callback may call C<end> immediately
or retain the Response and finish it from a later event. If it returns while
the Response remains active, Connection pauses application reads so later
pipelined requests cannot overtake the current transaction.

A direct/adopted connection may instead use a constructor callback:

    my $connection = Linux::Event::Net::HTTP::Connection->new(
        fh => $connected_socket,
        on_request => sub ($connection, $request, $response) {
            $response->end("hello\n");
        },
    );

=head1 RESPONSE FLOW

The Response object owns status, headers, body output, and transaction
completion:

    $response->status(200);
    $response->header('Content-Type', 'text/plain');
    $response->end("hello\n");

For fixed-length streaming, declare the final length before output starts:

    $response->header('Content-Length', 12);
    my $accepted = $response->write("hello ");
    $response->end("world\n");

The first C<write> commits the HTTP response head, after which status and
headers are immutable. C<write> returns Linux::Event Stream backpressure status.
C<end> completes the transaction and allows the next buffered request to run.

HEAD responses suppress body bytes while retaining the representation length
used for automatic Content-Length. Status 204 and 304 reject supplied body
bytes. Informational responses and Transfer-Encoding require later protocol
APIs.

If the request or response requires connection close, Response C<end> uses
L<Linux::Event::IO::Sock::Stream/end> internally so queued output drains before
the write side is ended.

=head1 LIMITS

The current connection request-head limit is 65,536 bytes and the parser header
count limit is 100 fields. These will become explicit HTTP protocol tuning
policy before the first release.

=head1 SEE ALSO

L<Linux::Event::Net::HTTP::Request>, L<Linux::Event::Net::HTTP::Response>,
L<Linux::Event::IO::Sock::Stream>, L<Linux::Event::IO::Sock::Listener>.

=cut
