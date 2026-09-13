# Linux::Event::HTTP

Linux::Event::HTTP is a native HTTP protocol layer for Linux::Event.

Linux::Event owns sockets, TLS, readiness, buffering, backpressure, and ordered
byte output. Linux::Event::HTTP owns HTTP parsing, framing, persistence,
serialization, client policy, and HTTP exchange state. It is deliberately not a
web framework.

## Server quick start

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
Response paired with that Request. The active one-request/one-response exchange
is available as `$conn->transaction` when lifecycle or incremental-body
operations are needed.

## Client quick start

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
        say 'done';
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

High-level Client methods return `Linux::Event::HTTP::Client::Operation`. An
operation normally contains one `Linux::Event::HTTP::Transaction`. If redirects
are followed, every hop is another Transaction because a Transaction always
means exactly one Request/Response exchange.

For the current or final hop:

```perl
my $tx  = $operation->transaction;
my $req = $operation->request;
my $res = $operation->response;
```

Low-level `Linux::Event::HTTP::Client::Connection->request()` still returns a
single Transaction directly.

For a small response that should be available as one scalar, opt into a bound:

```perl
$client->get(
    'https://example.com/config.json',
    buffer_body => 1_048_576,
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
);
```

There is no implicit unbounded whole-response buffer.

## Shared message and lifecycle model

Request and Response are HTTP message objects, not client/server role objects:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Transaction       = exactly one Request + one Response + exchange lifecycle
Client::Operation = one high-level client action containing one or more Transactions
Connection        = one persistent transport executing Transactions
```

The same `Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response`
classes are used on both sides. A locally constructed message is mutable until
protocol commit. Received message metadata is committed/read-only.

A Request contains an HTTP request-target, not a full URL. The high-level Client
owns URL parsing, redirects, destination selection, Host synthesis, TLS policy,
and connection reuse. This keeps Request protocol-correct and usable in either
direction.

## Redirects

The Client follows 301, 302, 303, 307, and 308 responses by default, with a
limit of five redirects:

```perl
my $operation = $client->get(
    $url,
    max_redirects => 5,
    on_redirect => sub ($op, $tx, $res, $next_url) {
        say "redirecting to $next_url";
    },
    on_complete => sub ($tx) {
        say $tx->response->status;
    },
);
```

`max_redirects` may be configured on the Client or overridden per request.
`max_redirects => 0` disables redirect interpretation entirely: a 3xx response,
including all of its Location fields and body, is delivered as the final
response.

Every followed redirect creates a distinct Transaction. The operation keeps the
history:

```perl
my @transactions = $operation->transactions;
my @urls         = $operation->urls;
```

Relative Location values are resolved against the current absolute URL. URL
fragments remain client-side URL state and are never sent in the HTTP
request-target.

Redirect method/body policy is intentionally conservative and familiar:

- 301 and 302 change POST to GET and discard the body;
- 303 uses GET, except an original HEAD remains HEAD, and discards the body;
- 307 and 308 preserve method and body;
- a complete scalar body can be replayed for a method-preserving redirect;
- a streaming body producer is not assumed to be rewindable, so an automatic
  method-preserving redirect for a streamed body fails clearly rather than
  replaying unsafe or incomplete data.

Redirect hops regenerate Host and HTTP framing fields. Cross-origin redirects
also remove `Authorization` and `Cookie`. `Proxy-Authorization` and
connection-specific fields are never propagated automatically.

`on_response`, `on_body`, and `on_complete` describe the final response.
Intermediate redirect bodies are still consumed according to HTTP framing so
the connection remains correct, but they are not delivered through the final
`on_body` callback. `on_redirect` is the hook for each followed intermediate
response.

## Body handling

Wire framing and application body handling are different concerns.

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

On the server, an incremental outgoing Response body belongs to Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

On the client, an incremental outgoing Request body follows the same producer
model. The producer belongs to the current Transaction; Client::Operation
provides a convenient delegate:

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

Linux::Event remains the only output queue. `Body::Stream->write` preserves the
Linux::Event flow-control contract:

```text
true  = bytes accepted; producer may continue
false = bytes accepted; pause until on_drain
```

A streaming Request with Content-Length must produce exactly that many bytes. If
its length is unknown, HTTP/1.1 uses chunked transfer coding automatically.
HTTP/1.0 streaming requires Content-Length; Request bodies are never
close-delimited. Scalar `body` and `stream_body` are mutually exclusive.

Incoming bodies are incremental-first. Server request bodies use `on_body`;
Client response bodies use `on_body`. If no consumer is installed, bytes are
drained/discarded rather than accumulated implicitly into Request or Response.

The Client offers explicit bounded response buffering:

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

`buffer_body` cannot be combined with `on_body`. Its limit counts body bytes
after HTTP/1 transfer framing has been removed. A declared Content-Length above
the limit fails before accumulation; unknown-length bodies fail when decoded
accumulation would cross the configured bound. The same bound applies while an
intermediate redirect body is consumed.

## Deferred server responses

Inside an HTTP callback, setting a scalar Response body does not serialize in
the middle of the callback. Metadata remains configurable until callback return:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

If another event completes the Response later, retain the Transaction and send
the configured scalar message explicitly:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Response stays a transport-independent message; it has no hidden Connection
back-reference.

## Client behavior

The high-level Client supports:

```text
request
get
head
post
put
delete
connect_tunnel
```

`request($method, $url, ...)` accepts absolute `http` and `https` URLs and builds
a canonical Request for each hop. `headers` is an array reference of `[name,
value]` pairs. `body` supplies a complete scalar Request body; `stream_body`
selects a Transaction-owned producer instead.

The initial connection reuse policy is intentionally simple and bounded:

- one in-flight Transaction per HTTP/1 connection;
- no HTTP/1 pipelining;
- sequential keep-alive reuse;
- at most one idle connection retained per origin;
- concurrent same-origin requests may use additional connections;
- extra connections close when they later become idle;
- each redirect hop independently selects a connection for its target origin;
- a connection that leaves HTTP through Upgrade or successful CONNECT is never
  returned to the HTTP idle pool.

Client response framing supports Content-Length, HTTP/1.1 chunked transfer
coding, bodyless HEAD/204/304 responses, informational responses,
`101 Switching Protocols`, successful CONNECT tunnel boundaries, and
close-delimited responses. Ambiguous Transfer-Encoding plus Content-Length is
rejected for ordinary HTTP responses.

Cancelling a Client::Operation cancels the active Transaction. Cancelling an
HTTP/1 client Transaction closes its connection rather than trying to reuse a
socket that may still contain an unfinished response.

Automatic forward-proxy policy, automatic authentication helpers, a cookie jar,
and richer pool policy remain later features.

## HTTPS

HTTPS uses the same Client, Server, Request, Response, Transaction, Operation,
and Connection concepts. TLS remains Linux::Event transport policy; there is no
parallel HTTPS class hierarchy.

Server:

```perl
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8443,
    tls => {
        cert_file => '/etc/myapp/server-cert.pem',
        key_file  => '/etc/myapp/server-key.pem',
        alpn      => ['http/1.1'],
    },
    on_request => sub ($conn, $req, $res) {
        $res->body("secure\n");
    },
);
```

Client:

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop => $loop,
    tls => {
        verify  => 1,
        ca_file => '/etc/ssl/certs/custom.pem',
    },
);

$client->get('https://example.com/');
```

The Client uses the URL host as the TLS server name and currently offers only
`http/1.1` through ALPN. `connect_tunnel` also accepts an `https` proxy endpoint;
that TLS session terminates at the proxy before CONNECT establishes the byte
tunnel.

## CONNECT tunnels

The high-level Client can explicitly establish a CONNECT tunnel without turning
ordinary requests into implicit proxy traffic:

```perl
my $operation = $client->connect_tunnel(
    'http://proxy.example:3128',
    'target.example:443',
    tunnel_to => 'MyTunnelProtocol',
    headers => [
        [ 'Proxy-Authorization' => $value ],
    ],
    on_tunnel => sub ($op, $tx, $res, $connection) {
        # same live socket, now owned by MyTunnelProtocol
    },
);
```

The proxy URL selects where the HTTP connection is made. The second argument is
the authority-form `host:port` target carried by CONNECT and used for Host. A
successful 2xx response ends HTTP framing immediately after its header section;
Content-Length and Transfer-Encoding on that successful response are ignored,
and bytes already read afterward are tunnel bytes. Response and Transaction are
complete before `on_tunnel`, and Linux::Event `transition_to()` hands the same
live stream object to `tunnel_to`.

A non-2xx response, such as 407, remains ordinary HTTP and may be consumed with
`on_body` or explicit `buffer_body`. If its persistence/framing permits reuse,
the failed CONNECT connection can return to the proxy-origin idle pool. A
successful tunnel never returns to HTTP reuse. `connect_tunnel` deliberately
does not follow redirects or provide automatic proxy-authentication policy.

Low-level callers can construct the CONNECT Request directly and use
`Client::Connection->request(..., tunnel_to => $class, on_tunnel => ...)`.
CONNECT Requests are HTTP/1.1, authority-form, bodyless, and contain neither
Content-Length nor Transfer-Encoding.

## Upgrade

Server-side HTTP Upgrade is a Transaction lifecycle operation on the same live
transport:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

Linux::Event::HTTP validates and queues the 101 response, completes the HTTP
Transaction, and uses Linux::Event `transition_to()` to hand the same stream
object to the target protocol class.

Client-side Upgrade mirrors the same transport handoff model. The request
explicitly advertises the protocol and names the Linux::Event stream subclass
that should own the connection after a validated `101`:

```perl
my $operation = $client->get(
    $url,
    headers => [
        [ Connection => 'Upgrade' ],
        [ Upgrade    => 'my-protocol' ],
    ],
    upgrade_to => 'MyProtocolConnection',
    on_upgrade => sub ($op, $tx, $res, $connection) {
        # $connection is the same live stream object, now MyProtocolConnection
    },
);
```

Client Upgrade requires HTTP/1.1 and a bodyless Request. The switching Response
must contain `Connection: Upgrade`, select a protocol offered by the Request,
and contain no Content-Length or Transfer-Encoding. The Response and
Transaction complete before `on_upgrade`. Bytes already read after the 101 head
are preserved for the target protocol during `transition_to()`.

Redirects may precede the successful 101. Each redirect hop regenerates the
Upgrade handshake fields rather than forwarding stale connection-specific
headers. Once the connection transitions away from HTTP, it is never returned
to the Client's HTTP idle pool.

A bare unexpected 101 without `upgrade_to` is a protocol error. WebSocket
handshake/frame semantics belong in a separate `Linux::Event::WebSocket`
distribution that can use this handoff capability.

## Advanced connection subclasses

Most programs use `Server` and `Client` directly. The advanced transport
extension points are:

```text
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Client::Connection
```

Both are Linux::Event stream-socket subclasses. `Server->new(connection_class =>
...)` and `Client->new(connection_class => ...)` allow reusable socket/tuning
policy without changing Request, Response, Transaction, or Operation APIs.

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

## Native HTTP boundary

HTTP/1 native work remains consolidated in one private extension:

```text
Linux::Event::HTTP::_HTTP1
```

It owns picohttpparser server request-head parsing/lazy Request accessors,
chunked transfer decoding, response-head serialization, and the narrow eligible
server scalar-response builder.

The client response-head parser remains deliberately strict Perl code. The
existing native chunked decoder is reused. Client response-head parsing should
move into native code only if measurement demonstrates a worthwhile need.

## Build and test

```sh
perl Makefile.PL
make
make test
```

The distribution includes server/client, TLS, persistence, pipelining, Upgrade,
CONNECT tunneling, request-body, streaming-upload, redirects, response-body,
framing-error, bounded-buffer, Transaction/Operation lifecycle, and
distribution-integrity coverage.

See `docs/ARCHITECTURE.md` for detailed ownership and lifecycle rules and
`docs/BENCHMARKING.md` for benchmark discipline.

## Scope

Linux::Event::HTTP is an HTTP communications layer. It does not include routing,
middleware, sessions, templates, PSGI, PAGI, or general web-framework
responsibilities. Reusable low-level socket, buffering, backpressure, and
transport performance work belongs in Linux::Event core.
