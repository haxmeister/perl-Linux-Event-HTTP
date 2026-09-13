# Linux::Event::HTTP

Linux::Event::HTTP is a native HTTP protocol layer for Linux::Event.

Linux::Event owns sockets, TLS, readiness, buffering, backpressure, and ordered
byte output. Linux::Event::HTTP owns HTTP parsing, framing, persistence,
serialization, and transaction state. It is deliberately not a web framework.

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

my $tx = $client->get(
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

Client methods return `Linux::Event::HTTP::Transaction`. The canonical outgoing
Request is available immediately through `$tx->request`; the Response becomes
available through `$tx->response` after its final response head arrives.

For a small response that should be available as one scalar, opt into a bound:

```perl
$client->get(
    'https://example.com/config.json',
    buffer_body => 1_048_576,
    on_complete => sub ($tx) {
        my $bytes = $tx->response->body;
        ...;
    },
    on_error => sub ($tx, $error) {
        warn $error;
    },
);
```

## Shared message model

Request and Response are HTTP message objects, not client/server role objects:

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response

Transaction = one Request + one Response + exchange lifecycle
```

The same `Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response`
classes are used on both sides. A locally constructed message is mutable until
protocol commit. Received message metadata is committed/read-only.

A Request contains an HTTP request-target, not a full URL. The high-level Client
owns URL parsing, destination selection, Host synthesis, TLS selection, and
connection reuse. This keeps the Request type protocol-correct and usable on
both client and server.

## Body handling

Wire framing and application body handling are different concerns.

A complete scalar body belongs to the message:

```perl
$res->body($bytes);
```

On the server, an incremental outgoing Response body belongs to Transaction:

```perl
my $body = $conn->transaction->response_body(
    on_drain => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

On the client, an incremental outgoing Request body follows the same producer
model:

```perl
my $tx = $client->post(
    $url,
    stream_body => {
        on_drain  => sub ($body) { ... },
        on_cancel => sub ($body) { ... },
    },
);

my $body = $tx->request_body;
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
There is intentionally no unbounded automatic whole-body buffer.

The Client offers one explicit bounded convenience:

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

`buffer_body` cannot be combined with `on_body`. Its limit counts the same body
bytes that `on_body` would receive after HTTP/1 chunk framing has been removed.
A declared Content-Length above the limit fails after the response head is
available and before accumulation. Chunked, close-delimited, or otherwise
unknown-length bodies fail when accumulation would cross the configured bound.
Failure is a Transaction error and the HTTP/1 connection is closed rather than
reused with unread response bytes.

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
```

`request($method, $url, ...)` accepts absolute `http` and `https` URLs and builds
the canonical Request. `headers` is an array reference of `[name, value]` pairs.
`body` supplies a complete scalar Request body; `stream_body` selects a
Transaction-owned producer instead.

The first reuse policy is intentionally simple and bounded:

- one in-flight Transaction per HTTP/1 connection;
- no HTTP/1 pipelining;
- sequential keep-alive reuse;
- at most one idle connection retained per origin;
- concurrent same-origin requests may use additional connections;
- extra connections close when they later become idle.

A scalar Request body automatically receives Content-Length when the caller did
not supply it. Streaming bodies enforce an explicit Content-Length or use
HTTP/1.1 chunked framing when length is unknown. If a final Response arrives
before an outgoing producer finishes, the producer is cancelled and that HTTP/1
connection is not reused.

Client response framing supports Content-Length, HTTP/1.1 chunked transfer
coding, bodyless HEAD/204/304 responses, informational responses, and
close-delimited responses. Ambiguous Transfer-Encoding plus Content-Length is
rejected.

Cancelling a client Transaction closes its HTTP/1 connection rather than trying
to reuse a socket that may still contain an unfinished response.

Redirects, proxy policy, cookies, authentication helpers, CONNECT/client
Upgrade, and richer pool policy remain later features.

## HTTPS

HTTPS uses the same Client, Server, Request, Response, Transaction, and
Connection concepts. TLS remains Linux::Event transport policy; there is no
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
`http/1.1` through ALPN.

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

Client-side 101 handoff is not part of the initial Client foundation.
WebSocket framing belongs in a separate `Linux::Event::WebSocket` distribution.

## Advanced connection subclasses

Most programs use `Server` and `Client` directly. The advanced transport
extension points are:

```text
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Client::Connection
```

Both are Linux::Event stream-socket subclasses. `Server->new(connection_class =>
...)` and `Client->new(connection_class => ...)` allow reusable socket/tuning
policy without changing Request, Response, or Transaction APIs.

## Public modules

```text
Linux::Event::HTTP
Linux::Event::HTTP::Client
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

The first client response-head parser is deliberately strict Perl code. The
existing native chunked decoder is reused. Client response-head parsing should
move into native code only if measurement demonstrates a worthwhile need.

## Build and test

```sh
perl Makefile.PL
make
make test
```

The distribution includes server/client, TLS, persistence, pipelining, Upgrade,
request-body, streaming-upload, response-body, framing-error, bounded-buffer,
Transaction-lifecycle, and distribution-integrity coverage.

See `docs/ARCHITECTURE.md` for the detailed ownership and lifecycle model and
`docs/BENCHMARKING.md` for benchmark discipline.

## Scope

Linux::Event::HTTP is an HTTP communications layer. It does not include routing,
middleware, sessions, templates, PSGI, PAGI, or general web-framework
responsibilities. Reusable low-level socket, buffering, backpressure, and
transport performance work belongs in Linux::Event core.
