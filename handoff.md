# Linux::Event::HTTP handoff

Updated: 2026-09-25 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Repository: `haxmeister/perl-Linux-Event-HTTP`

Canonical branch: `main`

Project boundary: modify only Linux::Event::HTTP unless the user explicitly
authorizes another repository in the current chat.

### Active HTTP/2 stabilization state

Active branch:

`experiment/http2-nghttp2-spike`

Draft PR: #39.

### HTTP/2 backend decision (2026-09-26)

Use the released `Net::HTTP2::nghttp2 0.011` binding as the production HTTP/2
backend. Do not merge the private native binding experiment into the release
path.

The private binding experiment proved that a wrapper-level strict stream-ID
check can make h2spec report zero failures, but deeper validation showed that
such a check can misclassify a legitimate late-HEADERS race after a locally
serialized RST_STREAM. libnghttp2 deliberately keeps conservative behavior for
that ambiguity. The remaining h2spec stream-ID failure is therefore accepted as
the underlying libnghttp2 policy rather than overridden in Linux::Event::HTTP.

No upstream pull request to Net::HTTP2::nghttp2 is planned for this behavior.
Continue development and release work against the current CPAN 0.011 binding.

HTTP/2 remains optional for HTTP/1-only installations. `Makefile.PL` now
records an optional `http2` feature requiring `Net::HTTP2::nghttp2 >= 0.011`,
and the README documents explicit installation of that binding.

Current stabilization code head before this handoff update:

`a37583a5f4176ef46b9913dc8aa1c1ee1660557c`
"Defer HTTP/2 teardown across nghttp2 callbacks"

The high-level HTTP/2 Server/Client work, multiplexing, streaming uploads,
decoded header-list limits, aggregate buffered-response limits, and ALPN
selector transition are already implemented on this branch. The current work
was a correctness/conformance hardening pass.

The hardening pass found and fixed seven HTTP-side defects:

1. `Linux::Event::HTTP::_HTTP2::Server` handled GOAWAY but omitted the
   `H2_GOAWAY => 7` constant. That compile error made every HTTP/2-enabled
   high-level test report a misleading "Net::HTTP2::nghttp2 unavailable"
   failure. Commit `2bfcacb9720c89fc89691ae0893dedc0d908a3be` fixes it.

2. The Server::Connection transport-close callback is cached before
   `transition_to()`. After the object becomes
   `_HTTP2::ServerConnection`, calling `$self->_clear_transaction` from that
   retained callback incorrectly assumes the object still inherits the HTTP/1
   class. Commit `34880db818cb1ac1f7e7a940b34433e43089d95e` makes the callback
   invoke its owning HTTP/1 cleanup subroutine directly. Commit
   `1bc53334d2885fe4655dbef29b9fe70794f4c47f` adds a focused regression.

3. HTTP/2 server shutdown used immediate `Stream->close` after peer GOAWAY.
   With unread peer bytes this produced an abortive TCP reset. Merely leaving
   the transport open instead produced a timeout because nghttp2 had already
   finished the session. The final behavior uses `Stream->end`: queued HTTP/2
   output is allowed to finish, then the writable side shuts down gracefully.
   The same lifecycle rule is used when nghttp2 reports that it wants neither
   read nor write after a connection-level protocol error. Commits
   `7fa30b5e1d905468248d6ad3828486dba934319e` and
   `defeead0cc362d8259b2184ce3d801f688af589c` contain the implementation and
   focused regression coverage.

4. The HTTP/2 Client correctly stopped assigning new work after peer GOAWAY,
   but a draining connection could remain open after its final active stream
   disappeared until some later request happened to revisit the pool. The
   Client executor now retires that transport with `Stream->end` after the
   drain completes, while leaving ordinary reusable H2 connections open.
   Transport shutdown is initiated from the post-nghttp2 flush path rather
   than reentrantly from inside the nghttp2 stream-close callback. Commits
   `d1c0a6b291b2164d655aae144a6413e45d51a2c6`,
   `fc282b7a0943bd7b9a1b17a11a387070885da9a6`, and
   `f9ab6b3d266543a0459353a15657e211466a1e4a` contain the implementation,
   focused regression, and reentrancy tightening.

5. Pre-ALPN client bursts previously opened one negotiating TLS connection per
   operation because a selector could hold only one provisional Transaction.
   The Client now keeps an origin-scoped negotiating-selector pool. One selector
   may hold up to 100 provisional Transactions while ALPN is unresolved. If H2
   wins, all queued Transactions are submitted onto the selected multiplexed
   connection while preserving their original Request/Transaction identity and
   streaming-body controllers. If HTTP/1.1 wins, the first Transaction remains
   on the negotiated connection and the remainder are reassigned onto separate
   HTTP/1.1 connections, preserving fallback concurrency rather than serializing
   them. The main implementation commits are
   `7e839265cad0b74140048a4fed835059f2e815cc`,
   `10eda72217e41350351dcdd9fdd880bdb317b63a`,
   `d817e787ec2202604d1e675464f433c7dceee756`, and
   `74d77163f4a5c907dfe5b4e0c6cb0a7872c4b1e1`.

6. The new fallback-concurrency test exposed an older TLS lifecycle problem:
   when more than one reusable same-origin HTTP/1 connection completed, the
   Client kept one idle connection and discarded the surplus with immediate
   `close()`. Over TLS this can produce "peer closed without close_notify".
   Surplus reusable connections now retire with `end()` when available.
   ClientSelector exposes a private delegating `end()` for the same purpose.
   Commits `0ed883c2e57555fb4fe5018ef3ab1d199607094c` and
   `272115a44fe69b49b83596ba4f0962e1954d8c36` contain that fix.

7. Moving the HTTP/2 binding floor from Net::HTTP2::nghttp2 0.008 to 0.011
   exposed a real reentrant teardown bug. A high-level callback such as
   on_complete can close the Client while nghttp2 mem_recv() is still executing
   the callback that delivered that completion. The old executor close path
   immediately destroyed the Session in that callback. Net::HTTP2::nghttp2
   0.011 deliberately hardens this lifecycle and made the unsafe pattern
   visible. Client and Server executors now mark close pending while a Session
   call is active, stop accepting further callback work, return from mem_recv()
   or mem_send(), and only then destroy Session/provider state. The same commit
   also removes a raw spike-only mem_send() call from inside an nghttp2
   callback. Commit
   `a37583a5f4176ef46b9913dc8aa1c1ee1660557c` contains the fix.

Focused integration coverage:

`t/100-http2-prealpn-fanout.t`

starts six H2-capable operations and four HTTP/1.1-fallback operations before
either TLS handshake completes. It proves:

- each client initially creates only one negotiating TLS connection;
- the six H2 operations complete through one selected H2 connection;
- the four HTTP/1.1 fallback operations fan out onto four concurrent
  connections after ALPN resolves;
- every Request retains provisional HTTP/1.1 identity before ALPN;
- H2 Requests become version 2 after selection while fallback Requests remain
  version 1.1;
- every target is delivered exactly once;
- surplus fallback TLS connections retire without a missing-close_notify error.

`t/101-http2-high-level-policy.t` proves protocol-neutral high-level policy by
running one Operation through 302 redirect -> Set-Cookie -> 401 Basic challenge
-> authenticated 200 over one selected H2 connection.

`t/102-http2-cancellation-isolation.t` proves that client-side Operation
cancellation and server-side Transaction cancellation reset only the intended
HTTP/2 stream while sibling streams on the same TLS connection continue and
complete normally.

The HTTP/2 binding floor is now Net::HTTP2::nghttp2 0.011. HTTP/2 tests also
require 0.011 before running, so systems with an older optional binding skip the
optional H2 suite rather than exercising an unsupported lifecycle.

Version 0.011 is important for this integration because it hardens provider and
Session teardown around callbacks and refuses reentrant mem_send()/mem_recv().
Its build path requires nghttp2 >= 1.57. That also means the server benefits
from nghttp2's HTTP/2 Rapid Reset RST_STREAM limiter; Linux::Event::HTTP leaves
the binding's default token-bucket policy in place rather than adding another
public tuning option at this stage.

h2spec v2.6.0 now reaches the full 146-test run with:

- 144 passed;
- 1 skipped;
- 1 failed.

The sole remaining failure is:

`5.1.1 - Sends stream identifier that is numerically smaller than previous`

Stock nghttpd/libnghttp2 is independently documented with this same h2spec
failure. Do not add application-level response reordering merely to hide that
underlying nghttp2/h2spec baseline behavior.

CI now treats h2spec as a gate rather than a non-blocking diagnostic. A clean
run is accepted, and the pinned v2.6.0 run is also accepted when it has exactly
the known 144-pass / 1-skip / 1-fail baseline and that one failure is the
stream-identifier case above. Any additional h2spec failure fails CI.

Validation:

- CI run `36215138738` fully passed after the graceful HTTP/2 shutdown fix,
  including Build-and-test on Perl 5.36, 5.38, 5.40, 5.42, 5.44, latest, and
  latest-threaded, the h2spec run, benchmark smoke/comparisons, and distribution
  integrity.
- CI run `36215274760` validates the added server regressions and conformance
  gate. It fully passed Build-and-test on every configured Perl lane, the
  latest-Perl h2spec gate, benchmark/smoke work, and distribution integrity.
- CI run `36215569666` validates the client GOAWAY retirement change and its
  focused regression. It fully passed on Perl 5.36, 5.38, 5.40, 5.42, 5.44,
  latest, and latest-threaded. The latest lane also passed the h2spec
  conformance gate, same-run production comparisons, benchmark smoke tests,
  and distribution integrity.
- CI run `36216660868` validates the pre-ALPN selector queue, HTTP/1.1
  fallback fan-out, and graceful surplus-connection retirement. Build-and-test
  passed on Perl 5.36, 5.38, 5.40, 5.42, 5.44, latest, and latest-threaded.
  The latest lane reported 55 files / 1,444 tests, Result PASS, passed the
  h2spec conformance gate, production comparison/smoke work, and distribution
  integrity.
- CI run `36216974089` validates high-level redirect, cookie, and
  authentication policy over HTTP/2. It fully passed on Perl 5.36, 5.38, 5.40,
  5.42, 5.44, latest, and latest-threaded; latest also passed h2spec and
  distribution integrity. Focused coverage is
  `t/101-http2-high-level-policy.t`, which executes one Operation through
  302 -> cookie storage -> 401 Basic challenge -> authenticated 200 on one H2
  TLS connection. All three Transactions retain HTTP/2 Request/Response
  identity and the expected Operation redirect/auth history.
- CI run `36217849502` validates Net::HTTP2::nghttp2 0.011, the cancellation
  isolation test, and deferred Session teardown. It fully passed Build-and-test
  on Perl 5.36, 5.38, 5.40, 5.42, 5.44, latest, and latest-threaded. The latest
  lane reported 57 files / 1,488 tests, Result PASS; t/102 passed; h2spec stayed
  at exactly 144 passed / 1 skipped / 1 known baseline failure; production
  comparison/smoke work and distribution integrity also passed.

The earlier pre-ALPN connection fan-out issue is now resolved. Do not revert to
one negotiating TLS connection per simultaneous operation.

The next useful HTTP/2 work should begin from this state rather than revisiting
the earlier ALPN/core-segfault investigation.

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

### Linux::Event 0.117 review and HTTP/2 selector diagnosis

The HTTP/2 experiment now targets the released Linux::Event 0.117 baseline.

A Linux::Event core investigation attempted to reproduce the earlier selector
SIGSEGV without HTTP code. Core could not reproduce a transition failure.

The core investigation covered the exact intended transition shape:

- TLS Stream with an active external/native raw consumer;
- ALPN selecting h2;
- pause_read;
- Loop->defer;
- native-consumer -> ordinary raw transition_to();
- object/fd/TLS identity preservation;
- preserved decrypted plaintext;
- later duplex TLS I/O after transition;
- native-consumer destruction exactly once.

That regression passes the full Linux::Event functional matrix. The retained
core investigation branch head reported back to HTTP is:

`e1cc1010a0134e77f874b9c0a6fe62831bf4c82b`

and contains only the focused regression, MANIFEST entry, and handoff
documentation. No production core source change was required.

The HTTP-side diagnosis then found the actual ordering problem.

The original selector constructed the HTTP/2 executor before transition_to().
The executor constructor was active: it created the nghttp2 Session, called
send_connection_preface(), called mem_send(), and immediately wrote the
preface/SETTINGS bytes through the Stream while the Stream was still the
HTTP/1 native-consumer connection class.

The old effective order was:

    TLS ALPN selects h2
    pause_read
    Loop->defer
    construct H2 executor
    send/flush H2 preface and SETTINGS on HTTP/1 connection
    transition_to H2 raw connection
    resume_read

That ordering produced the SIGSEGV seen in the earlier t/94 runs.

The selector was instrumented around executor construction, transition,
executor start/flush, resume_read, target on_data, and executor input. The H2
executor was then made capable of passive construction with `autostart => 0`.

The corrected order is:

    TLS ALPN selects h2
    pause_read
    Loop->defer
    construct passive H2 executor
    attach executor to the connection
    transition_to H2 raw connection
    start H2 executor
    send/flush H2 preface and SETTINGS
    resume_read
    process H2 input

Diagnostic run `36208108220` proves this removes the crash:

- client executor construction completes;
- client transition_to() completes;
- client executor start/preface flush completes;
- server executor construction completes;
- server transition_to() completes;
- server executor start/preface flush completes;
- both sides resume reads;
- both H2 raw target on_data callbacks run;
- repeated server/client executor input() calls return normally;
- the complete t/94 selector test passes inside the Build-and-test step,
  including the HTTP/1.1 ALPN fallback connection.

Therefore the HTTP/2 selector rule is now explicit:

**No HTTP/2 protocol bytes may be written until the live Stream has completed
its HTTP/1-native-consumer -> HTTP/2-raw transition.**

This is an HTTP executor-lifecycle requirement, not a Linux::Event core bug.

CI coverage was subsequently expanded because the old matrix only tested Perl
5.36, latest Perl, and latest threaded Perl. The HTTP/2 spike dependency was
also previously installed only on the latest non-threaded lane, allowing H2
tests to skip on the other Perls.

Commit `d84ca034c3dfb87f5e0655ea6877a5d371f04ed2` expands the matrix to:

- Perl 5.36;
- Perl 5.38;
- Perl 5.40;
- Perl 5.42;
- Perl 5.44;
- latest Perl;
- latest threaded Perl.

On the HTTP/2 spike branch, Net::HTTP2::nghttp2 is installed in every one of
those lanes so t/90 through t/94 are exercised rather than skipped.

CI run `36208655559` confirms Build-and-test success on 5.36, 5.38, 5.40,
5.42, 5.44, latest, and latest-threaded. The explicit non-latest lanes and
latest-threaded completed successfully; latest non-threaded also passed the
test suite and continued through the longer benchmark/dist steps.

Clean validation run `36208252365` removed all phase instrumentation and used
the actual private HTTP/2 connection classes. Results:

- Perl 5.36: PASS;
- latest Perl: PASS;
- latest threaded Perl: PASS;
- Build and test: PASS, including the cleaned t/94 selector;
- same-run production native HTTP comparisons: PASS;
- end-to-end benchmark smoke: PASS;
- client receive-path benchmark smoke: PASS;
- distribution integrity / disttest: PASS.

The selector fix is therefore validated independently of the temporary
diagnostic subclasses and warning markers.

Linux::Event 0.117 feature adoption in HTTP is also now underway/completed on
this branch:

1. Loop->defer()
   - distribution prerequisite raised to Linux::Event >= 0.117;
   - server Upgrade uses Loop->defer();
   - server CONNECT uses Loop->defer();
   - client Upgrade uses Loop->defer();
   - client CONNECT uses Loop->defer();
   - real-duration timers remain Kernel::Timer objects;
   - existing focused Upgrade/CONNECT tests pass.

2. Loop->fork()
   - t/43-managed-fork-server.t validates plain HTTP Listener sharing through:
         $loop->fork(share => [ $server->listener ])
   - Server POD documents this as a deployment pattern;
   - worker creation/supervision remains application policy;
   - TLS/HTTPS managed-fork Listener sharing remains unclaimed until separately
     validated.

3. Kernel::Inotify
   - no HTTP protocol integration planned; file/config/certificate watching is
     application/deployment policy.

4. TTY ownership changes
   - no HTTP impact.

5. ordinary-fork misuse detection
   - indirect safety improvement only; no HTTP wrapper required.

The next HTTP/2 work is to keep the now-validated selector ordering, complete a
clean final branch gate without the temporary phase diagnostics, and then wire
the private HTTP/2 executors behind the high-level Server/Client ALPN selection
path.

### High-level HTTP/2 Server, Client, and multiplexing

The private HTTP/2 executors are now wired behind opt-in high-level APIs on
`experiment/http2-nghttp2-spike`.

High-level Server:

    Linux::Event::HTTP::Server->new(
        http2 => 1,
        tls   => { ... },
        ...
    )

- advertises h2 before http/1.1;
- transitions to the private H2 ServerConnection only after ALPN selects h2;
- constructs the executor passively, transitions first, then starts H2;
- preserves the ordinary on_request/on_body/on_request_end callback shape;
- HTTP/1.1 ALPN fallback stays on the existing Server::Connection;
- currently requires the default connection_class.

High-level Client:

    Linux::Event::HTTP::Client->new(
        http2 => 1,
        tls   => { ... },
    )

- advertises h2 before http/1.1 for direct HTTPS operations;
- preserves immediate Operation/Transaction/Request identity while initial ALPN
  is unresolved;
- if H2 wins, the same mutable Request becomes version 2 and gains
  scheme/authority metadata before commit;
- maps a caller Host field into :authority and removes Host from the normal H2
  field list;
- falls back cleanly to the existing HTTP/1.1 connection when h2 is not
  selected;
- selected H2 connections are pooled per origin and can accept concurrent
  streams while earlier Transactions are still active;
- local admission is capped at 100 active submitted streams per H2 connection;
- nghttp2 enforces peer SETTINGS_MAX_CONCURRENT_STREAMS;
- GOAWAY marks a connection draining so the pool stops assigning new work.

Current high-level HTTP/2 exclusions intentionally fall back to HTTP/1:

- streaming Request bodies before ALPN selection;
- forward proxy routes;
- Upgrade;
- CONNECT tunnel handoff;
- explicit HTTP version selection.

Multiplex validation:

`t/96-http2-high-level-multiplex.t`

establishes one H2 TLS connection and, while the first stream is still active,
launches six more high-level Operations. The server delays all six responses.
The test requires:

- one server TLS connection for all requests;
- at least six simultaneously active H2 streams;
- independent status/body completion for every Operation.

CI run `36210309139` passed Build-and-test, including t/96, on:

- Perl 5.36;
- Perl 5.38;
- Perl 5.40;
- Perl 5.42;
- Perl 5.44;
- latest Perl;
- latest threaded Perl.

Remaining client-pool work:

- transparent GOAWAY replay is not implemented because
  Net::HTTP2::nghttp2 0.008 does not expose the received GOAWAY
  last_stream_id needed to identify safely replayable streams;
- cross-origin H2 connection coalescing remains deferred.

Pre-ALPN same-origin fan-out is implemented: simultaneous Operations share a
bounded negotiating selector and either collapse onto H2 or fan back out after
HTTP/1.1 selection.

### High-level HTTP/2 streaming Request bodies

High-level streaming uploads now participate in HTTP/2 ALPN selection rather
than being forced to HTTP/1.

The public behavior is intentionally unchanged:

    my $op = $client->post(
        $url,
        stream_body => {
            on_drain  => sub ($body) { ... },
            on_cancel => sub ($body) { ... },
        },
    );

    my $body = $op->request_body;
    $body->write($bytes);
    $body->complete;

The producer is available immediately, including before TLS handshake/ALPN
completion.

Implementation:

- the selector creates the ordinary Transaction and Body::Stream immediately;
- pre-selection body writes go into a selector-owned ordered queue;
- cooperative selector backpressure begins at 65,536 queued bytes;
- Content-Length is enforced while bytes are still pre-selection;
- when ALPN resolves, the selected HTTP/1 or H2 executor adopts the same
  Transaction and existing Body::Stream rather than creating another producer;
- queued bytes are transferred once into the selected protocol's ordinary body
  output path;
- later writes go directly to that protocol executor;
- an HTTP/1.1 fallback with unknown body length adds normal chunked framing;
- H2 does not add Transfer-Encoding;
- on_drain/on_cancel remain attached to the same producer object.

Focused validation:

`t/97-http2-high-level-streaming-upload.t`

covers:

- a 100,000-byte write made before ALPN;
- pre-selection false/backpressure return;
- H2 selection and body transfer;
- on_drain continuation adding the final 4 bytes;
- exact 100,004-byte H2 request body;
- Content-Length preservation;
- no H2 Transfer-Encoding;
- Request identity/version/authority preservation;
- no producer cancellation after successful completion;
- HTTP/1.1 ALPN fallback using the same pre-selection producer;
- automatic chunked HTTP/1.1 framing for unknown length;
- immediate pre-ALPN Content-Length mismatch rejection.

CI run `36211493852` passed Build-and-test with t/97 on Perl 5.36, 5.38,
5.40, 5.42, 5.44, latest, and latest-threaded. A completed 5.42 lane reported
52 files / 1,338 tests, Result PASS.

The latest non-threaded lane also completed the full regression gate:

- Build and test: PASS;
- same-run production native HTTP comparisons: PASS;
- end-to-end benchmark smoke: PASS;
- client receive-path benchmark smoke: PASS;
- distribution integrity / disttest: PASS.

### HTTP/2 decoded header-list hardening

Both private HTTP/2 executors now enforce a decoded header-list limit.

Public option on high-level Server and Client:

    http2_max_header_list_size => 65_536

The option requires `http2 => 1`.

Accounting follows HTTP/2 SETTINGS_MAX_HEADER_LIST_SIZE semantics:

    length(name) + length(value) + 32

for each decoded field.

Behavior:

- default limit is 65,536 bytes;
- the configured limit is advertised through SETTINGS_MAX_HEADER_LIST_SIZE;
- the same limit is independently enforced after HPACK decoding;
- Server applies it to initial Request headers and Request trailers;
- Client applies it to Response header blocks;
- an over-limit block resets/fails only the offending stream using
  ENHANCE_YOUR_CALM rather than closing the entire H2 connection;
- repeated fields after the limit trip do not cause repeated application errors.

Focused coverage:

`t/98-http2-header-list-limit.t`

checks the emitted SETTINGS frame and both Server and Client decoded-limit
paths using a fake transport.

CI run `36212199466` passed Build-and-test, including t/98, on Perl 5.36,
5.38, 5.40, 5.42, 5.44, latest, and latest-threaded. The Perl 5.42 lane
reported 53 files / 1,360 tests, Result PASS.

GOAWAY replay note discovered during this hardening pass:

Net::HTTP2::nghttp2 0.008 exposes receipt of a GOAWAY frame through
on_frame_recv, but its frame hash does not expose GOAWAY last_stream_id and no
alternate Session accessor provides it. Safe transparent replay requires that
value to distinguish streams the peer promises it did not process. Therefore
HTTP currently marks the connection draining and does not automatically replay
streams. Do not guess from stream-close timing or replay all active requests.

### HTTP/2 aggregate buffered-response hardening

High-level H2 Client buffering now has a per-connection aggregate memory budget.

Public option:

    http2_max_buffered_response_bytes => 67_108_864

The option requires `http2 => 1`; default is 64 MiB.

This limit is separate from per-operation `buffer_body => $max`.

The H2 Client executor tracks body bytes currently retained for active buffered
responses across all multiplexed streams. Before appending each DATA chunk it
checks both:

- the operation's own buffer_body limit;
- the connection-wide aggregate H2 buffer limit.

If the aggregate limit would be exceeded:

- only the offending stream fails with CANCEL;
- unrelated H2 streams remain healthy;
- the connection remains usable;
- the rejected chunk is not added to the aggregate accounting.

Accounting is released when a buffered response completes, fails, is cancelled,
or the connection closes.

Focused test:

`t/99-http2-aggregate-buffer-limit.t`

creates two concurrently buffered H2 streams with a 10-byte connection budget.
The first holds 6 bytes; a 6-byte chunk on the second stream is rejected without
affecting the first; the first then grows to 10 bytes, completes successfully,
and releases aggregate accounting to zero.

CI run `36212430127` passed Build-and-test with t/99 on Perl 5.36, 5.38,
5.40, 5.42, 5.44, latest, and latest-threaded. The Perl 5.44 lane reported
54 files / 1,383 tests, Result PASS.

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
