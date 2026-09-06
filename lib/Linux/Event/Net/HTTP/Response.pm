package Linux::Event::Net::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

our $VERSION = '0.001';

sub new ($class, %args) {
    my $status  = delete($args{status}) // 200;
    my $reason  = delete $args{reason};
    my $headers = delete $args{headers};

    die 'unknown response constructor option: ' . join(', ', sort keys %args)
        if %args;

    _validate_status($status);
    _validate_reason($reason) if defined $reason;

    my $self = bless {
        status  => 0 + $status,
        reason  => $reason,
        headers => [],
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

sub status ($self, @args) {
    return $self->{status} if !@args;

    die 'status accepts exactly one value' if @args != 1;
    _validate_status($args[0]);
    $self->{status} = 0 + $args[0];
    return $self;
}

sub reason ($self, @args) {
    return $self->{reason} if !@args;

    die 'reason accepts exactly one value' if @args != 1;
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
    _validate_value($args[0]);

    my @kept = grep { lc($_->[0]) ne lc($name) } @{$self->{headers}};
    push @kept, [ "$name", "$args[0]" ];
    $self->{headers} = \@kept;

    return $self;
}

sub add_header ($self, $name, $value) {
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

Linux::Event::Net::HTTP::Response - HTTP response representation

=head1 SYNOPSIS

    my $response = Linux::Event::Net::HTTP::Response->new(
        status => 200,
    );

    $response->header('Content-Type', 'text/plain');
    $response->add_header('Set-Cookie', 'a=1');
    $response->add_header('Set-Cookie', 'b=2');

=head1 DESCRIPTION

Response stores application-supplied response metadata while HTTP/1 wire
serialization is performed in XS. Header names and values are validated before
they can be emitted, including rejection of CR/LF/NUL control characters that
could otherwise permit response splitting.

Body streaming belongs to the HTTP protocol connection layer. The Response
object does not require a response body to be accumulated in memory.

=head1 METHODS

=head2 new

    my $response = Linux::Event::Net::HTTP::Response->new(
        status => 200,
        reason => 'OK',
        headers => [
            [ 'Content-Type', 'text/plain' ],
        ],
    );

C<status> defaults to 200. C<reason> is optional; the HTTP/1 serializer supplies
the conventional reason phrase for common status codes when it is omitted.

The optional C<headers> value is an array reference of C<[name, value]> pairs so
field order and repeated field names can be preserved.

=head2 status

    my $status = $response->status;
    $response->status(404);

Gets or sets the three-digit status code.

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

=head1 INTERNAL SERIALIZATION

The private C<_serialize_head> method serializes the HTTP/1 status line and
field section. It is used by the connection protocol layer and is not the
application response-writing API.

The serializer rejects invalid field names and control characters, multiple
C<Content-Length> fields, and a response containing both C<Content-Length> and
C<Transfer-Encoding>.

=cut
