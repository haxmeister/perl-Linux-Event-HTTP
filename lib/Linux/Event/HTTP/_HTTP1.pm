package Linux::Event::HTTP::_HTTP1;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

require XSLoader;
XSLoader::load(__PACKAGE__);

# Native parsing can create a Linux::Event::HTTP::Request without loading
# Request.pm. Keep the protocol-neutral version() getter available in that
# parser-only case; Request.pm replaces it with the full local/native wrapper
# when the public message class is loaded.
sub Linux::Event::HTTP::Request::version ($self) {
    return $self->http_version;
}

sub CLONE_SKIP { 1 }

1;
