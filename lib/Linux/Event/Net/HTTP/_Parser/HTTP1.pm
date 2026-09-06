package Linux::Event::Net::HTTP::_Parser::HTTP1;
use v5.36;
use strict;
use warnings;

use Linux::Event::Net::HTTP ();
use Linux::Event::Net::HTTP::Request ();
use XSLoader ();

our $VERSION = $Linux::Event::Net::HTTP::VERSION;

XSLoader::load(__PACKAGE__, $VERSION);

1;
