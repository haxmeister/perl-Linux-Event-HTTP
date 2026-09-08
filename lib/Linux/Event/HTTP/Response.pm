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

# Transitional API retained while the body/stream_body design is evaluated.
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

Linux::Event::HTTP::Response - HTTP response message

=head1 SYNOPSIS

    sub on_request ($conn, $req, $res) {
        $res->status(200);
        $res->header('Content-Type', 'text/plain');
        $res->body("hello\n");
    }

Streaming bodies are selected explicitly:

    $res->stream_body(
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    );

    $res->stream_body->write($bytes);
    $res->stream_body->complete;

=head1 DESCRIPTION

Every successfully dispatched HTTP request receives one Response object created
and bound by L<Linux::Event::HTTP::Server::Connection>. The Response describes
one HTTP response message, not the underlying socket or a writable handle.

C<body> supplies a complete scalar body. C<stream_body> selects a body whose
bytes are produced over time. The streaming body object owns C<write> and
C<complete>; the Response owns status, headers, and body selection.

=head1 METHODS

=head2 status, reason, header, add_header, header_values

Configure or inspect response metadata before output starts.

=head2 body

    $res->body("hello\n");
    my $bytes = $res->body;

Selects a complete scalar byte body. Once the enclosing HTTP callback returns,
the connection can serialize the response. If C<body> is called later from an
asynchronous callback, the response is serialized immediately. A scalar body
and a streaming body are mutually exclusive.

=head2 stream_body

    $res->stream_body(
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    );

Creates the response's streaming body on first call and returns it. Later
argumentless calls return the same object. C<on_drain> runs after downstream
Linux::Event output pressure clears. C<on_cancel> runs if the HTTP consumer
disappears before the body is completed.

=head2 upgrade

Schedules a validated HTTP/1.1 protocol handoff.

=head2 connection, request, is_started, is_complete, is_upgrading

Expose the owning transaction and response lifecycle state.

=head1 TRANSITIONAL METHODS

C<write> and C<complete> remain temporarily while the C<body>/C<stream_body>
API is evaluated on this feature branch. New application code should use
C<body> for scalar responses or the object returned by C<stream_body> for
streaming output.

=cut
