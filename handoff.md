# Linux::Event::HTTP handoff

Updated: 2026-09-25 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Repository: `haxmeister/perl-Linux-Event-HTTP`

Canonical branch: `main`

Project boundary: modify only Linux::Event::HTTP unless the user explicitly
authorizes another repository in the current chat.

### Post-0.002 main state

The native client response-head work from PR #38 is now merged to `main`.

Merge commit:

`ddbc9f177b25b36bcc3d4d17d9229e2b4978a25e`
"Merge native client response-head input"

Production client input now parses HTTP/1 response heads directly from
Linux::Event's native ordered-input buffer. The existing Perl body
framing/delivery state machine remains in place after the head boundary for
Content-Length, chunked, close-delimited, `buffer_body`, and `on_body`.

The obsolete Perl response-head parser was removed. Focused native-client
coverage is in `t/16-native-raw-client.t`.

Final candidate validation before merge:

- Perl 5.36 PASS;
- latest Perl PASS;
- latest threaded Perl PASS;
- 42 files / 1,033 tests;
- `make disttest` PASS;
- same-run client receive A/B retained roughly 14-23% throughput improvement
  with roughly 14-19% lower client CPU per response.

PR #38 is closed/merged. Its remote branch
`experiment/client-receive-path` contains no unmerged work.

### Current cross-server performance snapshot

Benchmark trigger/support commit:

`f37db2b8a27600edd7e13deab43e075feecc0fce`
"[benchmark] ci: run explicit cross-server comparison on push"

GitHub Actions run:

`36191905900`

The comparison job passed completely. It used one process / one execution slot
per server, loopback TCP, one shared raw Perl benchmark client, 100 persistent
connections, pipeline depth 1, 1,000 warmup requests, 10,000 measured requests
per repeat, and 3 rotated repeats.

Median throughput:

| Server | GET 32 B req/s | GET 16 KiB req/s | POST 4 KiB -> 32 B req/s |
| --- | ---: | ---: | ---: |
| Linux::Event::HTTP | 35,679.8 | 26,843.4 | 21,653.9 |
| Feersum | 74,244.0 | 64,169.7 | 66,398.9 |
| Mojolicious | 1,866.4 | 1,749.2 | 1,824.4 |
| Node.js http | 22,830.4 | 21,369.6 | 20,525.2 |
| Go net/http | 61,524.1 | 38,758.0 | 49,945.8 |
| Python aiohttp | 20,336.2 | 18,377.2 | 15,719.9 |
| libh2o evloop | 73,570.5 | 64,231.4 | 64,984.0 |

Interpretation:

- Linux::Event::HTTP is clearly ahead of Node.js and aiohttp for both GET
  workloads and slightly ahead of Node.js on the 4 KiB POST workload.
- Linux::Event::HTTP remains materially behind Feersum and libh2o on all three
  workloads.
- Compared with Go net/http, Linux::Event::HTTP is about 58% of Go throughput on
  GET/32 B, about 69% on GET/16 KiB, and about 43% on POST/4 KiB.
- Request-body processing remains the largest relative server-side performance
  gap in this matrix.

The benchmark JSON reports are retained in the
`cross-server-comparison` artifact from run `36191905900`.

Last week's native server-input work was still worthwhile. The exact pre-raw
same-run comparisons recorded during 0.002 preparation were:

- GET / 32-byte response: 31,133.8 -> 33,842.8 req/s (+8.7%);
- GET / 16 KiB response: 23,032.8 -> 26,717.6 req/s (+16.0%);
- POST / 4 KiB request, 32-byte response:
  19,051.8 -> 20,186.5 req/s (+6.0%).

The new competitor snapshot is broadly consistent with those post-native server
numbers and shows no evidence of a server-side regression after the later client
work.

### Released baseline

Linux::Event::HTTP **0.002 has been uploaded to CPAN and is the current released
baseline**.

Release 0.002 is stamped `2026-09-20` in Changes at commit:

`3f18be8c1677f9e2704dcf718d3071a9e19359ad`
"release: stamp 0.002"

The release-state documentation commit is:

`d6f0f849e0da4260927e681a1337126b700d6c6c`
"docs: record stamped 0.002 release state"

Do not treat 0.002 as pending release work. New development is post-0.002 and is
expected to become the 0.003 development cycle unless the user decides otherwise.

Linux::Event::HTTP 0.002 requires:

`Linux::Event >= 0.117`

Do not lower that dependency without a specific compatibility investigation.

### Current production architecture

Production native server-input implementation:

`71ec89135be61094a1599e3cee74dadd46addf02`
"Make native HTTP input the production server path"

`Linux::Event::HTTP::Server::Connection` owns HTTP byte input through the
Linux::Event native-consumer ABI:

- the class declares the HTTP raw native consumer directly;
- the base class no longer defines ordinary `on_data`;
- application subclasses customize `on_request`, `on_body`,
  `on_request_end`, transport lifecycle callbacks, and `stream_tuning`;
- defining `on_data` on an HTTP Server::Connection subclass is invalid because
  HTTP owns protocol byte input;
- request heads are parsed before native input is unnecessarily surfaced into
  Perl;
- Content-Length bodies remain native for draining/direct on_body delivery;
- chunked bodies remain native with persistent pico decoder state;
- Upgrade and CONNECT preserve same-read post-HTTP bytes across
  `transition_to()`.

The public HTTP/1 feature set includes server/client execution, persistent
connections, streaming request and response bodies with backpressure, bounded
client buffering, redirects, cookies through HTTP::CookieJar, authentication
through Uniform::HTTP::Auth, explicit/default forward proxies, proxy
authentication, client/server CONNECT, Upgrade, HTTPS/TLS, protocol handoff, and
server ordered persistent request processing.

### Remaining HTTP/1 performance asymmetry

Server request input and client response-head input are now native.

The remaining client receive-path boundary is response-body handling:

```text
Linux::Event native input
    -> native HTTP response-head parse
    -> existing Perl response body framing/dispatch
```

That boundary is deliberate. Native response-body handling is not part of the
merged client-head change and should only be investigated as a separate measured
experiment.

### Client receive-path measurement result

Experiment branch:

`experiment/client-receive-path`

Validated benchmark commit:

`a09b16d328e648c3babf3e56f1bdd892ed6e5704`
"bench: retain client connection across terminal callbacks"

Draft experiment PR: #38.

GitHub Actions run `36188055780` on Perl 5.44.0 / Linux::Event 0.116
passed the normal 41-file / 1,029-test suite, the client benchmark smoke, the
five-case directional matrix, artifact upload, and `make disttest`.

Directional matrix configuration:

- 10,000 measured responses per repeat;
- 1,000 warmup responses;
- 100 persistent connections;
- 3 repeats;
- separate raw responder process;
- client-process CPU measured with CLOCK_PROCESS_CPUTIME_ID.

Median current-client results:

- 32 B Content-Length, drained: 6,507.3 responses/s; 153.612 us client CPU/response;
- 16 KiB Content-Length, drained: 6,222.9 responses/s; 160.665 us CPU/response;
- 16 KiB Content-Length, on_body: 6,077.0 responses/s; 164.471 us CPU/response;
- 16 KiB Content-Length, buffer_body: 5,880.3 responses/s; 169.954 us CPU/response;
- 16 KiB chunked, drained: 6,322.1 responses/s; 158.111 us CPU/response.

The isolated current Perl response-head parse plus transfer/framing decision
cost 33.849 us/response over 50,000 iterations. On the 32-byte workload this is
about 22% of total measured client CPU/response.

The instrumentation run observed exactly 1.000 Perl `on_data` call per response
for all five workloads. The 32-byte response delivered 95 bytes/call; the
16-KiB Content-Length response delivered 16,450 bytes/call; the chunked response
delivered 16,492 bytes/call. Therefore this experiment is not primarily about
reducing callback fragmentation. It is about avoiding the ordinary
native-buffer -> Perl scalar -> _http_client_input -> Perl response-head parser
path and unnecessary Perl buffer manipulation.

Conclusion: the measurement threshold is met. A native Client::Connection
receive-path prototype is justified. The experiment must still prove correctness
and repeatable end-to-end improvement before anything is promoted to production.

### Native client response-head prototype result

The first native client prototype keeps the scope deliberately narrow:

- response heads are parsed directly from Linux::Event's borrowed native input
  buffer by a dedicated HTTP/1 client raw-consumer provider;
- the parsed head is materialized as the existing public
  `Linux::Event::HTTP::Response` object;
- Content-Length, chunked, close-delimited, buffering, and `on_body` behavior
  still use the existing client body state machine through native fallback;
- Upgrade and successful CONNECT pause HTTP input while the zero-delay handoff
  is pending, preserving same-read post-head bytes for `transition_to()`.

The client uses a separate native-consumer operations table from the server.
HTTP request and response wire roles are therefore explicit rather than selected
by a server/client branch inside one provider.

Important prototype commits include:

- `61caa490694c2deb8f7f13b4bd7bbb60057b3e44`
  "experiment: add native HTTP client response consumer";
- `cabfc41bc7cc6e215e45151aa497a14912f12590`
  "experiment: expose native client consumer definition";
- `8d36e852c4baac0d6bd77dbcca98e92f28aa285e`
  "experiment: route client response heads through native input";
- `f7a8d035a1cef05aad45dd2b93353c04b7943e27` and
  `4a6541e889b75d9c4cb7a52f616882de1e4ee6ca`
  add pause/resume discipline to client Upgrade/CONNECT handoff;
- `afad8a3f5173aeb64062491309f634fc9c717897`
  updates the benchmark to instrument native fallback input.

The initial native prototype exposed one real handoff bug: after a successful
CONNECT or 101 head, the raw consumer could immediately see same-read target
protocol bytes and try to parse them as another HTTP response before the
scheduled handoff ran. Pausing HTTP input while the handoff is pending and
restoring the previous read state after `transition_to()` fixes this and matches
the server-side transition discipline.

After that fix the full suite passes, including Upgrade and CONNECT:
41 test files / 1,029 tests.

#### Same-run baseline versus native-head A/B

Decision-quality comparison run:

`36189414550`

Environment for both trees in the same GitHub Actions job:

- Perl 5.44.0;
- Linux::Event 0.116;
- same hosted runner;
- exact pre-native baseline commit
  `a09b16d328e648c3babf3e56f1bdd892ed6e5704`;
- native-head experiment from the current branch;
- 10,000 measured responses per repeat;
- 1,000 warmup responses;
- 100 persistent connections;
- 3 repeats per case.

Same-run medians:

| Workload | Baseline resp/s | Native resp/s | Throughput | Baseline CPU us/resp | Native CPU us/resp | CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 B Content-Length drain | 6,187.6 | 7,593.1 | +22.7% | 161.567 | 131.651 | -18.5% |
| 16 KiB Content-Length drain | 6,188.9 | 7,003.6 | +13.2% | 161.543 | 142.727 | -11.6% |
| 16 KiB Content-Length on_body | 6,054.9 | 6,959.9 | +14.9% | 165.140 | 143.657 | -13.0% |
| 16 KiB Content-Length buffer_body | 5,975.5 | 6,579.5 | +10.1% | 167.308 | 151.938 | -9.2% |
| 16 KiB chunked drain | 6,285.6 | 7,318.0 | +16.4% | 159.027 | 136.615 | -14.1% |

The same run passed the current full test suite and `make disttest`. Both
baseline and native benchmark JSON reports were uploaded from the same job.

Conclusion: native response-head input is worth keeping. The gain is broad,
repeatable on a same-run A/B, and achieved without rewriting body framing.
Before promotion, remove or clearly isolate stale ordinary response-head parsing,
add focused native-client regression coverage, update architecture/user
documentation, and decide whether native body handling should be a separate
follow-on experiment rather than part of this change.

### Cleaned native-client production candidate

The native client response-head change has now passed its cleanup and final
candidate gate.

Current candidate head:

`c20af7f6fad53598dbd30eade62db19a7bc4163f`
"experiment: allow reentrant next client transaction"

Follow-on documentation/test commits through:

`1bedc32dd5d01db9757dbc820bfa293b4e98cce1`
"docs: document client receive benchmark"

plus the reentrant-next-Transaction correction above remain on
`experiment/client-receive-path` / draft PR #38.

Cleanup completed:

- removed the obsolete Perl response-head parser from Client::Connection;
- kept the existing Perl body framing/delivery state machine as the fallback
  after a native final response head;
- retained immediate next-Transaction behavior when an `on_complete` callback
  starts another request before the prior body driver unwinds;
- added `t/16-native-raw-client.t` covering fragmented native heads,
  informational + final heads in one read, native input ownership, and
  reentrant close from `on_response`;
- updated README, architecture, client policy, benchmark documentation, and
  MANIFEST.

Final candidate CI run:

`36190306057`

Results:

- Perl 5.36: PASS;
- latest Perl: PASS;
- latest threaded Perl: PASS;
- full suite: 42 files / 1,033 tests;
- focused client receive benchmark smoke: PASS;
- exact pre-native baseline build: PASS;
- same-run baseline matrix: PASS;
- same-run cleaned native matrix: PASS;
- paired benchmark artifact upload: PASS;
- `make disttest`: PASS, again 42 files / 1,033 tests.

Final cleaned same-run A/B medians:

| Workload | Baseline resp/s | Native resp/s | Throughput | Baseline CPU us/resp | Native CPU us/resp | CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 B Content-Length drain | 9,911.4 | 12,197.4 | +23.1% | 100.871 | 81.961 | -18.7% |
| 16 KiB Content-Length drain | 9,141.9 | 10,772.7 | +17.8% | 109.330 | 92.778 | -15.1% |
| 16 KiB Content-Length on_body | 8,638.0 | 9,992.7 | +15.7% | 115.690 | 99.947 | -13.6% |
| 16 KiB Content-Length buffer_body | 8,007.8 | 9,668.6 | +20.7% | 124.660 | 103.403 | -17.1% |
| 16 KiB chunked drain | 9,067.7 | 11,094.1 | +22.3% | 110.263 | 90.131 | -18.3% |

Decision: keep native response-head input. Do **not** expand this change into a
native response-body rewrite. The current boundary already produces a large,
repeatable gain while preserving the mature Content-Length, chunked,
close-delimited, bounded buffering, callback, redirect/auth retry, and connection
reuse body lifecycle. Native body handling, if investigated later, must be a
separate measured experiment with its own correctness and maintenance case.

This production candidate was merged to `main` as PR #38 at
`ddbc9f177b25b36bcc3d4d17d9229e2b4978a25e`.

### Next agenda

The HTTP/1 native-client receive-path decision is complete and merged.

The next substantive development item is the HTTP/2 architecture investigation.
Before implementation, define:

1. how HTTP/2 connection and stream state map onto the existing
   Request/Response/Transaction model;
2. which semantics are genuinely shared with HTTP/1 and which need
   version-specific executors;
3. HPACK ownership and dependency strategy;
4. flow-control/backpressure integration with Linux::Event;
5. TLS ALPN selection between `h2` and `http/1.1`;
6. clear boundaries that avoid contaminating the public API with HTTP/2 wire
   details.

Separate performance follow-up remains available: the current cross-server
matrix shows the largest HTTP/1 server gap in request-body processing. Do not
mix that optimization work into HTTP/2 architecture unless the user explicitly
chooses to return to HTTP/1 performance first.

### HTTP/2 architecture investigation result

The first architecture investigation is complete and recorded in:

`docs/HTTP2-ARCHITECTURE.md`

Design commit:

`ccecc580c4b2a407b5965f3cb3f551f9158b0e93`
"docs: define HTTP/2 architecture investigation"

Current decisions:

- HTTP/2 remains in Linux::Event::HTTP rather than a separate distribution.
- Request, Response, Transaction, Client::Operation, Client, Server, and
  Body::Stream remain the shared application model.
- HTTP/1 and HTTP/2 need separate internal protocol executors.
- One HTTP/2 stream maps to one Transaction.
- Client pooling must become capacity-aware rather than treating a connection
  as simply idle/busy.
- Server conn->transaction can only mean the Transaction associated with the
  callback currently executing; asynchronous work must retain the Transaction.
- HTTP/2 pseudo-headers must not be exposed as ordinary message headers.
- Request scheme/authority needs a small protocol-neutral API design review.
- Body::Stream remains the outgoing producer; the HTTP/2 executor maps its
  accepted/drain contract onto stream + connection flow control and Linux::Event
  transport backpressure.
- HTTP/1 Upgrade and whole-socket CONNECT handoff do not generalize to HTTP/2;
  extended CONNECT needs a future stream-level transport abstraction.
- initial production HTTP/2 should target TLS ALPN h2; deprecated h2c Upgrade is
  explicitly out of scope.
- server push, connection coalescing, priority API, cleartext prior knowledge,
  and WebSocket-over-H2 are deferred until base HTTP/2 is correct.

Protocol-engine research currently favors nghttp2 through the low-level
Net::HTTP2::nghttp2 binding. Do not use the higher-level Net::HTTP2 client API,
and do not implement HPACK/frame/state machinery from scratch before testing the
nghttp2 integration.

The next action is a private Net::HTTP2::nghttp2 integration spike. It must not
change the public Client/Server API or refactor the production HTTP/1 executor.
The spike should prove Linux::Event transport integration, concurrent streams,
streaming DATA defer/resume, h2spec viability, and basic overhead before the
backend choice is frozen.

### HTTP/2 nghttp2 integration spike result

Active experiment branch:

`experiment/http2-nghttp2-spike`

Draft PR: #39.

The transport/protocol-engine spike has validated Net::HTTP2::nghttp2 0.008 as
the preferred HTTP/2 engine direction.

Key spike commits:

- `fc7d3039bfa50c68b6e35a94586bcacb74c647fe`
  "experiment: add nghttp2 Linux::Event integration spike";
- `af6f6fb0a6ecee6ece8fd576f38ccb79c52e3aa4`
  "experiment: fix nghttp2 pseudo-header capture";
- `1b42ecc80e1dac4d408993d4b3cdce36ce126aee`
  "experiment: prove h2 ALPN selection with nghttp2".

Validated CI run:

`36195688110`

Latest-Perl results:

- Net::HTTP2::nghttp2 0.008 plus libnghttp2 installed successfully in CI;
- `t/90-http2-nghttp2-spike.t` PASS;
- `t/91-http2-alpn-spike.t` PASS;
- full checkout test run with the two optional spike tests:
  44 files / 1,084 tests, PASS;
- existing HTTP end-to-end benchmark smoke PASS;
- existing client receive-path benchmark smoke PASS;
- `make disttest` PASS for the production MANIFEST.

The plain-TCP spike proves one Linux::Event connection can host one nghttp2
session with nine simultaneous streams:

- seven concurrent GET streams;
- one POST stream carrying request DATA;
- one deferred response whose data provider returns no data until a
  Linux::Event Timer fires, then resumes the stream.

All streams completed independently.

The TLS spike proves:

- server and client both advertise `h2` before `http/1.1`;
- both sides expose negotiated `selected_alpn eq 'h2'` before application
  protocol bytes are processed;
- nghttp2 sessions can be created after TLS transport readiness;
- an HTTP/2 request/response completes over the encrypted Linux::Event Stream.

The early spike failures were test-scaffolding errors, not protocol-engine or
Linux::Event failures. One came from a pseudo-header test regex losing its
backslash while being generated through JavaScript; another came from following
a stale Session synopsis that showed a leading session callback argument. The
actual 0.008 callback contract and XS implementation use the documented
positional forms without a leading session object.

Decision:

Net::HTTP2::nghttp2 is the selected implementation direction for the first
Linux::Event::HTTP HTTP/2 executor. Do not build a competing in-house HPACK/frame
engine and do not use the higher-level Net::HTTP2 client abstraction.

The spike remains experimental and does not yet add Net::HTTP2::nghttp2 to the
production Makefile.PL dependency set.

The next design/implementation boundary is HTTP/2 message mapping, specifically
how `:scheme` and `:authority` are preserved in the protocol-neutral Request
API without exposing pseudo-headers as ordinary headers.

### HTTP/2 message mapping decision

The Request pseudo-header mapping decision is now implemented on
`experiment/http2-nghttp2-spike`.

Key commits:

- `ac2278c2517121cf4e9e0516f01d53beeb2aac5a`
  "http2: add Request scheme and authority metadata";
- `b28becb9acbfb88d5fa3dfdb4ad6c4ec5ca2318d`
  "http2: add private message mapping adapter";
- `53a9d056b40f1b7212a92f49049346cb4ea30082`
  "http2: test message and Transaction mapping".

Decisions:

- `Request->scheme` and `Request->authority` are protocol-neutral message
  metadata.
- HTTP/2 maps `:scheme` and `:authority` directly into those accessors.
- HTTP/2 pseudo-headers never appear in the ordinary lossless header list.
- HTTP/1 origin-form derives authority from one Host field but does not invent a
  scheme.
- HTTP/1 absolute-form derives both scheme and authority from the target.
- HTTP/1 and HTTP/2 ordinary CONNECT expose authority-form through
  `Request->target` and `Request->authority`.
- Extended CONNECT `:protocol` remains explicitly unsupported for now.
- the private `Linux::Event::HTTP::_HTTP2` mapper validates HTTP/2 header
  ordering and connection-specific field rules at the protocol boundary.
- one HTTP/2 request stream maps to one ordinary Transaction whose Response uses
  version `2`.

The next implementation step is a private HTTP/2 executor around one nghttp2
Session and a stream-id-to-Transaction map. It should consume the mapper rather
than duplicating message semantics in callbacks.

### Linux::Event 0.117 transition finding and feature review

The HTTP/2 experiment is now tested against the released Linux::Event 0.117
tag, not the earlier pinned 0.116 commit.

CI run `36201072448` confirms:

- Linux::Event 0.117 installs successfully;
- HTTP/1 tests remain green through the ordinary production suite;
- HTTP/2 message mapping, ALPN, private server executor, and private client
  executor tests `t/90` through `t/93` pass;
- `t/94-http2-selector-transition-spike.t` still exits with SIGSEGV before
  producing TAP.

The remaining HTTP/2 selector blocker is therefore a current-core transition
bug, not an obsolete 0.116 limitation.

The missing Linux::Event transition cross-product is precise:

- plain native-consumer -> ordinary raw transition is covered in Linux::Event;
- TLS ordinary-stream -> ordinary-stream transition with preserved decrypted
  tail is covered in Linux::Event;
- TLS native-consumer -> ordinary raw transition is not covered;
- the HTTP/2 selector exercises exactly TLS native-consumer -> ordinary raw and
  segfaults on Linux::Event 0.117 even after reads are paused and the transition
  is deferred with Loop->defer() outside TLS on_ready dispatch.

Do not work around this by changing Linux::Event from the HTTP repository. The
next core action should be a reduced Linux::Event regression reproducing TLS
native-consumer -> ordinary raw transition.

Linux::Event 0.117 feature review for HTTP:

1. Loop->defer(): KEEP / ADOPT.
   HTTP currently uses zero-delay Kernel::Timer objects solely to escape the
   current callback stack in four production handoff paths:
   server Upgrade, server CONNECT, client Upgrade, and client CONNECT.
   Loop->defer() is the exact semantic primitive for that work and should
   replace those timer allocations once Linux::Event >= 0.117 becomes the HTTP
   prerequisite. The HTTP/2 ALPN selector should use the same mechanism after
   the transition bug is fixed.

2. Loop->fork(): USEFUL TO USERS, NOT YET AN INTERNAL SERVER FEATURE.
   HTTP::Server already exposes ->listener, and Linux::Event Listener supports
   managed-fork share/move. A plain HTTP pre-fork example can therefore likely
   use:
       $loop->fork(share => [ $server->listener ])
   without a new HTTP API. Validate this in HTTP, and validate HTTPS/TLS
   Listener sharing separately, before documenting a supported HTTP pre-fork
   recipe. Do not make Server automatically fork workers.

3. Kernel::Inotify: NO DIRECT HTTP-LAYER INTEGRATION.
   It could help an application watch certificates, static files, or config,
   but those are deployment/application policies. HTTP should not acquire
   filesystem-watch responsibilities merely because core now provides them.

4. TTY borrowed-handle ownership: NO HTTP IMPACT.

5. inherited-Loop misuse detection after ordinary CORE::fork(): INDIRECT SAFETY
   BENEFIT ONLY. HTTP needs no wrapper around it.

6. public POD rewrite: use 0.117 documentation as the current core contract,
   especially Loop->defer(), managed fork, Listener recipes, and transition
   semantics.

HTTP-side 0.117 adoption now completed on this branch:

- the distribution prerequisite is Linux::Event >= 0.117;
- server Upgrade, server CONNECT, client Upgrade, and client CONNECT now use
  Loop->defer() rather than zero-delay Kernel::Timer objects;
- real-duration timers remain timers;
- focused existing Upgrade/CONNECT tests pass with the defer implementation;
- t/43-managed-fork-server.t validates a plain HTTP server using
  Loop->fork(share => [ $server->listener ]);
- Server POD documents managed pre-fork Listener sharing while keeping worker
  management outside the HTTP protocol API;
- TLS/HTTPS managed-fork Listener sharing remains intentionally unclaimed until
  separately validated.

Validation run 36203949038 reached all of these tests successfully:

- t/42-upgrade.t PASS;
- t/43-managed-fork-server.t PASS;
- t/67-client-upgrade.t PASS;
- t/69-client-connect.t PASS;
- t/72-server-connect.t PASS;
- t/90 through t/93 HTTP/2 tests PASS.

The same run still fails only at the known current-core blocker:

- t/94-http2-selector-transition-spike.t exits with SIGSEGV while exercising
  TLS native-consumer -> ordinary raw transition on Linux::Event 0.117.

Next after the core transition fix:

- continue the HTTP/2 high-level ALPN selector using Loop->defer();
- separately validate managed-fork TLS/HTTPS Listener sharing before documenting
  it as supported.

### HTTP/2 distribution decision

HTTP/2 belongs in **Linux::Event::HTTP**, not in a separate Linux::Event::HTTP2
distribution.

The intended architectural rule is one HTTP distribution and one public
message/application model, with version-specific protocol executors underneath
it. Request, Response, Transaction, Client::Operation, Client, and Server should
remain conceptually shared where their semantics genuinely survive the protocol
version change.

HTTP/2 is expected to need separate connection/stream/framing/HPACK/flow-control
machinery internally. Exact package names and implementation boundaries are not
yet decided.

TLS ALPN should eventually select between HTTP executors, for example `h2` and
`http/1.1`, without forcing applications to choose a separate HTTP library.

Do not begin HTTP/3/QUIC work before the HTTP/2 architecture has been explored
and the shared abstractions have been validated.

### Validation baseline for 0.002

The native-default implementation passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- 41 test files / 1,029 tests;
- `make disttest`;
- transaction-lifecycle diagnostic smoke;
- end-to-end benchmark smoke;
- same-run production-native comparisons.

Release-prep latest-Perl same-run medians against the exact pre-native server
baseline were:

- GET / 32-byte response: 31,133.8 -> 33,842.8 req/s (+8.7%);
- GET / 16 KiB response: 23,032.8 -> 26,717.6 req/s (+16.0%);
- POST / 4 KiB request, 32-byte response:
  19,051.8 -> 20,186.5 req/s (+6.0%).

These are server-path measurements and do not answer whether the client receive
path warrants native conversion.

### Deferred client policy

Keep these separate until a real workload requires them:

- HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment discovery;
- NO_PROXY matching;
- PAC;
- SOCKS;
- preemptive authentication caches;
- Authentication-Info / Proxy-Authentication-Info handling;
- richer connection-pool policy;
- parser XS that is not justified by measurement.

The next work item is measurement of the client receive path, not expansion of
these policy features.
