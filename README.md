# Linux::Event::HTTP

Linux::Event::HTTP is a native HTTP communications layer for Linux::Event.

Linux::Event owns sockets, TLS, readiness, buffering, backpressure, and ordered
byte output. Linux::Event::HTTP owns HTTP parsing, framing, persistence,
serialization, client policy, and HTTP exchange lifecycle. It is deliberately
not a web framework.

## Server

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;

my $loop = Linux::Event::Loop->new;

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,
    on_request => sub ($conn, $req, $res) {
        $res->header('Content-Type', 'text/plain');
        $res->body("hello\n");
    },
);

$loop->run;
```

The callback receives the persistent HTTP connection, one Request, and the
Response paired with that Request. The active exchange is available as
`$conn->transaction` when lifecycle or incremental-body operations are needed.

## Client

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Client;

my $loop = Linux::Event::Loop->new;
my $client = Linux::Event::HTTP::Client->new(loop => $loop);

my $operation = $client->get(
    'https://example.com/items?limit=10',
    on_response => sub ($tx, $res) {
        say $res->status;
    },
    on_body => sub ($tx, $res, $bytes) {
        process_bytes($bytes);
    },
    on_complete => sub ($tx) {
        $client->close;
        $loop->stop;
    },
    on_error => sub ($tx, $error) {
        warn $error;
        $client->close;
        $loop->stop;
    },
);

$loop->run;
```

High-level Client methods return `Linux::Event::HTTP::Client::Operation`.
An operation normally contains one `Linux::Event::HTTP::Transaction`. Every
followed redirect creates another Transaction because a Transaction always means
exactly one Request/Response exchange.

```perl
my $tx  = $operation->transaction;
my $req = $operation->request;
my $res = $operation->response;
```

Low-level `Linux::Event::HTTP::Client::Connection->request()` returns one
Transaction directly.

## Message and lifecycle model

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Request / Response = direction-neutral HTTP messages
Transaction        = exactly one Request + one Response + exchange lifecycle
Client::Operation  = one high-level client action, possibly several Transactions
Connection         = one persistent transport executing Transactions
```

A locally constructed message is mutable until protocol commit. Received message
metadata is committed/read-only. Request contains an HTTP request-target, not a
full application URL; URL and routing policy belong to the high-level Client.

## Bodies

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

Incremental server Response production belongs to Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

Incremental client Request production uses the same producer model:

```perl
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
```

Linux::Event remains the only output queue. `Body::Stream->write` follows the
Linux::Event flow-control contract:

```text
true  = bytes accepted; producer may continue
false = bytes accepted; pause until on_drain
```

Incoming bodies are incremental-first. If no consumer is installed, body bytes
are drained rather than accumulated implicitly. Small client Responses can opt
into bounded whole-body buffering:

```perl
$client->get(
    $url,
    buffer_body => 1_048_576,
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
);
```

There is no implicit unbounded whole-response buffer.

## Redirects

The Client follows 301, 302, 303, 307, and 308 by default with a limit of five
redirects. `max_redirects => 0` disables redirect interpretation.

```perl
my $operation = $client->get(
    $url,
    max_redirects => 5,
    on_redirect => sub ($op, $tx, $res, $next_url) {
        say "redirecting to $next_url";
    },
);
```

Every followed hop is a distinct Transaction retained by the Operation.
301/302 may change POST to GET, 303 uses GET except for HEAD, and 307/308 preserve
method and body. Complete scalar bodies can be replayed; streaming producers are
not assumed to be rewindable.

Cross-origin redirects remove caller-supplied `Authorization` and `Cookie`.
Connection-specific fields are regenerated rather than forwarded verbatim.

## Forward proxies

A Client can configure one explicit default forward proxy:

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop  => $loop,
    proxy => 'http://proxy.example:3128',
);

$client->get('http://origin.example/path');
```

One operation can override the Client default:

```perl
$client->get(
    'http://origin.example/path',
    proxy => 'http://other-proxy.example:3128',
);
```

Or explicitly bypass it:

```perl
$client->get(
    'http://origin.example/path',
    proxy => undef,
);
```

Direct requests use origin-form targets such as `/path?x=1`. Proxied ordinary
HTTP/1 requests use absolute-form targets such as
`http://origin.example/path?x=1`. Host is always derived from the target URL in
proxy mode.

The target origin remains the redirect and origin-credential identity. The route
origin selects the actual connection and idle-pool entry. Sequential requests to
different target origins can therefore reuse one persistent proxy connection.
Caller-supplied `Proxy-Authorization` stays associated with that selected proxy
route across redirects while target credentials still obey cross-origin rules.

Proxy endpoints may use `http` or `https`. TLS to an HTTPS proxy terminates at
the proxy. An HTTPS target URI used with ordinary `proxy` routing is still sent
in absolute-form; it is not a hidden CONNECT tunnel and does not create
end-to-end TLS to that target.

There is no automatic environment-proxy discovery, PAC/NO_PROXY policy, SOCKS,
or automatic 407 authentication negotiation.

## CONNECT tunnels

Client CONNECT is explicit:

```perl
my $operation = $client->connect_tunnel(
    'http://proxy.example:3128',
    'target.example:443',
    tunnel_to => 'MyTunnelProtocol',
    on_tunnel => sub ($op, $tx, $res, $connection) {
        ...;
    },
);
```

The proxy endpoint and tunnel target are separate. Any successful 2xx response
ends HTTP framing at the response-head boundary; already-read following bytes
become tunnel input and the same Linux::Event stream transitions to
`tunnel_to`. Non-2xx responses remain ordinary HTTP.

Server CONNECT arrives through the normal request callback and is accepted
explicitly through Transaction:

```perl
on_request => sub ($conn, $req, $res) {
    if ($req->method eq 'CONNECT') {
        $conn->transaction->tunnel('MyTunnelProtocol');
        return;
    }

    ...;
};
```

Linux::Event::HTTP owns the CONNECT handshake and live-stream handoff. It does
not decide destination authorization, create the upstream server connection, or
relay bytes between two streams. See `docs/CONNECT.md` for the full lifecycle and
validation rules.

## Upgrade

Server Upgrade is a Transaction lifecycle operation:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Client Upgrade explicitly names the target stream class:

```perl
my $operation = $client->get(
    $url,
    headers => [
        [ Connection => 'Upgrade' ],
        [ Upgrade    => 'my-protocol' ],
    ],
    upgrade_to => 'MyProtocolConnection',
    on_upgrade => sub ($op, $tx, $res, $connection) {
        ...;
    },
);
```

A validated 101 completes the HTTP Transaction before Linux::Event
`transition_to()` hands the same live stream to the next protocol. Already-read
post-HTTP bytes are preserved.

## HTTPS

HTTPS uses the same Client, Server, Request, Response, Transaction, Operation,
and Connection classes. TLS remains Linux::Event transport policy; there is no
parallel HTTPS hierarchy.

Server TLS is configured on `Server->new(tls => {...})`. Direct Client HTTPS
uses the target URL host as the TLS server name and currently advertises only
`http/1.1` through ALPN. An HTTPS proxy endpoint uses TLS to the proxy itself.

## Connection reuse

The initial HTTP/1 reuse policy is deliberately bounded:

- one active Transaction per Client::Connection;
- no HTTP/1 pipelining on the client;
- sequential keep-alive reuse;
- at most one idle connection retained per route origin;
- concurrent operations may open additional connections;
- extra connections close when they later become idle;
- connections that leave HTTP through Upgrade or successful CONNECT never return
  to the HTTP idle pool.

Server::Connection supports ordered persistent request processing and deferred
responses on the same accepted HTTP/1 connection.

## Advanced connection subclasses

Most programs use `Server` and `Client` directly. Advanced transport extension
points are:

```text
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Client::Connection
```

Both are Linux::Event stream-socket subclasses. Custom classes can provide
reusable socket or tuning policy without changing Request, Response,
Transaction, or Operation APIs.

## Public modules

```text
Linux::Event::HTTP
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Operation
Linux::Event::HTTP::Client::Connection
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Transaction
Linux::Event::HTTP::Body::Stream
```

HTTP/1-specific native work remains consolidated in the private
`Linux::Event::HTTP::_HTTP1` extension. Client response-head parsing remains
strict Perl code unless measurement demonstrates that another native boundary is
worth maintaining.

## Build and test

```sh
perl Makefile.PL
make
make test
```

Linux::Event::HTTP currently requires Linux::Event 0.113 or newer.

## Design documents

- `docs/ARCHITECTURE.md` - ownership, lifecycle, framing, pooling, and native boundaries.
- `docs/CONNECT.md` - client and server CONNECT validation and handoff semantics.
- `docs/CLIENT-POLICY.md` - client policy roadmap and deliberately deferred policy.
- `docs/BENCHMARKING.md` - benchmark discipline and interpretation.
- `docs/PICOHTTPPARSER-EXPERIMENT.md` - parser provenance and representation experiments.

## Scope

Linux::Event::HTTP is an HTTP communications layer. It does not include routing,
middleware, sessions, templates, PSGI, PAGI, or general web-framework
responsibilities. Reusable low-level socket, buffering, backpressure, and
transport performance work belongs in Linux::Event core.
