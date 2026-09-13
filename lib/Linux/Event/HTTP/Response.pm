package Linux::Event::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(refaddr);
use utf8 ();

use Linux::Event::HTTP::_HTTP1 ();

our $VERSION = '0.001';

my $EMPTY_HEADERS = [];

sub new ($class, %args) {
    my $status  = delete($args{status}) // 200;
    my $reason  = delete $args{reason};
    my $version = delete($args{version}) // '1.1';
    my $headers = delete $args{headers};
    my $has_body = exists $args{body};
    my $body = delete $args{body};

    die 'unknown response option: ' . join(', ', sort keys %args)
        if %args;

    _validate_status($status);
    _validate_reason($reason) if defined $reason;
    _validate_version($version);

    my $self = bless {
        status    => 0 + $status,
        reason    => $reason,
        version   => "$version",
        headers   => $EMPTY_HEADERS,
        committed => 0,
        complete  => 0,
        body_kind => undef,
        body      => undef,
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

    $self->body($body) if $has_body;
    return $self;
}

sub _new ($class, %args) {
    return $class->new(%args);
}

sub is_complete ($self) { !!$self->{complete} }

sub _assert_mutable ($self) {
    die 'response metadata cannot change after message commit'
        if $self->{committed};
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

sub version ($self, @args) {
    return $self->{version} if !@args;

    die 'version accepts exactly one value' if @args != 1;
    $self->_assert_mutable;
    _validate_version($args[0]);
    $self->{version} = "$args[0]";
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

sub remove_header ($self, $name) {
    $self->_assert_mutable;
    _validate_name($name);
    my $wanted = lc $name;
    my @kept = grep { lc($_->[0]) ne $wanted } @{$self->{headers}};
    $self->{headers} = \@kept;
    return $self;
}

sub header_values ($self, $name) {
    _validate_name($name);
    my $wanted = lc $name;
    return map { $_->[1] }
        grep { lc($_->[0]) eq $wanted }
        @{$self->{headers}};
}

sub header_count ($self) {
    return scalar @{$self->{headers}};
}

sub header_name ($self, $index) {
    die 'header index out of range'
        if !defined($index) || $index !~ /\A[0-9]+\z/ || $index >= @{$self->{headers}};
    return $self->{headers}[$index][0];
}

sub header_value ($self, $index) {
    die 'header index out of range'
        if !defined($index) || $index !~ /\A[0-9]+\z/ || $index >= @{$self->{headers}};
    return $self->{headers}[$index][1];
}

sub content_length ($self) {
    my @values = $self->header_values('Content-Length');
    return undef if !@values;
    die 'response must not contain multiple Content-Length fields' if @values != 1;
    die 'response Content-Length must be a decimal number'
        if $values[0] !~ /\A[0-9]+\z/;
    return 0 + $values[0];
}

sub _body_bytes ($operation, $body) {
    die "$operation(): body must be a scalar byte string" if ref($body);

    my $bytes = defined($body) ? "$body" : '';
    if (utf8::is_utf8($bytes)) {
        die "$operation(): body contains wide characters; encode it to bytes first"
            if !utf8::downgrade($bytes, 1);
    }
    return $bytes;
}

sub body ($self, @args) {
    return $self->{body} if !@args;

    die 'body accepts exactly one value' if @args != 1;
    $self->_assert_mutable;
    die 'body(): response already has an incremental body producer'
        if ($self->{body_kind} // '') eq 'stream';

    $self->{body_kind} = 'scalar';
    $self->{body} = _body_bytes('body', $args[0]);
    $self->{complete} = 1;
    return $self;
}

sub _set_received_body ($self, $body) {
    die 'received response body can only be attached after message commit'
        if !$self->{committed};
    die 'received response body has already been attached'
        if defined $self->{body_kind};

    $self->{body_kind} = 'scalar';
    $self->{body} = _body_bytes('received body', $body);
    return $self;
}

sub _begin_stream_body ($self) {
    $self->_assert_mutable;
    die 'response_body(): Response already has a complete scalar body'
        if ($self->{body_kind} // '') eq 'scalar';
    die 'response_body(): Response already has an incremental body producer'
        if ($self->{body_kind} // '') eq 'stream';

    $self->{body_kind} = 'stream';
    $self->{complete} = 0;
    return $self;
}

sub _has_scalar_body ($self) {
    return ($self->{body_kind} // '') eq 'scalar';
}

sub _has_incremental_body ($self) {
    return ($self->{body_kind} // '') eq 'stream';
}

sub _scalar_body ($self) {
    return $self->{body};
}

sub _commit ($self) {
    $self->{committed} = 1;
    return $self;
}

sub _is_committed ($self) {
    return !!$self->{committed};
}

sub _mark_complete ($self) {
    $self->{complete} = 1;
    return;
}

sub _mark_incomplete ($self) {
    $self->{complete} = 0;
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

sub _validate_version ($version) {
    die 'HTTP version is required' if !defined($version) || ref($version);
    die 'invalid HTTP version' if "$version" !~ /\A[0-9]+(?:\.[0-9]+)?\z/;
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

Linux::Event::HTTP::Response - HTTP response message

=head1 SYNOPSIS

    my $response = Linux::Event::HTTP::Response->new(
        status => 200,
        headers => [
            [ 'Content-Type', 'text/plain' ],
        ],
        body => "hello\n",
    );

Server callbacks receive the same Response class:

    sub on_request ($conn, $req, $res) {
        $res->status(200);
        $res->header('Content-Type', 'text/plain');
        $res->body("hello\n");
    }

=head1 DESCRIPTION

C<Linux::Event::HTTP::Response> represents one HTTP response message. It is not
a socket, transaction, connection, or writable transport handle. The same
message class is used for locally constructed outgoing responses and parsed
incoming client responses.

A Response owns status, reason, version, headers, complete scalar-body data, and
message completion state. It does not retain its peer Request or the Connection
that happens to carry it. Exchange lifecycle, output progress, cancellation,
Upgrade, and incremental body production belong to
L<Linux::Event::HTTP::Transaction> and the protocol Connection.

Selecting a complete scalar C<body> on a locally constructed Response makes the
message body complete immediately. That does not mean the message has been
written to a transport. Incremental body production is selected through the
owning Transaction; the Response records only that its body is incomplete until
the producer announces its final bytes.

A received client Response normally exposes body bytes incrementally through the
Client callback path. If the caller explicitly requests bounded whole-body
buffering, C<body> returns that completed scalar after the message boundary is
reached. Received response metadata remains committed and read-only either way.

=head1 METHODS

=head2 new

Constructs a mutable response message. C<status> defaults to 200 and C<version>
defaults to C<1.1>. C<headers> is an optional array reference of C<[name,
value]> pairs. C<body> is an optional complete scalar byte body.

=head2 status

Gets or sets the response status code before message commit.

=head2 reason

Gets or sets the optional HTTP/1 reason phrase before message commit.

=head2 version

Gets or sets the HTTP version before message commit.

=head2 header

Gets the first matching field value. The setter form replaces all fields of the
same ASCII case-insensitive name.

=head2 add_header

Adds another header field while preserving existing same-name fields.

=head2 remove_header

Removes all fields with the supplied ASCII case-insensitive name.

=head2 header_values

Returns all matching values in message order.

=head2 header_count, header_name, header_value

Provide exact indexed access to fields in message order while preserving the
original field names.

=head2 content_length

Returns the declared Content-Length as an integer, or undef when absent.

=head2 body

Gets or sets the complete scalar byte body. Setting it is available only while a
locally constructed Response is mutable and declares that its message body is
complete. Incremental output is selected through the owning Transaction rather
than through the Response message.

For a received client Response, the getter returns the complete body only when
the client was explicitly asked to buffer it within a bounded limit. Otherwise
received body bytes remain incremental and C<body> returns undef.

=head2 is_complete

Returns whether the complete HTTP message body is known or its final boundary
has been reached. This is deliberately independent of whether an outgoing
message has started or finished writing to a transport.

=head1 SEE ALSO

L<Linux::Event::HTTP::Request>, L<Linux::Event::HTTP::Transaction>.

=cut
