use v5.36;
use strict;
use warnings;

use Test::More;

use_ok('Linux::Event::HTTP');
use_ok('Linux::Event::HTTP::Server');
use_ok('Linux::Event::HTTP::Server::Connection');
use_ok('Linux::Event::HTTP::Request');
use_ok('Linux::Event::HTTP::Response');
use_ok('Linux::Event::HTTP::Body::Stream');

ok(Linux::Event::HTTP::Response->can('body'),
    'Response exposes body');
ok(Linux::Event::HTTP::Response->can('stream_body'),
    'Response exposes stream_body');
ok(!Linux::Event::HTTP::Response->can('write'),
    'Response does not expose streaming write');
ok(!Linux::Event::HTTP::Response->can('complete'),
    'Response does not expose body completion');
ok(Linux::Event::HTTP::Response->can('is_complete'),
    'Response exposes is_complete');
ok(!Linux::Event::HTTP::Response->can('end'),
    'Response does not retain ambiguous end alias');
ok(!Linux::Event::HTTP::Response->can('is_ended'),
    'Response does not retain is_ended alias');

done_testing;
