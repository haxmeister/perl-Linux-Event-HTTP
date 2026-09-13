package Linux::Event::HTTP::Client::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';

use Carp qw(croak);
use Config ();
use Scalar::Util qw(blessed refaddr);
use utf8 ();

use Linux::Event::HTTP::_HTTP1 ();
use Linux::Event::HTTP::Request;
use Linux::Event::HTTP::Response;
use Linux::Event::HTTP::Transaction;

our $VERSION = '0.001';

my $CHUNKED = 'Linux::Event::HTTP::_HTTP1::Chunked';
my $MAX_RESPONSE_HEAD = 65_536;
my $MAX_HEADERS = 100;
my $MAX_CONTENT_LENGTH = $Config::Config{ivsize} >= 8
    ? '9223372036854775807'
    : '2147483647';

my %RESERVED_CALLBACK = map { $_ => 1 } qw(
    on_data on_eof on_error on_close on_message on_messages
);

sub _reject_reserved_callbacks ($operation, $option) {
    my @reserved = grep { exists $option->{$_} } sort keys %RESERVED_CALLBACK;
    croak "$operation(): HTTP Client::Connection owns callbacks: "
        . join(', ', @reserved)
        if @reserved;
    return;
}

sub _init_http_client ($self) {
    $self->{_http_client_input} = '';
    $self->{_http_client_active_transaction} = undef;
    $self->{_http_client_callbacks} = undef;
    $self->{_http_client_response_state} = undef;
    $self->{_http_client_driving} = 0;
    $self->{_http_client_reusable} = 1;
    return $self;
}

sub new ($class, %option) {
    _reject_reserved_callbacks('new', \%option);
    my $self = $class->SUPER::new(%option);
    return $self->_init_http_client;
}

sub connect ($class, %option) {
    croak 'connect(): must be called as a class method' if ref $class;
    _reject_reserved_callbacks('connect', \%option);
    my $self = $class->SUPER::connect(%option);
    return $self->_init_http_client;
}

sub transaction ($self) {
    return $self->{_http_client_active_transaction};
}

sub _byte_string ($operation, $value) {
    croak "$operation(): value must be a scalar byte string" if ref $value;
    my $bytes = defined($value) ? "$value" : '';
    if (utf8::is_utf8($bytes)) {
        croak "$operation(): value contains wide characters; encode it to bytes first"
            if !utf8::downgrade($bytes, 1);
    }
    return $bytes;
}

sub _buffer_limit ($value) {
    croak 'request(): buffer_body must be a positive integer byte limit'
        if !defined($value) || ref($value) || "$value" !~ /\A[0-9]+\z/;

    my $digits = "$value";
    $digits =~ s/\A0+(?=\d)//;
    croak 'request(): buffer_body must be greater than zero'
        if $digits eq '0';
    croak 'request(): buffer_body exceeds supported range'
        if length($digits) > length($MAX_CONTENT_LENGTH)
        || (length($digits) == length($MAX_CONTENT_LENGTH)
            && $digits gt $MAX_CONTENT_LENGTH);
    return 0 + $digits;
}

sub _serialize_request_head ($request) {
    my $version = $request->version;
    croak "request(): HTTP/1 client supports version 1.0 or 1.1, not $version"
        if $version ne '1.0' && $version ne '1.1';

    my $method = _byte_string('request method', $request->method);
    my $target = _byte_string('request target', $request->target);
    my $head = "$method $target HTTP/$version\r\n";

    for my $index (0 .. $request->header_count - 1) {
        my $name = _byte_string('request header name', $request->header_name($index));
        my $value = _byte_string('request header value', $request->header_value($index));
        croak 'request(): invalid header field name'
            if $name !~ /\A[!#\$%&'*+\-.^_`|~0-9A-Za-z]+\z/;
        croak 'request(): header field value contains invalid control characters'
            if $value =~ /[\x00-\x08\x0a-\x1f\x7f]/;
        $head .= "$name: $value\r\n";
    }

    $head .= "\r\n";
    return $head;
}

sub _prepare_request ($request) {
    croak 'request(): requires a Linux::Event::HTTP::Request'
        if !blessed($request)
        || !$request->isa('Linux::Event::HTTP::Request');

    my $version = $request->version;
    croak "request(): HTTP/1 client supports version 1.0 or 1.1, not $version"
        if $version ne '1.0' && $version ne '1.1';
    croak 'request(): CONNECT tunneling is not implemented yet'
        if uc($request->method) eq 'CONNECT';

    my @host = $request->header_values('Host');
    croak 'request(): HTTP/1.1 requires exactly one Host field'
        if $version eq '1.1' && @host != 1;
    croak 'request(): multiple Host fields are not allowed'
        if @host > 1;

    my @transfer = $request->header_values('Transfer-Encoding');
    croak 'request(): streaming/Transfer-Encoding request bodies are not implemented yet'
        if @transfer;

    my $body = $request->body;
    my $length = $request->content_length;

    if (defined $body) {
        my $body_length = length($body);
        if (defined $length) {
            croak 'request(): Content-Length does not match scalar body length'
                if $length != $body_length;
        } else {
            $request->header('Content-Length', $body_length);
        }
    } elsif (defined($length) && $length != 0) {
        croak 'request(): non-zero Content-Length requires a scalar body in this client stage';
    }

    my $head = _serialize_request_head($request);
    return ($head, $body // '');
}

sub request ($self, $request, %option) {
    croak 'request(): connection is closed' if $self->is_closed;
    croak 'request(): connection is not reusable' if !$self->{_http_client_reusable};
    croak 'request(): another Transaction is already active on this connection'
        if $self->{_http_client_active_transaction};

    my $buffer_limit;
    if (exists $option{buffer_body}) {
        $buffer_limit = _buffer_limit(delete $option{buffer_body});
    }

    my %callback;
    my %known = map { $_ => 1 } qw(
        on_response on_body on_complete on_error on_informational
    );
    my @unknown = grep { !$known{$_} } keys %option;
    croak 'request(): unknown options: ' . join(', ', sort @unknown)
        if @unknown;

    for my $name (keys %option) {
        my $value = $option{$name};
        croak "request(): $name must be a coderef"
            if defined($value) && ref($value) ne 'CODE';
        $callback{$name} = $value if defined $value;
    }

    croak 'request(): buffer_body cannot be combined with on_body'
        if defined($buffer_limit) && $callback{on_body};
    $callback{buffer_body} = $buffer_limit if defined $buffer_limit;

    my ($head, $body) = _prepare_request($request);
    $request->_mark_committed;

    my $transaction = Linux::Event::HTTP::Transaction->_new(
        request    => $request,
        controller => $self,
    );
    $transaction->_activate;

    $self->{_http_client_active_transaction} = $transaction;
    $self->{_http_client_callbacks} = \%callback;
    $self->{_http_client_response_state} = undef;

    my $wire = $head . $body;
    my $written = eval {
        $self->write($wire);
        1;
    };
    if (!$written) {
        my $error = "$@";
        $self->_fail_active_transaction($error || 'request write failed', 1);
        croak $error || 'request(): write failed';
    }

    $self->_drive_http1 if length($self->{_http_client_input});
    return $transaction;
}

sub _parse_response_head ($buffer) {
    my $end = index($buffer, "\r\n\r\n");
    return if $end < 0;

    my $consumed = $end + 4;
    croak 'HTTP/1 response head exceeds configured limit'
        if $consumed > $MAX_RESPONSE_HEAD;

    my $head = substr($buffer, 0, $end);
    my @line = split /\r\n/, $head, -1;
    my $status_line = shift @line;

    croak 'malformed HTTP/1 response status line'
        if !defined($status_line)
        || $status_line !~ /\AHTTP\/(1\.[01]) ([0-9]{3}) (.*)\z/s;

    my ($version, $status, $reason) = ($1, 0 + $2, $3);
    my @headers;
    my $count = 0;

    for my $field (@line) {
        croak 'malformed HTTP/1 response header'
            if $field eq '' || $field =~ /\A[ \t]/;
        my ($name, $value) = $field =~ /\A([^:]+):(.*)\z/s;
        croak 'malformed HTTP/1 response header' if !defined $name;
        $value =~ s/\A[ \t]+//;
        $value =~ s/[ \t]+\z//;
        push @headers, [ $name, $value ];
        ++$count;
        croak "HTTP/1 response has more than $MAX_HEADERS header fields"
            if $count > $MAX_HEADERS;
    }

    my $response = Linux::Event::HTTP::Response->new(
        status  => $status,
        reason  => $reason,
        version => $version,
        headers => \@headers,
    );
    $response->_commit;
    return ($response, $consumed);
}

sub _decimal_content_length ($value) {
    my $digits = $value;
    $digits =~ s/\A0+(?=\d)//;
    croak 'invalid or conflicting response Content-Length'
        if $digits eq '' || $digits !~ /\A[0-9]+\z/;
    croak 'response Content-Length exceeds supported range'
        if length($digits) > length($MAX_CONTENT_LENGTH)
        || (length($digits) == length($MAX_CONTENT_LENGTH)
            && $digits gt $MAX_CONTENT_LENGTH);
    return 0 + $digits;
}

sub _response_content_length ($response) {
    my @values = $response->header_values('Content-Length');
    return undef if !@values;

    my $length;
    for my $value (@values) {
        for my $member (split /,/, $value, -1) {
            $member =~ s/\A[ \t]+//;
            $member =~ s/[ \t]+\z//;
            my $parsed = _decimal_content_length($member);
            croak 'invalid or conflicting response Content-Length'
                if defined($length) && $length != $parsed;
            $length = $parsed;
        }
    }
    return $length;
}

sub _connection_tokens ($response) {
    my %token;
    for my $value ($response->header_values('Connection')) {
        for my $member (split /,/, $value, -1) {
            $member =~ s/\A[ \t]+//;
            $member =~ s/[ \t]+\z//;
            next if $member eq '';
            $token{lc $member} = 1;
        }
    }
    return \%token;
}

sub _response_keep_alive ($response) {
    my $token = _connection_tokens($response);
    return 0 if $token->{close};
    return 1 if $response->version eq '1.1';
    return $token->{'keep-alive'} ? 1 : 0;
}

sub _response_transfer_mode ($request, $response) {
    my $status = $response->status;
    my $keep_alive = _response_keep_alive($response);
    my @transfer = $response->header_values('Transfer-Encoding');
    my @length_fields = $response->header_values('Content-Length');

    if ($status >= 100 && $status < 200) {
        croak 'informational response must not contain Content-Length or Transfer-Encoding'
            if @transfer || @length_fields;
        return { mode => 'none', keep_alive => $keep_alive };
    }

    if ($status == 204) {
        croak '204 response must not contain Content-Length or Transfer-Encoding'
            if @transfer || @length_fields;
        return { mode => 'none', keep_alive => $keep_alive };
    }

    if (uc($request->method) eq 'HEAD' || $status == 304) {
        return { mode => 'none', keep_alive => $keep_alive };
    }

    if (@transfer && @length_fields) {
        croak 'response cannot contain both Transfer-Encoding and Content-Length';
    }

    if (@transfer) {
        my @coding;
        for my $value (@transfer) {
            for my $member (split /,/, $value, -1) {
                $member =~ s/\A[ \t]+//;
                $member =~ s/[ \t]+\z//;
                croak 'invalid response Transfer-Encoding' if $member eq '';
                push @coding, lc $member;
            }
        }
        croak 'unsupported response Transfer-Encoding; only chunked is currently implemented'
            if @coding != 1 || $coding[0] ne 'chunked';
        return {
            mode       => 'chunked',
            keep_alive => $keep_alive,
            decoder    => $CHUNKED->new,
        };
    }

    my $length = _response_content_length($response);
    if (defined $length) {
        return {
            mode       => 'content-length',
            keep_alive => $keep_alive,
            remaining  => $length,
        };
    }

    return {
        mode       => 'close',
        keep_alive => 0,
    };
}

sub _same_active_transaction ($self, $transaction) {
    my $active = $self->{_http_client_active_transaction};
    return $active && refaddr($active) == refaddr($transaction);
}

sub _callback ($self, $name, @args) {
    my $callback = $self->{_http_client_callbacks}{$name} or return;
    $callback->(@args);
    return;
}

sub _clear_active_transaction ($self) {
    $self->{_http_client_active_transaction} = undef;
    $self->{_http_client_callbacks} = undef;
    $self->{_http_client_response_state} = undef;
    return;
}

sub _buffer_response_chunk ($self, $chunk) {
    my $state = $self->{_http_client_response_state} or return 1;
    return 1 if !exists $state->{buffer_limit};

    my $new_length = length($state->{buffer}) + length($chunk);
    if ($new_length > $state->{buffer_limit}) {
        my $limit = $state->{buffer_limit};
        $self->_fail_active_transaction(
            "response body exceeds buffer_body limit of $limit bytes", 1,
        );
        return 0;
    }

    $state->{buffer} .= $chunk;
    return 1;
}

sub _finish_active_response ($self) {
    my $transaction = $self->{_http_client_active_transaction} or return;
    my $response = $transaction->response or return;
    my $state = $self->{_http_client_response_state}
        or croak 'response completion requires framing state';
    my $callback = $self->{_http_client_callbacks}{on_complete};
    my $keep_alive = $state->{keep_alive} ? 1 : 0;

    $response->_set_received_body($state->{buffer})
        if exists $state->{buffer_limit};
    $response->_mark_complete;
    $transaction->_mark_complete;
    $self->_clear_active_transaction;

    if (!$keep_alive) {
        $self->{_http_client_reusable} = 0;
        $self->{_http_client_input} = '';
        $self->close if !$self->is_closed;
    }

    $callback->($transaction) if $callback;
    return;
}

sub _fail_active_transaction ($self, $error, $close_connection = 1) {
    my $transaction = $self->{_http_client_active_transaction};
    return if !$transaction || $transaction->is_terminal;

    my $callback = $self->{_http_client_callbacks}{on_error};
    $transaction->_fail($error);
    $self->_clear_active_transaction;
    $self->{_http_client_reusable} = 0;
    $self->{_http_client_input} = '';

    $self->close if $close_connection && !$self->is_closed;
    $callback->($transaction, $error) if $callback;
    return;
}

sub _cancel_http_transaction ($self, $transaction) {
    return if $transaction->is_terminal;
    croak 'cancel(): Transaction is not active on this HTTP connection'
        if !$self->_same_active_transaction($transaction);

    $transaction->_mark_cancelled;
    $self->_clear_active_transaction;
    $self->{_http_client_reusable} = 0;
    $self->{_http_client_input} = '';
    $self->close if !$self->is_closed;
    return;
}

sub _consume_response_body ($self) {
    my $transaction = $self->{_http_client_active_transaction} or return 0;
    my $response = $transaction->response or return 0;
    my $state = $self->{_http_client_response_state} or return 0;

    if ($state->{mode} eq 'content-length') {
        if ($state->{remaining} == 0) {
            $self->_finish_active_response;
            return 1;
        }
        return 0 if !length($self->{_http_client_input});

        my $available = length($self->{_http_client_input});
        my $take = $available < $state->{remaining}
            ? $available : $state->{remaining};
        my $chunk = substr($self->{_http_client_input}, 0, $take, '');
        $state->{remaining} -= $take;

        if (length($chunk) && exists $state->{buffer_limit}) {
            return 1 if !$self->_buffer_response_chunk($chunk);
        }

        if (length($chunk) && $self->{_http_client_callbacks}{on_body}) {
            $self->_callback('on_body', $transaction, $response, $chunk);
            return 1 if !$self->_same_active_transaction($transaction);
        }

        $self->_finish_active_response if $state->{remaining} == 0;
        return 1;
    }

    if ($state->{mode} eq 'chunked') {
        return 0 if !length($self->{_http_client_input});

        my ($done, $decoded);
        my $emit = $self->{_http_client_callbacks}{on_body}
            || exists($state->{buffer_limit});
        my $ok = eval {
            ($done, $decoded) = $state->{decoder}->feed(
                $self->{_http_client_input}, $emit ? 1 : 0,
            );
            1;
        };
        if (!$ok) {
            my $error = "$@";
            $self->_fail_active_transaction(
                "malformed HTTP/1 chunked response body: $error", 1,
            );
            return 1;
        }

        if (defined($decoded) && length($decoded)
            && exists $state->{buffer_limit}) {
            return 1 if !$self->_buffer_response_chunk($decoded);
        }

        if (defined($decoded) && length($decoded)
            && $self->{_http_client_callbacks}{on_body}) {
            $self->_callback('on_body', $transaction, $response, $decoded);
            return 1 if !$self->_same_active_transaction($transaction);
        }

        $self->_finish_active_response if $done;
        return 1;
    }

    if ($state->{mode} eq 'close') {
        return 0 if !length($self->{_http_client_input});
        my $chunk = substr(
            $self->{_http_client_input}, 0,
            length($self->{_http_client_input}), '',
        );

        if (length($chunk) && exists $state->{buffer_limit}) {
            return 1 if !$self->_buffer_response_chunk($chunk);
        }

        if (length($chunk) && $self->{_http_client_callbacks}{on_body}) {
            $self->_callback('on_body', $transaction, $response, $chunk);
        }
        return 1;
    }

    $self->_finish_active_response;
    return 1;
}

sub _drive_http1 ($self) {
    return if $self->{_http_client_driving} || $self->is_closed;
    local $self->{_http_client_driving} = 1;

    while (!$self->is_closed) {
        my $transaction = $self->{_http_client_active_transaction} or last;

        if (!$transaction->response) {
            last if !length($self->{_http_client_input});

            my ($response, $consumed);
            my $parsed = eval {
                ($response, $consumed) = _parse_response_head(
                    $self->{_http_client_input},
                );
                1;
            };
            if (!$parsed) {
                my $error = "$@";
                $self->_fail_active_transaction($error || 'malformed HTTP/1 response', 1);
                last;
            }

            if (!defined $response) {
                if (length($self->{_http_client_input}) > $MAX_RESPONSE_HEAD) {
                    $self->_fail_active_transaction(
                        'HTTP/1 response head exceeds configured limit', 1,
                    );
                }
                last;
            }

            substr($self->{_http_client_input}, 0, $consumed, '');

            if ($response->status >= 100 && $response->status < 200) {
                if ($response->status == 101) {
                    $self->_fail_active_transaction(
                        'HTTP/1 101 Upgrade is not implemented by Client::Connection yet',
                        1,
                    );
                    last;
                }

                my $valid = eval {
                    _response_transfer_mode($transaction->request, $response);
                    1;
                };
                if (!$valid) {
                    my $error = "$@";
                    $self->_fail_active_transaction($error, 1);
                    last;
                }

                $response->_mark_complete;
                $self->_callback(
                    'on_informational', $transaction, $response,
                ) if $self->{_http_client_callbacks}{on_informational};
                next if $self->_same_active_transaction($transaction);
                last;
            }

            my $state;
            my $valid = eval {
                $state = _response_transfer_mode(
                    $transaction->request, $response,
                );
                1;
            };
            if (!$valid) {
                my $error = "$@";
                $self->_fail_active_transaction($error, 1);
                last;
            }

            my $buffer_limit = $self->{_http_client_callbacks}{buffer_body};
            if (defined $buffer_limit) {
                $state->{buffer_limit} = $buffer_limit;
                $state->{buffer} = '';
            }

            $transaction->_set_response($response);
            $self->{_http_client_response_state} = $state;

            $self->_callback('on_response', $transaction, $response)
                if $self->{_http_client_callbacks}{on_response};
            next if !$self->_same_active_transaction($transaction);

            if (exists($state->{buffer_limit})
                && $state->{mode} eq 'content-length'
                && $state->{remaining} > $state->{buffer_limit}) {
                my $limit = $state->{buffer_limit};
                $self->_fail_active_transaction(
                    "response body exceeds buffer_body limit of $limit bytes", 1,
                );
                last;
            }

            if ($state->{mode} eq 'none'
                || ($state->{mode} eq 'content-length'
                    && $state->{remaining} == 0)) {
                $self->_finish_active_response;
                next;
            }
        }

        last if !$self->{_http_client_active_transaction};
        my $progress = $self->_consume_response_body;
        last if !$progress;
    }

    return;
}

sub on_data ($self, $bytes) {
    return if $self->is_closed;
    $self->{_http_client_input} .= $bytes;
    $self->_drive_http1;
    return;
}

sub on_eof ($self) {
    my $transaction = $self->{_http_client_active_transaction};
    if ($transaction && !$transaction->is_terminal) {
        my $state = $self->{_http_client_response_state};
        if ($transaction->response && $state && $state->{mode} eq 'close') {
            $self->_consume_response_body if length($self->{_http_client_input});
            $self->_finish_active_response
                if $self->{_http_client_active_transaction};
        } else {
            $self->_fail_active_transaction(
                'unexpected EOF before HTTP response completed', 0,
            );
        }
    }

    $self->{_http_client_reusable} = 0;
    $self->close if !$self->is_closed;
    return;
}

sub on_error ($self, $error) {
    $self->_fail_active_transaction($error, 0);
    $self->{_http_client_reusable} = 0;
    return;
}

sub on_close ($self) {
    if (my $transaction = $self->{_http_client_active_transaction}) {
        $self->_fail_active_transaction(
            'HTTP connection closed before Transaction completed', 0,
        ) if !$transaction->is_terminal;
    }
    $self->{_http_client_reusable} = 0;
    return;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Client::Connection - one HTTP/1 client connection

=head1 SYNOPSIS

    use Linux::Event::HTTP::Client::Connection;
    use Linux::Event::HTTP::Request;

    my $conn = Linux::Event::HTTP::Client::Connection->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => 8080,
    );

    my $tx = $conn->request(
        Linux::Event::HTTP::Request->new(
            method => 'GET',
            target => '/',
            headers => [ [ Host => 'example.test' ] ],
        ),
        on_response => sub ($tx, $res) {
            say $res->status;
        },
        on_body => sub ($tx, $res, $bytes) {
            process_bytes($bytes);
        },
        on_complete => sub ($tx) {
            say 'done';
        },
        on_error => sub ($tx, $error) {
            warn $error;
        },
    );

=head1 DESCRIPTION

C<Linux::Event::HTTP::Client::Connection> is the low-level HTTP/1 execution
object for one persistent Linux::Event stream socket. URL parsing, destination
selection, connection pooling, redirects, and higher-level convenience belong
above this class.

The connection executes one L<Linux::Event::HTTP::Transaction> at a time. After
a persistent response completes, another Transaction may reuse the same socket.
HTTP/1 client pipelining is deliberately not enabled.

Response bodies are incremental-first. C<on_body> receives delivered body bytes;
when it is absent, body bytes are drained and discarded rather than accumulated
implicitly into the Response object. Explicit C<buffer_body> requests bounded
whole-body accumulation using the same framing/consumption path.

Outgoing streaming request bodies, CONNECT tunnels, and client Upgrade handoff
remain later layers.

=head1 METHODS

=head2 connect

Uses the normal L<Linux::Event::IO::Sock::Stream> asynchronous C<connect>
contract. Requests may be submitted before transport readiness because
Linux::Event already queues pre-connect output in order.

The HTTP implementation owns C<on_data>, C<on_eof>, C<on_error>, and C<on_close>.
Per-Transaction response callbacks belong to C<request>.

=head2 transaction

Returns the currently active Transaction, or undef when the connection is idle.

=head2 request

    my $tx = $conn->request($request,
        buffer_body      => 1_048_576,
        on_response      => sub ($tx, $res) { ... },
        on_complete      => sub ($tx) {
            my $bytes = $tx->response->body;
            ...;
        },
        on_error         => sub ($tx, $error) { ... },
        on_informational => sub ($tx, $res) { ... },
    );

Starts one exchange and returns its Transaction immediately. Only one
Transaction may be active on this connection at a time.

For HTTP/1.1, the Request must contain exactly one Host field. A complete scalar
body automatically gains Content-Length when it was not already supplied. An
explicit Content-Length must match the scalar body. Transfer-Encoding request
bodies are not implemented in this stage.

C<on_response> runs once after the final response head is validated and before
body delivery. C<on_informational> receives 1xx responses such as 100 Continue;
101 Upgrade is not yet supported. C<on_body> receives decoded Content-Length,
chunked, or close-delimited body bytes. C<on_complete> runs after the complete
message boundary. C<on_error> reports terminal protocol or transport failure.

C<buffer_body =E<gt> $max_bytes> explicitly requests whole-body buffering with a
positive byte limit. It cannot be combined with C<on_body>. The limit counts the
same body bytes that C<on_body> would receive: HTTP/1 chunk framing has already
been removed. A known Content-Length above the limit fails after C<on_response>
and before body accumulation. Unknown-length/chunked bodies fail as soon as the
delivered byte count would cross the limit. Limit failure is a Transaction error
and closes the connection. On successful completion, C<< $tx->response->body >>
returns the buffered scalar, including the empty string for a bodyless response.

Cancellation closes the connection because an HTTP/1 response cannot in general
be abandoned mid-message and then safely reused without consuming its remaining
wire bytes.

=head1 RESPONSE FRAMING

The client applies HTTP/1 message framing independently from application body
handling:

=over 4

=item * HEAD, 204, and 304 responses have no delivered message body;

=item * Content-Length bodies are delivered incrementally to their exact length;

=item * HTTP/1 chunked transfer coding is decoded with the existing native
C<_HTTP1::Chunked> decoder;

=item * responses without a length or transfer coding are close-delimited and
make the connection non-reusable.

=back

There is no implicit or unbounded whole-body buffer. Explicit C<buffer_body>
uses this same framing path and enforces its configured bound.

=head1 SEE ALSO

L<Linux::Event::HTTP::Client>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::HTTP::Transaction>,
L<Linux::Event::IO::Sock::Stream>.

=cut
