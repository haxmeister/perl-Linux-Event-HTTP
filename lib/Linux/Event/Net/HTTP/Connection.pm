package Linux::Event::Net::HTTP::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';

use Carp qw(croak);
use Scalar::Util qw(blessed);
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

        $self->{_http_active_request} = $request;
        $self->{_http_dispatching} = 1;

        my $handled = eval {
            $self->{_http_on_request}->($self, $request);
            1;
        };
        my $failure = $@;
        $self->{_http_dispatching} = 0;

        if (!$handled) {
            if ($self->{_http_active_request}) {
                $self->_protocol_error(500, $request->http_version);
            } elsif (!$self->{_http_closing} && !$self->is_closed) {
                $self->pause_read;
                $self->end;
                $self->{_http_closing} = 1;
            }
            last;
        }

        if ($self->{_http_active_request}) {
            # A callback may intentionally respond later (for example from a
            # timer or another event). Stop accepting more request bytes until
            # respond() completes this request.
            $self->pause_read if !$self->is_read_paused;
            last;
        }
    }

    return;
}

sub respond ($self, $response, $body = '') {
    croak 'respond(): connection is closing or closed'
        if $self->{_http_closing} || $self->is_closed;
    croak 'respond(): no HTTP request is awaiting a response'
        if !$self->{_http_active_request};
    croak 'respond(): response must be a Linux::Event::Net::HTTP::Response'
        if !blessed($response)
        || !$response->isa('Linux::Event::Net::HTTP::Response');
    croak 'respond(): body must be a scalar byte string'
        if ref($body);

    my $body_bytes = defined($body) ? "$body" : '';
    if (utf8::is_utf8($body_bytes)) {
        croak 'respond(): body contains wide characters; encode it to bytes first'
            if !utf8::downgrade($body_bytes, 1);
    }

    my $request = $self->{_http_active_request};
    my $version = $request->http_version;
    my $method = $request->method;
    my $status = $response->status;

    croak 'respond(): informational responses require a future interim-response API'
        if $status >= 100 && $status < 200;

    my $body_forbidden = $status == 204 || $status == 304;
    croak 'respond(): this response status cannot carry a message body'
        if $body_forbidden && length($body_bytes);

    my @transfer_encoding = $response->header_values('Transfer-Encoding');
    croak 'respond(): Transfer-Encoding response bodies are not implemented yet'
        if @transfer_encoding;

    my @content_length = $response->header_values('Content-Length');
    my $head_request = $method eq 'HEAD';

    if (!@content_length && !$body_forbidden) {
        $response->header('Content-Length', length($body_bytes));
        @content_length = $response->header_values('Content-Length');
    }

    if (!$head_request && !$body_forbidden && @content_length == 1) {
        my $declared = $content_length[0];
        if ($declared =~ /\A\d+\z/) {
            $declared =~ s/\A0+(?=\d)//;
            my $actual = '' . length($body_bytes);
            croak 'respond(): Content-Length does not match scalar body length'
                if $declared ne $actual;
        }
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
    my $wire_body = ($head_request || $body_forbidden) ? '' : $body_bytes;
    my $wire = $head . $wire_body;

    $self->{_http_active_request} = undef;

    if ($close_after) {
        $self->{_http_closing} = 1;
        $self->{_http_input} = '';
        $self->pause_read if !$self->is_read_paused;
        $self->end($wire);
        return $self;
    }

    $self->write($wire);
    $self->resume_read if $self->is_read_paused;
    $self->_drive_http1 if !$self->{_http_dispatching};
    return $self;
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

    my $response = Linux::Event::Net::HTTP::Response->new(
        status => $status,
        headers => [
            [ 'Content-Length', '0' ],
            [ 'Connection', 'close' ],
        ],
    );

    my $head = $response->_serialize_head($version);
    $self->{_http_active_request} = undef;
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
    use Linux::Event::Net::HTTP::Response;

    sub on_request ($self, $request) {
        my $body = "hello\n";
        my $response = Linux::Event::Net::HTTP::Response->new(
            status => 200,
            headers => [
                [ 'Content-Type', 'text/plain' ],
            ],
        );
        $self->respond($response, $body);
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

=head1 CURRENT BODY SUPPORT

This first connection milestone dispatches requests with no message body or an
explicit C<Content-Length: 0>. A positive Content-Length or chunked request is
answered with 501 and the connection is closed. This is deliberate: request
body streaming is the next protocol state rather than an implicit whole-body
buffer.

Scalar response bodies are supported by C<respond>. Chunked/streaming response
bodies are not yet accepted. C<respond> adds Content-Length when necessary and
uses Linux::Event's normal ordered write queue and backpressure behavior.

=head1 CALLBACKS

=head2 on_request

    sub on_request ($connection, $request) {
        ...
    }

Receives one validated L<Linux::Event::Net::HTTP::Request>. The callback may
call C<respond> immediately or later. If it returns without responding,
Connection pauses application reads until C<respond> completes that request,
which prevents later pipelined requests from overtaking it.

A direct/adopted connection may instead use a constructor callback:

    my $connection = Linux::Event::Net::HTTP::Connection->new(
        fh => $connected_socket,
        on_request => sub ($connection, $request) {
            ...
        },
    );

=head1 METHODS

=head2 respond

    $connection->respond($response, $bytes);

Serializes the HTTP/1 response head and queues the scalar byte body in order.
When neither Content-Length nor Transfer-Encoding is present, Content-Length is
added from the scalar body length. A supplied Content-Length must agree with a
normal scalar response body.

HEAD responses suppress the supplied body bytes while retaining their length
for automatic Content-Length. Status 204 and 304 responses reject supplied body
bytes. Informational responses and Transfer-Encoding require later protocol
APIs and are rejected by this method for now.

If the request or response requires connection close, C<respond> uses
L<Linux::Event::IO::Sock::Stream/end> so queued output drains before the write
side is ended. Otherwise the next buffered request can be dispatched in order.

=head1 LIMITS

The current connection request-head limit is 65,536 bytes and the parser header
count limit is 100 fields. These will become explicit HTTP protocol tuning
policy before the first release.

=head1 SEE ALSO

L<Linux::Event::Net::HTTP::Request>, L<Linux::Event::Net::HTTP::Response>,
L<Linux::Event::IO::Sock::Stream>, L<Linux::Event::IO::Sock::Listener>.

=cut
