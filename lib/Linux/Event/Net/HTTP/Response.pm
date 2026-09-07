package Linux::Event::Net::HTTP::Response;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(refaddr weaken);

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();
use Linux::Event::Net::HTTP::_Upgrade ();

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
sub is_ended     ($self) { !!$self->{ended} }
sub is_upgrading ($self) { !!$self->{upgrade_pending} }

sub _assert_mutable ($self) {
    die 'response metadata cannot change after Upgrade handoff is requested'
        if $self->{upgrade_pending};
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
    die 'write(): response has already ended' if $self->{ended};
    my $connection = $self->{connection}
        or die 'write(): response is not bound to an active HTTP connection';
    return $connection->_write_response($self, $bytes, 0);
}

sub end ($self, $bytes = '') {
    die 'end(): response has an Upgrade handoff pending'
        if $self->{upgrade_pending};
    die 'end(): response has already ended' if $self->{ended};
    my $connection = $self->{connection}
        or die 'end(): response is not bound to an active HTTP connection';

    $connection->_write_response($self, $bytes, 1);
    return $self;
}

sub upgrade ($self, $target_class) {
    Linux::Event::Net::HTTP::_Upgrade->schedule($self, $target_class);
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

Linux::Event::Net::HTTP::Response - private transitional HTTP response implementation

=head1 DESCRIPTION

This Net-prefixed package is retained temporarily while the implementation is
migrated to L<Linux::Event::HTTP>. New application code should use
L<Linux::Event::HTTP::Response>.

Each dispatched request receives one Response object created and bound by the
HTTP Connection. Applications configure status and headers, use C<write> for
streaming output, and use C<end> to complete the response.

All complete responses now use the same ordinary response state machine. The
previous native default-response shortcut has been removed from this path so
complete, streamed, and deferred output share one behavior model.

=head1 METHODS

The implementation provides C<status>, C<reason>, C<header>, C<add_header>,
C<header_values>, C<write>, C<end>, C<upgrade>, C<connection>, C<request>,
C<is_started>, C<is_ended>, and C<is_upgrading>.

HTTP/1 framing, Content-Length validation, automatic chunked streaming,
connection persistence, HEAD behavior, and body-forbidden status handling are
owned by the Connection protocol state machine.

=head1 SEE ALSO

L<Linux::Event::HTTP::Response>, L<Linux::Event::HTTP::Connection>.

=cut
