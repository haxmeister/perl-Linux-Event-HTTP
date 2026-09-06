package Linux::Event::Net::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(weaken);

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

our $VERSION = '0.001';

sub _new ($class, %args) {
    my $status  = delete($args{status}) // 200;
    my $reason  = delete $args{reason};
    my $headers = delete $args{headers};

    die 'unknown response option: ' . join(', ', sort keys %args)
        if %args;

    _validate_status($status);
    _validate_reason($reason) if defined $reason;

    my $self = bless {
        status     => 0 + $status,
        reason     => $reason,
        headers    => [],
        connection => undef,
        request    => undef,
        started    => 0,
        ended      => 0,
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
    my $self = $class->_new;
    $self->{connection} = $connection;
    weaken($self->{connection});
    $self->{request} = $request;
    return $self;
}

sub connection ($self) { $self->{connection} }
sub request    ($self) { $self->{request} }
sub is_started ($self) { !!$self->{started} }
sub is_ended   ($self) { !!$self->{ended} }

sub _assert_mutable ($self) {
    die 'response metadata cannot change after output has started'
        if $self->{started};
    die 'response has already ended' if $self->{ended};
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
    die 'write(): response has already ended' if $self->{ended};
    my $connection = $self->{connection}
        or die 'write(): response is not bound to an active HTTP connection';
    return $connection->_write_response($self, $bytes, 0);
}

sub end ($self, $bytes = '') {
    die 'end(): response has already ended' if $self->{ended};
    my $connection = $self->{connection}
        or die 'end(): response is not bound to an active HTTP connection';
    $connection->_write_response($self, $bytes, 1);
    return $self;
}

sub _mark_started ($self) {
    $self->{started} = 1;
    return;
}

sub _mark_ended ($self) {
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

Linux::Event::Net::HTTP::Response - response half of an HTTP transaction

=head1 SYNOPSIS

    sub on_request ($connection, $request, $response) {
        $response->status(200);
        $response->header('Content-Type', 'text/plain');
        $response->end("hello\n");
    }

=head1 DESCRIPTION

Every successfully dispatched HTTP request receives one Response object created
and bound by L<Linux::Event::Net::HTTP::Connection>. Applications do not
construct Response objects and do not pass them back to Connection.

Response owns application-facing response construction. Status and headers may
be configured until output begins. C<end> completes a normal scalar response.
C<write> begins a fixed-length streaming response when Content-Length has been
set explicitly.

The HTTP/1 response head is serialized in XS. Header names and values are
validated before they can be emitted, including rejection of CR/LF/NUL control
characters that could otherwise permit response splitting.

=head1 TRANSACTION RELATIONSHIP

C<connection> returns the owning HTTP Connection while it is alive. C<request>
returns the Request paired with this response. The connection reference is weak
so retaining a completed Response does not retain the socket.

=head1 METHODS

=head2 status

    my $status = $response->status;
    $response->status(404);

Gets or sets the three-digit status code. It defaults to 200.

=head2 reason

    my $reason = $response->reason;
    $response->reason('Not Here');

Gets or sets the optional reason phrase. Passing undef restores the serializer's
default phrase for the status code.

=head2 header

    $response->header('Content-Type', 'text/plain');
    my $type = $response->header('Content-Type');

With a value, replaces all existing fields of the same ASCII
case-insensitive name with one field. Without a value, returns the first
matching value or undef.

=head2 add_header

    $response->add_header('Set-Cookie', 'a=1');
    $response->add_header('Set-Cookie', 'b=2');

Appends another field without removing existing fields of the same name.

=head2 header_values

    my @cookies = $response->header_values('Set-Cookie');

Returns all matching values in output order.

=head2 write

    $response->header('Content-Length', 12);
    my $accepted = $response->write("hello ");
    $response->end("world\n");

Begins or continues a fixed-length response body. Until chunked response
streaming is implemented, Content-Length must be set before the first C<write>.
The return value mirrors Linux::Event Stream write backpressure: false means the
bytes were accepted but the configured high watermark has been reached.

Status and headers become immutable when the first bytes are committed.

=head2 end

    $response->end("hello\n");

Completes the response. When C<end> is the first body operation,
Content-Length is added automatically from the supplied byte-string length.
For a response already started with C<write>, the total emitted byte count must
match the declared Content-Length.

HEAD and body-forbidden status handling is enforced by the connection protocol
layer. If HTTP persistence requires close, C<end> drains queued output before
ending the transport write side.

=head2 connection

Returns the owning L<Linux::Event::Net::HTTP::Connection> while it remains
alive.

=head2 request

Returns the L<Linux::Event::Net::HTTP::Request> paired with this response.

=head2 is_started

True after the response head has been committed.

=head2 is_ended

True after C<end> completes the HTTP transaction.

=head1 INTERNAL SERIALIZATION

The private C<_serialize_head> method serializes the HTTP/1 status line and
field section. It is used by the connection protocol layer and is not the
application response-writing API.

The serializer rejects invalid field names and control characters, multiple
C<Content-Length> fields, and a response containing both C<Content-Length> and
C<Transfer-Encoding>.

=cut
