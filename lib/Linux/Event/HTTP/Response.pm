package Linux::Event::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(refaddr weaken);
use utf8 ();

use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::_Upgrade ();

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
        status          => 0 + $status,
        reason          => $reason,
        version         => "$version",
        headers         => [],
        connection      => undef,
        request         => undef,
        started         => 0,
        ended           => 0,
        upgrade_pending => 0,
        body_kind       => undef,
        body            => undef,
        stream_body     => undef,
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

sub _new_bound ($class, $connection, $request) {
    my $self = bless {
        status          => 200,
        reason          => undef,
        version         => $request->version,
        headers         => $EMPTY_HEADERS,
        connection      => $connection,
        request         => $request,
        started         => 0,
        ended           => 0,
        upgrade_pending => 0,
        body_kind       => undef,
        body            => undef,
        stream_body     => undef,
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
    die 'body(): response already has a streaming body'
        if ($self->{body_kind} // '') eq 'stream';

    $self->{body_kind} = 'scalar';
    $self->{body} = _body_bytes('body', $args[0]);

    if (my $connection = $self->{connection}) {
        $connection->_response_body_ready($self);
    }

    return $self;
}

sub stream_body ($self, @args) {
    if ($self->{stream_body}) {
        die 'stream_body options may only be supplied when the stream is created'
            if @args;
        return $self->{stream_body};
    }

    $self->_assert_mutable;
    die 'stream_body(): response already has a scalar body'
        if ($self->{body_kind} // '') eq 'scalar';
    die 'stream_body options must be key/value pairs' if @args % 2;

    require Linux::Event::HTTP::Body::Stream;
    my $body = Linux::Event::HTTP::Body::Stream->_new($self, @args);
    $self->{body_kind} = 'stream';
    $self->{stream_body} = $body;
    return $body;
}

sub _has_scalar_body ($self) {
    return ($self->{body_kind} // '') eq 'scalar';
}

sub _scalar_body ($self) {
    return $self->{body};
}

sub _stream_write ($self, $bytes) {
    die 'stream body write rejected: response has an Upgrade handoff pending'
        if $self->{upgrade_pending};
    die 'stream body write rejected: response is already complete'
        if $self->{ended};
    my $connection = $self->{connection}
        or die 'stream body write rejected: response is not bound to an active HTTP connection';
    return $connection->_write_response($self, $bytes, 0, 'stream_body->write');
}

sub _stream_complete ($self, $bytes = '') {
    die 'stream body complete rejected: response has an Upgrade handoff pending'
        if $self->{upgrade_pending};
    die 'stream body complete rejected: response is already complete'
        if $self->{ended};
    my $connection = $self->{connection}
        or die 'stream body complete rejected: response is not bound to an active HTTP connection';
    $connection->_write_response($self, $bytes, 1, 'stream_body->complete');
    return $self;
}

sub _stream_body_object ($self) {
    return $self->{stream_body};
}

sub _cancel_stream_body ($self) {
    my $body = $self->{stream_body} or return;
    $body->_cancel;
    return;
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
    $connection->_complete_active_transaction_state;

    $connection->{_http_active_transaction} = undef;
    $connection->{_http_active_request} = undef;
    $connection->{_http_active_response} = undef;
    $connection->{_http_request_state} = undef;
    $connection->{_http_response_state} = undef;

    $connection->resume_read if $connection->is_read_paused;
    return 1;
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
a socket or connection object. The same message class is intended for both
locally constructed outgoing responses and parsed incoming responses.

The current server implementation still binds its outgoing Response to server
transaction machinery for scalar commit, streaming output, and Upgrade. Those
lifecycle responsibilities are being separated from the message API as the
shared Transaction layer is introduced.

=head1 METHODS

=head2 new

Constructs a mutable response message. C<status> defaults to 200 and C<version>
defaults to C<1.1>. C<headers> is an optional array reference of C<[name,
value]> pairs. C<body> is an optional complete scalar byte body.

=head2 status

Gets or sets the response status code before the message is committed.

=head2 reason

Gets or sets the optional HTTP/1 reason phrase before commit.

=head2 version

Gets or sets the HTTP version before commit.

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

Gets or sets the complete scalar byte body. Incremental body transfer is a
transaction/connection responsibility rather than a different kind of HTTP
message.

=head2 is_complete

Reports whether the protocol layer has completed this message. During the
server-to-Transaction migration this still follows the existing server response
lifecycle and becomes true after final output is committed.

=head2 stream_body

The existing server streaming producer remains available while streaming
ownership is moved to Transaction. It writes through Linux::Event's existing
ordered-byte transport and does not create a second HTTP output queue.

=head2 upgrade

The existing server Upgrade handoff remains available while lifecycle ownership
moves to Transaction.

=cut
