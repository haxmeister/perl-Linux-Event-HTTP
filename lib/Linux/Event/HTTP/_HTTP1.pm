package Linux::Event::HTTP::_HTTP1;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

require XSLoader;
XSLoader::load(__PACKAGE__);

sub CLONE_SKIP { 1 }

1;
