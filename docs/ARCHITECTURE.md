# Linux::Event::HTTP architecture

Linux::Event::HTTP is an HTTP communications layer for Linux::Event. It is not a
web framework or framework-adapter distribution.

## Ownership boundaries

The design separates five responsibilities:

- **Transport** - Linux::Event owns sockets, TLS, readiness, byte buffering,
  backpressure, deadlines, ordered output queues, and event dispatch.
- **Protocol execution** - Client::Connection and Server::Connection own HTTP/1
  parsing, serialization, framing, ordering, persistence, protocol handoff, and
  movement of bytes across Linux::Event transports.
- **Messages** - Request and Response represent HTTP messages independent of
  whether they were created or received by a client or server.
- **Exchange lifecycle** - Transaction represents exactly one Request/Response
  exchange and owns cancellation plus exchange-specific producer/output state.
- **High-level client lifecycle** - Client::Operation represents one application
  client action. It normally contains one Transaction, but may contain several
  when redirects are followed.

`Body::Stream` is the writable producer used by Transaction for outgoing
incremental Request or Response bodies. It is not a message and does not own a
second transport queue.

Reusable transport or ordered-byte performance work belongs in Linux::Event.
HTTP-specific native code should remain limited to HTTP wire work where a native
boundary is justified by correctness or measurement.

Routing, middleware, sessions, templates, PSGI/PAGI, and general framework
concerns are outside this distribution.

## Public structure

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

There is deliberately no generic public `Linux::Event::HTTP::Connection`.
Client and server connections execute opposite HTTP roles and have different
state machines even though both are Linux::Event stream sockets.

There are deliberately no `Client::Request`, `Client::Response`,
`Server::Request`, or `Server::Response` classes. Endpoint direction does not
change HTTP message identity.

## Message model

```text
client sends Request  -----> server receives Request
client gets Response  <----- server sends Response
```

A locally constructed message is mutable until protocol commit. A received
message uses the same public type but its wire metadata is committed/read-only.
Parsed server Requests retain lazy XS-backed storage rather than being eagerly
expanded into Perl hashes or header objects.

Common message concepts are:

```text
Request                         Response
-------                         --------
method                          status
target                          reason
version                         version
header                          header
add_header                      add_header
remove_header                   remove_header
header_values                   header_values
header_count                    header_count
header_name                     header_name
header_value                    header_value
content_length                  content_length
body                            body
is_complete                     is_complete
```

`target` is intentionally used instead of `uri`. An HTTP Request contains a
request-target. Full URL parsing, scheme, authority, destination selection,
Host synthesis, redirect resolution, and connection pooling are Client policy.
They do not belong in Request merely because a client needs them.

Request and Response do not retain their peer message, Connection, output
writer, pool, redirect chain, or protocol-transition state. Those relationships
belong to Transaction, Client::Operation, and protocol executors.

HTTP/1-only framing and persistence decisions remain private protocol state
rather than generic message methods.

## Transaction model

A Transaction represents exactly one HTTP exchange:

```text
Transaction
    one Request
    zero/one Response
    lifecycle state
    cancellation/error
    outgoing Request/Response body producer where applicable
    server response-output state
    server Upgrade state
```

A Transaction does not own a socket, parser, connection pool, URL, redirect
chain, or transport output queue. Its Client::Connection or Server::Connection
controller performs protocol execution.

A redirect is another HTTP exchange and therefore another Transaction. This is
an invariant, not an implementation detail.

A successful client or server Upgrade still completes the HTTP Transaction
before the live transport belongs to the next protocol. Protocol handoff is an
executor/transport transition, not a new kind of HTTP message.

## Client::Operation model

High-level Client methods return Client::Operation rather than pretending a
multi-hop redirect sequence is one Transaction:

```text
Client::Operation
    initial URL
    current/final URL
    redirect limit
    Transaction history
    operation terminal state

        Transaction #1: Request -> 302 Response
        Transaction #2: Request -> 307 Response
        Transaction #3: Request -> 200 Response
```

For the common single-hop case, Operation delegates `request`, `response`,
`request_body`, `cancel`, and terminal-state access so ordinary code remains
concise. The actual body producer remains Transaction-owned.

Low-level `Client::Connection->request()` continues to return exactly one
Transaction. Redirect policy exists only in the high-level Client.

## Server model

`Linux::Event::HTTP::Server` is the ordinary server entry point and a thin
control-plane convenience over `Linux::Event::IO::Sock::Listener`.

```perl
on_request => sub ($conn, $req, $res) {
    $res->body("hello\n");
}
```

The active exchange is available without another callback argument:

```perl
my $tx = $conn->transaction;
```

The objects have different lifetimes:

- `$conn` is the persistent TCP/TLS HTTP connection;
- `$tx` is one HTTP exchange on that connection;
- `$req` is that exchange's Request;
- `$res` is that exchange's Response.

A complete HTTP response does not imply transport shutdown. On persistent
HTTP/1.1 the same socket normally remains available for later Transactions.

## Client model

`Linux::Event::HTTP::Client` is the ordinary outbound entry point:

```text
Client
    absolute URL parsing
    redirect policy
    scheme/host/port selection
    Host synthesis
    TLS transport creation
    connection selection/reuse
    protocol-handoff policy
    convenience verbs

Client::Operation
    one application-facing client action
    one or more Transactions
    redirect history/limit
    cancellation and operation terminal state

Client::Connection
    one HTTP/1 socket
    one active Transaction at a time
    Request serialization
    Response parsing/framing
    persistence/reuse eligibility
    validated 101 protocol handoff

Transaction
    exactly one Request/Response exchange
```

The high-level form is:

```perl
my $operation = $client->request(
    'POST',
    'https://example.com/api/items',
    body => $bytes,
    max_redirects => 5,
    on_redirect => sub ($op, $tx, $res, $next_url) { ... },
    on_response => sub ($tx, $res) { ... },
    on_body => sub ($tx, $res, $bytes) { ... },
    on_complete => sub ($tx) { ... },
    on_error => sub ($tx, $error) { ... },
);
```

Convenience methods are `get`, `head`, `post`, `put`, and `delete`.

The current connection-reuse policy is deliberately bounded:

- no HTTP/1 pipelining;
- one active Transaction per Client::Connection;
- sequential keep-alive reuse;
- at most one idle connection retained per origin;
- concurrent same-origin operations may create additional connections;
- when multiple connections later become idle for one origin, one is retained
  and extras are closed;
- each redirect hop independently selects a connection for its target origin;
- a connection transitioned to another protocol is never returned to the HTTP
  idle pool.

## Client URL and redirect policy

Client uses the established `URI` distribution rather than implementing URL
parsing itself.

Only absolute `http` and `https` starting URLs are accepted. Fragments are not
transmitted. Origin-form path plus query becomes the Request target, with `/`
used when the URL has no path. HTTP/1.1 Host is synthesized when absent.

Userinfo is rejected rather than silently creating authentication policy.

Automatic redirect following recognizes 301, 302, 303, 307, and 308. Relative
Location references are resolved against the current absolute URL. When a
redirect Location omits a fragment, the existing fragment is inherited for URL
processing; fragments still never enter the HTTP request-target.

`max_redirects` defaults to 5 and may be configured globally or per operation.
Zero disables redirect interpretation completely. In that mode a 3xx is an
ordinary final Response; the Client does not validate or interpret its Location
fields as redirect instructions.

When following is enabled, a redirect is followed only when one Location field
is available. Multiple Location fields are rejected as ambiguous redirect
instructions.

Method/body policy follows common HTTP user-agent semantics:

- 301/302: POST may be changed to GET and its body discarded;
- 303: use GET, except HEAD remains HEAD, and discard the body;
- 307/308: preserve method and body.

A complete scalar body is replayable and may be reused for a method-preserving
redirect. A streaming producer is not inherently rewindable, so automatic
method-preserving redirect of a streaming Request fails rather than guessing.
A redirect that changes POST to GET can proceed because no body replay is
required.

Each redirect hop regenerates Host and framing/connection-specific fields.
Cross-origin redirects additionally remove Authorization and Cookie.
Proxy-Authorization is never propagated automatically. The Client does not yet
implement a cookie jar or authentication manager; this is defensive forwarding
policy for caller-supplied headers.

When an operation is explicitly waiting for HTTP Upgrade, a redirect hop also
regenerates `Connection: Upgrade` and the originally offered `Upgrade` protocol
fields. The Client does not forward a previous hop's connection-specific header
verbatim.

`on_response`, `on_body`, and `on_complete` are final-response callbacks.
Intermediate redirect responses are consumed to their actual message boundary
but are not emitted through final `on_body`. `on_redirect` receives each
completed intermediate redirect Transaction before the next hop begins.
`on_informational` remains per-Transaction and can run on any hop.

## Body model

HTTP wire framing and application body handling are separate concepts.
`Content-Length`, HTTP/1 chunked transfer coding, close delimiting, or a future
HTTP/2 DATA-frame boundary tell protocol execution how to identify body bytes.
They do not dictate whether the application buffers, incrementally
produces/consumes, forwards, parses, writes to disk, or discards those bytes.

A message's `body(...)` means the application has a complete scalar byte body.

### Server outgoing Response

```perl
$res->status(200);
$res->header('Content-Type', 'text/plain');
$res->body("hello\n");
```

Inside an HTTP callback, body assignment declares a complete body rather than
writing immediately. Response metadata remains mutable until callback return.

For a Response completed by another event:

```perl
my $tx = $conn->transaction;
$tx->response->body("later\n");
$tx->send_response;
```

Incremental server Response production is Transaction-owned:

```perl
my $body = $conn->transaction->response_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);

$body->write($bytes);
$body->complete;
```

Creating the producer does not commit response headers. First write/complete is
the output commit point. Complete scalar body and incremental producer are
mutually exclusive.

### Server incoming Request

`on_request` runs after the validated request head. `on_body` receives decoded
body bytes and `on_request_end` marks the actual body boundary. If `on_body` is
absent, body bytes are drained/discarded rather than accumulated.

### Client outgoing Request

A complete scalar body is stored on Request. Client::Connection adds
Content-Length when needed and checks an explicit Content-Length.

Incremental output is Transaction-owned:

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

Known-length streams enforce Content-Length exactly. Unknown-length HTTP/1.1
streams use chunked transfer coding. HTTP/1.0 streaming requires Content-Length.

### Client incoming Response

Client bodies are incremental-first:

```perl
on_response => sub ($tx, $res) { ... },
on_body => sub ($tx, $res, $bytes) { ... },
on_complete => sub ($tx) { ... },
```

If `on_body` is absent, bytes are drained/discarded. The protocol layer never
creates an implicit unbounded whole-body scalar.

For callers that explicitly want one scalar:

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

`buffer_body` and `on_body` are mutually exclusive. The configured limit counts
bytes after HTTP/1 chunk framing is removed. Content-Encoding is not decoded.
The same bound applies while intermediate redirect bodies are consumed.

A known Content-Length above the limit fails before accumulation. Unknown-size
bodies fail when adding decoded bytes would cross the bound. Failure closes the
HTTP/1 connection so unread bytes cannot be mistaken for a reusable stream.

## Commit and completion state

Message, Transaction, and Operation completion are distinct:

- Request/Response `is_complete` describes the message body boundary;
- received metadata is committed/read-only once parsed;
- server `Transaction->is_response_started` describes output start;
- `Transaction->is_complete` means one HTTP exchange succeeded;
- `Client::Operation->is_complete` means the overall high-level client action,
  including followed redirects, reached its final successful Transaction;
- for a successful client Upgrade, the final 101 Response and Transaction are
  complete and the Operation is marked complete before `on_upgrade` runs;
- cancellation and errors are separate terminal states.

## Client HTTP/1 response framing

Client::Connection applies framing independently from application handling:

- HEAD, 204, and 304 have no delivered body;
- non-switching informational 1xx responses may precede the final Response;
- Content-Length is consumed to the exact declared boundary;
- HTTP/1.1 chunked transfer coding is decoded with the existing native decoder;
- a response without Content-Length or Transfer-Encoding is close-delimited and
  makes the connection non-reusable;
- Transfer-Encoding plus Content-Length is rejected as ambiguous;
- only plain `chunked` Transfer-Encoding is currently supported;
- a validated `101 Switching Protocols` completes HTTP framing and transitions
  the same live stream to the explicitly requested target class;
- CONNECT tunneling remains separate work.

Cancelling an active client Transaction closes its HTTP/1 connection because an
unfinished response cannot generally be skipped safely while preserving stream
reuse. Operation cancellation delegates to the active Transaction.

## Backpressure and transport ownership

Linux::Event remains the only transport-output queue. HTTP does not maintain a
second queue for server or client body producers.

`Body::Stream->write()` preserves Linux::Event flow control:

```text
true  = accepted and producer may continue
false = accepted, but producer should pause until on_drain
```

Linux::Event owns queued bytes, watermarks, pending-byte limits, readiness,
drain signaling, connection progress, and TLS transport state.

The optional Client response buffer is retained message/application data, not a
transport queue.

## Native HTTP/1 boundary

HTTP/1 native work is consolidated in one private extension:

```text
Linux::Event::HTTP::_HTTP1
```

It currently owns:

- picohttpparser server request-head parsing and lazy Request accessors;
- chunked transfer decoding used by server and client;
- server response-head serialization;
- the narrow default server scalar-response builder.

The client response-head parser is intentionally strict Perl code. Do not add
parser XS merely for symmetry. Benchmark representative client workloads before
adding another native fast path.

## Connection classes

`Linux::Event::HTTP::Server::Connection` and
`Linux::Event::HTTP::Client::Connection` are
`Linux::Event::IO::Sock::Stream` subclasses.

Server::Connection owns HTTP/1 server ordering, parsing, response output, and
Upgrade handoff. Client::Connection owns exactly one active client Transaction,
Request serialization, Response framing, reuse eligibility, and validated 101
handoff.

The high-level Client normally creates Client::Connection objects. Direct
Client::Connection use is appropriate when destination acquisition and redirect
policy are being handled elsewhere.

## TLS

HTTPS uses the same message, lifecycle, and connection classes. TLS remains
Linux::Event transport policy. Client HTTPS uses the URL host as server name and
currently offers only `http/1.1` through ALPN.

There is no separate HTTPS hierarchy.

## Upgrade

Server-side HTTP Upgrade is Transaction lifecycle:

```perl
$res->header('Upgrade', 'my-protocol');
$conn->transaction->upgrade('MyProtocolConnection');
```

The 101 response is validated and queued, the HTTP Transaction completes, and
Linux::Event `transition_to()` hands the same live stream object to the next
protocol class while preserving transport identity/state.

Client-side Upgrade is an explicit Client/Client::Connection policy layered on
the same Linux::Event transport primitive:

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

The Request must be bodyless HTTP/1.1 and advertise `Connection: Upgrade` plus
at least one Upgrade protocol. A successful 101 must use HTTP/1.1, contain
`Connection: Upgrade`, contain no Content-Length or Transfer-Encoding, and
select only protocols offered by the Request.

The 101 Response and HTTP Transaction complete before handoff callback delivery.
Linux::Event `transition_to()` reuses the same live stream object and preserves
bytes already read after the response head as target-protocol input. The
transitioned stream is no longer an HTTP connection and is never returned to the
Client's idle HTTP pool. Redirect hops may precede the 101; Upgrade handshake
fields are regenerated on each hop.

An unexpected bare 101 without `upgrade_to` is a protocol error. CONNECT is a
separate tunnel operation and remains future work. WebSocket handshake/frame
semantics belong in a separate `Linux::Event::WebSocket` distribution that can
use the client/server handoff primitives here.

## Performance policy

Correctness, ease of correct use, coherent APIs, maintainability, and
composability take priority over HTTP-specific benchmark tricks.

Benchmark discoveries may justify private optimizations, but should not create
alternate public APIs merely to expose a fast path. The ordinary API should take
an optimization transparently when eligible.

Before adding HTTP-specific native transport machinery, first ask whether the
expensive primitive is reusable socket, buffer, or write machinery that belongs
in Linux::Event core.

Do not add a second HTTP output queue. Do not split the consolidated `_HTTP1`
extension without a measured reason. Do not add HTTP-specific XS merely to win
a benchmark.

## Current status

The current foundation includes:

1. Direction-neutral Request and Response message types.
2. Transaction as exactly one Request/Response exchange.
3. HTTP/1 Server and Server::Connection with request-body delivery, persistent
   ordering, scalar/incremental responses, TLS, deferred response send, and
   Upgrade.
4. HTTP/1 Client::Connection with scalar/streaming Request serialization,
   strict Response parsing, informational responses, incremental
   Content-Length/chunked/close body delivery, cancellation, sequential reuse,
   and validated 101 protocol handoff.
5. High-level Client::Operation with redirect chains of distinct Transactions,
   bounded redirect policy, cross-origin sensitive-header stripping, safe
   refusal to replay non-rewindable streaming Request bodies, and client Upgrade
   lifecycle integration.
6. High-level Client URL parsing, HTTP/HTTPS destination acquisition, bounded
   same-origin idle reuse, common convenience verbs, explicit bounded
   whole-response buffering, and redirect-to-Upgrade handshake regeneration.
7. One consolidated private `_HTTP1` native extension and no duplicate transport
   queues.

Later client work includes richer pool policy, proxy/auth/cookie conveniences,
CONNECT, and measurement-driven parser optimization.

HTTP/2 is future protocol work. WebSocket remains a separate protocol
distribution.
