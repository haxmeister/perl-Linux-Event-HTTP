package Linux::Event::HTTP::_HTTP2::Native;
use v5.36;
use strict;
use warnings;

use XSLoader;

our $VERSION = '0.002';

XSLoader::load(__PACKAGE__, $VERSION);

sub new_client ($class, %option) {
    my $callbacks = delete($option{callbacks}) // {};
    die 'new_client(): callbacks must be a hash reference'
        if ref($callbacks) ne 'HASH';
    die 'new_client(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    return $class->_new(0, $callbacks);
}

sub new_server ($class, %option) {
    my $callbacks = delete($option{callbacks}) // {};
    die 'new_server(): callbacks must be a hash reference'
        if ref($callbacks) ne 'HASH';
    die 'new_server(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    return $class->_new(1, $callbacks);
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::_HTTP2::Native - private libnghttp2 bridge

=head1 DESCRIPTION

Experimental private XS boundary between Linux::Event::HTTP and libnghttp2.
It deliberately exposes only the session primitives needed by the HTTP/2
executors and is not a general-purpose Perl nghttp2 binding.

=cut
