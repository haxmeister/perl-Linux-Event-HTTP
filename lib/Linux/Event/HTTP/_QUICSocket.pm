package Linux::Event::HTTP::_QUICSocket;
use v5.36;
use Carp qw(croak);
use Scalar::Util qw(weaken refaddr);
use Socket qw(AF_INET6 inet_pton);
use Linux::Event::Address;
use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Kernel::Timer;

# This adapter deliberately binds one concrete address. Linux::Event's
# datagram callback has no per-packet destination address for wildcard binds.
# Net::QUIC cannot route a received packet using a wildcard local address.
sub _concrete ($address) {
    return 0 unless $address && ($address->family eq 'inet' || $address->family eq 'inet6');
    my $host = $address->host;
    return $host ne '0.0.0.0' if $address->family eq 'inet';
    my $packed = inet_pton(AF_INET6, $host);
    return defined($packed) && $packed ne ("\0" x 16);
}

sub new ($class, %option) {
    my $loop = delete $option{loop};
    my $host = delete $option{host};
    my $port = delete $option{port};
    my $on_error = delete $option{on_error};
    croak 'QUIC socket requires loop, host and port'
        unless $loop && defined($host) && defined($port);
    croak 'QUIC socket on_error must be a coderef'
        if defined($on_error) && ref($on_error) ne 'CODE';
    croak 'QUIC socket unknown options: ' . join(', ', sort keys %option) if %option;
    croak 'QUIC socket requires a concrete local host, not a wildcard address'
        if $host eq '0.0.0.0' || $host eq '::';
    my $self = bless { loop => $loop, on_error => $on_error }, $class;
    my $weak = $self;
    weaken($weak);
    $self->{socket} = Linux::Event::IO::Sock::Dgram->new(
        loop => $loop, host => $host, port => $port,
        on_datagram => sub ($socket, $bytes, $peer) {
            my $owner = $weak or return;
            my $manager = $owner->{manager} or return;
            $manager->receive($bytes, $owner->{local}, $peer->sockaddr);
        },
        on_drain => sub {
            my $owner = $weak or return;
            my $manager = $owner->{manager} or return;
            $manager->writable;
        },
        on_error => sub ($socket, $error) {
            my $owner = $weak or return;
            $owner->{on_error}->($socket, $error) if $owner->{on_error};
        },
        on_close => sub {
            my $owner = $weak or return;
            $owner->close;
        },
    );
    my $local = $self->{socket}->local;
    unless (_concrete($local)) {
        $self->close;
        croak 'QUIC socket requires a concrete IPv4/IPv6 local address';
    }
    $self->{local} = $local->sockaddr;
    return $self;
}

sub socket ($self) { $self->{socket} }
sub local ($self) { $self->{local} }

sub send_callback ($self) {
    my $weak = $self;
    weaken($weak);
    return sub ($packet) {
        my $owner = $weak or croak 'QUIC socket no longer exists';
        croak 'QUIC socket is closed' if $owner->{closed};
        croak 'QUIC datagram uses a different source address'
            if $packet->local ne $owner->{local};
        return $owner->{socket}->send(
            $packet->data,
            to => Linux::Event::Address->new($packet->peer),
        );
    };
}

sub set_timeout_callback ($self) {
    my $weak = $self;
    weaken($weak);
    return sub ($seconds) {
        my $owner = $weak or return;
        return if $owner->{closed};
        $owner->_set_timeout($seconds);
    };
}

sub _set_timeout ($self, $seconds) {
    if (my $old = delete $self->{timer}) {
        $old->cancel;
    }
    return unless defined $seconds;
    croak 'QUIC timeout must be non-negative seconds'
        unless !ref($seconds) && $seconds =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/;
    my $weak = $self;
    weaken($weak);
    $self->{timer} = Linux::Event::Kernel::Timer->new(
        loop => $self->{loop}, after => $seconds,
        on_timer => sub ($timer) {
            my $owner = $weak or return;
            return if $owner->{closed};
            my $current = $owner->{timer} or return;
            return unless refaddr($current) == refaddr($timer);
            delete $owner->{timer};
            my $manager = $owner->{manager} or return;
            $manager->timeout;
        },
    );
    return;
}

sub start ($self, $manager) {
    croak 'QUIC socket has been closed' if $self->{closed};
    croak 'QUIC socket already started' if $self->{manager};
    croak 'QUIC manager must implement start, receive, timeout and writable'
        unless ref($manager) && !grep { !$manager->can($_) }
            qw(start receive timeout writable);
    $self->{manager} = $manager;
    $manager->start;
    return $self;
}

sub close ($self) {
    return $self if $self->{closed}++;
    my $timer = delete $self->{timer};
    $timer->cancel if $timer;
    delete $self->{manager};
    my $socket = delete $self->{socket};
    $socket->close if $socket && $socket->is_active;
    return $self;
}

1;
