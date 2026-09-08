package Linux::Event::HTTP::Body::Stream;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(weaken);

our $VERSION = '0.001';

sub _new ($class, $response, %option) {
    my $on_drain  = delete $option{on_drain};
    my $on_cancel = delete $option{on_cancel};

    die 'stream_body(): on_drain must be a coderef'
        if defined($on_drain) && ref($on_drain) ne 'CODE';
    die 'stream_body(): on_cancel must be a coderef'
        if defined($on_cancel) && ref($on_cancel) ne 'CODE';
    die 'stream_body(): unknown option: ' . join(', ', sort keys %option)
        if %option;

    my $self = bless {
        response     => $response,
        on_drain     => $on_drain,
        on_cancel    => $on_cancel,
        complete     => 0,
        cancelled    => 0,
        flow_blocked => 0,
    }, $class;
    weaken($self->{response});
    return $self;
}

sub is_complete  ($self) { !!$self->{complete} }
sub is_cancelled ($self) { !!$self->{cancelled} }

sub _assert_writable ($self, $operation) {
    die "$operation(): streaming body is already complete"
        if $self->{complete};
    die "$operation(): streaming body was cancelled"
        if $self->{cancelled};
    my $response = $self->{response}
        or die "$operation(): response is no longer available";
    return $response;
}

sub write ($self, $bytes) {
    my $response = $self->_assert_writable('write');
    my $accepted = $response->_stream_write($bytes);
    $self->{flow_blocked} = 1 if !$accepted;
    return $accepted;
}

sub complete ($self, $bytes = '') {
    my $response = $self->_assert_writable('complete');
    $response->_stream_complete($bytes);
    $self->{complete} = 1;
    $self->{flow_blocked} = 0;
    return $self;
}

sub _drain ($self) {
    return if $self->{complete} || $self->{cancelled};
    return if !$self->{flow_blocked};
    $self->{flow_blocked} = 0;
    my $callback = $self->{on_drain} or return;
    $callback->($self);
    return;
}

sub _cancel ($self) {
    return if $self->{complete} || $self->{cancelled};
    $self->{cancelled} = 1;
    $self->{flow_blocked} = 0;
    my $callback = $self->{on_cancel} or return;
    $callback->($self);
    return;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Body::Stream - writable producer for a streaming HTTP body

=head1 DESCRIPTION

Applications normally obtain this object from C<< $res->stream_body(...) >>.
They do not construct it directly. Creating the object does not commit the
Response; the first C<write> or C<complete> starts response output.

C<write> supplies more body bytes and preserves Linux::Event's cooperative
backpressure return value. False means the bytes were accepted but the producer
should stop until C<on_drain> runs. C<complete> supplies optional final bytes and
announces that no more body bytes will be produced.

C<on_cancel> reports that the HTTP consumer disappeared before completion so an
upstream producer can stop work.

=cut
