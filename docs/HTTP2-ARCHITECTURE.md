# Linux::Event::HTTP HTTP/2 architecture

Status: production candidate
Date: 2026-09-26

## Purpose

HTTP/2 belongs in the Linux::Event::HTTP distribution rather than a separate
distribution.

The public goal is one HTTP message and application model with protocol-specific
executors underneath it. HTTP/2 must not turn Request, Response, Transaction,
Client, or Server into containers for HTTP/2 frame details.

The first implementation should prefer correctness, maintainability, and clean
composition over reproducing HTTP/1 internals or maximizing a microbenchmark.

## Standards baseline

The HTTP/2 implementation target is RFC 9113.

HPACK is defined by RFC 7541.

For TLS, HTTP/2 is selected with the ALPN token:

    h2

The deprecated HTTP/1.1 Upgrade path historically called h2c is not part of the
initial design.

Cleartext HTTP/2 by prior knowledge is valid protocol behavior, but it is a
separate deployment mode and does not need to be in the first implementation.

## Shared public model

The following existing concepts remain valid for HTTP/2:

    Linux::Event::HTTP::Request
    Linux::Event::HTTP::Response
    Linux::Event::HTTP::Transaction
    Linux::Event::HTTP::Client::Operation
    Linux::Event::HTTP::Client
    Linux::Event::HTTP::Server
    Linux::Event::HTTP::Body::Stream

Request and Response remain transport-independent HTTP messages.

Transaction remains exactly one Request/Response exchange.

Client::Operation remains one application action and may still contain more than
one Transaction for redirects, authentication retries, or future transport
retries.

Cookie, authentication, redirect, target-origin, and proxy-selection policy
remain high-level Client concerns.

## Protocol-specific executors

HTTP/1 and HTTP/2 have fundamentally different connection state machines.

HTTP/1:

    one ordered byte stream
    one active client Transaction per connection
    ordered server requests
    text framing
    connection-level persistence

HTTP/2:

    one binary framed connection
    many concurrent streams
    one Transaction per HTTP/2 stream
    HPACK state shared by the connection
    per-stream and connection flow control
    SETTINGS / PING / GOAWAY control state
    stream errors distinct from connection errors

Do not add pervasive protocol-version conditionals throughout the current
HTTP/1 state machines.

The intended internal split is conceptually:

    Client / Server policy
            |
            +-- HTTP/1 executor
            |
            +-- HTTP/2 executor

The implemented private HTTP/2 namespace is:

    Linux::Event::HTTP::_HTTP2
    Linux::Event::HTTP::_HTTP2::Client
    Linux::Event::HTTP::_HTTP2::Server
    Linux::Event::HTTP::_HTTP2::ClientConnection
    Linux::Event::HTTP::_HTTP2::ServerConnection
    Linux::Event::HTTP::_HTTP2::ClientSelector
    Linux::Event::HTTP::_HTTP2::ClientSelectorConnection

These are protocol implementation and selection objects, not replacement public
message classes.

## Protocol engine recommendation

Do not implement HTTP/2 framing, HPACK, stream state, and flow control from
scratch as the first approach.

The preferred integration candidate is nghttp2 through the low-level
Net::HTTP2::nghttp2 binding.

Reasons:

- nghttp2 is a mature dedicated HTTP/2 implementation;
- it implements RFC 9113 and HPACK;
- it owns frame parsing/serialization, stream state, flow control, SETTINGS,
  PING, GOAWAY, RST_STREAM, CONTINUATION, and HPACK dynamic-table state;
- the Perl binding exposes client and server session objects;
- mem_recv()/mem_send() fit an event-driven transport integration;
- submit_request()/submit_response() support scalar and streaming bodies;
- stream user data can associate an nghttp2 stream with a Transaction state;
- h2spec integration already exists in the binding ecosystem;
- other current Perl HTTP/2 implementations are successfully using nghttp2.

Do not use Net::HTTP2 as the Linux::Event::HTTP API layer. It is a higher-level
client abstraction with its own event-loop integration. Linux::Event::HTTP needs
a protocol engine below its existing Client/Server API.

Protocol::HTTP2 remains a useful comparison and possible fallback experiment,
but it should not be the default architectural choice. Its current public
documentation still describes a beta RFC 7540 implementation and marks portions
of its implementation incomplete.

The integration work has proved that Net::HTTP2::nghttp2 exposes the control
needed by Linux::Event::HTTP. HTTP/2 requires version 0.011 or newer because
0.011 fixes provider/session lifetime hazards during callback-driven stream
teardown and explicitly rejects reentrant mem_send()/mem_recv(). Its build path
requires nghttp2 >= 1.57.

The binding remains optional for HTTP/1-only installations. Distribution
metadata records an optional `http2` feature requiring
`Net::HTTP2::nghttp2 >= 0.011`, while requesting `http2 => 1` at runtime
without that capability produces an explicit constructor error.

nghttp2 >= 1.57 also provides the HTTP/2 Rapid Reset RST_STREAM rate limiter.
The binding leaves nghttp2's default limiter active when no custom burst/rate is
provided. Linux::Event::HTTP currently relies on that tested default rather than
adding a second public rate-limit policy.

## TLS and ALPN

The default HTTP client remains HTTP/1.1-only. When the high-level Client is
constructed with:

    http2 => 1

direct HTTPS connections advertise, in preference order:

    h2
    http/1.1

The high-level Server uses the same preference order when HTTP/2 is enabled.

Linux::Event already exposes the negotiated protocol through selected_alpn.

No HTTP request bytes may be serialized before TLS negotiation selects the HTTP
executor.

For servers, ALPN selection must also occur before protocol bytes are dispatched
to the HTTP/1 parser or HTTP/2 engine.

The protocol-selection spike has validated the connection transition boundary.

A critical ordering invariant is:

    TLS handshake completes
    selected_alpn is inspected
    pause_read
    Loop->defer(...)
    construct the selected HTTP/2 executor passively
    attach the executor to the live connection
    transition_to the HTTP/2 raw connection class
    start the HTTP/2 executor
    emit preface / SETTINGS
    resume_read

The HTTP/2 executor must not emit protocol bytes while the live Stream is still
the HTTP/1 native-consumer connection class.

The initial spike violated this rule because the executor constructor
immediately called send_connection_preface(), mem_send(), and Stream->write()
before transition_to(). That ordering produced the selector SIGSEGV.

Passive construction followed by transition, explicit start/flush, and then
resume_read completes successfully while preserving Stream identity, fd
identity, TLS transport, the shared application callback shape, and HTTP/1.1
ALPN fallback.

HTTP/1.1 selection performs no transition and continues using the existing
HTTP/1 connection implementation.

## nghttp2 callback lifecycle

A Net::HTTP2::nghttp2 Session call is a non-reentrant boundary.

Do not call mem_send() or mem_recv() from inside one of the Session's callbacks.
Callbacks may submit protocol work, but serialization/receive driving resumes
only after the active Session call returns.

The same rule applies to teardown. Application callbacks can close a Client,
Server-side connection, or Stream while nghttp2 is delivering a callback.
Therefore the private executors track whether a Session call is active. A close
requested during that interval is recorded as pending; subsequent callbacks are
ignored, control returns from mem_recv()/mem_send(), and only then are Session,
provider, and stream maps destroyed.

This is not merely defensive style. Validation against Net::HTTP2::nghttp2
0.011 exposed real crashes when the older executor destroyed Session state
reentrantly from an application completion callback.

## HTTP/2 connection state

An HTTP/2 connection executor needs connection-scoped state roughly equivalent
to:

    nghttp2 session
    peer/local SETTINGS
    peer max concurrent streams
    connection send/receive flow-control state
    stream_id -> stream state map
    GOAWAY state
    protocol error / closing state
    output scheduling state

A connection does not have one active Transaction.

Each live HTTP/2 stream owns stream-specific state roughly equivalent to:

    stream id
    Transaction
    Request
    zero/one Response
    callback set
    incoming body state
    outgoing body producer state
    stream flow-control state
    terminal/reset state

The nghttp2 stream ID is private protocol state and does not belong on Request
or Response.

## Server callback model

The existing callback shape should remain:

    on_request => sub ($conn, $req, $res) { ... }

and:

    on_body => sub ($conn, $req, $res, $bytes) { ... }

The important semantic change is that an HTTP/2 connection can have many live
Transactions.

For HTTP/2, conn->transaction should mean the Transaction associated with the
HTTP callback that is currently executing. Code that needs the Transaction
after the callback returns must retain it:

    my $tx = $conn->transaction;

This is already the documented pattern for delayed responses.

There must not be one connection-global active Transaction for HTTP/2.

## Client multiplexing

The high-level Client now has a separate per-origin H2 connection pool.

Once ALPN selects H2, that selector remains available while streams are active.
Later Operations can therefore submit new streams without waiting for earlier
Transactions to complete.

The private H2 client executor exposes only a capacity predicate to the pool.
The pool does not know stream IDs, HPACK state, or flow-control windows.

Current admission behavior:

    local active-stream cap: 100
    peer SETTINGS enforcement: nghttp2
    GOAWAY: mark connection draining, admit no new streams
    draining connection with no active streams: retire it
    no available H2 capacity: open another connection

The local cap prevents unbounded application submission into one Session.
nghttp2 remains responsible for honoring the peer's actual
SETTINGS_MAX_CONCURRENT_STREAMS and may queue submitted streams internally
until peer capacity is available.

The Client now has an origin-scoped pre-selection queue. Simultaneous Operations
created before the first TLS/ALPN decision share one negotiating selector up to
the local 100-Transaction cap.

If ALPN selects H2, the queued Transactions are submitted onto that one
multiplexed connection. If ALPN selects HTTP/1.1, the first Transaction remains
on the negotiated connection and the remaining queued Transactions are fanned
out onto separate HTTP/1.1 connections so fallback concurrency is preserved.

Each Operation still receives its Transaction and Request synchronously before
ALPN. Streaming Request bodies use per-Transaction pre-selection body queues so
their public Body::Stream producers remain immediately writable. After protocol
selection, the selected executor adopts the same Transaction and Body::Stream
objects and drains any queued bytes into its ordinary body path.

Connection coalescing across origins remains deferred.

GOAWAY retry policy also remains deferred. New work is kept off a draining
connection, but automatic replay of streams based on GOAWAY last-stream-id is
not yet implemented.

## Request pseudo-header mapping

HTTP/2 pseudo-headers are wire syntax and must not appear in the ordinary
Request header list.

The intended mapping is:

    :method     -> Request method
    :path       -> Request target
    HTTP/2      -> Request version "2"

Normal HTTP field lines remain in the normal lossless header list.

The representation for :scheme and :authority is now decided:

    Request->scheme
    Request->authority

These are protocol-neutral message metadata rather than HTTP/2 pseudo-header
accessors. HTTP/2 maps the pseudo-header values directly into these accessors.
HTTP/1 derives them only when the request message itself carries enough
information.

For HTTP/1, authority can be derived where the request target or Host field
provides it. Scheme is not always present on an HTTP/1 wire request and can be
undefined when the message itself does not carry it.

Do not synthesize a Host header merely because an HTTP/2 request carried
:authority. That would make the ordinary header list no longer lossless.

Pseudo-headers never appear in the ordinary lossless header list. The private
_HTTP2 mapper consumes them at the protocol boundary.

## Response mapping

HTTP/2 :status maps directly to Response->status.

Received HTTP/2 responses use:

    version => "2"

HTTP/2 has no reason phrase. A received HTTP/2 Response therefore has an
undefined reason.

A locally configured Response reason may remain application metadata, but the
HTTP/2 executor must not serialize it.

## Header validation

HTTP/2 wire field names are lowercase. The executor may lowercase names for wire
encoding without mutating the Request or Response object.

Outbound HTTP/2 must reject or correctly handle connection-specific HTTP/1
fields that are invalid in HTTP/2.

In particular, Transfer-Encoding chunked is not an HTTP/2 body framing
mechanism. DATA plus END_STREAM defines body completion.

Content-Length may still be present and must remain internally consistent with
the body.

Initial implementation should enforce the HTTP/2 header rules at the protocol
boundary rather than weakening the generic message classes.

## Body::Stream and outgoing flow control

Body::Stream remains the public outgoing streaming producer.

For HTTP/1, acceptance is governed primarily by Linux::Event transport output
backpressure.

For HTTP/2, a body write is constrained by both:

    Linux::Event transport output capacity
    HTTP/2 connection flow-control credit
    HTTP/2 stream flow-control credit

The HTTP/2 executor must translate Body::Stream writes into DATA production and
defer/resume the nghttp2 data provider when either protocol flow control or
transport backpressure prevents progress.

Body::Stream should not learn about HTTP/2 frame or window concepts.

Its existing false-return / on_drain contract remains the right public
abstraction if the executor only signals drain when output can genuinely make
forward progress again.

## Incoming body flow control

HTTP/2 endpoints must continue reading and processing connection frames even
when one stream cannot make progress. Pausing the entire socket because one
stream is slow is not an acceptable HTTP/2 backpressure design.

The initial callback API can treat successful on_body delivery as application
consumption and return receive-window credit accordingly.

This matches the current callback contract: on_body receives bytes
synchronously and the library does not retain them after callback return.

buffer_body remains bounded by its explicit application limit.

A future API for deliberately withholding per-stream receive credit can be
designed if a real workload requires asynchronous inbound backpressure. It is
not required for the first HTTP/2 implementation.

## Cancellation and errors

HTTP/2 distinguishes stream failure from connection failure.

Transaction cancellation should reset only its HTTP/2 stream when possible.

A stream error fails that Transaction without destroying unrelated streams.

A connection error fails all Transactions still owned by that connection.

GOAWAY requires special client handling:

- streams the peer may have processed can finish according to protocol state;
- streams known not to have been processed may be eligible for retry;
- no new streams are opened on a draining connection.

How transparent transport retries appear in Client::Operation history is an
open design item. They must not be confused with redirect_count or
auth_retry_count.

## Upgrade, CONNECT, and WebSocket

HTTP/1 protocol handoff changes ownership of the whole live transport.

That model does not apply to a multiplexed HTTP/2 connection.

Therefore the existing:

    Transaction->upgrade($class)
    Transaction->tunnel($class)

remain HTTP/1 transport-handoff semantics.

Ordinary HTTP/2 does not use a 101 Upgrade transition.

HTTP/2 CONNECT and RFC 8441 extended CONNECT create a bidirectional byte channel
inside one HTTP/2 stream. Supporting them correctly requires a stream-level
transport abstraction rather than transition_to() on the whole socket.

Base HTTP/2 should be implemented and validated before designing this
stream-level tunnel abstraction.

## Server push and priority

Server push is not required for the first implementation. Clients should
initially advertise push disabled where appropriate.

Do not build application API around the old HTTP/2 dependency-tree priority
scheme.

Priority support can be revisited only if a real requirement appears.

## Cleartext HTTP/2

The first production path should target TLS HTTP/2 negotiated with ALPN.

Do not implement the deprecated h2c HTTP/1.1 Upgrade mechanism.

Cleartext HTTP/2 prior knowledge can be added later as an explicit mode after the
TLS path is stable.

## Security and resource limits

HTTP/2 adds connection-wide attack surfaces that do not exist in the same form
in HTTP/1.

The implementation must define and test limits for at least:

    maximum concurrent streams
    maximum decoded header list size
    HPACK dynamic table size
    maximum pending output
    connection aggregate buffered body bytes
    stream reset rate / Rapid Reset protection
    control-frame flood behavior
    graceful GOAWAY behavior

Where nghttp2 already provides safe enforcement, use it rather than duplicating
protocol state in Perl.

Current implemented limits include:

    server/client decoded header list: 65,536 bytes by default
    client aggregate active buffer_body storage: 64 MiB per H2 connection
    server advertised concurrent streams: 100
    client local active-stream admission cap: 100

The decoded header limit is advertised through SETTINGS_MAX_HEADER_LIST_SIZE and
enforced independently after HPACK expansion. The aggregate response buffer
limit counts only bytes still owned by active H2 buffer_body streams on that
connection and is released when a stream completes or fails.

Application-visible limits should be added only when there is a useful policy
choice rather than exposing every nghttp2 setting.

## Public connection classes

The largest structural question still open is the existing advanced
connection_class API.

Today:

    Client::Connection
    Server::Connection

are public HTTP/1 executors and may be subclassed.

The ordinary high-level Client and Server APIs can hide protocol-specific
executors, but a dual-protocol server must still define what happens to a custom
Server::Connection subclass after ALPN selects h2.

Do not solve this with runtime method injection, roles, or multiple inheritance.

This needs a small implementation spike before the public contract is changed.

Candidate approaches to test:

1. Keep low-level public Connection classes explicitly HTTP/1 and make HTTP/2
   high-level-only at first.
2. Extract shared transport/application behavior into a protocol-neutral
   connection base and make HTTP/1 and HTTP/2 sibling executors.
3. Keep the application connection object stable and compose a private protocol
   executor into it.

Option 3 has the cleanest long-term application identity but would require a
careful HTTP/1 refactor. Do not perform that refactor until the nghttp2 spike
shows that the executor boundary is practical.

## Dependency policy

Do not make HTTP/1 users depend on a second HTTP/2 implementation merely for
symmetry.

The first spike should test Net::HTTP2::nghttp2 as an optional development
dependency.

After the spike, decide whether HTTP/2 support is:

    a normal required dependency
    an optional capability enabled when the binding is installed

The decision should consider CPAN installation reliability, Alien::nghttp2
behavior, CPAN Testers coverage, and the maintenance cost of conditional
features.

Do not maintain both Protocol::HTTP2 and nghttp2 production backends unless a
real portability requirement justifies the duplication.

## Validation plan

Correctness comes before optimization.

The implementation should be tested with:

    h2spec
    nghttp / h2load
    curl HTTP/2 client behavior
    TLS ALPN negotiation tests
    concurrent stream tests
    request/response streaming tests
    per-stream cancellation tests
    GOAWAY tests
    flow-control stall/resume tests
    large/fragmented header tests
    HPACK dynamic-table tests
    malformed frame tests
    Rapid Reset tests

Existing HTTP-level tests for redirects, authentication, cookies, buffering,
streaming bodies, and operation history should be reused against HTTP/2 wherever
the semantics are protocol-independent. Focused H2 coverage now includes
redirect + cookie + authentication retry policy in
`t/101-http2-high-level-policy.t`.

Performance benchmarking should compare:

    HTTP/1 vs HTTP/2 in Linux::Event::HTTP
    HTTP/2 vs current nghttp2-backed servers
    one connection / many streams
    many connections / moderate streams
    scalar bodies
    streaming bodies
    request-body workloads

Do not optimize the integration around a one-stream echo test.

## Implementation phases

### Phase 1 - dependency and transport spike

No public API commitment.

Build a minimal private HTTP/2 session adapter using Net::HTTP2::nghttp2.

Prove:

    client and server sessions can run on Linux::Event streams
    ALPN h2 selection is visible before HTTP bytes are emitted
    mem_recv/mem_send integrate cleanly
    multiple streams make progress concurrently
    scalar request/response bodies work
    streaming DATA can defer and resume
    h2spec can exercise the server

Measure basic overhead before deciding whether a deeper native-buffer adapter is
worth maintaining.

### Phase 2 - shared message mapping

Map HTTP/2 header sections into the existing Request/Response model.

Resolve Request scheme/authority metadata.

Create one Transaction per stream.

Prove informational responses, body completion, cancellation, and delayed
server responses.

### Phase 3 - high-level Server

Enable TLS ALPN h2/http/1.1 selection behind Linux::Event::HTTP::Server.

Preserve the ordinary callback API.

Support multiplexed requests and per-stream response bodies.

Define safe defaults for HTTP/2 settings and resource limits.

### Phase 4 - high-level Client

Enable TLS ALPN selection behind Linux::Event::HTTP::Client.

Make the connection pool capacity-aware and multiplex Client::Operations across
HTTP/2 streams.

Reuse redirect, authentication, cookie, and URL policy without duplicating it in
the HTTP/2 executor.

### Phase 5 - hardening and performance

Run h2spec and adversarial protocol tests.

Add h2load comparison benchmarks.

Only then investigate native-buffer integration, connection coalescing,
cleartext prior knowledge, trailers, extended CONNECT, and WebSocket-over-H2.

## Validated nghttp2 spike

The initial transport spike is complete.

Net::HTTP2::nghttp2 0.008 installed successfully in the project CI environment
and interoperated directly with Linux::Event Streams.

The cleartext spike carried nine simultaneous streams on one connection,
including request DATA and a deferred/resumed response body.

The TLS spike negotiated `h2` through Linux::Event ALPN before application
protocol input and then completed an nghttp2 request/response over the encrypted
Stream.

Therefore nghttp2 is now the selected first HTTP/2 protocol-engine direction,
not merely a candidate.

This does not yet make Net::HTTP2::nghttp2 a required production dependency.
The protocol-engine question is settled; the remaining dependency question is
how the CPAN distribution should advertise/install the optional H2 capability.

## Current implementation state

The shared message mapper, private client/server nghttp2 executors, TLS ALPN
selection, high-level Server/Client integration, multiplexing, streaming
uploads/responses, decoded header limits, aggregate response-buffer limits,
GOAWAY draining, and pre-ALPN same-origin queue are implemented on the HTTP/2
experiment branch.

High-level redirect, cookie, and authentication policy has also been validated
across multiple HTTP/2 Transactions without duplicating that policy inside the
HTTP/2 executor.

Current hardening work should focus on remaining production boundaries rather
than rebuilding completed phases. In particular:

- keep h2spec at or better than the documented nghttp2 baseline;
- do not implement transparent GOAWAY replay without reliable received
  last_stream_id information;
- decide optional dependency/install metadata before release;
- resolve/document the advanced custom connection_class contract;
- add security/resource hardening where nghttp2 does not already provide it;
- benchmark realistic multiplexed HTTP/2 workloads before native-buffer
  optimization is considered.
