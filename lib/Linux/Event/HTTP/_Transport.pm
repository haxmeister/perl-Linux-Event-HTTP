package Linux::Event::HTTP::_Transport;
use v5.36;
use parent 'Linux::Event::IO::Sock::Stream';

sub on_ready ($self) {
    my $state = $self->data;
    if (my $ready = delete $state->{ready}) {
        my $engine = $ready->(
            transport => $self, alpn => $self->selected_alpn,
            verified_origin => $state->{verified_origin} ? 1 : 0,
        );
        if ($self->is_closed) {
            $engine->transport_error('HTTP transport closed during attachment') if $engine;
            return;
        }
        $self->{http_engine} = $engine;
        $self->close unless $engine;
    } elsif (my $server = $state->{server}) {
        $self->{http_engine} = $server->_attach($self);
    } else {
        $self->close;
    }
    return;
}

sub on_eof ($self) {
    my $engine = $self->{http_engine};
    $engine->input_eof if $engine && $engine->want_read;
    return;
}

sub on_drain ($self) {
    my $engine = $self->{http_engine};
    $engine->resume_output if $engine;
    return;
}

sub _http_drain ($self) {
    if (my $engine = $self->{http_engine}) {
        $engine->drain;
    } else {
        # No admitted HTTP request exists during a TLS handshake.
        $self->close;
    }
    return;
}

sub on_error ($self, $error) {
    if (my $ready = delete $self->data->{ready}) {
        $ready->(error => "$error");
    }
    my $engine = $self->{http_engine};
    $engine->transport_error("$error") if $engine;
    return;
}

sub on_close ($self) {
    # Remove before notifying: transport_error may call unblock_abort again.
    my $engine = delete $self->{http_engine};
    my $state = $self->data;
    $engine->transport_error('HTTP transport closed') if $engine;
    if (my $server = $state->{server}) {
        $server->_closed($self);
    }
    if (my $ready = delete $state->{ready}) {
        $ready->(error => 'HTTP transport closed before readiness');
    }
    return;
}

sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die "HTTP transport closed during output\n" if $self->is_closed;
    return $ready;
}

sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

1;
