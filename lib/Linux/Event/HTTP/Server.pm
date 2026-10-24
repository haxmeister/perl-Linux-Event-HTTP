package Linux::Event::HTTP::Server;
use v5.36;
use Carp qw(croak);
use Scalar::Util qw(weaken refaddr);
use Unblock::HTTP::Server 0.02;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::Kernel::Timer;
use Linux::Event::HTTP::_Config;
use Linux::Event::HTTP::_Stream;

our $VERSION = '0.003';

sub new ($class, %option) {
    my $loop = delete $option{loop};
    Linux::Event::HTTP::_Config::loop($loop);
    my $stream_class = Linux::Event::HTTP::_Config::stream_class(\%option);
    my %protocols = Linux::Event::HTTP::_Config::protocols(\%option);
    my %callbacks;
    for my $name (qw(on_headers on_request on_error)) {
        $callbacks{$name} = delete $option{$name} if exists $option{$name};
    }
    my $definition = Unblock::HTTP::Server->new(%protocols, %callbacks);
    my $self = bless { loop => $loop, definition => $definition,
        connections => {} }, $class;
    my $state = { server => $self };
    weaken($state->{server});
    my %stream = (class => $stream_class, data => $state);
    for my $name (qw(tls tuning)) {
        $stream{$name} = delete $option{$name} if exists $option{$name};
    }
    if (exists $stream{tls}) {
        croak 'new(): tls must be a hash reference' unless ref($stream{tls}) eq 'HASH';
        croak 'new(): HTTP Server owns TLS alpn' if exists $stream{tls}{alpn};
        $stream{tls} = { %{ $stream{tls} }, alpn => [$definition->alpn_protocols] };
    }
    my $on_error = delete $option{on_listener_error};
    my %listen;
    for my $name (qw(host port path fh backlog reuseaddr reuseport v6only unlink_on_close)) {
        $listen{$name} = delete $option{$name} if exists $option{$name};
    }
    croak 'new(): unknown option: ' . join(', ', sort keys %option) if %option;
    $self->{listener} = Linux::Event::IO::Sock::Listener->new(
        loop => $loop, %listen, stream => \%stream,
        on_accept => sub ($listener, $stream) {
            my $server = $state->{server};
            $server ? $server->_track($stream) : $stream->close;
        },
        (defined($on_error) ? (on_error => $on_error) : ()),
    );
    return $self;
}

sub loop ($self) { $self->{loop} }
sub listener ($self) { $self->{listener} }
sub host ($self) { $self->{listener}->host }
sub port ($self) { $self->{listener}->port }
sub pause ($self) { $self->{listener}->pause; return $self }
sub resume ($self) { $self->{listener}->resume; return $self }
sub close ($self) { $self->{listener}->close; return $self }
sub connection_count ($self) { scalar keys %{ $self->{connections} } }

sub shutdown ($self, %option) {
    my $grace = delete($option{grace}) // 30;
    my $complete = delete $option{on_complete};
    croak 'shutdown(): grace must be a non-negative number of seconds'
        unless !ref($grace) && $grace =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/;
    croak 'shutdown(): on_complete must be a coderef'
        if defined($complete) && ref($complete) ne 'CODE';
    croak 'shutdown(): unknown option: ' . join(', ', sort keys %option) if %option;
    return $self if $self->{shutdown};
    $self->{shutdown} = 1;
    $self->{shutdown_complete} = $complete;
    $self->close;
    # A synchronous close can remove a stream while this snapshot is drained.
    for my $stream (values %{ $self->{connections} }) {
        $stream->_http_drain;
    }
    if ($self->connection_count) {
        my $weak = $self;
        weaken($weak);
        $self->{shutdown_timer} = Linux::Event::Kernel::Timer->new(
            loop => $self->{loop}, after => $grace,
            on_timer => sub {
                my $server = $weak or return;
                $_->close for values %{ $server->{connections} };
                $server->_shutdown_done;
            },
        );
    }
    $self->_shutdown_done;
    return $self;
}

sub _shutdown_done ($self) {
    return unless $self->{shutdown} && !$self->connection_count;
    return if $self->{shutdown_notified}++;
    my $timer = delete $self->{shutdown_timer};
    $timer->cancel if $timer;
    my $complete = delete $self->{shutdown_complete};
    $complete->($self) if $complete;
    return;
}

sub _track ($self, $stream) {
    return if $stream->is_closed;
    return $stream->close if $self->{shutdown};
    $self->{connections}{refaddr($stream)} = $stream;
    return;
}

sub _attach ($self, $stream) {
    if ($self->{shutdown}) { $stream->close; return }
    $self->_track($stream);
    return $self->{definition}->attach_stream(
        transport => $stream, alpn => $stream->selected_alpn,
    );
}

sub _closed ($self, $stream) {
    delete $self->{connections}{refaddr($stream)};
    $self->_shutdown_done if $self->{shutdown};
    return;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Server - Native Linux listener for Unblock HTTP

=head1 SYNOPSIS

    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop, port => 8080,
        on_request => sub ($tx, $request) {
            $tx->respond(status => 200, body => "Hello\n");
        },
    );

=head1 DESCRIPTION

HTTP/1 is enabled by default. Callbacks receive real Unblock transactions
and Uniform messages. C<on_headers> runs before the body; C<on_request> runs
once after successful body completion. Set C<$tx-E<gt>on_data(...)> during
C<on_headers> to stream a request. Otherwise Unblock buffers up to 1 MiB;
configure C<http1 =E<gt> { max_buffered_body_bytes =E<gt> ... }> to change it.

C<tls> and C<tuning> configure the Linux::Event listener's accepted streams.
HTTP owns TLS ALPN selection; do not specify C<tls =E<gt> { alpn =E<gt> ... }>.
C<native_input =E<gt> 0> selects the Perl input path for diagnostics.
C<on_listener_error> receives listener failures; C<on_error> is the HTTP
engine error callback. Unknown options are rejected.

C<loop>, C<listener>, C<host>, C<port>, C<pause>, C<resume>, C<close> and
C<connection_count> expose listener controls and live connection count.
C<close> stops accepting connections; existing connections continue.

C<shutdown(grace =E<gt> 30, on_complete =E<gt> sub ($server) { ... })>
stops listening, drains admitted HTTP/1 requests, and closes remaining owned
connections when the grace period expires. TLS handshakes without admitted
requests close immediately. Completion runs once after owned connections
and their transactions have finished; it can run synchronously if idle.
Repeated shutdown calls have no effect. C<grace> is non-negative seconds.
HTTP/2/3 are subsequent reconstruction stages.

=cut
