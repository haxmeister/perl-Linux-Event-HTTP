use v5.36;
use strict;
use warnings;

use Test::More;

use_ok('Linux::Event::HTTP');
use_ok('Linux::Event::HTTP::Server');
use_ok('Linux::Event::HTTP::Server::Connection');
use_ok('Linux::Event::HTTP::Request');
use_ok('Linux::Event::HTTP::Response');
use_ok('Linux::Event::HTTP::Transaction');
use_ok('Linux::Event::HTTP::Body::Stream');

ok(Linux::Event::HTTP::Request->can('new'),
    'Request exposes public message construction');
ok(Linux::Event::HTTP::Request->can('version'),
    'Request exposes protocol-neutral version accessor');
ok(Linux::Event::HTTP::Response->can('new'),
    'Response exposes public message construction');
ok(Linux::Event::HTTP::Response->can('body'),
    'Response exposes complete scalar body');
ok(!Linux::Event::HTTP::Response->can('stream_body'),
    'Response does not own streaming body production');
ok(!Linux::Event::HTTP::Response->can('write'),
    'Response does not expose streaming write');
ok(!Linux::Event::HTTP::Response->can('complete'),
    'Response does not expose body completion operation');
ok(Linux::Event::HTTP::Response->can('is_complete'),
    'Response exposes message completion state');
ok(!Linux::Event::HTTP::Response->can('end'),
    'Response does not retain ambiguous end alias');
ok(!Linux::Event::HTTP::Response->can('is_ended'),
    'Response does not retain is_ended alias');
ok(Linux::Event::HTTP::Transaction->can('request'),
    'Transaction exposes its Request');
ok(Linux::Event::HTTP::Transaction->can('response'),
    'Transaction exposes its Response');
ok(Linux::Event::HTTP::Transaction->can('response_body'),
    'Transaction owns outgoing Response body production');
ok(Linux::Event::HTTP::Transaction->can('cancel'),
    'Transaction exposes cancellation');
ok(Linux::Event::HTTP::Server::Connection->can('transaction'),
    'server Connection exposes its active Transaction');

done_testing;
