# Linux::Event::HTTP - Unblock Reconstruction Plan

Status: Stages A-E implemented and verified (including strict HTTP2 conformance, real HTTP3/QUIC, and WebSocket/handoff integration). Stage B HTTP1 performance characterized with reproducible published-stack comparisons; exact legacy throughput parity is not required. Stage F cleanup/packaging verified; final release audit and maintainer approval remain.
Date: 2026-10-22
Repository: https://github.com/haxmeister/perl-Linux-Event-HTTP
Working branch: `feature/unblock-http-rebuild`
Starting main SHA: `c0bf714e0f08f9031684e2eb4fd70dea3c68449f`

## 1. Goal and scope

Rebuild Linux::Event::HTTP as a thin, high-performance, Linux-native
integration around Unblock::HTTP. This is a deliberate redesign, not an
incremental preservation of the original HTTP implementation.

Linux::Event is primarily a communications engine. A programmer should be
able to speak HTTP/1, HTTP/2, HTTP/3, and optionally WebSocket without
knowing how to attach protocol engines, manage ALPN, drive QUIC, or translate
between event-loop and protocol callbacks. Simple usage must remain simple;
advanced transport and protocol capabilities must remain accessible.

NO BACKWARD COMPATIBILITY IS REQUIRED. The new public API, callback
signatures, object model, and internals may break all previous releases.
Document migration-relevant changes, but do not retain duplicate engines,
wrappers, compatibility shims, or old code solely for old users.

The redesign must not turn Linux::Event::HTTP into a web framework or
user-agent policy library. Routing, template rendering, sessions, middleware,
automatic redirect following, cookie jars, authentication policy, caching,
multipart upload parsing, and high-level proxy policy belong above this layer
or in optional future facilities. Do not create Linux::Event::Web as part of
this work. Uniform::Upload was reviewed and deliberately deferred.

## 2. Layer ownership

- Linux::Event: epoll/reactor, TCP/Unix sockets, listeners, streams, TLS,
  UDP datagrams, timers, native buffers, backpressure, and stream transitions.
- Unblock::HTTP: framework-neutral Server and Client coordination, HTTP
  engine selection, transaction/request lifecycle, client scheduling,
  connection pooling, ALPN policy, and protocol-aware WebSocket transitions.
- Unblock::HTTP1/2/3: HTTP parsing, framing, correctness, flow control,
  multiplexing, and protocol-specific lifecycle.
- Net::QUIC: standalone QUIC transport, with driver UDP/timer requirements.
- Unblock::WebSocket: framework-neutral WebSocket implementation.
- Uniform::HTTP: canonical HTTP Request and Response messages.
- Linux::Event::HTTP: turnkey Linux-native Server and Client endpoint
  integration, transport ownership, native ABI bridging, listener/connection
  lifecycle, and small application-facing convenience methods.

Use actual Unblock Transaction objects and Uniform Request/Response objects
at the application boundary. Do not recreate Linux::Event::HTTP-specific
Request, Response, Transaction, or client Operation wrappers. The transport
adapter is internal; callers must not have to implement `unblock_send`,
`unblock_finish`, `unblock_abort`, `unblock_upgrade`, connection
factories, timer callbacks, or native consumer plumbing.

Preserve the independence of Unblock and Net::QUIC. Do not put framework
adapters in Unblock distributions. The Linux::Event adapters belong here.

Performance boundary (reaffirmed 2026-10-25):
- Never change Unblock's parsers, response lifecycle, callback contract or
  internal API to compensate for a Linux::Event-specific transport cost.
- An optimization in Unblock is acceptable only if it is a defensible
  framework-neutral HTTP improvement, preserves canonical Uniform semantics,
  benefits other attached transports as well, and has standalone regressions.
- Linux reactor, native consumer and socket ownership optimizations must
  remain in Linux::Event::HTTP or Linux::Event as appropriate.
- A benchmark-only diagnostic may use a frozen prebuilt canonical response
  to bound construction overhead; it does not authorize production response
  caching, weakened validation or alternate per-framework protocol modes.
- Measure matched throughput/CPU and correctness before claiming performance
  wins. Baseline parity for h2spec is not clean conformance.

## 3. Agreed public Server API

Illustrative proposed API; not yet implemented:

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

Contract:
- HTTP/1.0/1.1 available by default. `http2 => 1` and `http3 => 1`
  request additional protocol support; protocol hashrefs such as
  `http2 => { ... }` expose engine tuning. Confirm constructor shape and
  validation when implementing.
- TLS configuration stays with Linux::Event. For H2/H3, arrange ALPN and
  QUIC readiness/UDP/timers internally. A single application request
  callback works for all HTTP versions.
- `on_headers($tx, $request)` runs as soon as headers are available and
  permits early rejection, streamed body setup, and `$tx->on_data(...)`.
- `on_request($tx, $request)` runs ONCE after the entire incoming body
  and trailers complete successfully. In default mode Unblock provides a
  bounded complete body; with `on_data` it streams and does not accumulate
  the complete body. A failed/cancelled body never invokes `on_request`.
- Default buffered body limit follows Unblock (currently 1 MiB) unless
  explicitly configured otherwise. Never accumulate unbounded bodies.
- Responses use `$tx->respond(...)`, `$tx->write(...)`,
  `$tx->end(...)`, and existing Transaction completion/error callbacks.
- Transactions are engine objects; callback ordering/terminal state must
  remain consistent with Unblock, including asynchronous write acceptance.
- Expose ordinary listener introspection and control: `loop`, `listener`,
  `host`, `port`, `pause`, `resume`, `close`.
- Define a proposed `shutdown(grace => $seconds, on_complete => sub {...})`
  as full service draining, distinct from merely closing listening sockets.
  HTTP/1 completes admitted requests, H2 uses GOAWAY, H3 uses protocol
  shutdown/drain. Timeouts use seconds; do not block the event loop.
- HTTP service controls its owned connections. A generic handoff transfers
  ownership. WebSocket shutdown must distinguish HTTP1 whole-socket and
  H2/H3 per-stream sessions.
- Do not introduce a new universal public Connection wrapper. Provide
  advanced transport/peer/TLS introspection without per-body-chunk cost.

## 4. Agreed public Client API

Illustrative proposed API; not yet implemented:

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop => $loop,
    http2 => 1,
    http3 => 1,
);
my $op = $client->request(
    method => 'GET',
    url => 'https://example.com/',
    timeout => 15,
    on_response => sub ($tx, $response) {
        say $response->status;
    },
    on_error => sub ($object, $error) {
        warn $error;
    },
);
```

Contract:
- Linux::Event::HTTP supplies native `connect_stream`, `connect_quic`,
  `defer`, `schedule_timer`, and `release_connection` callbacks
  required by Unblock::HTTP::Client. No application adapter code.
- Reuse Unblock's pools, ALPN policy, H2/H3 multiplexing, Alt-Svc policy,
  cancellation, and request queue. No second HTTP connection pool.
- Without `on_data`, buffer a complete bounded response and call
  `on_response` at completion. With `on_data`, call `on_response` at
  headers, deliver chunks via `on_data`, then `on_end`. Preserve
  `on_error`, `on_finish`, and informational response callbacks.
- Return the real Unblock operation handle immediately; its
  `transaction()` becomes a real engine Transaction after dispatch.
  Allow cancellation before or after dispatch. Pre-dispatch failures
  receive an Operation, not an invented Transaction.
- Per-request timeouts cover queueing, connect, and response completion.
  Use Linux::Event timers; timer values are seconds.
- Permit strict `http_version => '1.1'|'2'|'3'` requests. A strict
  unavailable version fails; don't silently downgrade.
- Keep optional shorthand `get`, `head`, `post`, `put`, `delete`
  only when they add negligible complexity.
- Expose pool observations, `pending_count`, `network_changed`,
  and `shutdown` with Unblock semantics.
- Do not automatically follow redirects, manage cookies or credentials,
  replay dispatched requests, or implement other user-agent policy.
  Protocol-level CONNECT/tunneling remains necessary for generic
  communications; application proxy policy belongs above this layer.
- Important open upstream improvement: investigate an event
  `on_transaction($tx)` at request dispatch to initiate streaming
  request bodies without a second pre-connection buffer. The current
  Unblock client gives an Operation before admission and a Transaction
  only after admission. Do not invent method injection or a duplicate
  body queue to work around that. Verify actual H1/H2/H3 request-body
  write/end interfaces and backpressure before committing to the
  callback shape.

## 5. WebSocket and generic protocol handoff

Keep `Linux::Event::WebSocket` as a separate distribution providing
dedicated Linux-native WebSocket Client/Server entry points. That package
can later be rebuilt on Unblock::WebSocket plus Linux::Event::HTTP.
Do not modify it during this reconstruction without fresh authorization.

Linux::Event::HTTP itself optionally supports:
- `on_websocket($tx, $request)` on Server and
  `connect_websocket(...)` on Client through the existing Unblock
  coordination; ordinary HTTP remains independent of WebSocket.
- HTTP/1 Upgrade and CONNECT: transfer the whole live TCP/TLS stream,
  preserve socket and write ordering, and deliver unread post-boundary
  bytes exactly once to the new native consumer.
- HTTP/2 and HTTP/3 Extended CONNECT: transfer an individual multiplexed
  stream, NOT the underlying socket/QUIC connection. Other HTTP streams
  continue undisturbed.
- Explicit generic, non-WebSocket protocol handoff. A generic hook may
  require a small, framework-neutral Unblock::HTTP contract addition.
  Investigate this first; don't bypass the unified abstraction with
  a Linux-only hack. Keep the existing Linux::Event transition_to()
  capabilities where a whole stream is handed off.
- Cancellation and shutdown ownership must be well-defined for both
  socket-wide and stream-local transitions.

## 6. Performance and native ABI requirements

Performance is evaluated through documented, reproducible measurements,
not a fixed throughput target or automatic requirement to match the original
HTTP/1 implementation. Correctness, event-loop responsiveness, bounded
memory, working backpressure and native input paths take priority over
additional requests per second. The HTTP1 performance comparison and its
limitations are recorded in docs/HTTP1-PUBLISHED-STACK-PERFORMANCE.md.

Finish the reconstruction after the existing bounded, API-neutral
performance experiments. Do not extend the release gate with more
micro-optimizations or introduce new public callback/API variants for
marginal gains. Shared Unblock engines must stay event-loop neutral.
Keep an optimization only if its correctness, simplicity and measured
benefit justify the maintenance cost; it can remain unmerged if not.

Current Linux::Event::HTTP has a native HTTP/1 borrowed-input consumer
using Linux::Event's native consumer ABI. The Unblock::HTTP1/2 native
ABI provider interfaces are distinct from Linux::Event's
`les_consumer_ops_v1_t` ABI: matching version numbers do not make
function tables interchangeable.

Implement a small native XS bridge if required, in this repository,
which adapts per-connection Unblock contexts to the Linux::Event raw
consumer lifecycle. Validate create/destroy ownership, incoming borrowed
(data,len) windows, consumed counts, backpressure, EOF, error,
reentrant teardown, and HTTP1 INPUT_SWITCH/remainder handling. Keep
post-Upgrade bytes intact and deliver them exactly once. Consider
H2 native output sinks only where supported and measured.

Start with a correct Perl transport path if useful for integration;
then establish measured native fast paths before removing prior
performance-critical code. No duplicate protocol parser should survive.
Avoid duplicate buffering, per-chunk generic forwarding, redundant
object creation, hot-path closures, and unnecessary method dispatch.

Record baseline and rebuilt performance under the same workload and
environment. Existing historical one-process benchmark reference
(see `handoff.md`, Sep 2026):
- GET / 32-byte response: 35,679.8 requests/s
- GET / 16 KiB response: 26,843.4 requests/s
- POST / 4 KiB request -> 32-byte response: 21,653.9 requests/s

These historical figures are reference only, not a valid cross-machine
A/B comparison. Also test client throughput, CPU, RSS/retention,
per-connection concurrency, HTTP2 multiplexing, QUIC, and WebSockets.
Do not claim a performance gain without a reproducible same-run test.

## 7. Dependency and packaging decision

The published dependency stack is Unblock::HTTP >= 0.03,
Unblock::HTTP1 >= 0.13 and Uniform::HTTP >= 0.06. HTTP2 >= 0.13,
HTTP3 >= 0.14 with Net::QUIC >= 0.06, and Unblock::WebSocket >= 0.02
remain optional. Enable-time guards report missing or outdated engines.
The earlier upstream publication and optional-packaging blockers are resolved;
validation now uses actual CPAN distributions instead of feature revisions.

Retain Linux-only scope. Establish supported Perl versions from the
actual current dependencies and CI before updating MIN_PERL_VERSION;
historically the current Linux::Event::HTTP baseline is Perl 5.36+.

Current implementation evidence: `docs/UNBLOCK-REBUILD-STATUS.md`.
The architecture below remains authoritative. Stage B performance has been measured and documented; the original-server throughput gap is an acknowledged trade-off, not an indefinite blocker. The optional, unpublished internal HTTP1 experiment is tracked separately.

## 8. Work plan and validation gates

Work on `haxmeister/perl-Linux-Event-HTTP`, branch `feature/unblock-http-rebuild`.
The previously authorized upstream integration work is now published.
All upstream distributions are read-only during this phase; any further
upstream change needs separate discussion and authorization.
Do not modify main, merge, tag, bump releases, push other repositories,
or start a release process without user approval. If upstream changes
are needed, prepare a precise proposal and obtain authorization before
changing them. Update `handoff.md` frequently.

Stage A - Inventory, baseline, and executable skeleton:
- Re-read this plan, `handoff.md`, current source, Unblock current
  released interfaces, native headers, and Linux::Event Stream APIs.
- Record dependency/ABI/feature compatibility, baseline tests and
  same-run benchmark setup, including server/client performance.
- Build a minimal Server/Client around Unblock without relying on
  the old HTTP parsers or old HTTP-specific object model.
- Gate: simple end-to-end HTTP1 GET/POST from the proposed APIs.

Stage B - HTTP/1 lifecycle and native fast path:
- Implement true Linux::Event connection ownership, EOF/error/drain
  contracts (including output congestion), timers, cancellation,
  bounded body reception, request/response streaming, and repeated
  HTTP/1 requests over persistent sockets.
- Implement and test native input bridge or a measured better path.
- Gate: lifecycle, ownership, backpressure and documented native versus legacy benchmarks; no requirement for parity in peak requests/second.

Stage C - HTTP/2:
- Add TLS ALPN, H1 fallback, multiplexed Client/Server, concurrent
  stream independence, GOAWAY/draining, flow-control and cancellation.
- Gate: HTTP2 loopback, concurrency, ALPN, callback reentrancy,
  and focused protocol conformance.

Stage D - HTTP/3:
- Add Linux::Event UDP, Net::QUIC Driver and dynamic timer handoff,
  verified origin TLS/QUIC, H3 client/server acceptance and stream
  scheduling, shutdown and error paths.
- Gate: real QUIC/TLS loopback, timeout, credit recovery,
  cancellation, and multi-connection tests.

Stage E - WebSocket and generic handoff:
- Add opt-in HTTP1 Upgrade and H2/H3 Extended CONNECT through Unblock.
- Implement generic Upgrade/CONNECT semantics with an agreed
  framework-neutral contract where necessary.
- Gate: same-read post-upgrade tail exactly once, TLS preservation,
  H2/H3 independent stream traffic, close/shutdown ownership.

Stage F - Clean replacement and release-readiness evaluation:
- Delete superseded private parsers, duplicated HTTP2/HTTP1 executors,
  old Request/Response/Transaction/Operation wrappers, obsolete XS,
  irrelevant old policy helpers, and obsolete tests/examples.
  Remove only after coverage for their required capabilities exists.
- Rewrite all public docs, SYNOPSIS, POD, examples and dependency
  metadata for the new interface. No compatibility layer.
- Gate: regression, leak/reentrancy, security and malformed-input
  tests; Perl 5.36/5.38/5.40/5.42/5.44 and current/latest threaded
  lanes as supported; `make disttest`; protocol conformance;
  independent baseline/rebuilt benchmark report. An unexplained correctness,
  resource, or event-loop starvation failure blocks release; a documented
  throughput difference alone does not. No release without explicit approval.

## 9. Design and safety constraints

- Maintain Linux::Event's subclass-based/native low-overhead model.
  Prefer direct engine input and output, not multi-layer byte relaying.
- Avoid async/await, future chains, global state, object monkeypatching,
  and unnecessary per-message callback closures.
- Use ASCII in code/POD; place POD at file end; timers in seconds.
- Do not presume old CI, release numbers, or GitHub branches are current.
- Do not revisit prior resolved Linux::Event core ALPN segfault analysis
  without a new reproduction.
- Respect existing Linux::Event core and all Unblock distributions as
  read-only dependencies until explicit authorization to edit them.
- Review remote refs and working tree before editing, run focused
  tests after each step, and update `handoff.md` after each milestone.
- Keep the plan updated when a genuine design decision is approved;
  record deviations and their technical reasons rather than silently
  changing the agreed boundaries.

## 10. First action for implementation chat

Read `docs/UNBLOCK-REBUILD-PLAN.md` and current `handoff.md` from
`feature/unblock-http-rebuild`, inspect repository status, then review
the current published Unblock::HTTP / HTTP1 / HTTP2 / HTTP3 / Net::QUIC
and Linux::Event integration contracts. Start Stage A. Make useful
incremental implementation changes on the feature branch; benchmark
and test rather than endlessly revisiting architectural discussion.
Do not modify main or other repositories without fresh authorization.
