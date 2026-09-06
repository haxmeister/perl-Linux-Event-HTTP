package Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked;
use v5.36;
use strict;
use warnings;

use Linux::Event::Net::HTTP ();
use XSLoader ();

our $VERSION = $Linux::Event::Net::HTTP::VERSION;

XSLoader::load(__PACKAGE__, $VERSION);

sub CLONE_SKIP ($class) { 1 }

1;
