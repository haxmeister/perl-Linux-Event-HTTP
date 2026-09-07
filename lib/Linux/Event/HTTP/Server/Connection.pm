package Linux::Event::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(refaddr weaken);

use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::_Upgrade ();

our $VERSION = '0.001';

my $EMPTY_HEADERS = [];

sub _new ($class, %args) {
    my $status  = delete($args{status}) // 200;
    my $reason  = delete $args{reason};
    my $headers = delete $args{headers};

    die 'unknown response option: ' . join(', ', sort keys %args)
        if %args;

    _validate_status($status);
    _validate_reason($reason) if defined $reason;

    my $self = bless {
        status          => 0 + $status,
        reason          => $reason,
        headers         => [],
        connection      => undef,
        request         => undef,
        started         => 0,
        ended           => 0,
        upgrade_pending => 0,
    }, $class;

    if (defined $headers) {
        die 'headers must be an array reference of [name, value] pairs'
            if ref($headers) ne 'ARRAY';

        for my $pair (@$headers) {
            die 'each response header must be a [name, value] pair'
                if ref($pair) ne 'ARRAY' || @$pair != 2;
            $self->add_header($pair->[0], $pair->[1]);
        }
    }

    return $self;
}

sub _new_bound ($class, $connection, $request) {
    my $self = bless {
        status          => 200,
        reason          => undef,
        headers         => $EMPTY_HEADERS,
        connection      => $connection,
        request         => $request,
        started         => 0,
        ended           => 0,
        upgrade_pending => 0,
    }, $class;
    weaken($self->{connection});
    return $self;
}

sub connection   ($self) { $self->{connection} }
sub request      ($self) { $self->{request} }
sub is_started   ($self) { !!$self->{started} }
sub is_complete  ($self) { !!$self->{ended} }
sub is_upgrading ($self) { !!$self->{upgrade_pending} }

sub _assert_mutable ($self) {
    die 'response metadata cannot change after Upgrade handoff is requested'
        if $self->{upgrade_pending};
    die 'response metadata cannot change after output has started'
        if $self->{started};
    die 'response is already complete' if $self->{ended};
    return;
}

sub status ($self, @args) {
    return $self->{status} if !@args;

    die 'status accepts exactly one value' if @args != 1;
    $self->_assert_mutable;
    _validate_status($args[0]);
    $self->{status} = 0 + $args[0];
    return $self;
}

sub reason ($self, @args) {
    return $self->{reason} if !@args;

    die 'reason accepts exactly one value' if @args != 1;
    $self->_assert_mutable;
    _validate_reason($args[0]) if defined $args[0];
    $self->{reason} = $args[0];
    return $self;
}

sub header ($self, $name, @args) {
    _validate_name($name);

    if (!@args) {
        for my $pair (@{$self->{headers}}) {
            return $pair->[1] if lc($pair->[0]) eq lc($name);
        }
        return undef;
    }

    die 'header setter accepts exactly one value' if @args != 1;
    $self->_assert_mutable;
    _validate_value($args[0]);

    my @kept = grep { lc($_->[0]) ne lc($name) } @{$self->{headers}};
    push @kept, [ "$name", "$args[0]" ];
    $self->{headers} = \@kept;

    return $self;
}

sub add_header ($self, $name, $value) {
    $self->_assert_mutable;
    _validate_name($name);
    _validate_value($value);
    $self->{headers} = []
        if refaddr($self->{headers}) == refaddr($EMPTY_HEADERS);
    push @{$self->{headers}}, [ "$name", "$value" ];
    return $self;
}

sub header_values ($self, $name) {
    _validate_name($name);
    my $wanted = lc $name;
    return map { $_->[1] }
        grep { lc($_->[0]) eq $wanted }
        @{$self->{headers}};
}

sub write ($self, $bytes) {
    die 'write(): response has an Upgrade handoff pending'
        if $self->{upgrade_pending};
    die 'write(): response is already complete' if $self->{ended};
    my $connection = $self->{connection}
        or die 'write(): response is not bound to an active HTTP connection';
    return $connection->_write_response($self, $bytes, 0);
}

sub _try_native_default_final ($self, $connection, $body) {
    return 0 if ref($self) ne __PACKAGE__;
    return 0 if $self->{status} != 200 || defined($self->{reason});
    return 0 if @{$self->{headers}};
    return 0 if $connection->{_http_closing} || $connection->is_closed;
    return 0 if $connection->{_http_response_state};

    my $active = $connection->{_http_active_response} or return 0;
    return 0 if refaddr($active) != refaddr($self);

    my $request = $connection->{_http_active_request} or return 0;
    return 0 if !defined($self->{request})
        || refaddr($request) != refaddr($self->{request});

    my $request_state = $connection->{_http_request_state} or return 0;
    return 0 if !$request_state->{body_done};

    my $wire = Linux::Event::HTTP::_HTTP1
        ->build_default_final($request, $body);
    return 0 if !defined $wire;

    $self->{started} = 1;
    $self->{ended} = 1;
    $connection->{_http_response_state} = undef;

    $connection->write($wire);

    $connection->{_http_active_request} = undef;
    $connection->{_http_active_response} = undef;
    $connection->{_http_request_state} = undef;
    $connection->{_http_response_state} = undef;

    $connection->resume_read if $connection->is_read_paused;
    return 1;
}

sub complete ($self, $bytes = '') {
    die 'complete(): response has an Upgrade handoff pending'
        if $self->{upgrade_pending};
    die 'complete(): response is already complete' if $self->{ended};
    my $connection = $self->{connection}
        or die 'complete(): response is not bound to an active HTTP connection';

    return $self if $self->_try_native_default_final($connection, $bytes);

    $connection->_write_response($self, $bytes, 1);
    return $self;
}

sub upgrade ($self, $target_class) {
    Linux::Event::HTTP::_Upgrade->schedule($self, $target_class);
    return $self;
}

sub _mark_started ($self) {
    $self->{started} = 1;
    return;
}

sub _mark_complete ($self) {
    $self->{ended} = 1;
    return;
}

sub _validate_status ($status) {
    die 'response status must be an integer between 100 and 999'
        if !defined($status) || "$status" !~ /\A[0-9]{3}\z/
        || $status < 100 || $status > 999;
}

sub _validate_reason ($reason) {
    die 'response reason phrase contains invalid control characters'
        if $reason =~ /[\x00-\x08\x0a-\x1f\x7f]/;
}

sub _validate_name ($name) {
    die 'response header field name is required'
        if !defined($name) || $name eq '';

    die 'invalid response header field name'
        if $name !~ /\A[!#\$%&'*+\-.^_`|~0-9A-Za-z]+\z/;
}

sub _validate_value ($value) {
    die 'response header field value must be defined'
        if !defined $value;

    die 'response header field value contains invalid control characters'
        if $value =~ /[\x00-\x08\x0a-\x1f\x7f]/;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Response - response half of an HTTP transaction

=head1 SYNOPSIS

    sub on_request ($self, $req, $res) {
        $res->status(200);
        $res->header('Content-Type', 'text/plain');
        $res->complete("hello\n");
    }

=head1 DESCRIPTION

Every successfully dispatched HTTP request receives one Response object created
and bound by L<Linux::Event::HTTP::Server::Connection>. Applications do not
construct Response objects and do not pass them back to Connection.

A Response represents one HTTP response, not the underlying TCP or TLS
connection. C<complete> completes this HTTP response. It does not mean "close
the socket"; on a persistent HTTP connection the same socket normally remains
open for later requests.

Status and headers may be configured until output begins. C<write> streams body
bytes. C<complete> may supply final body bytes and marks the response half of
the transaction complete.

=head1 METHODS

=head2 status

    my $status = $res->status;
    $res->status(404);

Gets or sets the three-digit status code. It defaults to 200.

=head2 reason

    my $reason = $res->reason;
    $res->reason('Not Here');

Gets or sets the optional reason phrase. Passing undef restores the serializer's
default phrase for the status code.

=head2 header

    $res->header('Content-Type', 'text/plain');
    my $type = $res->header('Content-Type');

With a value, replaces all existing fields of the same ASCII
case-insensitive name with one field. Without a value, returns the first
matching value or undef.

=head2 add_header

    $res->add_header('Set-Cookie', 'a=1');
    $res->add_header('Set-Cookie', 'b=2');

Appends another field without removing existing fields of the same name.

=head2 header_values

    my @cookies = $res->header_values('Set-Cookie');

Returns all matching values in output order.

=head2 write

    my $accepted = $res->write("hello ");
    $res->write("world\n");
    $res->complete;

Begins or continues a streaming response body. The return value mirrors
Linux::Event Stream write backpressure: false means the bytes were accepted but
the configured high watermark has been reached.

For HTTP/1.1, if Content-Length was not set before the first C<write>, the
Connection automatically uses chunked transfer coding. C<complete> emits the
terminating chunk. If Content-Length was set explicitly, the total body length
must match it exactly.

HTTP/1.0 cannot use chunked transfer coding. Unknown-length streaming is
close-delimited, so completing that response also requires the HTTP connection
to close after queued output has drained.

=head2 complete

    $res->complete("hello\n");

Completes this HTTP response. Optional bytes are the final response-body bytes.
When C<complete> is the first body operation, Content-Length is added
automatically from the supplied byte-string length.

    $res->write($chunk);
    $res->write($chunk);
    $res->complete;

After streaming has started, C<complete> follows the framing mode selected by
the first C<write>. Completing a response normally does not close a persistent
HTTP connection. The connection closes only when HTTP framing or persistence
rules require it.

=head2 upgrade

    $res->header('Upgrade', 'websocket');
    $res->header('Sec-WebSocket-Accept', $accept);
    $res->upgrade('MyWebSocketConnection');

Completes an HTTP/1.1 protocol switch and hands the same live stream-socket
object to another L<Linux::Event::IO::Sock::Stream> subclass. The request and
response must satisfy HTTP Upgrade rules before the handoff is scheduled.

=head2 connection

Returns the owning L<Linux::Event::HTTP::Server::Connection> while it remains
alive.

=head2 request

Returns the L<Linux::Event::HTTP::Request> paired with this response.

=head2 is_started

True after the response head has been committed.

=head2 is_complete

True after C<complete> completes the response half of the HTTP transaction, or
after an Upgrade switching response is committed immediately before handoff.

=head2 is_upgrading

True after C<upgrade> has validated and scheduled a protocol handoff but before
the 101 response has been committed and the live stream has transitioned.

=head1 INTERNAL SERIALIZATION

The private C<_serialize_head> method serializes the HTTP/1 status line and
field section. It is used by the connection protocol layer and is not the
application response-writing API.

=cut
