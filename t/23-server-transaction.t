use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::Response;
use Linux::Event::HTTP::Server::Connection;
use Linux::Event::HTTP::Transaction;

{
    package T::ServerTransactionConnection;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $request, $response) {
        my $transaction = $self->{_http_active_transaction};
        $self->data->{transaction} = $transaction;
        $self->data->{request} = $request;
        $self->data->{response_object} = $response;
        $self->data->{request_complete_on_request}
            = $request->is_complete ? 1 : 0;
        $self->data->{transaction_state_on_request}
            = $transaction->state;
        return;
    }

    sub on_body ($self, $request, $response, $bytes) {
        $self->data->{body} .= $bytes;
        return;
    }

    sub on_request_end ($self, $request, $response) {
        $self->data->{request_complete_on_end}
            = $request->is_complete ? 1 : 0;
        $self->data->{transaction_state_on_end}
            = $self->{_http_active_transaction}->state;
        $response->body("ok\n");
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    body     => '',
    response => '',
};

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::ServerTransactionConnection',
        data  => $state,
    },
);

my $client = Linux::Event::IO::Sock::Stream->connect(
    loop => $loop,
    host => '127.0.0.1',
    port => $listener->port,
    on_ready => sub ($stream) {
        $stream->write(
            "POST /upload HTTP/1.1\r\n" .
            "Host: example.test\r\n" .
            "Content-Length: 4\r\n" .
            "Connection: close\r\n" .
            "\r\n" .
            "data"
        );
    },
    on_data => sub ($stream, $bytes) {
        $state->{response} .= $bytes;
    },
    on_eof => sub ($stream) {
        $stream->close;
        $listener->close;
        $loop->stop;
    },
    on_error => sub ($stream, $error) {
        die "server Transaction test client failed: $error\n";
    },
);

$loop->run;

isa_ok($state->{transaction}, 'Linux::Event::HTTP::Transaction');
is($state->{transaction}->request, $state->{request},
    'server Transaction owns the dispatched Request');
is($state->{transaction}->response, $state->{response_object},
    'server Transaction owns the paired Response');
is($state->{transaction_state_on_request}, 'active',
    'server Transaction is active during on_request');
ok(!$state->{request_complete_on_request},
    'bodyful Request is incomplete while only its head has been dispatched');
is($state->{body}, 'data', 'request body is delivered incrementally');
ok($state->{request_complete_on_end},
    'Request becomes complete at its actual body boundary');
is($state->{transaction_state_on_end}, 'active',
    'Transaction remains active while on_request_end configures the response');
ok($state->{transaction}->is_complete,
    'server Transaction completes after request and response complete');
like($state->{response}, qr/\r\n\r\nok\n\z/,
    'server Transaction still emits the expected response');

{
    package T::FastPathConnection;

    sub new ($class) {
        return bless {
            _http_closing            => 0,
            _http_response_state      => undef,
            _http_active_transaction => undef,
            _http_active_request     => undef,
            _http_active_response    => undef,
            _http_request_state      => undef,
            writes                   => [],
        }, $class;
    }

    sub is_closed      ($self) { 0 }
    sub is_read_paused ($self) { 0 }
    sub resume_read    ($self) { return }

    sub write ($self, $bytes) {
        push @{$self->{writes}}, $bytes;
        return 1;
    }

    sub _complete_active_transaction_state ($self) {
        my $transaction = $self->{_http_active_transaction} or return;
        $transaction->_mark_complete if !$transaction->is_terminal;
        return;
    }
}

my $request = Linux::Event::HTTP::_HTTP1->parse_request(
    "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
    0,
    100,
);
my $connection = T::FastPathConnection->new;
my $response = Linux::Event::HTTP::Response->_new_bound($connection, $request);
my $transaction = Linux::Event::HTTP::Transaction->_new(
    request    => $request,
    controller => $connection,
);
$transaction->_set_response($response);
$transaction->_activate;

$connection->{_http_active_transaction} = $transaction;
$connection->{_http_active_request} = $request;
$connection->{_http_active_response} = $response;
$connection->{_http_request_state} = { body_done => 1 };

ok($response->_try_native_default_final($connection, 'hello'),
    'native default final response fast path remains available');
ok($transaction->is_complete,
    'native default final response completes the Transaction');
ok(!defined $connection->{_http_active_transaction},
    'native default final response clears active Transaction state');
is(
    $connection->{writes}[0],
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    'native fast path still emits the same optimized wire response',
);

done_testing;
