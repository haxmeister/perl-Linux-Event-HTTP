use v5.36;
use strict;
use warnings;

use Test::More;
use Scalar::Util qw(refaddr);

use Linux::Event::HTTP::Response;

{
    package T::BodyConnection;

    sub new ($class) {
        return bless {
            ready_calls => 0,
            writes      => [],
            next_write  => 1,
        }, $class;
    }

    sub _response_body_ready ($self, $response) {
        ++$self->{ready_calls};
        return;
    }

    sub _write_response ($self, $response, $bytes, $final, $operation = undef) {
        push @{$self->{writes}}, [ $bytes, $final, $operation ];
        return $self->{next_write};
    }
}

{
    package T::Request;
    sub version ($self) { '1.1' }
}

my $connection = T::BodyConnection->new;
my $request = bless {}, 'T::Request';
my $response = Linux::Event::HTTP::Response->_new_bound($connection, $request);

ok(!$response->can('write'), 'Response does not expose streaming write');
ok(!$response->can('complete'), 'Response does not expose body completion');
ok(!defined $response->body, 'response starts without a scalar body');
$response->body("hello\n");
is($response->body, "hello\n", 'body setter stores complete scalar body bytes');
is($connection->{ready_calls}, 1, 'body setter notifies its bound connection');

$response->body("changed\n");
is($response->body, "changed\n", 'scalar body can be replaced before output starts');
is($connection->{ready_calls}, 2, 'replacement body notifies connection again');

my $ok = eval { $response->stream_body; 1 };
ok(!$ok, 'scalar body and stream body are mutually exclusive');
like($@, qr/scalar body/, 'scalar-versus-stream error is clear');

$connection = T::BodyConnection->new;
$response = Linux::Event::HTTP::Response->_new_bound($connection, $request);

my ($drains, $cancels) = (0, 0);
my $stream;
$stream = $response->stream_body(
    on_drain => sub ($body) {
        ++$drains;
        is(refaddr($body), refaddr($stream), 'on_drain receives the same body stream');
    },
    on_cancel => sub ($body) {
        ++$cancels;
    },
);

is(refaddr($response->stream_body), refaddr($stream),
    'argumentless stream_body returns the same stream object');

$ok = eval { $response->stream_body(on_cancel => sub {}); 1 };
ok(!$ok, 'stream callbacks can only be configured on first stream_body call');
like($@, qr/only be supplied when the stream is created/,
    'stream reconfiguration rejection is clear');

$ok = eval { $response->body('nope'); 1 };
ok(!$ok, 'stream body and scalar body are mutually exclusive');
like($@, qr/streaming body/, 'stream-versus-scalar error is clear');

$connection->{next_write} = 0;
ok(!$stream->write('abc'), 'stream write preserves downstream false backpressure return');
is_deeply(
    $connection->{writes}[0],
    [ 'abc', 0, 'stream_body->write' ],
    'stream write delegates body bytes without owning a second queue',
);

$stream->_drain;
is($drains, 1, 'on_drain fires after a blocked stream is drained');
$stream->_drain;
is($drains, 1, 'drain callback does not repeat without another blocked write');

$connection->{next_write} = 1;
$stream->write('def');
$stream->complete('ghi');
ok($stream->is_complete, 'stream reports producer completion');
ok(!$stream->is_cancelled, 'completed stream is not cancelled');
is_deeply(
    $connection->{writes}[-1],
    [ 'ghi', 1, 'stream_body->complete' ],
    'stream completion delegates optional final bytes',
);

$ok = eval { $stream->write('late'); 1 };
ok(!$ok, 'write after stream completion is rejected');
like($@, qr/already complete/, 'post-completion write rejection is clear');

$connection = T::BodyConnection->new;
$response = Linux::Event::HTTP::Response->_new_bound($connection, $request);
my $cancelled = $response->stream_body(
    on_cancel => sub ($body) { ++$cancels },
);
$response->_cancel_stream_body;
ok($cancelled->is_cancelled, 'connection cancellation marks stream cancelled');
is($cancels, 1, 'on_cancel fires once');
$response->_cancel_stream_body;
is($cancels, 1, 'repeated cancellation is idempotent');

$ok = eval { $cancelled->complete; 1 };
ok(!$ok, 'cancelled stream cannot complete');
like($@, qr/cancelled/, 'cancelled stream completion rejection is clear');

done_testing;
