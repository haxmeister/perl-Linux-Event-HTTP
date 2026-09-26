use v5.36;
use strict;
use warnings;

use Test::More;
use Scalar::Util qw(refaddr);

BEGIN {
    eval {
        require Linux::Event::HTTP::_HTTP2::Native;
        Linux::Event::HTTP::_HTTP2::Native->available;
        1;
    } or plan skip_all => 'native libnghttp2 bridge is not built';
}

use Linux::Event::HTTP::_HTTP1;
use Linux::Event::HTTP::_HTTP2::NativeConnection;
use Linux::Event::Framer ();
use Linux::Event::HTTP::Request;
use Linux::Event::HTTP::_HTTP2::Client;
use Linux::Event::HTTP::_HTTP2::Server;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

{
    package T::RawSource;
    use parent 'Linux::Event::IO::Sock::Stream';
    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__, Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );
}

{
    package T::BlockedNative;
    use parent 'Linux::Event::HTTP::_HTTP2::NativeConnection';
    our ($blocked_writes, $violations, $drains) = (0, 0, 0);

    sub write ($self, $bytes) {
        ++$violations if $self->{test_blocked};
        my $accepted = $self->SUPER::write($bytes);
        return $accepted if $self->{test_blocked};
        # Bytes are accepted by Stream; false means stop until drain, not retry.
        $self->{test_blocked} = 1;
        ++$blocked_writes;
        $self->loop->defer(sub {
            return if $self->is_closed;
            $self->{test_blocked} = 0;
            ++$drains;
            $self->{_http2_executor}->transport_drain;
        });
        return 0;
    }
}

my $native = 'Linux::Event::HTTP::_HTTP2::Native';
my $loop = Linux::Event::Loop->new;
my %server_executor;
my %server_body;
my @errors;
my $server_stream_initial;
my $server_stream_drains = 0;

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::RawSource',
        on_ready => sub ($stream) {
            my $executor;
            $executor = Linux::Event::HTTP::_HTTP2::Server->new(
                stream         => $stream,
                autostart      => 0,
                _session_class => $native,
                on_request => sub ($h2, $request, $response) {
                    my $tx = $h2->transaction;
                    my $target = $request->target;
                    $server_body{$target} //= '';

                    if ($target eq '/scalar') {
                        $response->header('x-native', 'scalar');
                        $response->body('scalar-response');
                        return;
                    }

                    if ($target eq '/post') {
                        $response->header('x-native', 'post');
                        return;
                    }

                    if ($target eq '/stream-response') {
                        $response->header('x-native', 'stream-response');
                        my $producer = $tx->response_body(
                            on_drain => sub ($body) {
                                ++$server_stream_drains;
                                $body->complete('done');
                            },
                        );
                        $server_stream_initial =
                            $producer->write('r' x 100_000) ? 1 : 0;
                        return;
                    }

                    if ($target eq '/stream-upload') {
                        $response->header('x-native', 'stream-upload');
                        return;
                    }

                    die "unexpected native executor target $target\n";
                },
                on_body => sub ($h2, $request, $response, $bytes) {
                    $server_body{$request->target} .= $bytes;
                },
                on_request_end => sub ($h2, $request, $response) {
                    if ($request->target eq '/post') {
                        $response->body(
                            'post:' . $server_body{'/post'},
                        );
                    }
                    elsif ($request->target eq '/stream-upload') {
                        $response->body(
                            'upload:' . length($server_body{'/stream-upload'}),
                        );
                    }
                },
                on_error => sub ($h2, $stream_id, $error) {
                    push @errors, "server stream $stream_id: $error";
                },
            );
            $server_executor{refaddr($stream)} = $executor;
            $stream->{_http2_executor} = $executor;
            $stream->{_http2_native_session} = $executor->session;
            $stream->transition_to('T::BlockedNative');
            $executor->start;
        },
        on_drain => sub ($stream) {
            my $executor = $server_executor{refaddr($stream)} or return;
            $executor->transport_drain;
        },
        on_error => sub ($stream, $error) {
            push @errors, "server transport: $error";
            $loop->stop;
        },
        on_close => sub ($stream) {
            my $executor = delete $server_executor{refaddr($stream)};
            $executor->close if $executor;
        },
    },
);

my $expected = 4;
my $complete = 0;
my %result;
my @transactions;
my $upload_initial;
my $upload_drains = 0;
my $client_executor;

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 10,
    on_timer => sub ($timer) {
        die "native HTTP/2 executor integration timed out\n";
    },
);

my $client_stream = T::RawSource->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $client_executor = Linux::Event::HTTP::_HTTP2::Client->new(
            stream         => $stream,
            autostart      => 0,
            _session_class => $native,
        );

        $stream->{_http2_executor} = $client_executor;
        $stream->{_http2_native_session} = $client_executor->session;
        $stream->transition_to('T::BlockedNative');
        $client_executor->start;

        my $start = sub ($target, %option) {
            my $capture = $result{$target} = {
                body => '',
            };
            my $request = Linux::Event::HTTP::Request->new(
                method    => delete($option{method}) // 'GET',
                target    => $target,
                version   => '2',
                scheme    => 'http',
                authority => 'native-executor.test',
                (exists($option{body})
                    ? (body => delete($option{body})) : ()),
            );

            my $tx = $client_executor->request(
                $request,
                (exists($option{stream_body})
                    ? (stream_body => delete($option{stream_body})) : ()),
                on_response => sub ($transaction, $response) {
                    $capture->{status} = $response->status;
                    $capture->{kind} = $response->header('x-native');
                },
                on_body => sub ($transaction, $response, $bytes) {
                    $capture->{body} .= $bytes;
                },
                on_complete => sub ($transaction) {
                    $capture->{complete} = 1;
                    ++$complete;
                    if ($complete == $expected) {
                        $guard->cancel;
                        $stream->close if !$stream->is_closed;
                        $listener->close;
                        $loop->stop;
                    }
                },
                on_error => sub ($transaction, $error) {
                    push @errors, "$target: $error";
                },
            );
            die 'unused native executor request option: '
                . join(', ', sort keys %option)
                if %option;
            push @transactions, $tx;
            return $tx;
        };

        $start->('/scalar');
        $start->(
            '/post',
            method => 'POST',
            body   => 'payload',
        );
        $start->('/stream-response');

        my $upload = $start->(
            '/stream-upload',
            method => 'POST',
            stream_body => {
                on_drain => sub ($body) {
                    ++$upload_drains;
                    $body->complete('done');
                },
            },
        );
        $upload_initial =
            $upload->request_body->write('u' x 100_000) ? 1 : 0;
    },
    on_drain => sub ($stream) {
        $client_executor->transport_drain if $client_executor;
    },
    on_error => sub ($stream, $error) {
        push @errors, "client transport: $error";
        $loop->stop;
    },
    on_close => sub ($stream) {
        $client_executor->close if $client_executor;
    },
);

$loop->run;

is_deeply(\@errors, [],
    'existing HTTP/2 executors report no native-backend errors');
is($complete, $expected,
    'all Transactions complete through native session backend');
is(scalar(@transactions), $expected,
    'native backend preserves one Transaction per H2 stream');
ok($_->is_complete,
    'native-backed executor Transaction completes independently')
    for @transactions;

is($result{'/scalar'}{status}, 200,
    'scalar request receives HTTP/2 response');
is($result{'/scalar'}{kind}, 'scalar',
    'scalar response header survives native backend');
is($result{'/scalar'}{body}, 'scalar-response',
    'scalar response body survives native backend');

is($result{'/post'}{body}, 'post:payload',
    'scalar request body reaches Server executor through native backend');

is($server_stream_initial, 0,
    'large native-backed streaming response applies backpressure');
cmp_ok($server_stream_drains, '>=', 1,
    'native-backed response data provider resumes after drain');
is(length($result{'/stream-response'}{body}), 100_004,
    'native-backed streaming response delivers all bytes');
is(substr($result{'/stream-response'}{body}, -4), 'done',
    'native-backed streaming response delivers final bytes');

is($upload_initial, 0,
    'large native-backed streaming upload applies backpressure');
cmp_ok($upload_drains, '>=', 1,
    'native-backed request data provider resumes after drain');
is($result{'/stream-upload'}{body}, 'upload:100004',
    'native-backed streaming upload reaches Server executor intact');

cmp_ok($T::BlockedNative::blocked_writes, '>', 10,
    'client and server exercise transport write backpressure repeatedly');
cmp_ok($T::BlockedNative::drains, '>', 10,
    'transport drains resume queued nghttp2 output');
is($T::BlockedNative::violations, 0,
    'no additional output is written between false write and drain');
ok(!defined($client_executor->session),
    'close inside native input callback finishes executor teardown');

$_->stream->close for values %server_executor;
done_testing;
