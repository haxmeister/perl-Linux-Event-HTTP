package Linux::Event::HTTP::Transaction;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(blessed weaken);

our $VERSION = '0.001';

my %TERMINAL = map { $_ => 1 } qw(complete cancelled error);

sub _new ($class, %args) {
    my $request    = delete $args{request};
    my $controller = delete $args{controller};

    die 'Transaction requires a Linux::Event::HTTP::Request'
        if !blessed($request)
        || !$request->isa('Linux::Event::HTTP::Request');
    die 'Transaction controller must be an object'
        if defined($controller) && !blessed($controller);
    die 'unknown Transaction option: ' . join(', ', sort keys %args)
        if %args;

    my $self = bless {
        request    => $request,
        response   => undef,
        state      => 'pending',
        error      => undef,
        controller => $controller,
    }, $class;
    weaken($self->{controller}) if defined $self->{controller};
    return $self;
}

sub request      ($self) { $self->{request} }
sub response     ($self) { $self->{response} }
sub state        ($self) { $self->{state} }
sub error        ($self) { $self->{error} }
sub is_complete  ($self) { $self->{state} eq 'complete' }
sub is_cancelled ($self) { $self->{state} eq 'cancelled' }
sub is_terminal  ($self) { !!$TERMINAL{$self->{state}} }

sub cancel ($self) {
    return $self if $self->is_terminal;

    if (my $controller = $self->{controller}) {
        $controller->_cancel_http_transaction($self);
    }

    return $self if $self->is_terminal;
    return $self->_mark_cancelled;
}

sub _set_controller ($self, $controller) {
    die 'cannot change controller of a terminal Transaction'
        if $self->is_terminal;
    die 'Transaction controller must be an object'
        if defined($controller) && !blessed($controller);

    $self->{controller} = $controller;
    weaken($self->{controller}) if defined $self->{controller};
    return $self;
}

sub _activate ($self) {
    die 'cannot activate a terminal Transaction' if $self->is_terminal;
    $self->{state} = 'active';
    return $self;
}

sub _set_response ($self, $response) {
    die 'cannot attach a Response to a terminal Transaction'
        if $self->is_terminal;
    die 'Transaction already has a Response' if $self->{response};
    die 'Transaction response must be a Linux::Event::HTTP::Response'
        if !blessed($response)
        || !$response->isa('Linux::Event::HTTP::Response');

    $self->{response} = $response;
    $self->{state} = 'active' if $self->{state} eq 'pending';
    return $response;
}

sub _mark_complete ($self) {
    die 'cannot complete a terminal Transaction' if $self->is_terminal;
    die 'cannot complete a Transaction before it has a Response'
        if !$self->{response};

    $self->{state} = 'complete';
    delete $self->{controller};
    return $self;
}

sub _mark_cancelled ($self) {
    return $self if $self->{state} eq 'cancelled';
    die 'cannot cancel a terminal Transaction' if $self->is_terminal;

    $self->{state} = 'cancelled';
    delete $self->{controller};
    return $self;
}

sub _fail ($self, $error) {
    die 'cannot fail a terminal Transaction' if $self->is_terminal;
    die 'Transaction error must be defined' if !defined $error;

    $self->{error} = $error;
    $self->{state} = 'error';
    delete $self->{controller};
    return $self;
}

sub CLONE_SKIP { 1 }

1;

__END__

=head1 NAME

Linux::Event::HTTP::Transaction - lifecycle of one HTTP request/response exchange

=head1 DESCRIPTION

A Transaction represents exactly one HTTP exchange: one
L<Linux::Event::HTTP::Request> and, once available, one
L<Linux::Event::HTTP::Response>.

Request and Response are HTTP message objects. Transaction owns the lifecycle
that connects them. It does not own a socket, parser, connection pool, redirect
chain, or transport output queue. Client and server connection implementations
advance Transaction state as protocol work proceeds.

Redirects are separate HTTP exchanges and therefore use separate Transaction
objects.

Applications normally receive Transactions from L<Linux::Event::HTTP::Client>;
they do not construct them directly.

=head1 METHODS

=head2 request

Returns the Request for this exchange. It is available for the entire
Transaction lifetime.

=head2 response

Returns the Response after the response head has been received or created, or
undef before a Response exists.

=head2 state

Returns the coarse application-visible lifecycle state. The common states are
C<pending>, C<active>, C<complete>, C<cancelled>, and C<error>. Connection
implementations may track finer protocol phases privately without exposing
parser or transport internals here.

=head2 cancel

Requests cancellation of this exchange. Cancellation is idempotent from the
application's perspective. The current Client or Connection controller is
responsible for the protocol action needed to abandon the exchange safely.

=head2 is_complete

True only after the exchange completes successfully.

=head2 is_cancelled

True after the exchange has been cancelled.

=head2 is_terminal

True for successful completion, cancellation, or error.

=head2 error

Returns the terminal error value after failure, or undef otherwise.

=cut
