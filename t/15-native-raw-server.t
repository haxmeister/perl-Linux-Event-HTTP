use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Framer ();
use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::Server;
use Linux::Event::HTTP::Server::Connection;

{
    package T::RawHTTPConnection;
    use parent 'Linux::Event::HTTP::Server::Connection';
    use Linux::Event::Framer ();
    use Linux::Event::HTTP::_HTTP1 ();

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );

    sub can ($class, $name) {
        return undef if $name eq 'on_data';
        return $class->SUPER::can($name);
    }

    sub _http_native_request ($self, $request) {
        $self->data->{raw_request_hits}++;
        return $self->SUPER::_http_native_request($request);
    }

    sub _http_native_fallback_input ($self, $bytes) {
        $self->data->{fallback_hits}++;
        return $self->SUPER::_http_native_fallback_input($bytes);
    }

    sub on_request ($self, $request, $response) {
        my $state = $self->data;
        push @{$state->{paths}}, $request->target;
        $response->header('Content-Type', 'text/plain');
        $response->body(
            $request->target eq '/upload' ? 'POST'
            : $request->target eq '/after' ? 'AFTER'
            : 'RAW'
        );
        return;
    }

    sub on_body ($self, $request, $response, $bytes) {
        $self->data->{body} .= $bytes;
        return;
    }
}

subtest 'raw native head parsing shares the current request lifecycle' => sub {
    my $loop = Linux::Event::Loop->new;
    my $state = {
        wire => '',
        body => '',
        paths => [],
        raw_request_hits => 0,
        fallback_hits => 0,
    };
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::RawHTTPConnection',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "raw HTTP integration test timed out\n";
        },
    );

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write(
                "POST /upload HTTP/1.1\r\n" .
                "Host: example.test\r\n" .
                "Content-Length: 4\r\n\r\n" .
                "DATA" .
                "GET /after HTTP/1.1\r\n" .
                "Host: example.test\r\n\r\n"
            );
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
            my $responses = () = $state->{wire} =~ /HTTP\/1\.1 200 OK/g;
            if ($responses >= 2 && !$state->{sent_third}) {
                $state->{sent_third} = 1;
                $stream->write(
                    "GET /raw-again HTTP/1.1\r\n" .
                    "Host: example.test\r\n\r\n"
                );
            }
            if ($responses >= 3) {
                $guard->cancel;
                $stream->close;
                $server->close;
                $loop->stop;
            }
        },
        on_error => sub ($stream, $error) {
            die "raw HTTP client failed: $error\n";
        },
    );

    $loop->run;

    is($state->{body}, 'DATA',
        'body bytes return to the existing request-body state machine');
    is_deeply(
        $state->{paths},
        [ '/upload', '/after', '/raw-again' ],
        'request ordering survives body fallback and returns to native parsing',
    );
    cmp_ok($state->{raw_request_hits}, '>=', 2,
        'raw provider parsed request heads before and after body fallback');
    cmp_ok($state->{fallback_hits}, '>=', 1,
        'body-bearing request exercised native-to-Perl fallback');
    is(
        scalar(() = $state->{wire} =~ /HTTP\/1\.1 200 OK/g),
        3,
        'all three responses completed on one persistent connection',
    );
};

{
    package T::RawCloseConnection;
    use parent 'Linux::Event::HTTP::Server::Connection';
    use Linux::Event::Framer ();
    use Linux::Event::HTTP::_HTTP1 ();

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::HTTP::_HTTP1->_raw_consumer_definition,
    );

    sub can ($class, $name) {
        return undef if $name eq 'on_data';
        return $class->SUPER::can($name);
    }

    sub _http_native_request ($self, $request) {
        $self->data->{raw_request_hits}++;
        return $self->SUPER::_http_native_request($request);
    }

    sub on_request ($self, $request, $response) {
        $self->data->{callback_hits}++;
        $self->close;
        return;
    }
}

subtest 'reentrant close is safe inside raw-provider application callback' => sub {
    my $loop = Linux::Event::Loop->new;
    my $state = { raw_request_hits => 0, callback_hits => 0 };
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::RawCloseConnection',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "raw reentrant-close test timed out\n";
        },
    );

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write(
                "GET /close HTTP/1.1\r\nHost: example.test\r\n\r\n"
            );
        },
        on_data => sub ($stream, $bytes) {
            return;
        },
        on_eof => sub ($stream) {
            $guard->cancel;
            $stream->close;
            $server->close;
            $loop->stop;
        },
        on_error => sub ($stream, $error) {
            die "raw close client failed: $error\n";
        },
    );

    $loop->run;

    is($state->{raw_request_hits}, 1,
        'request entered through the raw native provider');
    is($state->{callback_hits}, 1,
        'application callback closed the Stream reentrantly');
};

done_testing;
