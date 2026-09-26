use v5.36;
use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Linux::Event::HTTP::_HTTP2::Native;
        Linux::Event::HTTP::_HTTP2::Native->available;
        1;
    } or plan skip_all => 'native libnghttp2 bridge is not built';
}

use Linux::Event::HTTP::_HTTP1;
use Linux::Event::HTTP::_HTTP2::NativeConnection;
use Linux::Event::HTTP::_HTTP2::Client;
use Linux::Event::HTTP::_HTTP2::Server;
use Linux::Event::HTTP::Request;
use Linux::Event::Framer ();
use Linux::Event::IO::Sock::Listener;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

{
    package T::ErrorSource;
    use parent 'Linux::Event::IO::Sock::Stream';
    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__, Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );
}

my $native = 'Linux::Event::HTTP::_HTTP2::Native';
my $target = 'Linux::Event::HTTP::_HTTP2::NativeConnection';
my $loop = Linux::Event::Loop->new;
my (@accepted, @sessions, @errors);
my ($bad_closed, $good_complete, $body) = (0, 0, '');
my $client;
my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop, after => 5,
    on_timer => sub ($timer) { die "native input isolation test timed out\n" },
);
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop, host => '127.0.0.1', port => 0,
    stream => {
        class => 'T::ErrorSource',
        on_ready => sub ($stream) {
            push @accepted, $stream;
            my $executor = Linux::Event::HTTP::_HTTP2::Server->new(
                stream => $stream, autostart => 0, _session_class => $native,
                on_request => sub ($h2, $req, $res) { $res->body('still alive') },
            );
            $stream->{_http2_executor} = $executor;
            $stream->{_http2_native_session} = $executor->session;
            push @sessions, $executor->session;
            $stream->transition_to($target);
            $executor->start;
        },
        on_close => sub ($stream) {
            my $executor = delete $stream->{_http2_executor};
            $executor->close if $executor;
            delete $stream->{_http2_native_session};
        },
    },
);

my $bad = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop, host => '127.0.0.1', port => $listener->port,
    on_ready => sub ($stream) { $stream->write('not an HTTP/2 preface' x 2) },
    on_data => sub ($stream, $bytes) { },
    on_eof => sub ($stream) {
        ++$bad_closed;
        $stream->close;
        # A fresh, valid exchange on the same listener must still succeed.
        $client = T::ErrorSource->connect(
            loop => $loop, host => '127.0.0.1', port => $listener->port,
            on_ready => sub ($good) {
                my $executor = Linux::Event::HTTP::_HTTP2::Client->new(
                    stream => $good, autostart => 0, _session_class => $native,
                );
                $good->{_http2_executor} = $executor;
                $good->{_http2_native_session} = $executor->session;
                push @sessions, $executor->session;
                $good->transition_to($target);
                $executor->start;
                $executor->request(
                    Linux::Event::HTTP::Request->new(
                        method => 'GET', target => '/', version => '2',
                        scheme => 'http', authority => 'isolation.test',
                    ),
                    on_body => sub ($tx, $res, $bytes) { $body .= $bytes },
                    on_complete => sub ($tx) {
                        ++$good_complete;
                        $good->close;
                        $loop->stop;
                    },
                    on_error => sub ($tx, $error) { push @errors, "$error" },
                );
            },
        );
    },
);

my $ok = eval { $loop->run; 1 };
my $error = $@;
$guard->cancel;
$bad->close if !$bad->is_closed;
$client->close if $client && !$client->is_closed;
$_->close for @accepted;
$listener->close;

ok($ok, 'malformed native input does not throw out of the event loop') or diag $error;
is($bad_closed, 1, 'only the malformed connection is closed');
is($good_complete, 1, 'listener serves a subsequent valid native H2 request');
is($body, 'still alive', 'valid response arrives after malformed peer');
is_deeply(\@errors, [], 'valid exchange has no errors');
ok($_->is_closed, 'retained native session closes with its executor') for @sessions;
done_testing;
