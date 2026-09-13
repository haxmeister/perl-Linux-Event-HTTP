package Linux::Event::HTTP::Client;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed refaddr weaken);
use URI ();

use Linux::Event::HTTP::Client::Connection;
use Linux::Event::HTTP::Client::Operation;
use Linux::Event::HTTP::Request;

our $VERSION = '0.001';

my %CALLBACK = map { $_ => 1 } qw(
    on_response on_body on_complete on_error on_informational on_redirect
);

my %REDIRECT_STATUS = map { $_ => 1 } qw(301 302 303 307 308);

sub _load_connection_class ($class) {
    croak 'new(): connection_class must be a package name'
        if !defined($class) || ref($class)
        || $class !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    if (!$class->can('connect')) {
        (my $file = "$class.pm") =~ s{::}{/}g;
        require $file;
    }

    croak 'new(): connection_class must inherit Linux::Event::HTTP::Client::Connection'
        if !$class->isa('Linux::Event::HTTP::Client::Connection');
    return $class;
}

sub _validate_tls_options ($option) {
    croak 'new(): tls must be a hash reference'
        if ref($option) ne 'HASH';
    my %known = map { $_ => 1 } qw(
        verify ca_file ca_path handshake_timeout shutdown_timeout
    );
    my @unknown = grep { !$known{$_} } keys %$option;
    croak 'new(): tls has unknown options: ' . join(', ', sort @unknown)
        if @unknown;
    return { %$option };
}

sub _validate_max_redirects ($value, $where) {
    croak "$where: max_redirects must be a non-negative integer"
        if !defined($value) || ref($value) || "$value" !~ /\A[0-9]+\z/;
    return 0 + $value;
}

sub new ($class, %option) {
    my $loop = delete $option{loop}
        // croak 'new(): loop is required';
    croak 'new(): loop must be an object implementing add() and watch_fd()'
        if !blessed($loop) || !$loop->can('add') || !$loop->can('watch_fd');

    my $connection_class = _load_connection_class(
        delete($option{connection_class})
            // 'Linux::Event::HTTP::Client::Connection',
    );
    my $connect_timeout = delete $option{connect_timeout};
    my $max_redirects = _validate_max_redirects(
        exists($option{max_redirects}) ? delete($option{max_redirects}) : 5,
        'new()',
    );
    my $tls = exists($option{tls})
        ? _validate_tls_options(delete $option{tls})
        : {};

    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    return bless {
        loop             => $loop,
        connection_class => $connection_class,
        connect_timeout  => $connect_timeout,
        max_redirects    => $max_redirects,
        tls              => $tls,
        idle             => {},
        connections      => {},
        closed           => 0,
    }, $class;
}

sub loop             ($self) { $self->{loop} }
sub connection_class ($self) { $self->{connection_class} }
sub max_redirects    ($self) { $self->{max_redirects} }
sub is_closed        ($self) { !!$self->{closed} }

sub _parse_url ($url) {
    croak 'request(): URL must be a scalar' if !defined($url) || ref($url);

    my $uri = eval { URI->new("$url") };
    croak "request(): invalid URL: $@" if !$uri;

    my $scheme = lc($uri->scheme // '');
    croak 'request(): URL scheme must be http or https'
        if $scheme ne 'http' && $scheme ne 'https';

    my $host = $uri->host;
    croak 'request(): URL must contain a host'
        if !defined($host) || $host eq '';
    croak 'request(): URL userinfo is not supported; use explicit authentication policy'
        if defined($uri->userinfo) && length($uri->userinfo);

    my $port = eval { $uri->port };
    croak "request(): invalid URL port: $@" if !defined($port) || $@;
    croak 'request(): URL port must be between 1 and 65535'
        if $port !~ /\A[0-9]+\z/ || $port < 1 || $port > 65_535;

    my $target = $uri->path_query;
    $target = '/' if !defined($target) || $target eq '';

    my $default_port = $scheme eq 'https' ? 443 : 80;
    my $authority_host = $host =~ /:/ ? "[$host]" : $host;
    my $host_header = $authority_host;
    $host_header .= ":$port" if $port != $default_port;

    my $origin = join("\0", $scheme, lc($host), $port);
    return {
        scheme      => $scheme,
        host        => $host,
        port        => 0 + $port,
        target      => "$target",
        host_header => $host_header,
        origin      => $origin,
    };
}

sub _copy_headers ($headers) {
    return [] if !defined $headers;
    croak 'request(): headers must be an array reference of [name, value] pairs'
        if ref($headers) ne 'ARRAY';

    my @copy;
    for my $pair (@$headers) {
        croak 'request(): each header must be a [name, value] pair'
            if ref($pair) ne 'ARRAY' || @$pair != 2;
        push @copy, [ $pair->[0], $pair->[1] ];
    }
    return \@copy;
}

sub _validate_buffer_body ($value) {
    croak 'request(): buffer_body must be a positive integer byte limit'
        if !defined($value) || ref($value) || "$value" !~ /\A[0-9]+\z/;
    croak 'request(): buffer_body must be greater than zero'
        if "$value" !~ /[1-9]/;
    return "$value";
}

sub _validate_stream_body ($value) {
    croak 'request(): stream_body must be a hash reference'
        if ref($value) ne 'HASH';
    my $copy = { %$value };
    require Linux::Event::HTTP::Body::Stream;
    Linux::Event::HTTP::Body::Stream->_validate_options('request', %$copy);
    return $copy;
}

sub _track_connection ($self, $connection) {
    my $id = refaddr($connection);
    $self->{connections}{$id} = $connection;
    weaken($self->{connections}{$id});
    return $connection;
}

sub _take_idle_connection ($self, $origin) {
    my $connection = delete $self->{idle}{$origin};
    return undef if !$connection;
    return undef if $connection->is_closed;
    return undef if defined $connection->transaction;
    return $connection;
}

sub _new_connection ($self, $destination) {
    my %connect = (
        loop => $self->{loop},
        host => $destination->{host},
        port => $destination->{port},
    );
    $connect{timeout} = $self->{connect_timeout}
        if defined $self->{connect_timeout};

    if ($destination->{scheme} eq 'https') {
        require Linux::Event::TLS;
        $connect{transport} = Linux::Event::TLS->client(
            server_name => $destination->{host},
            alpn        => ['http/1.1'],
            %{$self->{tls}},
        );
    }

    my $connection = $self->{connection_class}->connect(%connect);
    return $self->_track_connection($connection);
}

sub _connection_for ($self, $destination) {
    return $self->_take_idle_connection($destination->{origin})
        // $self->_new_connection($destination);
}

sub _release_connection ($self, $origin, $connection) {
    return if $self->{closed};
    return if !$connection || $connection->is_closed;
    return if defined $connection->transaction;

    if (my $idle = $self->{idle}{$origin}) {
        if (!$idle->is_closed && refaddr($idle) != refaddr($connection)) {
            $connection->close;
            return;
        }
    }

    $self->{idle}{$origin} = $connection;
    return;
}

sub _resolve_redirect_url ($current_url, $location) {
    my $base = URI->new("$current_url");
    my $reference = URI->new("$location");
    my $inherit_fragment = !defined($reference->fragment)
        ? $base->fragment : undef;

    my $next = URI->new_abs($reference, $base);
    $next->fragment($inherit_fragment) if defined $inherit_fragment;
    return $next->as_string;
}

sub _redirect_headers ($headers, $drop_body, $cross_origin) {
    my @next;

    for my $pair (@$headers) {
        my ($name, $value) = @$pair;
        my $lower = defined($name) && !ref($name) ? lc($name) : '';

        next if $lower eq 'host';
        next if $lower eq 'connection';
        next if $lower eq 'keep-alive';
        next if $lower eq 'proxy-connection';
        next if $lower eq 'proxy-authorization';
        next if $lower eq 'te';
        next if $lower eq 'trailer';
        next if $lower eq 'transfer-encoding';
        next if $lower eq 'upgrade';
        next if $lower eq 'content-length';

        if ($cross_origin) {
            next if $lower eq 'authorization';
            next if $lower eq 'cookie';
        }

        if ($drop_body) {
            next if $lower eq 'expect';
            next if $lower =~ /\Acontent-/;
        }

        push @next, [ $name, $value ];
    }

    return \@next;
}

sub _redirect_plan ($self, $operation, $spec, $destination, $response) {
    my $status = $response->status;
    return undef if !$REDIRECT_STATUS{$status};

    return undef if $spec->{max_redirects} == 0;

    my @location = $response->header_values('Location');
    return undef if !@location;
    return {
        error => 'redirect response contains multiple Location fields',
    } if @location != 1;
    return {
        error => 'maximum redirect count exceeded',
    } if $operation->redirect_count >= $spec->{max_redirects};

    my ($next_url, $next_destination);
    my $ok = eval {
        $next_url = _resolve_redirect_url($spec->{url}, $location[0]);
        $next_destination = _parse_url($next_url);
        1;
    };
    if (!$ok) {
        my $error = "$@";
        $error =~ s/\s+\z//;
        return {
            error => "invalid redirect Location: $error",
        };
    }

    my $method = $spec->{method};
    my $drop_body = 0;

    if ($status == 303) {
        $method = uc($method) eq 'HEAD' ? 'HEAD' : 'GET';
        $drop_body = 1;
    } elsif (($status == 301 || $status == 302)
        && uc($method) eq 'POST') {
        $method = 'GET';
        $drop_body = 1;
    }

    if (!$drop_body && $spec->{has_stream_body}) {
        return {
            error => "cannot automatically follow $status redirect for a streaming Request body because the producer is not replayable",
        };
    }

    my $headers = _redirect_headers(
        $spec->{headers},
        $drop_body,
        $destination->{origin} ne $next_destination->{origin},
    );

    my %next = (
        url             => $next_url,
        method          => $method,
        headers         => $headers,
        version         => $spec->{version},
        has_body        => 0,
        body            => undef,
        has_stream_body => 0,
        stream_body     => undef,
        has_buffer_body => $spec->{has_buffer_body},
        buffer_body     => $spec->{buffer_body},
        max_redirects   => $spec->{max_redirects},
        callback        => $spec->{callback},
    );

    if (!$drop_body && $spec->{has_body}) {
        $next{has_body} = 1;
        $next{body} = $spec->{body};
    }

    return {
        url  => $next_url,
        spec => \%next,
    };
}

sub _start_operation_hop ($self, $operation, $spec) {
    die 'cannot start another HTTP hop for a terminal Client operation'
        if $operation->is_terminal;

    my $destination = _parse_url($spec->{url});
    my $headers = _copy_headers($spec->{headers});

    my @host = grep {
        defined($_->[0]) && !ref($_->[0]) && lc($_->[0]) eq 'host'
    } @$headers;
    push @$headers, [ Host => $destination->{host_header} ] if !@host;

    my %request = (
        method  => $spec->{method},
        target  => $destination->{target},
        version => $spec->{version},
        headers => $headers,
    );
    $request{body} = $spec->{body} if $spec->{has_body};
    my $message = Linux::Event::HTTP::Request->new(%request);

    my $connection = $self->_connection_for($destination);
    my $callback = $spec->{callback};
    my $redirect;

    my %connection_callback;
    $connection_callback{on_response} = sub ($transaction, $response) {
        $redirect = $self->_redirect_plan(
            $operation, $spec, $destination, $response,
        );

        if (!$redirect && $callback->{on_response}) {
            $callback->{on_response}->($transaction, $response);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
        }
        return;
    };

    if ($callback->{on_body}) {
        $connection_callback{on_body} = sub ($transaction, $response, $bytes) {
            return if $redirect;
            $callback->{on_body}->($transaction, $response, $bytes);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
            return;
        };
    }

    if ($callback->{on_informational}) {
        $connection_callback{on_informational} = sub ($transaction, $response) {
            $callback->{on_informational}->($transaction, $response);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
            return;
        };
    }

    $connection_callback{stream_body} = $spec->{stream_body}
        if $spec->{has_stream_body};
    $connection_callback{buffer_body} = $spec->{buffer_body}
        if $spec->{has_buffer_body};

    $connection_callback{on_complete} = sub ($transaction) {
        $self->_release_connection(
            $destination->{origin}, $connection,
        );

        if ($redirect) {
            if (defined $redirect->{error}) {
                my $error = $redirect->{error};
                $operation->_fail($error) if !$operation->is_terminal;
                $callback->{on_error}->($transaction, $error)
                    if $callback->{on_error};
                return;
            }

            if (my $on_redirect = $callback->{on_redirect}) {
                $on_redirect->(
                    $operation,
                    $transaction,
                    $transaction->response,
                    $redirect->{url},
                );
                return if $operation->is_terminal;
            }

            my $ok = eval {
                $self->_start_operation_hop(
                    $operation, $redirect->{spec},
                );
                1;
            };
            if (!$ok) {
                my $error = "$@";
                $error =~ s/\s+\z//;
                $operation->_fail($error) if !$operation->is_terminal;
                $callback->{on_error}->($transaction, $error)
                    if $callback->{on_error};
            }
            return;
        }

        $operation->_mark_complete if !$operation->is_terminal;
        $callback->{on_complete}->($transaction)
            if $callback->{on_complete};
        return;
    };

    $connection_callback{on_error} = sub ($transaction, $error) {
        $operation->_fail($error) if !$operation->is_terminal;
        $callback->{on_error}->($transaction, $error)
            if $callback->{on_error};
        return;
    };

    my $transaction;
    my $ok = eval {
        $transaction = $connection->request(
            $message, %connection_callback,
        );
        1;
    };
    if (!$ok) {
        my $error = $@;
        $self->_release_connection(
            $destination->{origin}, $connection,
        ) if !$connection->is_closed && !defined($connection->transaction);
        die $error;
    }

    $operation->_append_transaction($transaction, $spec->{url});
    return $transaction;
}

sub request ($self, $method, $url, %option) {
    croak 'request(): Client is closed' if $self->{closed};
    croak 'request(): method is required'
        if !defined($method) || ref($method) || $method eq '';

    _parse_url($url);

    my $headers = _copy_headers(delete $option{headers});
    my $version = delete($option{version}) // '1.1';
    my $has_body = exists $option{body};
    my $body = delete $option{body};
    my $has_stream_body = exists $option{stream_body};
    my $stream_body = $has_stream_body
        ? _validate_stream_body(delete $option{stream_body})
        : undef;
    my $has_buffer_body = exists $option{buffer_body};
    my $buffer_body = $has_buffer_body
        ? _validate_buffer_body(delete $option{buffer_body})
        : undef;
    my $max_redirects = _validate_max_redirects(
        exists($option{max_redirects})
            ? delete($option{max_redirects})
            : $self->{max_redirects},
        'request()',
    );

    croak 'request(): body and stream_body are mutually exclusive'
        if $has_body && $has_stream_body;

    my %callback;
    for my $name (keys %CALLBACK) {
        next if !exists $option{$name};
        my $value = delete $option{$name};
        croak "request(): $name must be a coderef"
            if defined($value) && ref($value) ne 'CODE';
        $callback{$name} = $value if defined $value;
    }

    croak 'request(): buffer_body cannot be combined with on_body'
        if $has_buffer_body && $callback{on_body};
    croak 'request(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    my $operation = Linux::Event::HTTP::Client::Operation->_new(
        initial_url   => "$url",
        max_redirects => $max_redirects,
    );

    my $spec = {
        url             => "$url",
        method          => $method,
        headers         => $headers,
        version         => $version,
        has_body        => $has_body ? 1 : 0,
        body            => $body,
        has_stream_body => $has_stream_body ? 1 : 0,
        stream_body     => $stream_body,
        has_buffer_body => $has_buffer_body ? 1 : 0,
        buffer_body     => $buffer_body,
        max_redirects   => $max_redirects,
        callback        => \%callback,
    };

    $self->_start_operation_hop($operation, $spec);
    return $operation;
}

sub get ($self, $url, %option) {
    return $self->request('GET', $url, %option);
}

sub head ($self, $url, %option) {
    return $self->request('HEAD', $url, %option);
}

sub post ($self, $url, %option) {
    return $self->request('POST', $url, %option);
}

sub put ($self, $url, %option) {
    return $self->request('PUT', $url, %option);
}

sub delete ($self, $url, %option) {
    return $self->request('DELETE', $url, %option);
}

sub close ($self) {
    return $self if $self->{closed};
    $self->{closed} = 1;

    my %closed;
    for my $connection (values %{$self->{idle}}, values %{$self->{connections}}) {
        next if !$connection;
        my $id = refaddr($connection);
        next if $closed{$id}++;
        $connection->close if !$connection->is_closed;
    }

    $self->{idle} = {};
    $self->{connections} = {};
    return $self;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Client - asynchronous HTTP client

=head1 SYNOPSIS

    my $client = Linux::Event::HTTP::Client->new(
        loop => $loop,
        max_redirects => 5,
    );

    my $operation = $client->get(
        'https://example.com/start',
        on_redirect => sub ($op, $tx, $res, $next_url) {
            say "redirecting to $next_url";
        },
        on_complete => sub ($tx) {
            say $tx->response->status;
        },
        on_error => sub ($tx, $error) {
            warn $error;
        },
    );

=head1 DESCRIPTION

C<Linux::Event::HTTP::Client> is the high-level outbound HTTP entry point. It
owns URL parsing, destination selection, redirect policy, connection creation,
HTTPS transport policy, and a small bounded reuse policy.

Client methods return L<Linux::Event::HTTP::Client::Operation>. A client
operation normally contains one L<Linux::Event::HTTP::Transaction>, but each
followed redirect creates another Transaction because a Transaction always
represents exactly one Request/Response exchange.

Outgoing Request bodies may be complete scalar bodies or explicit streaming
producers owned by Transaction. Incoming Response handling remains
incremental-first. C<on_body> consumes body chunks. Without C<on_body>, body
bytes are drained and discarded. Explicit C<buffer_body =E<gt> $max_bytes>
requests bounded whole-body buffering; there is no implicit unbounded buffering.

=head1 METHODS

=head2 request

    my $operation = $client->request(
        'POST',
        'https://example.com/api/items',
        body => $bytes,
        max_redirects => 5,
        on_redirect => sub ($op, $tx, $res, $next_url) { ... },
        on_response => sub ($tx, $res) { ... },
        on_complete => sub ($tx) { ... },
        on_error => sub ($tx, $error) { ... },
    );

Builds the canonical Request for each hop, obtains or creates a connection for
the corresponding URL origin, and starts the operation immediately. Only
absolute C<http> and C<https> URLs are accepted. The URL path/query becomes the
Request target and Host is synthesized when absent.

Callbacks C<on_response>, C<on_body>, and C<on_complete> describe the final
response. Intermediate redirect response bodies are consumed according to the
normal HTTP framing rules but are not delivered through C<on_body>.
C<on_redirect> runs after an intermediate redirect Transaction completes and
before the next hop starts:

    on_redirect => sub ($operation, $tx, $res, $next_url) {
        ...
    }

C<on_informational> remains per-Transaction and can therefore run on any hop.

=head2 redirect policy

C<max_redirects> is a non-negative integer and defaults to 5. It can be set on
the Client or overridden per request. Zero disables automatic redirect
following and exposes a 3xx response as the final response without interpreting
its Location fields as redirect instructions.

Automatic redirects recognize 301, 302, 303, 307, and 308 when exactly one
Location field is present. Relative Location values are resolved against the
current absolute URL.

For compatibility with prevailing HTTP user-agent behavior, 301 and 302 change
POST to GET and discard the request body. 303 uses GET, or HEAD when the
original method was HEAD, and discards the body. 307 and 308 preserve the
method and body.

A complete scalar Request body can be replayed for a method-preserving
redirect. A streaming Request body is intentionally not replayed automatically
because a producer is not inherently rewindable. A method-preserving redirect
for a streaming Request therefore terminates the Client operation with a clear
error. Redirects that change POST to GET can proceed because the subsequent
request has no body.

Redirect hops regenerate Host and HTTP message-framing fields. Cross-origin
redirects also remove Authorization and Cookie. Proxy-Authorization and
connection-specific fields are never propagated automatically.

=head2 request bodies

C<body> supplies a complete scalar Request body. C<stream_body =E<gt> { ... }>
selects incremental body production instead; the two are mutually exclusive.
The producer remains owned by the current Transaction and is conveniently
available from the returned operation:

    my $operation = $client->post(
        $url,
        stream_body => {
            on_drain  => sub ($body) { ... },
            on_cancel => sub ($body) { ... },
        },
    );

    my $body = $operation->request_body;
    $body->write($bytes);
    $body->complete;

A supplied Content-Length is enforced exactly; otherwise HTTP/1.1 uses chunked
transfer coding automatically. HTTP/1.0 streaming requires Content-Length.

=head2 buffer_body

C<buffer_body =E<gt> $max_bytes> must be a positive integer byte limit and
cannot be combined with C<on_body>. The limit counts the same body bytes that
C<on_body> would receive after HTTP/1 chunk framing has been removed. On
redirect hops the same bound applies while the intermediate response is drained;
the final completed body is available through C<< $operation->response->body >>.

A limit failure is a terminal Client operation error and closes the affected
HTTP/1 connection.

=head2 get, head, post, put, delete

Convenience forms that call C<request> with the corresponding HTTP method.

=head2 loop

Returns the Linux::Event Loop.

=head2 connection_class

Returns the configured Client::Connection class.

=head2 max_redirects

Returns the Client default redirect limit.

=head2 is_closed

True after C<close>.

=head2 close

Closes all reachable idle or active client connections and prevents new
requests. Returns the Client.

=head1 CONNECTION REUSE

At most one idle connection is retained per origin. A concurrent request may
open another connection rather than queueing or using HTTP/1 pipelining. When
multiple connections later become idle, one is retained and extras are closed.

Each redirect hop independently selects a connection for its target origin.

=head1 HTTPS

HTTPS uses the same Client::Connection class with a Linux::Event TLS transport,
the URL host as the TLS server name, and C<http/1.1> as the offered ALPN
protocol.

=head1 SEE ALSO

L<Linux::Event::HTTP::Client::Operation>,
L<Linux::Event::HTTP::Client::Connection>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::HTTP::Transaction>,
L<Linux::Event::HTTP::Body::Stream>.

=cut
