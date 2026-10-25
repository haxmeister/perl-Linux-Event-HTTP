# Linux::Event::HTTP

This feature branch is reconstructing Linux::Event::HTTP as a thin Linux-native
integration of Unblock::HTTP. **It is not a completed replacement or a release
candidate.** There is no compatibility layer for the previous API.

The implemented slice provides HTTP/1 servers and clients over TCP and TLS,
real Unblock transactions and Uniform messages, bounded buffering, streaming
reception/responses, pooling, cancellation, timers and native borrowed input.
Queued streaming uploads and graceful HTTP/1 service shutdown are implemented.
Optional HTTP/2 over TLS uses ALPN, multiplexing, flow control and GOAWAY.
HTTP/3 Client and combined TCP/UDP Server integration is verified
with real QUIC/TLS loopback, timeout, cancellation, congestion and
multi-connection tests. HTTP/1 Upgrade and HTTP/2/3 WebSocket and generic
CONNECT handoff are verified. HTTP/1 throughput remains an open release gate. HTTP/2 strict
h2spec conformance passes with Unblock::HTTP2 0.13 or newer.

## Server

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    port => 8080,
    on_request => sub ($tx, $request) {
        $tx->respond(status => 200, body => "Hello\n");
    },
);
$loop->run;
```

`on_headers($tx, $request)` runs at headers. `on_request` runs once after the
whole body and trailers complete successfully. To stream an incoming body,
register `$tx->on_data(sub ($tx, $bytes) { ... })` during `on_headers`.
Otherwise Unblock buffers up to 1 MiB by default. Set
`http1 => { max_buffered_body_bytes => $bytes }` to change that bound.

Stream a response using `$tx->respond(status => 200, stream_body => 1,
on_drain => sub ($tx) { ... })`, followed by `write` and `end`. A false
`write` return means the chunk was accepted but the producer must pause until
`on_drain`; never resend that chunk.

`loop`, `listener`, `host`, `port`, `connection_count`, `pause`, `resume` and
`close` expose service controls. `close` closes TCP admission; with HTTP/3 enabled it also starts QUIC
GOAWAY draining. It does not immediately discard admitted H3 streams.
`shutdown(grace => 30, on_complete => sub ($server) { ... })` stops accepting,
completes admitted requests and responses, and closes any remaining owned
sockets after the grace deadline. Completion runs once after all owned
connections and transactions finish. It may run synchronously if idle.

## Client

```perl
use Linux::Event::HTTP::Client;

my $client = Linux::Event::HTTP::Client->new(loop => $loop);
my $op = $client->get('https://example.com/',
    timeout => 15,
    on_response => sub ($tx, $response) {
        say $response->status;
        say $response->body;
    },
    on_error => sub ($object, $error, @protocol_details) { warn "$error\n" },
);
$loop->run;
```

Without `on_data`, `on_response` receives the complete bounded response.
Supplying `on_data` selects streaming automatically: headers trigger
`on_response`, chunks trigger `on_data($tx, $bytes)`, and successful body
completion triggers `on_end($tx)`. `on_finish` runs on terminal cleanup.

The return value is the real Unblock operation. It supports `cancel`, `state`,
`error`, `is_terminal` and `transaction`; the transaction appears after
admission. Timeouts include queueing, connection establishment and reception.

Unblock owns the pools and their limits. `pool_stats`, `pending_count`,
`network_changed` and `shutdown` retain Unblock's semantics. Client shutdown
cancels queued work, lets active work finish and retires connections.
Stream an upload with `stream_body => 1` and
`on_transaction => sub ($tx) { $tx->write(...); $tx->end }`. The callback gets
the real transaction when queued work is admitted. It can run synchronously
on an available connection; use its argument rather than an operation
variable that may not yet have been assigned. There is no second body queue.

HTTPS verifies certificates and the original hostname by default. Use
`tls => { ca_file => $path }` for a private trust root. The Client owns TLS
hostname and ALPN selection. Server TLS options are passed as
`tls => { cert_file => $cert, key_file => $key }`.

## HTTP/3

Install `Net::QUIC >= 0.06` and `Unblock::HTTP3 >= 0.13`, then enable
`http3 => 1`. A strict Client request can use `http_version => '3'`.
A client may pass `quic => { ca_file => $path }` for a private CA and
uses Linux::Event's asynchronous UDP hostname resolution and Net::QUIC's
verification of the original HTTPS origin. The existing Unblock pool owns
the operation and H3 multiplexing.

A Server with HTTP3 enabled binds a UDP socket on the same concrete host
and port as its TCP listener, using `tls => { cert_file => ..., key_file => ... }`.
`quic => { transport => { ... } }` forwards QUIC policy to Net::QUIC.
The same `on_headers` and `on_request` callbacks receive actual H3
transactions and Uniform messages.

Current limits: wildcard UDP binding, H3-only listeners, comprehensive QUIC
migration and packet-origin metadata are not supported yet. Graceful H3
shutdown, failure, cancellation, congestion and multi-connection coverage
pass their required Stage D integration regressions.
Do not treat this feature branch as release ready.

## HTTP/2

Install `Unblock::HTTP2 >= 0.13` and set `http2 => 1` on Client and Server.
Server HTTP/2 requires `tls => { cert_file => ..., key_file => ... }`; ALPN
selects HTTP/2 while HTTP/1 stays available by default. Set `http1 => 0` to
disable it. Cleartext HTTP/2 prior knowledge and h2c are not implemented.

The same request callbacks receive actual HTTP2 Transactions and Uniform
messages. Protocol-specific engine tuning belongs in `http2 => { ... }`.
Client `http_version => '2'` is strict; ordinary requests can negotiate
HTTP/1 fallback. Cancelled H2 streams leave sibling streams active. Server
`shutdown` sends GOAWAY and drains admitted streams before its grace deadline.

`on_error` retains the engine callback arguments; HTTP/2 can supply a third
protocol error-code argument. With Perl signatures, use an optional argument
or `@protocol_details` as in the example above.

## Implementation and dependencies

Native borrowed HTTP/1 and HTTP/2 input is the default. `native_input => 0` selects the ordinary
Perl input path for comparisons and diagnostics. Both paths share lifecycle
callbacks; the native path adapts the two distinct ABIs and retains the host
across callbacks that can close the stream. It contains no HTTP parser.
HTTP/2 native input uses its own checked ABI table; output uses the ordinary
attached host, respecting congestion until on_drain. Malformed protocol input
closes the affected connection without unwinding the reactor.

Current direct runtime requirements: Linux, Perl 5.36+, Linux::Event 0.117,
Unblock::HTTP 0.02 and Uniform::HTTP 0.06. Unblock::HTTP requires
Unblock::HTTP1 and URI. HTTP::CookieJar and Uniform::HTTP::Auth are no
longer direct dependencies of this Linux integration layer.
This development checkpoint additionally needs the upstream feature commits
listed in the [status document](docs/UNBLOCK-REBUILD-STATUS.md) for admission
callbacks and server drain. Their version numbers are deliberately unchanged;
the published 0.02/0.12 releases do not contain these additions. On the feature
branch HTTP2/HTTP3 dependencies are optional, with an explicit error when an
enabled engine is unavailable. The superseded private HTTP parsers, executors and public Request/Response
wrappers have been removed from this feature branch; the untouched main
baseline retains the historical implementation and tests.

The measured server path is currently substantially slower than the original.
The performance gate has not passed. See
[implementation status and measurements](docs/UNBLOCK-REBUILD-STATUS.md),
[approved plan](docs/UNBLOCK-REBUILD-PLAN.md), and [active handoff](handoff.md).

## Development checks

```sh
perl Makefile.PL
make
make test
REBUILD_NATIVE_INPUT=0 make test
```

`make test` runs `t/rebuild/*.t`, the new contract's suite. The old
`t/*.t` suite has been removed from this feature branch; the complete old
suite and its pre-rebuild implementation remain on untouched main.
The untouched baseline passed 57 files / 1,489 tests before reconstruction.

CI is configured for Perl 5.36, 5.38, 5.40, 5.42, 5.44, latest and latest
threaded. Local results and unexecuted CI lanes are distinguished in the status
document. No release, version bump, tag or merge is part of this work.
