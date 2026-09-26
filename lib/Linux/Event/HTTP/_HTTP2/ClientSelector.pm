package Linux::Event::HTTP::_HTTP2::ClientSelector;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed refaddr weaken);

use Linux::Event::HTTP::Transaction;

our $VERSION = '0.002';

sub new ($class, %option) {
    my $loop = delete $option{loop};
    my $host = delete $option{host};
    my $port = delete $option{port};
    my $transport = delete $option{transport};
    my $timeout = delete $option{timeout};
    my $scheme = delete($option{scheme}) // 'https';
    my $authority = delete $option{authority};

    croak 'new(): loop is required' if !blessed($loop);
    croak 'new(): host is required'
        if !defined($host) || ref($host) || $host eq '';
    croak 'new(): port is required'
        if !defined($port) || ref($port);
    croak 'new(): transport is required' if !blessed($transport);
    croak 'new(): authority is required'
        if !defined($authority) || ref($authority) || $authority eq '';
    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    require Linux::Event::HTTP::_HTTP2::ClientSelectorConnection;
    require Linux::Event::HTTP::_HTTP2::Client;
    require Linux::Event::HTTP::_HTTP2::ClientConnection;

    my $self = bless {
        protocol    => 'negotiating',
        scheme      => "$scheme",
        authority   => "$authority",
        stream      => undef,
        executor    => undef,
        transaction => undef,
        pending     => undef,
        closed      => 0,
    }, $class;

    my %connect = (
        loop      => $loop,
        host      => $host,
        port      => $port,
        transport => $transport,
    );
    $connect{timeout} = $timeout if defined $timeout;

    my $stream = Linux::Event::HTTP::_HTTP2::ClientSelectorConnection
        ->connect(%connect);
    $stream->{_http2_selector} = $self;
    weaken($stream->{_http2_selector});
    $self->{stream} = $stream;

    return $self;
}

sub stream ($self) { $self->{stream} }

sub is_closed ($self) {
    return 1 if $self->{closed};
    return !$self->{stream} || $self->{stream}->is_closed ? 1 : 0;
}

sub protocol ($self) { $self->{protocol} }

sub _http2_capable ($self) { 1 }

sub transaction ($self) {
    my $tx = $self->{transaction} or return undef;
    return undef if $tx->is_terminal;
    return $tx;
}

sub request ($self, $request, %option) {
    croak 'request(): selector is closed' if $self->is_closed;
    croak 'request(): requires a Linux::Event::HTTP::Request'
        if !blessed($request)
        || !$request->isa('Linux::Event::HTTP::Request');

    if ($self->{protocol} eq 'http/1.1') {
        my $tx = $self->{stream}->request($request, %option);
        $self->{transaction} = $tx;
        return $tx;
    }

    if ($self->{protocol} eq 'h2') {
        $self->_prepare_h2_request($request);
        my $tx = $self->{executor}->request($request, %option);
        $self->{transaction} = $tx;
        return $tx;
    }

    croak 'request(): another Transaction is already pending protocol selection'
        if $self->transaction;

    croak 'request(): streaming Request bodies are not yet available before HTTP/2 ALPN selection'
        if exists $option{stream_body};
    croak 'request(): HTTP/1 Upgrade cannot be negotiated through an HTTP/2-capable selector'
        if exists $option{upgrade_to};
    croak 'request(): CONNECT tunnel handoff cannot be negotiated through an HTTP/2-capable selector'
        if exists $option{tunnel_to};

    my $tx = Linux::Event::HTTP::Transaction->_new(
        request    => $request,
        controller => $self,
    );
    $tx->_activate;

    $self->{transaction} = $tx;
    $self->{pending} = {
        request     => $request,
        transaction => $tx,
        option      => { %option },
    };
    return $tx;
}

sub _prepare_h2_request ($self, $request) {
    croak 'HTTP/2 selector cannot change a committed Request'
        if !$request->is_mutable;

    my $authority = $request->header('Host');
    $authority = $self->{authority}
        if !defined($authority) || $authority eq '';

    $request->version('2') if ($request->version // '') ne '2';
    $request->scheme($self->{scheme});
    $request->authority($authority);
    $request->remove_header('Host');
    return;
}

sub _transport_ready ($self, $stream) {
    return if $self->{closed};

    my $alpn = $stream->selected_alpn // '';
    if ($alpn eq 'http/1.1') {
        $self->{protocol} = 'http/1.1';
        $self->_submit_pending_http1;
        return;
    }

    if ($alpn ne 'h2') {
        $self->_fail_pending(
            "TLS selected unsupported HTTP ALPN '$alpn'",
        );
        $stream->close if !$stream->is_closed;
        return;
    }

    $self->{protocol} = 'selecting-h2';
    $stream->pause_read;
    $stream->loop->defer(sub {
        return if $self->{closed} || $stream->is_closed;

        my $executor = Linux::Event::HTTP::_HTTP2::Client->new(
            stream    => $stream,
            autostart => 0,
        );
        $self->{executor} = $executor;
        $stream->{_http2_executor} = $executor;

        $stream->transition_to(
            'Linux::Event::HTTP::_HTTP2::ClientConnection',
        );
        $executor->start;
        $self->{protocol} = 'h2';

        $self->_submit_pending_h2;
        $stream->resume_read if $stream->is_read_paused;
    });
    return;
}

sub _submit_pending_http1 ($self) {
    my $pending = $self->{pending} or return;
    my $ok = eval {
        $self->{stream}->request(
            $pending->{request},
            %{$pending->{option}},
            _transaction => $pending->{transaction},
        );
        1;
    };
    if ($ok) {
        delete $self->{pending};
    } else {
        $self->_fail_pending("$@");
    }
    return;
}

sub _submit_pending_h2 ($self) {
    my $pending = $self->{pending} or return;
    my $ok = eval {
        $self->_prepare_h2_request($pending->{request});
        $self->{executor}->request(
            $pending->{request},
            %{$pending->{option}},
            _transaction => $pending->{transaction},
        );
        1;
    };
    if ($ok) {
        delete $self->{pending};
    } else {
        $self->_fail_pending("$@");
    }
    return;
}

sub _fail_pending ($self, $error) {
    $error = 'HTTP connection failed during protocol selection'
        if !defined($error) || $error eq '';
    $error =~ s/\s+\z//;

    my $pending = delete $self->{pending};
    my $tx = $pending ? $pending->{transaction} : $self->{transaction};
    if ($tx && !$tx->is_terminal) {
        $tx->_fail($error);
    }

    my $callback = $pending ? $pending->{option}{on_error} : undef;
    $callback->($tx, $error) if $callback && $tx;
    return;
}

sub _transport_error ($self, $error) {
    return if $self->{protocol} ne 'negotiating'
        && $self->{protocol} ne 'selecting-h2';
    $self->_fail_pending($error);
    return;
}

sub close ($self) {
    return $self if $self->{closed};
    $self->{closed} = 1;

    if (my $pending = delete $self->{pending}) {
        my $tx = $pending->{transaction};
        $tx->_fail('HTTP connection closed before protocol selection')
            if !$tx->is_terminal;
        if (my $cb = $pending->{option}{on_error}) {
            $cb->($tx, $tx->error);
        }
    }

    if (my $stream = $self->{stream}) {
        $stream->close if !$stream->is_closed;
    }
    return $self;
}

sub _cancel_http_transaction ($self, $tx) {
    my $current = $self->{transaction};
    croak 'cancel(): Transaction is not pending on this HTTP selector'
        if !$current || refaddr($current) != refaddr($tx);

    if ($self->{pending}) {
        delete $self->{pending};
        $tx->_mark_cancelled if !$tx->is_terminal;
        return;
    }

    $tx->_mark_cancelled if !$tx->is_terminal;
    return;
}

sub _write_http_request_body ($self, $tx, $bytes, $final, $operation) {
    croak "$operation(): Request body cannot be written before protocol selection";
}

sub _write_http_response_body ($self, $tx, $bytes, $final, $operation) {
    croak "$operation(): client selector cannot write a Response body";
}

sub _upgrade_http_transaction ($self, $tx, $target_class) {
    croak 'upgrade(): unavailable while HTTP protocol selection is pending';
}

sub _tunnel_http_transaction ($self, $tx, $target_class) {
    croak 'tunnel(): unavailable while HTTP protocol selection is pending';
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::_HTTP2::ClientSelector - private HTTPS ALPN selector

=head1 DESCRIPTION

This private object preserves the high-level Client's synchronous Transaction
identity while delaying wire submission until TLS ALPN selects HTTP/1.1 or
HTTP/2.

=cut
