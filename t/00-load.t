use v5.36;
use strict;
use warnings;

use Test::More;

use_ok('Linux::Event::HTTP');
use_ok('Linux::Event::HTTP::Server');
use_ok('Linux::Event::HTTP::Server::Connection');
use_ok('Linux::Event::HTTP::Request');
use_ok('Linux::Event::HTTP::Response');

ok(Linux::Event::HTTP::Response->can('complete'),
    'Response exposes complete');
ok(Linux::Event::HTTP::Response->can('is_complete'),
    'Response exposes is_complete');
ok(!Linux::Event::HTTP::Response->can('end'),
    'Response does not retain ambiguous end alias');
ok(!Linux::Event::HTTP::Response->can('is_ended'),
    'Response does not retain is_ended alias');

done_testing;
