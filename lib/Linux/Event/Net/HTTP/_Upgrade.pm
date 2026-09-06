package Linux::Event::Net::HTTP::_Upgrade;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(refaddr);

use Linux::Event::IO::Sock::Stream ();
use Linux::Event::Kernel::Timer;

our $VERSION = '0.001';

sub _load_target ($target) {
    croak 'upgrade(): target class must be a package name'
        if !defined($target) || ref($target)
        || $target !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    if (!$target->can('transition_to')) {
        (my $file = "$target.pm") =~ s{::}{/}g;
        require $file;
    }

    croak 'upgrade(): target class must inherit Linux::Event::IO::Sock::Stream'
        if !$target->isa('Linux::Event::IO::Sock::Stream');

    return $target;
}

sub _tokens ($where, @values) {
    my @token;
    for my $value (@values) {
        for my $member (split /,/, $value, -1) {
            $member =~ s/\A[ \t]+//;
            $member =~ s/[ \t]+\z//;
            croak "upgrade(): invalid $where field value"
                if $member eq ''
                || $member !~ /\A[!#\$%&'*+\-.^_`|~0-9A-Za-z]+(?:\/[!#\$%&'*+\-.^_`|~0-9A-Za-z]+)?\z/;
            push @token, lc $member;
        }
    }
    return @token;
}

sub _connection_has ($values, $wanted) {
    for my $value (@$values) {
        for my $member (split /,/, $value, -1) {
            $member =~ s/\A[ \t]+//;
            $member =~ s/[ \t]+\z//;
            return 1 if lc($member) eq $wanted;
        }
    }
    return 0;
}

sub schedule ($class, $response, $target) {
    my $conn = $response->connection
        or croak 'upgrade(): response is not bound to an active HTTP connection';
    croak 'upgrade(): response output has already started'
        if $response->is_started;
    croak 'upgrade(): response has already ended'
        if $response->is_ended;
    croak 'upgrade(): response already has an Upgrade handoff pending'
        if $response->{upgrade_pending};
    croak 'upgrade(): connection is closing or closed'
        if $conn->{_http_closing} || $conn->is_closed;

    my $active = $conn->{_http_active_response};
    croak 'upgrade(): this Response is not the active HTTP transaction'
        if !$active || refaddr($active) != refaddr($response);

    my $req = $conn->{_http_active_request}
        or croak 'upgrade(): active Request is missing';
    my $request_state = $conn->{_http_request_state}
        or croak 'upgrade(): request state is missing';

    croak 'upgrade(): HTTP Upgrade requires HTTP/1.1'
        if $req->http_version ne '1.1';
    croak 'upgrade(): request body must be empty before protocol handoff'
        if $req->body_mode eq 'chunked'
        || ($req->body_mode eq 'content-length'
            && ($req->content_length // '0') ne '0');

    my @request_connection = $req->header_values('Connection');
    croak 'upgrade(): request Connection field must contain Upgrade'
        if !_connection_has(\@request_connection, 'upgrade');
    croak 'upgrade(): request cannot combine Connection: close with Upgrade'
        if _connection_has(\@request_connection, 'close') || !$req->keep_alive;

    my @offered = _tokens('request Upgrade', $req->header_values('Upgrade'));
    croak 'upgrade(): request must contain an Upgrade field' if !@offered;

    my @selected = _tokens(
        'response Upgrade', $response->header_values('Upgrade'),
    );
    croak 'upgrade(): response must select at least one Upgrade protocol'
        if !@selected;
    my %offered = map { $_ => 1 } @offered;
    for my $protocol (@selected) {
        croak "upgrade(): response selected protocol not offered by request: $protocol"
            if !$offered{$protocol};
    }

    croak 'upgrade(): response cannot contain Content-Length'
        if $response->header_values('Content-Length');
    croak 'upgrade(): response cannot contain Transfer-Encoding'
        if $response->header_values('Transfer-Encoding');

    my @response_connection = $response->header_values('Connection');
    if (!@response_connection) {
        $response->header('Connection', 'Upgrade');
    } else {
        croak 'upgrade(): response Connection field must contain Upgrade'
            if !_connection_has(\@response_connection, 'upgrade');
        croak 'upgrade(): response cannot combine Connection: close with Upgrade'
            if _connection_has(\@response_connection, 'close');
    }

    croak 'upgrade(): cannot replace an explicit non-upgrade status'
        if $response->status != 200 && $response->status != 101;
    $response->status(101);
    $response->reason(undef);

    $target = _load_target($target);
    croak "upgrade(): $target is already the active Connection class"
        if ref($conn) eq $target;

    $response->{upgrade_pending} = 1;
    $conn->{_http_pending_upgrade} = {
        response    => $response,
        target      => $target,
        resume_read => $conn->is_read_paused ? 0 : 1,
    };

    Linux::Event::Kernel::Timer->new(
        loop     => $conn->loop,
        after    => 0,
        data     => {
            connection => $conn,
            response   => $response,
            target     => $target,
        },
        on_timer => \&_handoff,
    );

    return $response;
}

sub _handoff ($timer) {
    my $state = $timer->data;
    my $conn = $state->{connection};
    my $response = $state->{response};
    my $target = $state->{target};

    return if !$conn || $conn->is_closed || $conn->{_http_closing};

    my $pending = $conn->{_http_pending_upgrade} or return;
    return if refaddr($pending->{response}) != refaddr($response);
    return if $pending->{target} ne $target;

    my $active = $conn->{_http_active_response};
    return if !$active || refaddr($active) != refaddr($response);

    my $request_state = $conn->{_http_request_state};
    if (!$request_state || !$request_state->{body_done}) {
        $response->{upgrade_pending} = 0;
        delete $conn->{_http_pending_upgrade};
        $conn->_fail_active_transaction(
            500, $conn->{_http_active_request}, $response,
        );
        return;
    }

    my $head;
    my $serialized = eval {
        $head = $response->_serialize_head('1.1');
        1;
    };
    if (!$serialized) {
        $response->{upgrade_pending} = 0;
        delete $conn->{_http_pending_upgrade};
        $conn->_fail_active_transaction(
            500, $conn->{_http_active_request}, $response,
        );
        return;
    }

    $response->_mark_started;
    $response->_mark_ended;
    $response->{upgrade_pending} = 0;
    $conn->{_http_response_state} = undef;

    # The switching response must enter the existing output queue before the
    # target protocol can synchronously write during transition readiness.
    $conn->write($head);

    my $input = $conn->{_http_input};
    my $resume_read = $pending->{resume_read};
    $conn->{_http_input} = '';
    delete $conn->{_http_pending_upgrade};
    $conn->_clear_transaction;

    my $transitioned = eval {
        if (length($input)) {
            $conn->transition_to($target, input => $input);
        } else {
            $conn->transition_to($target);
        }
        $conn->resume_read if $resume_read && $conn->is_read_paused;
        1;
    };
    if (!$transitioned) {
        # A 101 response is already queued, so an HTTP error response is no
        # longer possible. Terminal close is the only coherent failure mode.
        eval { $conn->close; 1 };
    }
    return;
}

sub CLONE_SKIP ($class) { 1 }

1;
