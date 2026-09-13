package Linux::Event::HTTP::Client;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed refaddr weaken);
use URI ();
use HTTP::CookieJar 0.014 ();

use Linux::Event::HTTP::Client::Connection;
use Linux::Event::HTTP::Client::Operation;
use Linux::Event::HTTP::Request;

our $VERSION = '0.001';

my %CALLBACK = map { $_ => 1 } qw(
    on_response on_body on_complete on_error on_informational on_redirect
    on_upgrade on_tunnel
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
    my $absolute_target = "$scheme://$host_header$target";

    my $origin = join("\0", $scheme, lc($host), $port);
    return {
        scheme          => $scheme,
        host            => $host,
        port            => 0 + $port,
        target          => "$target",
        absolute_target => $absolute_target,
        host_header     => $host_header,
        origin          => $origin,
    };
}

sub _parse_proxy_url ($url, $where = 'request()') {
    croak "$where: proxy must be a non-empty scalar URL"
        if !defined($url) || ref($url) || $url eq '';

    my $destination;
    my $ok = eval {
        $destination = _parse_url($url);
        1;
    };
    if (!$ok) {
        my $error = "$@";
        $error =~ s/\Arequest\(\)/$where/;
        die $error;
    }

    croak "$where: proxy URL must not contain a path or query"
        if $destination->{target} ne '/';
    return $destination;
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
    my $proxy_url = exists($option{proxy})
        ? delete($option{proxy})
        : undef;
    _parse_proxy_url($proxy_url, 'new()') if defined $proxy_url;

    my $cookie_jar = exists($option{cookie_jar})
        ? delete($option{cookie_jar})
        : undef;
    croak 'new(): cookie_jar must be an HTTP::CookieJar object'
        if defined($cookie_jar)
        && (!blessed($cookie_jar) || !$cookie_jar->isa('HTTP::CookieJar'));

    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    return bless {
        loop             => $loop,
        connection_class => $connection_class,
        connect_timeout  => $connect_timeout,
        max_redirects    => $max_redirects,
        tls              => $tls,
        proxy_url        => defined($proxy_url) ? "$proxy_url" : undef,
        cookie_jar       => $cookie_jar,
        idle             => {},
        connections      => {},
        closed           => 0,
    }, $class;
}

sub loop             ($self) { $self->{loop} }
sub connection_class ($self) { $self->{connection_class} }
sub max_redirects    ($self) { $self->{max_redirects} }
sub proxy            ($self) { $self->{proxy_url} }
sub cookie_jar       ($self) { $self->{cookie_jar} }
sub is_closed        ($self) { !!$self->{closed} }

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

sub _redirect_headers ($headers, $drop_body, $cross_origin, $through_proxy = 0) {
    my @next;

    for my $pair (@$headers) {
        my ($name, $value) = @$pair;
        my $lower = defined($name) && !ref($name) ? lc($name) : '';

        next if $lower eq 'host';
        next if $lower eq 'connection';
        next if $lower eq 'keep-alive';
        next if $lower eq 'proxy-connection';
        next if $lower eq 'proxy-authorization' && !$through_proxy;
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
        defined($spec->{proxy_url}) ? 1 : 0,
    );

    if (defined $spec->{upgrade_to}) {
        push @$headers, [
            Upgrade => $_->[1],
        ] for grep {
            defined($_->[0]) && !ref($_->[0]) && lc($_->[0]) eq 'upgrade'
        } @{$spec->{headers}};
        push @$headers, [ Connection => 'Upgrade' ];
    }

    my %next = (
        url             => $next_url,
        proxy_url       => $spec->{proxy_url},
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
        upgrade_to      => $spec->{upgrade_to},
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
    my $proxy = defined($spec->{proxy_url})
        ? _parse_proxy_url($spec->{proxy_url})
        : undef;
    my $route = $proxy // $destination;
    my $headers = _copy_headers($spec->{headers});
    my $cookie_url = $destination->{absolute_target};

    if (my $jar = $self->{cookie_jar}) {
        my $cookie = $jar->cookie_header($cookie_url);
        push @$headers, [ Cookie => $cookie ]
            if defined($cookie) && length($cookie);
    }

    if ($proxy) {
        @$headers = grep {
            !defined($_->[0]) || ref($_->[0]) || lc($_->[0]) ne 'host'
        } @$headers;
        push @$headers, [ Host => $destination->{host_header} ];
    } else {
        my @host = grep {
            defined($_->[0]) && !ref($_->[0]) && lc($_->[0]) eq 'host'
        } @$headers;
        push @$headers, [ Host => $destination->{host_header} ] if !@host;
    }

    my %request = (
        method  => $spec->{method},
        target  => $proxy
            ? $destination->{absolute_target}
            : $destination->{target},
        version => $spec->{version},
        headers => $headers,
    );
    $request{body} = $spec->{body} if $spec->{has_body};
    my $message = Linux::Event::HTTP::Request->new(%request);

    my $connection = $self->_connection_for($route);
    my $callback = $spec->{callback};
    my $redirect;
    my $upgraded = 0;

    my %connection_callback;
    $connection_callback{on_response} = sub ($transaction, $response) {
        if (my $jar = $self->{cookie_jar}) {
            $jar->add($cookie_url, $_)
                for $response->header_values('Set-Cookie');
        }

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

    if (defined $spec->{upgrade_to}) {
        $connection_callback{upgrade_to} = $spec->{upgrade_to};
        $connection_callback{on_upgrade} = sub ($transaction, $response, $upgraded_connection) {
            $upgraded = 1;
            $operation->_mark_complete if !$operation->is_terminal;
            $callback->{on_upgrade}->(
                $operation,
                $transaction,
                $response,
                $upgraded_connection,
            ) if $callback->{on_upgrade};
            return;
        };
    }

    $connection_callback{on_complete} = sub ($transaction) {
        if ($upgraded) {
            $callback->{on_complete}->($transaction)
                if $callback->{on_complete};
            return;
        }

        $self->_release_connection(
            $route->{origin}, $connection,
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
            $route->{origin}, $connection,
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

    my $proxy_url = exists($option{proxy})
        ? delete($option{proxy})
        : $self->{proxy_url};
    _parse_proxy_url($proxy_url) if defined $proxy_url;
    croak 'request(): proxy cannot be used with CONNECT; use connect_tunnel()'
        if defined($proxy_url) && uc($method) eq 'CONNECT';

    my $headers = _copy_headers(delete $option{headers});
    if ($self->{cookie_jar}) {
        for my $pair (@$headers) {
            next if !defined($pair->[0]) || ref($pair->[0]);
            croak 'request(): Cookie header is managed by cookie_jar; add cookies to the jar instead'
                if lc($pair->[0]) eq 'cookie';
        }
    }

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
    my $upgrade_to = exists($option{upgrade_to})
        ? delete($option{upgrade_to})
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
    croak 'request(): on_upgrade requires upgrade_to'
        if $callback{on_upgrade} && !defined($upgrade_to);
    croak 'request(): upgrade_to cannot be combined with buffer_body'
        if defined($upgrade_to) && $has_buffer_body;
    croak 'request(): upgrade_to cannot be combined with on_body'
        if defined($upgrade_to) && $callback{on_body};
    croak 'request(): on_tunnel is only valid with connect_tunnel()'
        if $callback{on_tunnel};
    croak 'request(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    my $operation = Linux::Event::HTTP::Client::Operation->_new(
        initial_url   => "$url",
        max_redirects => $max_redirects,
    );

    my $spec = {
        url             => "$url",
        proxy_url       => defined($proxy_url) ? "$proxy_url" : undef,
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
        upgrade_to      => $upgrade_to,
        callback        => \%callback,
    };

    $self->_start_operation_hop($operation, $spec);
    return $operation;
}

sub connect_tunnel ($self, $proxy_url, $target_authority, %option) {
    croak 'connect_tunnel(): Client is closed' if $self->{closed};
    croak 'connect_tunnel(): target authority is required'
        if !defined($target_authority) || ref($target_authority)
        || $target_authority eq '';

    my $destination = _parse_url($proxy_url);
    croak 'connect_tunnel(): proxy URL must not contain a path or query'
        if $destination->{target} ne '/';

    my $headers = _copy_headers(delete $option{headers});
    my @host = grep {
        defined($_->[0]) && !ref($_->[0]) && lc($_->[0]) eq 'host'
    } @$headers;
    push @$headers, [ Host => "$target_authority" ] if !@host;

    my $tunnel_to = delete($option{tunnel_to})
        // croak 'connect_tunnel(): tunnel_to is required';
    my $has_buffer_body = exists $option{buffer_body};
    my $buffer_body = $has_buffer_body
        ? _validate_buffer_body(delete $option{buffer_body})
        : undef;

    my %callback;
    my %known_callback = map { $_ => 1 } qw(
        on_response on_body on_complete on_error on_informational on_tunnel
    );
    for my $name (keys %known_callback) {
        next if !exists $option{$name};
        my $value = delete $option{$name};
        croak "connect_tunnel(): $name must be a coderef"
            if defined($value) && ref($value) ne 'CODE';
        $callback{$name} = $value if defined $value;
    }

    croak 'connect_tunnel(): buffer_body cannot be combined with on_body'
        if $has_buffer_body && $callback{on_body};
    croak 'connect_tunnel(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    my $operation = Linux::Event::HTTP::Client::Operation->_new(
        initial_url   => "$proxy_url",
        max_redirects => 0,
    );
    my $message = Linux::Event::HTTP::Request->new(
        method  => 'CONNECT',
        target  => "$target_authority",
        version => '1.1',
        headers => $headers,
    );
    my $connection = $self->_connection_for($destination);
    my $tunneled = 0;

    my %connection_callback = (
        tunnel_to => $tunnel_to,
    );
    $connection_callback{buffer_body} = $buffer_body
        if $has_buffer_body;

    $connection_callback{on_response} = sub ($transaction, $response) {
        if ($callback{on_response}) {
            $callback{on_response}->($transaction, $response);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
        }
        return;
    };

    if ($callback{on_body}) {
        $connection_callback{on_body} = sub ($transaction, $response, $bytes) {
            $callback{on_body}->($transaction, $response, $bytes);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
            return;
        };
    }

    if ($callback{on_informational}) {
        $connection_callback{on_informational} = sub ($transaction, $response) {
            $callback{on_informational}->($transaction, $response);
            $operation->_mark_cancelled
                if $transaction->is_cancelled && !$operation->is_terminal;
            return;
        };
    }

    $connection_callback{on_tunnel} = sub ($transaction, $response, $tunnel_connection) {
        $tunneled = 1;
        $operation->_mark_complete if !$operation->is_terminal;
        $callback{on_tunnel}->(
            $operation,
            $transaction,
            $response,
            $tunnel_connection,
        ) if $callback{on_tunnel};
        return;
    };

    $connection_callback{on_complete} = sub ($transaction) {
        if (!$tunneled) {
            $self->_release_connection(
                $destination->{origin}, $connection,
            );
            $operation->_mark_complete if !$operation->is_terminal;
        }
        $callback{on_complete}->($transaction)
            if $callback{on_complete};
        return;
    };

    $connection_callback{on_error} = sub ($transaction, $error) {
        $operation->_fail($error) if !$operation->is_terminal;
        $callback{on_error}->($transaction, $error)
            if $callback{on_error};
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

    $operation->_append_transaction($transaction, "$proxy_url");
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

    use HTTP::CookieJar;

    my $jar = HTTP::CookieJar->new;

    my $client = Linux::Event::HTTP::Client->new(
        loop => $loop,
        max_redirects => 5,
        proxy => 'http://proxy.example:3128',
        cookie_jar => $jar,
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
HTTPS transport policy, explicit forward-proxy routing, optional cookie-jar
integration, and a small bounded reuse policy.

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
        on_response => sub ($tx, $res) { ... },
        on_complete => sub ($tx) { ... },
        on_error => sub ($tx, $error) { ... },
    );

Builds the canonical Request for each hop and starts the operation immediately.
Only absolute C<http> and C<https> target URLs are accepted.

Without a selected proxy, the Client obtains or creates a connection for the
target URL origin and sends the path/query in origin-form. If the Client was
constructed with C<proxy =E<gt> $proxy_url>, that route is used by default.
A per-request C<proxy =E<gt> $other_proxy> overrides the Client default, while
C<proxy =E<gt> undef> explicitly bypasses it for that operation.

With a selected proxy, the Client connects to the explicit C<http> or C<https>
proxy endpoint and sends the target URL in HTTP/1 absolute-form. Host remains
the target Host. Target identity and route identity remain separate.

Callbacks C<on_response>, C<on_body>, and C<on_complete> describe the final
response. Intermediate redirect response bodies are consumed according to the
normal HTTP framing rules but are not delivered through C<on_body>.
C<on_redirect> runs after an intermediate redirect Transaction completes and
before the next hop starts.

=head2 cookie_jar

    my $jar = HTTP::CookieJar->new;
    my $client = Linux::Event::HTTP::Client->new(
        loop => $loop,
        cookie_jar => $jar,
    );

C<cookie_jar> is an optional injected L<HTTP::CookieJar>. The Client does not
create a jar implicitly. This keeps cookie storage lifetime, sharing, loading,
and persistence under application control.

Before each ordinary Request hop, the Client asks the jar for
C<cookie_header($target_url)> and synthesizes the Cookie field when one is
returned. Every Set-Cookie field on an ordinary final or redirect Response is
fed to C<add($target_url, $set_cookie)> before redirect policy or application
response callbacks run.

Cookie URL identity is always the target URL. A selected forward proxy never
becomes the cookie origin merely because the transport connection is made to
the proxy. Redirect hops ask the jar again for the new target URL, leaving
HTTP::CookieJar to enforce domain, path, expiry, and Secure rules.

When C<cookie_jar> is configured, caller-supplied Cookie fields are rejected so
there is a single owner of cookie selection. Seed or override cookie state
through the jar itself. C<connect_tunnel> does not consult the jar because its
HTTP exchange is with the explicitly named proxy endpoint rather than an
ordinary target resource request.

The C<cookie_jar> accessor returns the configured jar object or undef.

=head2 connect_tunnel

C<connect_tunnel($proxy_url, $target_authority, ...)> establishes one explicit
HTTP/1.1 CONNECT tunnel through the named proxy endpoint. The Client-level
default proxy and cookie jar are not consulted for tunnel routing or cookies.
A successful 2xx response transitions the same live Linux::Event stream to the
required C<tunnel_to> class. Non-2xx responses remain ordinary HTTP.

=head2 redirect policy

C<max_redirects> is a non-negative integer and defaults to 5. It can be set on
the Client or overridden per request. Zero disables automatic redirect
following. Automatic redirects recognize 301, 302, 303, 307, and 308 when
exactly one Location field is present.

301 and 302 change POST to GET and discard the body. 303 uses GET, or HEAD when
the original method was HEAD, and discards the body. 307 and 308 preserve the
method and body. Complete scalar bodies can be replayed for method-preserving
redirects; streaming bodies are not replayed automatically.

Authorization and caller-managed Cookie fields are stripped on cross-origin
redirects. With C<cookie_jar>, Cookie is regenerated independently for every
hop from the new target URL, so cookie domain/path/security policy belongs to
HTTP::CookieJar rather than redirect-header copying.

=head2 request bodies

C<body> supplies a complete scalar Request body. C<stream_body =E<gt> { ... }>
selects incremental body production instead; the two are mutually exclusive.
The producer belongs to the current Transaction and is available through the
returned operation.

A supplied Content-Length is enforced exactly; otherwise HTTP/1.1 uses chunked
transfer coding automatically. HTTP/1.0 streaming requires Content-Length.

=head2 client Upgrade

C<upgrade_to =E<gt> $class> requests a live HTTP/1.1 protocol handoff through
the low-level Client::Connection. On a validated 101 response, the HTTP
Transaction completes and the same live stream transitions to C<$class>.

=head2 buffer_body

C<buffer_body =E<gt> $max_bytes> requests bounded whole-response buffering and
cannot be combined with C<on_body>. The limit applies after HTTP transfer
framing has been removed and also applies while redirect bodies are consumed.

=head2 get, head, post, put, delete

Convenience forms that call C<request> with the corresponding HTTP method.

=head2 loop

Returns the Linux::Event Loop.

=head2 connection_class

Returns the configured Client::Connection class.

=head2 max_redirects

Returns the Client default redirect limit.

=head2 proxy

Returns the configured Client default forward-proxy URL, or undef when there is
no default proxy. An individual operation may override or bypass the default.

=head2 is_closed

True after C<close>.

=head2 close

Closes all reachable idle or active client connections and prevents new
requests. Returns the Client.

=head1 CONNECTION REUSE

At most one idle connection is retained per route origin. For direct requests,
the route origin is the target origin. For a request using a proxy route, the
route origin is the proxy endpoint, so sequential requests for different target
origins can reuse the same persistent proxy connection. Cookie selection does
not use route origin.

A connection that successfully leaves HTTP through Upgrade or CONNECT is never
returned to the HTTP idle pool. A non-2xx CONNECT response remains HTTP and may
leave a reusable proxy connection when its normal response framing permits it.

=head1 HTTPS

HTTPS uses the same Client::Connection class with a Linux::Event TLS transport.
For a direct HTTPS request, TLS is established to the target URL host. For an
C<https> forward-proxy endpoint, TLS is established to the proxy and the target
URI is then sent in absolute-form. Secure-cookie selection still uses the target
URL supplied to HTTP::CookieJar, not the proxy transport scheme.

=head1 SEE ALSO

L<HTTP::CookieJar>, L<Linux::Event::HTTP::Client::Operation>,
L<Linux::Event::HTTP::Client::Connection>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::HTTP::Transaction>,
L<Linux::Event::HTTP::Body::Stream>.

=cut
