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
        request       => $request,
        response      => undef,
        response_body => undef,
        state         => 'pending',
        error         => undef,
        controller    => $controller,
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

sub response_body ($self, @args) {
    die 'response_body(): Transaction is already terminal'
        if $self->is_terminal;
    my $response = $self->{response}
        or die 'response_body(): Transaction has no Response yet';

    if (my $body = $self->{response_body}) {
        die 'response_body options may only be supplied when the producer is created'
            if @args;
        return $body;
    }

    die 'response_body options must be key/value pairs' if @args % 2;

    require Linux::Event::HTTP::Body::Stream;
    my $body = Linux::Event::HTTP::Body::Stream->_new(
        $self, 'response', @args,
    );

    $response->_begin_stream_body;
    $self->{response_body} = $body;
    return $body;
}

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

sub _write_body ($self, $kind, $bytes, $final, $operation) {
    die "$operation(): Transaction is already terminal"
        if $self->is_terminal;
    die "$operation(): unsupported HTTP body producer '$kind'"
        if $kind ne 'response';

    my $response = $self->{response}
        or die "$operation(): Transaction has no Response";
    my $controller = $self->{controller}
        or die "$operation(): Transaction has no active controller";

    if ($final) {
        $response->_mark_complete;
    }

    my ($accepted, $ok, $error);
    {
        local $@;
        $ok = eval {
            $accepted = $controller->_write_http_response_body(
                $self, $bytes, $final, $operation,
            );
            1;
        };
        $error = $@;
    }

    if (!$ok) {
        $response->_mark_incomplete if $final;
        die $error;
    }

    return $accepted;
}

sub _response_body_object ($self) {
    return $self->{response_body};
}

sub _cancel_body_producers ($self) {
    if (my $body = $self->{response_body}) {
        $body->_cancel;
    }
    return;
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

    $self->_cancel_body_producers;
    $self->{state} = 'cancelled';
    delete $self->{controller};
    return $self;
}

sub _fail ($self, $error) {
    die 'cannot fail a terminal Transaction' if $self->is_terminal;
    die 'Transaction error must be defined' if !defined $error;

    $self->_cancel_body_producers;
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
that connects them, including writable body producers for outgoing messages. It
does not own a socket, parser, connection pool, redirect chain, or transport
output queue. Client and server connection implementations advance Transaction
state and move produced bytes through their transport.

Redirects are separate HTTP exchanges and therefore use separate Transaction
objects.

Applications normally receive Transactions from a Client or an active server
Connection; they do not construct them directly.

=head1 METHODS

=head2 request

Returns the Request for this exchange. It is available for the entire
Transaction lifetime.

=head2 response

Returns the Response after the response head has been received or created, or
undef before a Response exists.

=head2 response_body

Returns the writable producer for an outgoing streaming Response body. On a
server, the active transaction can be obtained from the connection:

    my $body = $conn->transaction->response_body(
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    );

    $body->write($bytes);
    $body->complete;

Creating the producer marks the Response body as incremental rather than a
complete scalar body. The Request/Response message objects themselves do not
own transport writers.

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
