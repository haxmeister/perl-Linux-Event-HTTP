package Linux::Event::Net::HTTP::_Experiment::FastFinalConnection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Net::HTTP::Connection';

use Carp qw(croak);

use Linux::Event::Net::HTTP::_Native::Response1 ();
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

our $VERSION = '0.001';

sub new ($class, %option) {
    my $handler = delete $option{on_request_final};
    if (defined $handler) {
        croak 'new(): on_request_final must be a coderef'
            if ref($handler) ne 'CODE';
    } else {
        $handler = $class->can('on_request_final');
    }

    croak 'new(): experimental fast-final Connection requires on_request_final callback or method'
        if !$handler;

    my $self = $class->SUPER::new(%option);
    $self->{_http_on_request_final} = $handler;
    return $self;
}

sub _drive_parent ($self) {
    local $self->{_http_driving} = 0;
    return $self->SUPER::_drive_http1;
}

sub _invoke_request_final ($self, $request) {
    my ($ok, $body);
    {
        local $self->{_http_dispatching} = 1;
        $ok = eval {
            $body = $self->{_http_on_request_final}->($self, $request);
            1;
        };
    }

    if (!$ok) {
        $self->_protocol_error(500, $request->http_version);
        return (0, undef);
    }

    return (1, $body);
}

sub _end_returned_body ($self, $request, $response) {
    $response->end($self->{_http_fast_final_fallback_body});
    return;
}

sub _drive_returned_body_fallback ($self, $body) {
    local $self->{_http_fast_final_fallback_body} = $body;
    local $self->{_http_on_request} = \&_end_returned_body;
    local $self->{_http_on_request_end} = undef;
    local $self->{_http_driving} = 0;
    return $self->SUPER::_drive_http1;
}

sub _drive_http1 ($self) {
    return if $self->{_http_driving} || $self->{_http_closing}
        || $self->is_closed;

    return $self->SUPER::_drive_http1 if $self->{_http_active_request};

    local $self->{_http_driving} = 1;

    while (!$self->{_http_closing} && !$self->is_closed) {
        return $self->_drive_parent if $self->{_http_active_request};
        last if !length($self->{_http_input});

        my $request;
        my $parsed = eval {
            $request = Linux::Event::Net::HTTP::_Parser::HTTP1->parse_request(
                $self->{_http_input}, 0, 100,
            );
            1;
        };

        return $self->_drive_parent if !$parsed;
        if (!defined $request) {
            return $self->_drive_parent
                if length($self->{_http_input}) > 65_536;
            last;
        }

        my $consumed = $request->_consumed;
        return $self->_drive_parent if $consumed > 65_536;

        my $expect = Linux::Event::Net::HTTP::Connection::_expect_continue(
            $request,
        );
        return $self->_drive_parent if $expect < 0;

        return $self->_drive_parent if $request->body_mode ne 'none';

        my ($ok, $body) = $self->_invoke_request_final($request);
        return if !$ok;
        return if $self->{_http_closing} || $self->is_closed;

        return $self->_drive_parent if !defined $body;

        my $wire;
        my $built = eval {
            $wire = Linux::Event::Net::HTTP::_Native::Response1
                ->build_default_final($request, $body);
            1;
        };
        if (!$built) {
            $self->_protocol_error(500, $request->http_version);
            return;
        }

        if (!defined $wire) {
            return $self->_drive_returned_body_fallback($body);
        }

        substr($self->{_http_input}, 0, $consumed, '');
        $self->write($wire);
    }

    return;
}

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::_Experiment::FastFinalConnection - benchmark-only fast-final HTTP connection

=head1 DESCRIPTION

This private module exists only on the native-final-response experiment branch.
It tests whether a bodyless request can bypass eager Response allocation and the
general transaction state machine when an application callback returns a
complete default-final response body.

It is not a supported public API and must not be merged as-is.

=cut
