package Linux::Event::HTTP::Client;
use v5.36;
use parent 'Unblock::HTTP::Client';
use Linux::Event::HTTP::_Config;
use Linux::Event::HTTP::_Stream;
use Linux::Event::Kernel::Timer;
use Carp qw(croak);

our $VERSION = '0.003';

sub new ($class, %option) {
    my $loop = delete $option{loop};
    Linux::Event::HTTP::_Config::loop($loop);
    my $stream_class = Linux::Event::HTTP::_Config::stream_class(\%option);
    my %protocols = Linux::Event::HTTP::_Config::protocols(\%option);
    my $tls = delete($option{tls}) // {};
    croak 'new(): tls must be a hash reference' unless ref($tls) eq 'HASH';
    croak 'new(): HTTP Client owns TLS server_name and alpn'
        if exists($tls->{server_name}) || exists($tls->{alpn});
    $tls = { %$tls };
    for my $name (qw(connect_stream connect_quic defer schedule_timer release_connection)) {
        die "new(): $name is owned by Linux::Event::HTTP\n" if exists $option{$name};
    }
    my $self = $class->SUPER::new(%option, %protocols,
        defer => sub ($callback) { $loop->defer($callback); return },
        schedule_timer => sub ($seconds, $callback) {
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $loop, after => $seconds,
                on_timer => sub ($timer) { $callback->() },
            );
            return sub { $timer->cancel };
        },
        connect_stream => sub ($origin, $alpn, $ready) {
            my %transport;
            my $verified = 0;
            if ($origin->{scheme} eq 'https') {
                require Linux::Event::TLS;
                $transport{transport} = Linux::Event::TLS->client(
                    %$tls, server_name => $origin->{host}, alpn => $alpn,
                );
                $verified = exists($tls->{verify}) ? $tls->{verify} : 1;
            }
            my $stream = $stream_class->connect(
                loop => $loop, host => $origin->{host}, port => $origin->{port},
                %transport, data => { ready => $ready, verified_origin => $verified },
            );
            return sub { $stream->close };
        },
        release_connection => \&_release_transport,
    );
    $self->{linux_event_loop} = $loop;
    return $self;
}

sub _release_transport ($stream, $engine, $protocol, $reason) {
    $stream->close;
    return;
}

sub loop ($self) { $self->{linux_event_loop} }
sub get ($self, $url, %option) { $self->request(%option, method => 'GET', url => $url) }
sub head ($self, $url, %option) { $self->request(%option, method => 'HEAD', url => $url) }
sub post ($self, $url, %option) { $self->request(%option, method => 'POST', url => $url) }
sub put ($self, $url, %option) { $self->request(%option, method => 'PUT', url => $url) }
sub delete ($self, $url, %option) { $self->request(%option, method => 'DELETE', url => $url) }

1;

__END__

=head1 NAME

Linux::Event::HTTP::Client - Unblock HTTP client using Linux::Event transports

=head1 SYNOPSIS

    my $client = Linux::Event::HTTP::Client->new(loop => $loop);
    my $op = $client->get('http://localhost:8080/',
        timeout => 15,
        on_response => sub ($tx, $response) { say $response->body },
    );

=head1 DESCRIPTION

This thin Unblock::HTTP::Client subclass supplies sockets, deferred work and
cancellable Linux::Event timers. Unblock owns pooling, scheduling, operations
and transactions. C<request>, C<pool_stats>, C<pending_count>, C<network_changed>
and C<shutdown> have the Unblock semantics.

C<on_response> receives a complete bounded response by default. Supplying
C<on_data> selects streaming: C<on_response> runs at headers, C<on_data>
provides chunks, and C<on_end> signals body completion. C<on_finish> runs
at terminal cleanup. C<timeout> is in seconds and includes time in the queue.
The returned operation supports cancellation before and after dispatch.

For a streamed upload, set C<stream_body =E<gt> 1> and supply
C<on_transaction =E<gt> sub ($tx) { $tx-E<gt>write(...); $tx-E<gt>end }>. This
callback runs when queued work is admitted to the real engine. It may run
synchronously for an available connection; use the supplied Transaction.

This reconstruction slice supports HTTP/1 over TCP/TLS and optional HTTP/2
over TLS with C<http2 =E<gt> 1> (Unblock::HTTP2 0.12 or later). HTTPS verifies
the certificate and original hostname by default. C<tls> accepts Linux::Event
TLS options such as C<ca_file>. HTTP owns the hostname and ALPN selection.
C<native_input =E<gt> 0> selects the Perl input path for diagnostics.
HTTP/2 uses ALPN and multiplexes operations through Unblock's pool. Ordinary
requests can fall back to HTTP/1; C<http_version =E<gt> '2'> fails if HTTP/2
cannot be negotiated. HTTP/2 C<on_error> may include a third protocol error-code
argument. HTTP/3 and protocol handoff remain subsequent stages.
No redirects, cookies, authentication retries or response wrappers are added.

=cut
