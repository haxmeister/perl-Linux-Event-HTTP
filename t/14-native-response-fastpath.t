use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Net::HTTP::_Native::Response1 ();
use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

my $parser = 'Linux::Event::Net::HTTP::_Parser::HTTP1';
my $native = 'Linux::Event::Net::HTTP::_Native::Response1';

my $get = $parser->parse_request(
    "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
    0,
    100,
);

is(
    $native->build_default_final($get, 'hello'),
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    'native builder emits default persistent HTTP/1.1 final response',
);

my $head = $parser->parse_request(
    "HEAD / HTTP/1.1\r\nHost: example.test\r\n\r\n",
    0,
    100,
);
is(
    $native->build_default_final($head, 'hello'),
    undef,
    'HEAD falls back to the general response path',
);

my $close = $parser->parse_request(
    "GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n",
    0,
    100,
);
is(
    $native->build_default_final($close, 'hello'),
    undef,
    'non-persistent request falls back to the general response path',
);

my $ok = eval {
    $native->build_default_final($get, []);
    1;
};
ok(!$ok, 'reference body is rejected');
like($@, qr/body must be a scalar byte string/, 'reference body error is stable');

my $wide = "\x{100}";
$ok = eval {
    $native->build_default_final($get, $wide);
    1;
};
ok(!$ok, 'wide-character body is rejected');
like($@, qr/body contains wide characters/, 'wide-character body error is stable');

done_testing;
