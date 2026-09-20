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

    sub _http_native_content_length_body ($self, $bytes, $done) {
        $self->data->{native_body_hits}++;
        return $self->SUPER::_http_native_content_length_body($bytes, $done);
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
        native_body_hits => 0,
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
        'Content-Length body bytes reach the existing on_body lifecycle');
    is_deeply(
        $state->{paths},
        [ '/upload', '/after', '/raw-again' ],
        'request ordering survives direct body delivery and remains native',
    );
    is($state->{raw_request_hits}, 3,
        'all request heads, including the same-read pipelined head, parse natively');
    cmp_ok($state->{native_body_hits}, '>=', 1,
        'Content-Length body used direct raw-provider body delivery');
    is($state->{fallback_hits}, 0,
        'Content-Length body does not enter the generic Perl input fallback');
    is(
        scalar(() = $state->{wire} =~ /HTTP\/1\.1 200 OK/g),
        3,
        'all three responses completed on one persistent connection',
    );
};

{
    package T::RawDrainConnection;
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

    sub _http_native_content_length_complete ($self) {
        $self->data->{native_complete_hits}++;
        return $self->SUPER::_http_native_content_length_complete;
    }

    sub on_request ($self, $request, $response) {
        push @{$self->data->{paths}}, $request->target;
        return;
    }

    sub on_request_end ($self, $request, $response) {
        $response->body($request->target eq '/drain' ? 'DRAIN' : 'NEXT');
        return;
    }
}

subtest 'raw Content-Length drain stays native through a pipelined next head' => sub {
    my $loop = Linux::Event::Loop->new;
    my $state = {
        wire => '',
        paths => [],
        raw_request_hits => 0,
        fallback_hits => 0,
        native_complete_hits => 0,
    };
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::RawDrainConnection',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "raw Content-Length drain test timed out\n";
        },
    );

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write(
                "POST /drain HTTP/1.1\r\n" .
                "Host: example.test\r\n" .
                "Content-Length: 4\r\n\r\n" .
                "DATA" .
                "GET /next HTTP/1.1\r\n" .
                "Host: example.test\r\n\r\n"
            );
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
            my $responses = () = $state->{wire} =~ /HTTP\/1\.1 200 OK/g;
            if ($responses >= 2) {
                $guard->cancel;
                $stream->close;
                $server->close;
                $loop->stop;
            }
        },
        on_error => sub ($stream, $error) {
            die "raw Content-Length drain client failed: $error\n";
        },
    );

    $loop->run;

    is_deeply($state->{paths}, [ '/drain', '/next' ],
        'drained body boundary preserves the pipelined next request');
    is($state->{raw_request_hits}, 2,
        'both request heads are parsed through the raw provider');
    is($state->{native_complete_hits}, 1,
        'drained Content-Length body notifies Perl only at completion');
    is($state->{fallback_hits}, 0,
        'drained Content-Length body never enters generic fallback');
};

subtest 'chunked bodies deliberately retain the generic fallback' => sub {
    my $loop = Linux::Event::Loop->new;
    my $state = {
        wire => '',
        body => '',
        paths => [],
        raw_request_hits => 0,
        fallback_hits => 0,
        native_body_hits => 0,
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
            die "raw chunked fallback test timed out\n";
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
                "Transfer-Encoding: chunked\r\n\r\n" .
                "4\r\nDATA\r\n0\r\n\r\n"
            );
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
            if ($state->{wire} =~ /HTTP\/1\.1 200 OK/) {
                $guard->cancel;
                $stream->close;
                $server->close;
                $loop->stop;
            }
        },
        on_error => sub ($stream, $error) {
            die "raw chunked fallback client failed: $error\n";
        },
    );

    $loop->run;

    is($state->{body}, 'DATA', 'chunked body still reaches on_body');
    cmp_ok($state->{fallback_hits}, '>=', 1,
        'chunked request exercises the generic fallback');
    is($state->{native_body_hits}, 0,
        'chunked request does not use the Content-Length direct path');
};

{
    package T::RawBodyCloseConnection;
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

    sub on_request ($self, $request, $response) {
        return;
    }

    sub on_body ($self, $request, $response, $bytes) {
        $self->data->{body_hits}++;
        $self->close;
        return;
    }
}

subtest 'reentrant close is safe inside direct raw Content-Length on_body' => sub {
    my $loop = Linux::Event::Loop->new;
    my $state = { body_hits => 0 };
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::RawBodyCloseConnection',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "raw body reentrant-close test timed out\n";
        },
    );

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write(
                "POST /close-body HTTP/1.1\r\n" .
                "Host: example.test\r\n" .
                "Content-Length: 4\r\n\r\nDATA"
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
            die "raw body close client failed: $error\n";
        },
    );

    $loop->run;
    is($state->{body_hits}, 1,
        'direct raw Content-Length body callback closed the Stream once');
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
