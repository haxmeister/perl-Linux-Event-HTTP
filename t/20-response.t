use v5.36;
use strict;
use warnings;

use Test::More;
use Linux::Event::Net::HTTP::Response;

my $response = Linux::Event::Net::HTTP::Response->new(status => 200);

is($response->status, 200, 'status getter returns constructor status');
ok(!defined $response->reason, 'reason is optional');

$response->header('Content-Type', 'text/plain');
is($response->header('content-type'), 'text/plain', 'header lookup is case-insensitive');

$response->add_header('Set-Cookie', 'a=1');
$response->add_header('Set-Cookie', 'b=2');
is_deeply(
    [ $response->header_values('set-cookie') ],
    [ 'a=1', 'b=2' ],
    'repeated response headers preserve order',
);

is(
    $response->_serialize_head('1.1'),
    "HTTP/1.1 200 OK\r\n" .
    "Content-Type: text/plain\r\n" .
    "Set-Cookie: a=1\r\n" .
    "Set-Cookie: b=2\r\n" .
    "\r\n",
    'native serializer produces a valid HTTP/1.1 response head',
);

$response->status(404)->reason('Gone Here');
is(
    $response->_serialize_head('1.0'),
    "HTTP/1.0 404 Gone Here\r\n" .
    "Content-Type: text/plain\r\n" .
    "Set-Cookie: a=1\r\n" .
    "Set-Cookie: b=2\r\n" .
    "\r\n",
    'serializer supports HTTP/1.0 and custom reason phrase',
);

$response->reason(undef);
like(
    $response->_serialize_head('1.1'),
    qr/\AHTTP\/1\.1 404 Not Found\r\n/,
    'default reason phrase follows changed status',
);

$response->header('Content-Type', 'application/json');
is_deeply(
    [ $response->header_values('Content-Type') ],
    [ 'application/json' ],
    'header setter replaces fields of same name',
);

my $with_length = Linux::Event::Net::HTTP::Response->new(
    status => 200,
    headers => [
        [ 'Content-Length', '0' ],
    ],
);
like(
    $with_length->_serialize_head('1.1'),
    qr/Content-Length: 0\r\n\r\n\z/,
    'decimal Content-Length serializes',
);

my $no_content_length = Linux::Event::Net::HTTP::Response->new(
    status => 204,
    headers => [
        [ 'Content-Length', '0' ],
    ],
);
my $no_content_ok = eval { $no_content_length->_serialize_head('1.1'); 1 };
ok(!$no_content_ok, '204 response cannot emit Content-Length');
like($@, qr/204.*Content-Length/, '204 Content-Length rejection is clear');

my $ok = eval { Linux::Event::Net::HTTP::Response->new(status => 99); 1 };
ok(!$ok, 'invalid status is rejected');
like($@, qr/status/, 'invalid status error is clear');

$ok = eval { $response->header('Bad Header', 'value'); 1 };
ok(!$ok, 'invalid response field name is rejected');
like($@, qr/field name/, 'invalid field name error is clear');

$ok = eval { $response->header('X-Test', "safe\r\nInjected: yes"); 1 };
ok(!$ok, 'CRLF response splitting attempt is rejected');
like($@, qr/control characters/, 'CRLF rejection error is clear');

$ok = eval { $response->reason("Bad\nReason"); 1 };
ok(!$ok, 'newline in reason phrase is rejected');
like($@, qr/reason phrase/, 'invalid reason phrase error is clear');

$ok = eval { $response->_serialize_head('2'); 1 };
ok(!$ok, 'HTTP/2 cannot use HTTP/1 serializer');
like($@, qr/version/, 'invalid serializer version error is clear');

my $both = Linux::Event::Net::HTTP::Response->new(
    headers => [
        [ 'Content-Length', '3' ],
        [ 'Transfer-Encoding', 'chunked' ],
    ],
);
$ok = eval { $both->_serialize_head('1.1'); 1 };
ok(!$ok, 'response TE plus CL is rejected');
like($@, qr/both Transfer-Encoding and Content-Length/, 'response TE plus CL error is clear');

my $duplicate_length = Linux::Event::Net::HTTP::Response->new(
    headers => [
        [ 'Content-Length', '3' ],
        [ 'Content-Length', '3' ],
    ],
);
$ok = eval { $duplicate_length->_serialize_head('1.1'); 1 };
ok(!$ok, 'multiple response Content-Length fields are rejected');
like($@, qr/multiple Content-Length/, 'duplicate response Content-Length error is clear');

my $bad_length = Linux::Event::Net::HTTP::Response->new(
    headers => [
        [ 'Content-Length', '3, 3' ],
    ],
);
$ok = eval { $bad_length->_serialize_head('1.1'); 1 };
ok(!$ok, 'serializer only emits canonical decimal Content-Length');
like($@, qr/decimal number/, 'non-canonical response Content-Length error is clear');

# Serializer validates again in case internals are modified directly.
my $tampered = Linux::Event::Net::HTTP::Response->new;
$tampered->{headers} = [ [ 'Bad Header', 'x' ] ];
$ok = eval { $tampered->_serialize_head('1.1'); 1 };
ok(!$ok, 'native serializer revalidates tampered field names');

$tampered->{headers} = [ [ 'X-Test', "x\0y" ] ];
$ok = eval { $tampered->_serialize_head('1.1'); 1 };
ok(!$ok, 'native serializer revalidates tampered field values');

done_testing;
