use v5.36;
use strict;
use warnings;

use Test::More;

use_ok('Linux::Event::Net::HTTP');
use_ok('Linux::Event::Net::HTTP::Server');
use_ok('Linux::Event::Net::HTTP::Connection');
use_ok('Linux::Event::Net::HTTP::Request');
use_ok('Linux::Event::Net::HTTP::Response');

done_testing;
