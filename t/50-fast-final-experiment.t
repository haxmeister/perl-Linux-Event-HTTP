use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::Net::HTTP::Server;
use Linux::Event::Net::HTTP::_Experiment::FastFinalConnection;

{
    package T::FastFinal;
    use parent 'Linux::Event::Net::HTTP::_Experiment::FastFinalConnection';

    sub on_request_final ($self, $request) {
        ++$self->data->{final_hits};
        die "fast-final boom\n" if $self->data->{final_die};
        return $self->data->{final_result};
    }

    sub on_request ($self, $request, $response) {
        my $state = $self->data;
        ++$state->{general_hits};
        if (($state->{general_mode} // '') eq 'immediate') {
            $response->end($state->{general_body});
        }
        return;
    }

    sub on_body ($self, $request, $response, $bytes) {
        ++$self->data->{body_hits};
        $self->data->{body} .= $bytes;
        return;
    }

    sub on_request_end ($self, $request, $response) {
        my $state = $self->data;
        ++$state->{request_end_hits};
        if (($state->{general_mode} // '') eq 'body') {
            $response->end('post:' . $state->{body} . "\n");
        }
        return;
    }
}

sub new_state (%extra) {
    return {
        wire => '',
        final_hits => 0,
        general_hits => 0,
        body_hits => 0,
        request_end_hits => 0,
        body => '',
        %extra,
    };
}

sub run_exchange ($request_wire, $state, $expected_wire_body = undef) {
    my $loop = Linux::Event::Loop->new;
    my $server = Linux::Event::Net::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::FastFinal',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "fast-final experiment integration test timed out\n";
        },
    );

    my $done = 0;
    my $finish = sub ($stream) {
        return if $done;
        my $head_end = index($state->{wire}, "\r\n\r\n");
        return if $head_end < 0;
        my $head_len = $head_end + 4;
        my $head = substr($state->{wire}, 0, $head_len);
        return if $head !~ /\r\nContent-Length:\s*(\d+)\r\n/i;
        my $body_len = defined($expected_wire_body) ? $expected_wire_body : 0 + $1;
        return if length($state->{wire}) < $head_len + $body_len;

        $done = 1;
        $guard->cancel;
        $stream->close;
        $server->close;
        $loop->stop;
    };

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write($request_wire);
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
            $finish->($stream);
        },
        on_eof => sub ($stream) {
            $finish->($stream);
            if (!$done) {
                die "server closed before complete fast-final response\n";
            }
        },
        on_error => sub ($stream, $error) {
            die "fast-final client failed: $error\n";
        },
    );

    $loop->run;
    ok($done, 'exchange completed');
    return $state->{wire};
}

my $state = new_state(final_result => "fast\n");
my $wire = run_exchange(
    "GET /fast HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 200 OK\r\nContent-Length: 5\r\n\r\nfast\n\z/s,
    'eligible bodyless request uses returned fast-final body',
);
is($state->{final_hits}, 1, 'fast-final callback runs once');
is($state->{general_hits}, 0, 'general on_request is skipped on fast success');
is($state->{request_end_hits}, 0, 'bodyless request-end callback is skipped on fast success');

$state = new_state(
    final_result => undef,
    general_mode => 'immediate',
    general_body => "general\n",
);
$wire = run_exchange(
    "GET /fallback HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like($wire, qr/\r\n\r\ngeneral\n\z/s, 'undef falls through to ordinary on_request path');
is($state->{final_hits}, 1, 'fast callback runs before undef fallback');
is($state->{general_hits}, 1, 'ordinary on_request handles undef fallback');

$state = new_state(final_result => 'head-body');
$wire = run_exchange(
    "HEAD /head HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
    0,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 200 OK\r\nContent-Length: 9\r\n\r\n\z/s,
    'HEAD preserves representation length through ordinary Response fallback',
);
is($state->{final_hits}, 1, 'HEAD still uses fast-final application callback');
is($state->{general_hits}, 0, 'HEAD fallback does not invoke general application callback');

$state = new_state(final_result => "old\n");
$wire = run_exchange(
    "GET /old HTTP/1.0\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.0 200 OK\r\nContent-Length: 4\r\n\r\nold\n\z/s,
    'HTTP/1.0 returned body falls back through ordinary Response serialization',
);
is($state->{final_hits}, 1, 'HTTP/1.0 invokes fast-final callback once');
is($state->{general_hits}, 0, 'HTTP/1.0 fallback does not re-run general callback');

$state = new_state(
    final_result => "must-not-run\n",
    general_mode => 'body',
);
$wire = run_exchange(
    "POST /body HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Content-Length: 4\r\n\r\n" .
        "data",
    $state,
);
like($wire, qr/\r\n\r\npost:data\n\z/s, 'body-bearing request stays on general streaming path');
is($state->{final_hits}, 0, 'fast-final callback is not invoked for request bodies');
is($state->{general_hits}, 1, 'general on_request handles body-bearing request');
is($state->{body}, 'data', 'general path receives request body bytes');
is($state->{request_end_hits}, 1, 'general path receives request-end callback');

$state = new_state(final_die => 1);
$wire = run_exchange(
    "GET /boom HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 500 [^\r\n]+\r\nContent-Length: 0\r\nConnection: close\r\n\r\n\z/s,
    'fast-final callback exception becomes protocol-safe 500',
);
is($state->{general_hits}, 0, 'exception does not fall through to general handler');

$state = new_state(final_result => "ignored\n");
$wire = run_exchange(
    "GET /expect HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Expect: nonsense\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 417 [^\r\n]+\r\nContent-Length: 0\r\nConnection: close\r\n\r\n\z/s,
    'unsupported Expect remains governed by ordinary protocol validation',
);
is($state->{final_hits}, 0, 'invalid Expect is rejected before fast-final callback');

done_testing;
