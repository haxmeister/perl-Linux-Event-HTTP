package Linux::Event::HTTP::Client;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed refaddr weaken);
use URI ();

use Linux::Event::HTTP::Client::Connection;
use Linux::Event::HTTP::Request;

our $VERSION = '0.001';

my %CALLBACK = map { $_ => 1 } qw(
    on_response on_body on_complete on_error on_informational
);

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
    my $tls = exists($option{tls})
        ? _validate_tls_options(delete $option{tls})
        : {};

    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    return bless {
        loop             => $loop,
        connection_class => $connection_class,
        connect_timeout  => $connect_timeout,
        tls              => $tls,
        idle             => {},
        connections      => {},
        closed           => 0,
    }, $class;
}

sub loop             ($self) { $self->{loop} }
sub connection_class ($self) { $self->{connection_class} }
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

sub request ($self, $method, $url, %option) {
    croak 'request(): Client is closed' if $self->{closed};
    croak 'request(): method is required'
        if !defined($method) || ref($method) || $method eq '';

    my $destination = _parse_url($url);
    my $headers = _copy_headers(delete $option{headers});
    my $version = delete($option{version}) // '1.1';
    my $has_body = exists $option{body};
    my $body = delete $option{body};

    my %callback;
    for my $name (keys %CALLBACK) {
        next if !exists $option{$name};
        my $value = delete $option{$name};
        croak "request(): $name must be a coderef"
            if defined($value) && ref($value) ne 'CODE';
        $callback{$name} = $value if defined $value;
    }

    croak 'request(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    my @host = grep {
        defined($_->[0]) && !ref($_->[0]) && lc($_->[0]) eq 'host'
    } @$headers;
    push @$headers, [ Host => $destination->{host_header} ] if !@host;

    my %request = (
        method  => $method,
        target  => $destination->{target},
        version => $version,
        headers => $headers,
    );
    $request{body} = $body if $has_body;
    my $message = Linux::Event::HTTP::Request->new(%request);

    my $connection = $self->_connection_for($destination);
    my %connection_callback;

    for my $name (qw(on_response on_body on_informational)) {
        my $user = $callback{$name} or next;
        $connection_callback{$name} = sub (@args) {
            $user->(@args);
            return;
        };
    }

    my $user_complete = $callback{on_complete};
    $connection_callback{on_complete} = sub ($transaction) {
        $self->_release_connection(
            $destination->{origin}, $connection,
        );
        $user_complete->($transaction) if $user_complete;
        return;
    };

    my $user_error = $callback{on_error};
    $connection_callback{on_error} = sub ($transaction, $error) {
        $user_error->($transaction, $error) if $user_error;
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

    return $transaction;
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

    use Linux::Event::HTTP::Client;

    my $client = Linux::Event::HTTP::Client->new(loop => $loop);

    my $tx = $client->get(
        'http://example.com/items?limit=10',
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

C<Linux::Event::HTTP::Client> is the ordinary high-level entry point for
outbound HTTP exchanges. It owns destination parsing, connection creation, and a
small bounded reuse policy while L<Linux::Event::HTTP::Client::Connection> owns
HTTP/1 wire execution.

Client methods return L<Linux::Event::HTTP::Transaction>. The Transaction owns
the canonical Request and eventual Response messages. A Request remains an HTTP
message with a request-target; the full URL belongs to Client destination
policy and is not stored on the Request merely to make connection management
convenient.

Response bodies remain incremental-first. The Client does not implicitly buffer
whole responses. Supply C<on_body> to consume bytes; otherwise body bytes are
drained and discarded. A bounded buffered convenience may be layered on this
primitive later.

The current reuse policy keeps at most one idle connection per origin. If that
connection is busy, a concurrent request creates another connection. When
multiple concurrent connections later become idle for the same origin, one is
kept and the extra connection is closed. HTTP/1 pipelining is not used.

Redirects, proxy policy, cookies, authentication helpers, and buffered-body
conveniences are intentionally not part of this first Client layer.

=head1 CONSTRUCTION

    my $client = Linux::Event::HTTP::Client->new(
        loop => $loop,
        connect_timeout => 10,
        tls => {
            verify => 1,
            ca_file => '/etc/ssl/certs/custom.pem',
        },
    );

C<loop> is required. C<connect_timeout> is passed to Linux::Event outbound
connection acquisition. C<tls> accepts client verification/CA and handshake or
shutdown timeout policy. HTTPS always offers only C<http/1.1> through ALPN in
this implementation.

C<connection_class> may name a subclass of
L<Linux::Event::HTTP::Client::Connection> for reusable stream tuning, socket
policy, or specialized connection behavior.

=head1 METHODS

=head2 request

    my $tx = $client->request(
        'POST',
        'https://example.com/api/items',
        headers => [
            [ 'Content-Type', 'application/json' ],
        ],
        body => $json,
        on_response => sub ($tx, $res) { ... },
        on_body => sub ($tx, $res, $bytes) { ... },
        on_complete => sub ($tx) { ... },
        on_error => sub ($tx, $error) { ... },
    );

Builds the canonical Request, obtains or creates a connection for the URL
origin, starts one Transaction, and returns it immediately.

Only absolute C<http> and C<https> URLs are accepted. URL fragments are not sent.
The request-target is origin-form path plus query, defaulting to C</>. For
HTTP/1.1 a Host field is synthesized from the URL when the caller did not supply
one. Non-default ports are included in the synthesized Host value.

C<headers> is an array reference of C<[name, value]> pairs so order and repeated
fields are preserved. C<body> is a complete scalar byte body. The response
callbacks have the same signatures as Client::Connection C<request>.

=head2 get, head, post, put, delete

Convenience forms that call C<request> with the corresponding HTTP method and
otherwise accept the same options.

=head2 loop

Returns the Linux::Event Loop used for outbound connections.

=head2 connection_class

Returns the configured low-level HTTP client Connection class.

=head2 is_closed

True after C<close> has been called.

=head2 close

Closes all currently reachable idle or active client connections and prevents
new requests. Returns the Client.

=head1 HTTPS

HTTPS uses the same Client::Connection class and HTTP message model. Client
creates a normal Linux::Event TLS transport with the URL host as the TLS server
name and C<http/1.1> as the only offered ALPN protocol. TLS remains transport
policy rather than an HTTP class hierarchy.

=head1 SEE ALSO

L<Linux::Event::HTTP::Client::Connection>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Response>, L<Linux::Event::HTTP::Transaction>.

=cut
