package Linux::Event::Net::HTTP::Server;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

use Linux::Event::IO::Sock::Listener;
use Linux::Event::Net::HTTP::Connection;
use Linux::Event::Net::HTTP::_ServerConnection ();

our $VERSION = '0.001';

my $ADAPTER = 'Linux::Event::Net::HTTP::_ServerConnection';

sub _load_connection_class ($class) {
    croak 'new(): connection_class must be a package name'
        if !defined($class) || ref($class)
        || $class !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    if (!$class->can('new')) {
        (my $file = "$class.pm") =~ s{::}{/}g;
        require $file;
    }

    croak 'new(): connection_class must inherit Linux::Event::Net::HTTP::Connection'
        if !$class->isa('Linux::Event::Net::HTTP::Connection');
    croak 'new(): connection_class cannot name the private Server adapter'
        if $class eq $ADAPTER;

    $class->_validate_accepted_configuration;
    return $class;
}

sub _take_callback ($name, $option) {
    return undef if !exists $option->{$name};
    my $callback = delete $option->{$name};
    croak "new(): $name must be a coderef" if ref($callback) ne 'CODE';
    return $callback;
}

sub new ($class, %option) {
    croak 'new(): stream_class is internal; use connection_class'
        if exists $option{stream_class};
    croak 'new(): HTTP Server owns on_data; use on_request/on_body callbacks'
        if exists $option{on_data};
    croak 'new(): HTTP Server cannot use message framing callbacks'
        if exists($option{on_message}) || exists($option{on_messages});
    croak 'new(): on_request_final is no longer supported; use on_request and Response'
        if exists $option{on_request_final};

    my $connection_class = _load_connection_class(
        delete($option{connection_class})
            // 'Linux::Event::Net::HTTP::Connection',
    );

    croak 'new(): on_request_final is no longer supported; use on_request and Response'
        if $connection_class->can('on_request_final');

    my %callbacks;
    for my $name (qw(on_request on_body on_request_end)) {
        my $callback = _take_callback($name, \%option);
        $callbacks{$name} = $callback if $callback;
    }

    croak 'new(): HTTP Server requires on_request callback or connection_class method'
        if !$callbacks{on_request} && !$connection_class->can('on_request');

    my $data = delete $option{data};
    my $state = {
        _http_server_state => 1,
        connection_class   => $connection_class,
        callbacks          => \%callbacks,
        data               => $data,
    };

    my $listener = Linux::Event::IO::Sock::Listener->new(
        %option,
        stream_class => $ADAPTER,
        data         => $state,
    );

    return bless {
        listener         => $listener,
        connection_class => $connection_class,
        data             => $data,
        state            => $state,
    }, $class;
}

sub listener         ($self) { $self->{listener} }
sub connection_class ($self) { $self->{connection_class} }
sub data             ($self) { $self->{data} }
sub loop             ($self) { $self->{listener}->loop }
sub fh               ($self) { $self->{listener}->fh }
sub fd               ($self) { $self->{listener}->fd }
sub host             ($self) { $self->{listener}->host }
sub port             ($self) { $self->{listener}->port }
sub path             ($self) { $self->{listener}->path }
sub family           ($self) { $self->{listener}->family }
sub family_number    ($self) { $self->{listener}->family_number }
sub is_tcp           ($self) { $self->{listener}->is_tcp }
sub is_unix          ($self) { $self->{listener}->is_unix }
sub state            ($self) { $self->{listener}->state }

sub pause ($self) {
    $self->{listener}->pause;
    return $self;
}

sub resume ($self) {
    $self->{listener}->resume;
    return $self;
}

sub close ($self) {
    $self->{listener}->close;
    return $self;
}

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Server - private transitional HTTP server implementation

=head1 DESCRIPTION

This Net-prefixed package is retained temporarily while the implementation is
migrated to L<Linux::Event::HTTP>. New application code should use
L<Linux::Event::HTTP::Server>.

The Server is a thin convenience over L<Linux::Event::IO::Sock::Listener>. It
accepts HTTP Connections and retains C<on_request>, C<on_body>, and
C<on_request_end> callbacks without introducing a web application framework.

The former benchmark-specific C<on_request_final> callback is no longer
supported. Complete, streamed, and deferred responses all use the ordinary
Request/Response lifecycle.

=head1 SEE ALSO

L<Linux::Event::HTTP::Server>, L<Linux::Event::HTTP::Connection>,
L<Linux::Event::IO::Sock::Listener>.

=cut
