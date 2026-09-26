package Linux::Event::HTTP::_HTTP2::NativeConnection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';
use Linux::Event::Framer ();
use Linux::Event::HTTP::_HTTP2::Native ();

our $VERSION = '0.002';

Linux::Event::Framer->declare_native_consumer(
    __PACKAGE__,
    Linux::Event::HTTP::_HTTP2::Native->_raw_consumer_definition,
);

sub _http2_native_input_complete ($self, $executor, $error = undef) {
    if (defined $error) {
        if ($executor->isa('Linux::Event::HTTP::_HTTP2::Client')) {
            $executor->close("HTTP/2 protocol input failed: $error");
        } else {
            $executor->close;
        }
        $self->close if !$self->is_closed;
        return;
    }
    return if $executor->_finish_pending_close;
    $executor->flush;
    return;
}

sub request ($self, @args) {
    my $executor = $self->{_http2_executor}
        or die 'HTTP/2 connection has no executor';
    return $executor->request(@args);
}

sub transaction ($self) {
    my $executor = $self->{_http2_executor} or return undef;
    return $executor->transaction;
}

sub on_close ($self) {
    if (my $executor = delete $self->{_http2_executor}) {
        $executor->close;
    }
    delete $self->{_http2_native_session};
    return;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::_HTTP2::NativeConnection - private native HTTP/2 Stream target

=head1 DESCRIPTION

ALPN selects this private target when the experimental native session is in
use. The HTTP/1 consumer is replaced without discarding unread transport bytes.
Input goes directly from the native Stream buffer to libnghttp2. The existing
Client or Server executor owns semantic callbacks, output and backpressure.

=cut
