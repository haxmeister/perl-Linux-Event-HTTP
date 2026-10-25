# Reconstruction implementation checkpoint

## Stage C h2spec fixture-timing isolation (2026-10-25 UTC)

The recorded 11 h2spec failures occur on the untouched legacy baseline,
the rebuilt native bridge, and the rebuilt Perl input path. Many failures
include an unexpected response DATA frame after a protocol error. The
existing conformance fixture responds immediately on on_headers while
discarding the request body, even when h2spec deliberately keeps a
request stream open. This suggests a precise fixture-timing hypothesis,
NOT a proven explanation or an HTTP2 conformance fix.

The root-only tools/http2-h2spec-server.pl now accepts
--response-mode headers (historical default) or request (respond after
the full request). Both modes send identical 200/ok response bytes.
A latest-nonthreaded CI diagnostic runs pinned h2spec v2.6.0 against
both variants on the same runner and prints exact counts/failing names.
Expected protocol test failures do not block other regression jobs;
a broken fixture or incomplete report still fails the diagnostic.
The results are PENDING; Stage C release gate remains OPEN and baseline
parity is not conformance. No Unblock::HTTP2, TLS or core source was
changed. Do not infer any improvement before the measurements.


## Stage F dependency and executable cleanup (2026-10-25 UTC)

The post-reconstruction source audit found 14 executable benchmark/fixture
files that still referenced deleted HTTP/1 parser, old Server::Connection,
Client::Connection, Request and Response implementations. They were
removed from this feature branch and MANIFEST; historical scripts remain
unchanged on main and the benchmark JSON evidence is retained. The five
Unblock-based benchmark executables remain in the distribution.

Root Makefile.PL no longer declares direct HTTP::CookieJar,
Uniform::HTTP::Auth or URI runtime prerequisites: the rebuilt Linux
adapter imports none of them, and Unblock::HTTP already requires URI
and HTTP1 as appropriate. CI setup no longer installs these extra
modules explicitly; it will exercise the metadata with only the
remaining direct prerequisites and feature-branch Unblock installs.
Unreleased Changes and README were brought into line with the rebuild.

**Verified**: root feature commit
f0f44edda0c8eb6a430625feb7285d175dc6cebd passed GitHub
Actions 40161695154, all SEVEN Perl jobs, including latest nonthreaded
make disttest, HTTP/1 native and Perl input, optional H2/H3 with real
TLS/QUIC, WebSocket and generic CONNECT. Direct prerequisite cleanup
was exercised by CI without explicit old CookieJar/Auth installs.
No main, upstream, version or release change was made.
Stage B throughput and Stage C h2spec conformance remain OPEN.


## Stage F verified cleanup and packaging gate - 2026-10-25 UTC

Root source removal: 51dc44d01f84848346a16bad9d6c1a0bd2541c8f.
GitHub Actions run 40158416159 PASSED all seven Perl jobs, including
both native and Perl input, H2/H3 transport, WebSocket and generic
handoff coverage. The 21 t/rebuild test files remain unchanged. The
native consumer ABI header was relocated unchanged to xsbridge.
Docs replacement: 21f0ec61808de7cb3a506faa7dc1a6613bdbe245.
Architecture/HTTP2/CONNECT/benchmark docs no longer present the deleted
client policy wrappers or old parsers as current production APIs.

New CI packaging gate PASSED: commit
e43be4eca0d8c2d406d3cd6bd2063d92da225a06,
GitHub Actions 40158734512, all SEVEN Perl jobs PASS. Latest
nonthreaded Perl successfully ran make disttest against the generated
distribution, compiling and testing its XS bridge and rebuilt API
from the MANIFEST tarball. Both ordinary and native/perl input,
H2/H3 and protocol transition checks remained green.

Stage B performance and Stage C h2spec remain OPEN, with no performance
claims from source cleanup. No upstream/main/version/release changes.

## Stage F initial legacy source and test removal (2026-10-25 UTC)

A root-only Stage F cleanup removes the former Linux::Event::HTTP-specific
Request/Response/Transaction/Operation classes, private HTTP1 parser and
HTTP2 executors, legacy client policy/upgrade helpers, 57 obsolete t/*.t
tests, and the superseded picohttpparser XS/vendor sources. The former
native stream consumer ABI header is copied unchanged into xsbridge and the
build now compiles ONLY the Unblock native input bridge. Public metadata
advertises only Linux::Event::HTTP, ::Server and ::Client; MANIFEST follows
the replacement layout. All 21 rebuilt protocol regressions are retained.
The legacy baseline and old tests remain available unchanged on main.
Benchmark evidence and historical research documents are preserved.

Source cleanup and packaging are verified by root CI 40158416159
and 40158734512. This does NOT close Stage B throughput or
Stage C h2spec gates. Upstream Unblock/Uniform/QUIC and
Linux::Event core sources remain untouched; no version bump or release.


Updated: 2026-10-25 (America/Chicago)
Measurements: Stage A 2026-10-22; Stage B 2026-10-23/24
Branch: `feature/unblock-http-rebuild`
Starting checkpoint: `634228c90070e0136175a4611e7079f33370a7d9`
Untouched baseline: `c0bf714e0f08f9031684e2eb4fd70dea3c68449f`

Stage A's executable HTTP1 GET/POST gate passes. Stage B is in progress;
HTTP1 lifecycle and service draining are implemented, but the performance
gate has NOT passed. Stage C initial integration is implemented; focused Stage C h2spec
conformance remains open. Stage D's planned real QUIC/TLS loopback, timeout,
credit recovery, cancellation and multi-connection gate is verified for the
supported concrete-address, combined TCP/UDP Server API. Stage E's core H1/H2/H3 WebSocket and generic handoff contract is
verified in native/Perl input and real TLS/QUIC integration; supplemental rejected-CONNECT fallthrough is verified.
Stage F source and packaging cleanup is underway; its final release gates remain open. See the explicit H3-only/wildcard limitations below. The user authorized
the specified upstream feature-branch changes. No release, version bump,
main change has occurred. Feature-branch publication is authorized.

## Stage B framework-neutral performance boundary and cost isolation (2026-10-25 UTC)

The architectural rule is now explicit in docs/UNBLOCK-REBUILD-PLAN.md:
do not change Unblock to compensate for Linux::Event reactor/adapter
overhead. Unblock source changes require framework-neutral benefit and
standalone correctness/throughput evidence. No Unblock, Uniform::HTTP,
Linux::Event core, or QUIC production files were changed in this round.

New ROOT-ONLY diagnostic files:
- bench/run-unblock-cost-breakdown.pl (per-request CPU experiments).
- bench/run-unblock-end-to-end.pl option
  --diagnostic-prebuilt-response. This shares one read-only frozen
  canonical Uniform::HTTP::Response ONLY to bound constructor cost
  in a benchmark; it is not a suggested application/engine policy.
- bench/results/unblock-stage-b/20261025-cost-boundary.json
  stores each actual sample and setup.

Root CI 40156778214 and 40157039519: all SEVEN Perl lanes PASS,
including required optional H2/H3 and WebSocket/handoff regressions.

Same runner, three 12k-request rounds, exclusive process CPU:
- Uniform::HTTP::Response->new(status=>200,body=>32B)
  4.479 / 4.519 / 4.494 us (median 4.494).
- Wire plan for prebuilt immutable canonical Response
  1.210 / 1.205 / 1.254 us (median 1.210).
- Direct Unblock::HTTP1::Server engine, fresh canonical response
  23.560 / 23.297 / 23.464 us (median 23.464).
- Upper Unblock::HTTP facade, fresh response
  23.404 / 25.339 / 23.182 us (median 23.404).
- Direct engine, prebuilt response
  17.991 / 17.884 / 18.209 us (median 17.991).
- Upper facade, prebuilt response
  17.625 / 17.848 / 17.957 us (median 17.848).
The upper Unblock facade does not show a meaningful per-request
penalty versus using the low-level HTTP1 engine directly. The
prebuilt experiments isolate constructor overhead; they do NOT
authorize pooling or unsafe bypass of Uniform canonical validation.

Matched real socket native-input mode on the same CI host:
33,986 / 33,683 req/s, CPU 30.424 / 30.283 us/req.
Perl input: 26,709 / 26,683 req/s, CPU 37.896 / 38.541.
Native input improves GET32 throughput ~27% over the Perl path.
Thus replacing the native bridge with a Perl callback does not
solve Stage B. These are comparisons within that specific job.

Paired TCP socket constructor upper bound, CI 40157039519:
fresh canonical response: 11,085 / 11,154 req/s,
91.417 / 91.448 server CPU us/req.
benchmark-only frozen prebuilt response: 14,566 / 14,554 req/s,
69.911 / 70.777 us/req.
The host in this CI run was much slower than earlier runs; do
NOT compare these absolute values to another CI host. Within this
ABBA matched run, removing object construction has a sizable
upper-bound effect but DOES NOT close the legacy gap. Production
applications are free to construct responses; engines must not
cache, reuse or mutate response objects behind callers' backs.

Stage B throughput release gate STILL OPEN: matching legacy main
c0bf714 versus rebuilt native on CI 40156778214:
legacy 62,715/62,024 req/s vs rebuilt 33,516/34,834;
server CPU legacy 17.819/17.991 vs rebuilt 30.693/29.299
us/request. From the CI 40157039519 slower host:
legacy 33,025/31,843 vs rebuilt 11,507/11,278 req/s.
Numbers vary significantly across CI hosts; no claim of an
absolute capacity forecast or passed release-performance gate.

Decision: do not add a Linux-specific Unblock path, weaken Uniform
validation, introduce response caching or duplicate protocol state.
The biggest isolated construction cost is in Uniform's PUBLIC
canonical response construction, not a demonstrable penalty from
the Unblock facade. A later framework-neutral Uniform constructor
optimization would belong to the Uniform repository and would
require a separate scope/authorization and exhaustive correctness
testing; none was attempted here. Further Stage B work can focus
on Linux::Event bridge/socket overhead independently, with matched
comparisons and no Unblock ABI changes. Stage C h2spec 11 fails and
Stage F cleanup remain as previously recorded.

## Stage B measured no-body HTTP1 fast-path experiment — 2026-10-25

Feature-branch HTTP1 change:
haxmeister/perl-Unblock-HTTP1 feature/linux-event-integration
implementation 4d19f59196481ae4460207c5b22c5125fdbfe186;
dedicated test and MANIFEST follow-up
a90cfef10ca7eccde941493eaf9ffa520309f271.
Unmodified HTTP1 main remains 826fb5733daac62d9f5b51538dffbe1dc189c6d9.
Change: skip _finish_receive() and mark_complete()/freeze() only for
body_mode='none' validated requests. Both portable FastPath and native
C trusted head builders already construct those Requests complete,
immutable and with an empty buffered body. Record receive_done on the
Transaction. The general body/POST/streamed path is unchanged.
t/57-bodyless-completion.t checks pipelined GET/GET/POST canonical
lifecycle and one terminal notification per transaction. Full
HTTP1 standalone cross-platform regression source CI 40155745915
PASS on Ubuntu 5.16/latest, macOS/latest and Windows/5.40,
and root all-seven-lane CI below PASS. Test-only commit CI 40156227917 PASSED all four standalone
jobs: Linux Perl 5.16/latest, macOS latest, Windows Strawberry
5.40. Framework examples CI 40156227919 PASSED both smoke jobs.
Upstream HTTP1 Handoff.md is updated in e43dcd9cea917f194a3d98eb9d648e0e4fb1db2e.

Focused NYTProf hot spots from root CI 40155412311:
Server::_drive 7.97%, Server::_transaction_respond 7.14%,
Uniform::HTTP::Response::new 6.82%, Uniform::HTTP::Message::body
5.55%, Message::new 5.29%, Server::_complete_request 4.55%,
Response::status 4.12%, Message::body_is_mutable 2.84% of the
profiled inclusive multi-case script's EXCLUSIVE ticks.
The profiler itself distorts absolute CPU measurements; these
percentages prioritize hypotheses, not expected speedups.

Paired UNPROFILED socket-free engine diagnostic on SAME CI job:
- CI 40155785500 before 24.390/23.010 us per full GET/response;
  after 22.020/21.606 us (about 8% lower median engine CPU).
- CI 40155946839 before 35.912/33.475 us; after
  31.665/32.547 us (about 7.5% lower median engine CPU).
No body constructor or transport change in either A/B. Variations
between runners forbid cross-run absolute performance comparisons.

Original-baseline-versus-rebuild SAME HOST real TCP benchmark in root
CI 40155946839 (all SEVEN Perl lanes PASS): Linux::Event 0.117,
Perl 5.44 latest nonthreaded, 100 persistent sockets, pipelining 1,
10,000 measured GET->32 B after 1,000 warmup, two repeats per
variant, measurement order legacy/rebuild/rebuild/legacy:
- Legacy main c0bf714: run medians 49,591.4 and 49,085.0 req/s;
  22.013 and 22.197 server CPU us/req.
- Rebuilt feature: run medians 24,906.2 and 24,601.5 req/s;
  41.022 and 41.572 server CPU us/req.
Rebuilt throughput is ~50% of the untouched legacy baseline;
the Stage B PERFORMANCE GATE REMAINS OPEN.
This is more representative than socket-free CPU but still a
shared-host diagnostic, not a production capacity forecast.

Reproduction/data: bench/results/unblock-stage-b/20261025-bodyless.json
and .github/workflows/ci.yml (latest Perl benchmark steps).
Current root latest run: 40155946839 all seven Perl lanes PASS,
including both H1 input paths, H2/H3 real transports, H3 stream
credit, WebSocket and generic CONNECT handoff.

Next Stage B work should test a single specific remaining hypothesis:
isolate per-response Uniform constructor cost versus parser/transaction
state management with equivalent validation. Do NOT skip Uniform
canonical message checks, invent cache semantics, or change
Linux::Event core to paper over HTTP-layer overhead. Compare actual
end-to-end before/after on the same runner. Stage C h2spec still
11 failures (baseline parity, not conformance); Stage F deferred.
No main changes, merges, tags, version bumps or releases.

## Stage E generic multiplexed CONNECT verified — 2026-10-25

Upper Unblock::HTTP feature/linux-event-integration source:
e9efa51ee0110227945628f3f85a3feedba90558,
follow-up terminal observer source 79aa4904ba756d72d409e285d00f5c260a5f56eb
and H3 SETTINGS-scoped source dc4848cbd05555fffc0af0bf6ae0e8cdc73b5dd3.
Upper CI 40154517724 PASSED Perl 5.20/5.44.
Upper handoff updated on authorized feature branch.

Root full CI 40154550676 PASSED all SEVEN Perl jobs.
Required t/rebuild/107-generic-multiplex.t PASSED in native and Perl
input modes with real H2 TLS and H3 QUIC:
- first generic Extended CONNECT waits for peer SETTINGS automatically,
  with no warmup request or WebSocket dependency;
- Server on_handoff($tx,$request,$bridge) and Client
  request(on_handoff=>...) accept protocol-neutral byte consumers;
- outgoing DATA is bounded/deferred over each independent H2/H3
  transaction, never replacing the whole TLS/QUIC connection;
- bidirectional PING/PONG raw tunnel, reciprocal EOF and terminal
  completion exactly once; concurrent ordinary HTTP sibling intact;
- rejection with undef returns HTTP 403, installs no Client consumer,
  closes unused request producer and returns pooled stream credit;
- one shared transport and zero remaining socket/timer watchers;
- existing H3 stream-credit/malformed UDP and H2/H3 WebSocket tests
  also PASS.

Supplemental rejection-fallthrough assertion root 1590a770b8ff8b4a7ab6f837afac75559a3ff386
VERIFIED in CI 40154733648: all SEVEN Perl lanes PASS,
including latest nonthreaded t/rebuild/107 in both native and
Perl input. No rejected H2/H3 CONNECT enters on_request.
This closes the core Stage E regression gate.

This is a focused Stage E stream contract; it does not claim that
HTTP2 or HTTP3 protocol conformance gates have passed.

Current core Stage E requirements from the approved plan are covered:
native same-read H1 Upgrade, TLS-preserving whole-stream handoff,
H2/H3 WebSocket and generic stream-local CONNECT, ordinary sibling
independence, close/shutdown ownership. Stage F cleanup remains
deferred. Stage B HTTP1 throughput comparison and Stage C h2spec
(146 total / 134 pass / 1 skip / 11 fail, baseline parity) still
FAIL release gates. Do not merge/tag/bump/release. Main unchanged.

## Stage E HTTP3 CONNECT fix — independently and downstream verified (2026-10-25)

User explicitly authorized feature-branch work on Unblock::HTTP3.
New branch: feature/connect-completion-recheck; main unmodified at
aa810d0b80dd4b3f94850b8ca95a4b5e6d7737a7.
Production implementation + test commit:
b0585f6083c91a7bdfea0ddbccfefea76ab92362.
Standalone full CI 40152896247 PASS across Perl 5.20/5.28/5.36/5.44.
Standalone t/28-connect-completion.t creates real Net::QUIC loopback:
CONNECT response DATA, reader and response FIN complete before Client
request FIN, then request writer complete() must invoke Client
on_complete/on_finish exactly once without further QUIC polling.
The fix rechecks existing Connection::_maybe_complete_transaction()
after Body::Stream->complete commits its writer-complete flag;
no adapter workaround, Linux core/Net::QUIC modification, or version bump.

Downstream Linux::Event::HTTP CI 40152960105 PASS all SEVEN Perl jobs,
including required latest-nonthreaded real QUIC H3 and WebSocket lanes.
Root CI pins exact H3 feature source b0585f6 and installs it AFTER
released dependency prerequisites. Mandatory
t/rebuild/102-websocket-multiplex.t PASS both native and Perl input:
H2 and H3 Extended CONNECT WebSocket echo, ordinary HTTP sibling on
one transport, close/FIN terminal on_finish uniqueness, stream credit
return, Server shutdown and zero leaked watchers. TLS WebSocket
t/rebuild/106 also PASS both modes; Stage D tests 70/80/90/95/96/97/
98/99 remain green.

The previously required failing H3 Close regression is RESOLVED by
that verified engine feature commit; earlier RED CI evidence below is
historical, not current. The original approved design is unchanged.
Still OPEN: Stage E generic H2/H3 non-WebSocket stream-local handoff,
Stage B HTTP1 throughput gate and Stage C h2spec (146 total,
134 pass / 1 skip / 11 fail, equal to legacy baseline). Stage F
legacy cleanup deferred. H3-only and wildcard bind unsupported.
No main, merge, tag, version bump or release changes in either repo.

## Stage E generic HTTP1 handoff and H3 completion diagnosis - 2026-10-25

Authorized upper Unblock::HTTP feature-branch commits:
- ba73dfd0f731620763ec3a0ba62c5d1262650ddf:
  framework-neutral Server on_handoff; HTTP1 101 Upgrade and successful
  CONNECT hand the same transport to a generic input consumer.
- a850460a253937735f8cfe763a4afd3bf43ec147:
  generic Client request(on_handoff => ...) for strict HTTP1;
  detaches upgraded socket from the upper Client's connection pool.
- Upper CI 40151043666 and 40151346692 both PASS Perl 5.20/5.44.

Linux::Event::HTTP uses its already verified native HTTP1 INPUT_SWITCH
and transition_to() class reblessing to deliver a same-read post-switch
tail exactly once, preserving socket/TLS and queued writes. No parser or
native ABI change was needed. t/rebuild/104-generic-handoff.t verifies
both 101 Upgrade and 2xx CONNECT; t/rebuild/105-generic-client.t
verifies public Client Upgrade, data exchange, pool transfer, later
ordinary HTTP and complete teardown. Both pass native and Perl input
on the 5.44 lane of CI 40151423807; six ordinary Perl lanes completed
successfully. Latest Perl H3-required lane remains blocked by 102.

Precise independent H3 defect evidence: CI 40150770545 captured a
ONE-SECOND, pre-timeout snapshot of the real H3 Client Transaction:
state=active, callback_depth=0, response.is_complete=1,
incoming response reader.is_complete=1,
request writer.is_complete=1, output_finished=1,
stream_lifecycle.closed_seen=1, WebSocket Close exchange complete=1.
Yet Client on_finish does not run; timeout cancels the stream at 5 sec.
This is an HTTP3 lifecycle completion recheck defect after all
completion prerequisites became true. Unblock::HTTP3 is READ-ONLY under
the current authorization. Do NOT add a private-engine method call to
Linux::Event::HTTP, and do NOT weaken or disable t/rebuild/102.
Ask for explicit authorization before fixing Unblock::HTTP3 source in
its own feature branch. No main, tags, releases or version changes.

Generic H2/H3 non-WebSocket stream-local Extended CONNECT and a
targeted TLS HTTP1 same-read Upgrade remain unfinished. Stage B HTTP1
throughput gate and Stage C h2spec parity failures remain OPEN.
Stage F cleanup remains deferred in the approved plan.

## Stage E TLS WebSocket handoff gate verified — 2026-10-25

- Root source for test fixture: be1434476b614214b30b5bdcc8a370b1b20642ad.
- CI https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40152181082:
  6/7 Perl lanes PASS (5.36, 5.38, 5.40, 5.42, 5.44 and latest
  threaded). Latest Perl nonthreaded lane FAILS ONLY because of the
  already-required H3 WebSocket completion regression in t/rebuild/102.
- The new required real TLS loopback t/rebuild/106-websocket-tls.t
  PASSED both native borrowed-input and Perl input modes on latest Perl.
  Validated established authenticated TLS transport/cipher on both
  reblessed successors, real encrypted WebSocket exchange, detached
  HTTP Client pool connection, shutdown and zero watchers.
- The initial TLS fixture mistakenly supplied too few callback parameters
  for Server on_request and Server WebSocket on_open, which Perl 5.44
  correctly rejected. Both fixture signatures corrected; no protocol or
  Linux::Event core change was necessary.
- t/rebuild/100 HTTP1 same-read Upgrade, t/rebuild/101 public WebSocket
  Client, 104 generic Server 101/CONNECT, and 105 generic Client
  continue passing native and Perl input.
- H2 part of t/rebuild/102 passes; H3 Client still misses its final
  transaction completion recheck despite response+reader+writer complete.
  Exact issue and proposed engine-only correction are recorded in
  docs/HTTP3-EXTENDED-CONNECT-COMPLETION.md.
- The approved Stage E plan remains. Generic H2/H3 non-WebSocket
  stream-local handoff and H3 close fix remain uncompleted. DO NOT
  change read-only Unblock::HTTP3, Net::QUIC or core without explicit
  authorization; do not weaken the H3 test.

## Stage E WebSocket implementation and verified boundary — 2026-10-24 local

Current tested implementation: dd902cc1015993b51ceed347110f76a5a3a88a59
(HTTP1 native INPUT_SWITCH/transition_to, WebSocket option, shared Server
defer); later feature-branch commits include tests and diagnostics.
- Root CI 40149010878 PASS all seven Perl lanes. The required actual
  HTTP1 TCP Upgrade fixture t/rebuild/100-websocket-h1.t passes 12
  assertions BOTH native XS and Perl input: handshake and masked frame
  received in one write, 101 output ahead of WebSocket echo, no duplicate
  tail, clean shutdown.
- Root CI 40149284214 PASS all seven Perl lanes. Public Client and
  Server t/rebuild/101-websocket-client.t pass in both native and Perl
  input, with ordinary HTTP on a separate connection after H1 takeover.
- t/rebuild/102-websocket-multiplex.t added to mandatory real H2/H3
  WebSocket testing, both native and Perl paths on latest Perl.
  H2 WebSocket Extended CONNECT and an independent ordinary H2
  transaction pass (16 assertions in native run).
  H3 WebSocket opens, echoes correctly and serves an ordinary H3 sibling
  over one QUIC connection; it FAILS graceful terminal lifecycle.
  CI 40149457160 and 40149637801 FAILED latest nonthreaded lane:
  H3 Client WebSocket operation expired after 5 seconds. Deferring
  WebSocket Close initiation to a later loop turn did NOT fix it.
  Diagnostic CI 40149783042 confirms:
  Client WebSocket close_sent=1, close_received=1, close_complete=1,
  but is_closed=0, Client H3 tx cancelled by timeout;
  Server H3 tx complete; ordinary H3 sibling complete; pool active=0.
  The missing boundary is Client receive-side HTTP3 stream EOF/finish
  after exchanged Close frames, not failure to send Close frames or
  HTTP1 native provider transition.
  Keep t/rebuild/102-websocket-multiplex.t mandatory and failing
  until resolved; do not weaken the Close/terminal requirement.
- Unblock::WebSocket main and Net::QUIC/HTTP3 engines are READ ONLY.
  Existing upstream Unblock::HTTP t/36-client-websocket-h3.t covers
  complete H3 close when driven directly by Net::QUIC Driver and an
  IO::Select loop. Compare precise adapter scheduling/callback order.
- Remaining Stage E: fix genuine H3 completion at authorized integration
  layer (or request permission before any read-only engine edits);
  then implement generic non-WebSocket Upgrade/CONNECT contract in
  authorized upper Unblock::HTTP feature branch. TLS H1 WebSocket same-read
  tail, rejection, and additional shutdown tests remain useful.

Stage D remains verified on supported combined TCP/UDP concrete-address
HTTP3; Stage B throughput gate remains OPEN; Stage C h2spec
146 total / 134 pass / 1 skip / 11 fail still OPEN. Stage F deferred.
No main changes, tags, merges, releases or version bumps.

## Stage D active H3 cancellation and delayed drain - pending validation

- Added t/rebuild/96-http3-active-drain.t, a required real-QUIC CI test
  covering cancellation of one admitted H3 operation while a 512 KiB streamed
  response continues independently, and shutdown started before a delayed
  admitted response has been sent.
- The test verifies terminal callback uniqueness, response integrity,
  graceful completion and watcher/timer cleanup, without modifying Unblock
  or Net::QUIC. Results are not yet verified; adjust implementation if CI
  reveals a lifecycle problem, and record the exact evidence here.
- Stage B throughput, Stage C h2spec conformance, Stage E and F unchanged.

## Stage D real H3 lifecycle and multi-connection progress

- CI run 40146031133 passed all seven Perl jobs after adjusting the test
  to await asynchronous zero-grace QUIC shutdown completion. Real H3
  active cancellation with independent 512 KiB streaming sibling and
  delayed admitted-response drain both passed. No protocol code change was
  needed to meet these two test cases.
- t/rebuild/97-http3-multiconnection.t now verifies two separate public
  clients and QUIC connections on one Server. It holds both requests until
  admitted, responds in reverse order, checks routing and independent
  completion, and requires release of both sessions and all loop watchers.
  This new test is pending real-QUIC CI verification.
- Stage D credit recovery and malformed-UDP containment remain open.
  Stages B/C gate exceptions, Stage E and Stage F remain unchanged.

## Stage D credit and malformed UDP checks - pending CI

- The real QUIC test t/rebuild/97-http3-multiconnection.t passed 13
  assertions in workflow 40146260213, and all seven Perl lanes passed.
- Added t/rebuild/98-http3-credit-malformed.t. The first subtest sets
  QUIC server max_bidi_streams => 1, holds the first admitted response,
  and requires a second queued public Client operation to be admitted
  after stream credit recovers. It checks both transaction identities and
  bodies. The second subtest injects three malformed raw UDP datagrams,
  then requires an authenticated public H3 request and response to succeed
  with no unwound event-loop error. Both require real dependencies in CI.
- These new checks are pending CI verification. No Stage B/C gate waiver,
  Stage E/F work, or dependency/main source modification occurred.

## 2026-10-25 Stage D credit recovery ownership fix - verification pending

- The real-QUIC credit test successfully admitted both operations and the
  malformed-UDP case passed, but it exposed an orphaned speculative QUIC
  connection after shutdown: Client pool had connecting=1 with pending=0,
  active=0, connections=0; a connected UDP watcher and its QUIC timer
  remained live. This was NOT a test-timing issue.
- Authorized upper Unblock::HTTP feature branch commit
  f15638ec1cb35f95e0b1f4eb4138298fccb5fc85 fixes the generic admission
  race: a recovered existing H3 connection cancels the speculative factory
  before dispatching its queued request. Shutdown also cancels any outstanding
  factory even if no queued op still refers to it.
- Root CI now pins that upper source commit and requires the unchanged
  real H3 credit/malformed regression. Verification pending; do not call the
  gate closed until both upstream and root CI pass.
- Unblock::HTTP1, Net::QUIC, core, Uniform, H2/3, WebSocket and main unchanged.

## Stage E HTTP1 WebSocket stream-wide transition (pending tests)

- Linux::Event::HTTP::_Transport implements Unblock's synchronous
  unblock_upgrade($successor) hook. It uses the existing Linux::Event
  transition_to() to replace HTTP1 input handling, without recreating TCP/TLS
  sockets, altering queued writes, or introducing a second HTTP parser.
  The private _UpgradedStream delegates data, EOF, errors, drain and
  teardown to the actual Unblock::WebSocket successor.
- The native XS bridge accepts HTTP1 INPUT_SWITCH only when a verified
  successor Stream transition has occurred. The reported consumed prefix
  stays with HTTP1; the native host retains and re-drives the unread suffix
  through the new class. Unsupported generic 101 switches remain rejected.
- Server now forwards opt-in on_websocket and supplies the event-loop defer
  callback required for H2/H3 Extended CONNECT. The existing protocol
  option validator no longer unconditionally rejects websocket => 1.
- WebSocket remains strictly opt-in and lazily loaded by Unblock. Full
  handshake, same-read native remainder, TLS, independent H2/H3 streams,
  and Client end-to-end tests are still required before Stage E can pass.
  This source slice is not yet CI-verified.

## Stage D verified gate — 2026-10-25

Source implementation checkpoint: 4243b0a676d9027ef185a08bfb7052d45704340c.
Unblock::HTTP admission/connector fix:
f15638ec1cb35f95e0b1f4eb4138298fccb5fc85 (documentation head 8c84553).
The Linux::Event::HTTP CI workflow 40147345109 PASSED seven Perl jobs
(5.36, 5.38, 5.40, 5.42, 5.44, latest and latest threaded).
The required latest Perl H3 lane installed real Net::QUIC 0.06 and
Unblock::HTTP3 0.13 and passed ALL targeted real QUIC/TLS tests:
- 70-http3-loopback.t: 19 checks
- 80-http3-client.t: 16 checks
- 90-http3-server.t: 13 checks
- 95-http3-errors.t: 2 subtests
- 96-http3-active-drain.t: 2 subtests
- 97-http3-multiconnection.t: 13 checks
- 98-http3-credit-malformed.t: 2 subtests
- 99-http3-timeout.t: 14 checks

The H3 timeout test verified an admitted operation expires with one
error/finish and a subsequent independent request on the same Client
succeeds, followed by zero surviving UDP/TCP/timer watchers.
The credit test verified real QUIC stream-credit wakeup, malformed UDP
isolation and cleanup after fixing a genuine upper-layer speculative
connection race. Upper Unblock H1-only CI 40147073797 also passed on
Perl 5.20 and 5.44. H1-only root isolation and both native/Perl H1
input paths remain green without importing optional QUIC engines.

Stage D gate is therefore met for the currently supported, explicitly
concrete IP-bound HTTP3 Client and combined TCP/UDP Server integration.
H3-only Server, wildcard/multihoming/pktinfo binding, independent QUIC
migration features and release-level performance/conformance claims are
NOT implied. The approved plan has NOT changed.

Remaining release blockers:
- Stage B baseline/rebuild HTTP1 throughput gate OPEN.
- Stage C h2spec parity: 146 total / 134 passed / 1 skipped /
  11 failed — identical to untouched baseline, NOT clean conformance.
- Native HTTP1 INPUT_SWITCH still explicitly fails.
- Stage E optional WebSocket and generic socket/stream handoff unimplemented.
- Stage F legacy code removal/documentation/package disttest unstarted.

## Stage D H3 credit recovery, malformed input, and timeout isolation

- Upper Unblock::HTTP source f15638ec1cb35f95e0b1f4eb4138298fccb5fc85
  fixes the credit-recovery speculative-connector race. Its H1-only CI
  40147073797 PASS on Perl 5.20 and 5.44.
- Linux Event::HTTP source 5eb520adf7c151db2244f58889589f3735ac051f
  pins that upper dependency; CI 40147115577 PASS all seven Perl lanes.
  The latest non-threaded lane required real QUIC and passed
  t/rebuild/98-http3-credit-malformed.t: two subtests. Both H3 operations
  recovered credit, all watchers were released, and junk UDP did not
  disturb a valid authenticated HTTP3 request.
- Removed temporary Data::Dumper diagnostics used to identify the stale
  QUIC socket and timer; the strict zero-watcher test remains.
- Added t/rebuild/99-http3-timeout.t to verify that an ACTIVE H3 request
  times out, invokes terminal callbacks once, and does not poison a later
  healthy request on the same public Client, followed by full cleanup.
  Required real QUIC CI verification is pending.
- Stage B throughput gate and Stage C 11 h2spec parity failures remain
  OPEN. Stage E and F have not started. No main, tag, merge or release.

## Stage D verified TLS identity and queued cancellation - 2026-10-24

- Source checkpoint: 8a48d6aed17e13fa0a57d6dbce772397a79c9cf2.
- CI https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40145575144
  PASS on all seven Perl lanes, with both H1 input paths, HTTP1-only
  isolation, optional HTTP2 and required real H3 tests preserved.
- t/rebuild/95-http3-errors.t passed two subtests using genuine QUIC:
  a trusted certificate naming localhost but not 127.0.0.1 cannot
  authenticate strict H3 requests to the IP address; on_error/on_finish
  fire, on_request is never admitted, and watchers release cleanly.
  An operation cancelled before QUIC readiness finishes once with
  cancelled state and no remaining connector/timer watchers.
- Existing real H3 tests remain green: lower loopback 19 assertions,
  public Client 16, public Server 13. These tests do not yet cover
  *active* H3 stream cancellation, credit recovery, independent
  multi-connection scheduling, packet errors, or graceful shutdown
  under a genuinely delayed response. Those are the next focused tasks.
- Stage B performance gate remains OPEN and Stage C's 11 h2spec parity
  failures remain OPEN. Stage E and Stage F are not started. Main and
  other read-only repositories remain untouched.

## Stage D HTTP3 public Client/Server verification - 2026-10-24

- Published source milestone: d0a1753c3edb9baf2351f9001fb876a26cbe5340.
- Seven-lane CI: https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40145261643
  PASS on Perl 5.36, 5.38, 5.40, 5.42, 5.44, latest and latest
  threaded. Both native/Perl H1 input modes, H1-only isolation and
  optional H2 tests remained green.
- The required latest-Perl H3 step installed real Net::QUIC 0.06 and
  Unblock::HTTP3 0.13. Passed three independent real QUIC/TLS tests:
  t/rebuild/70-http3-loopback.t: 19 assertions;
  t/rebuild/80-http3-client.t: 16 assertions;
  t/rebuild/90-http3-server.t: 13 assertions.
- Public Client uses the Unblock pool with async Linux Datagram address
  resolution, the QUIC Driver, original-origin TLS authentication, and
  actual engine Transaction objects. Four strict H3 requests multiplexed
  over one connection and released all UDP/timer watchers.
- Public combined TCP/UDP Server binds one concrete host and port, uses
  the same Unblock Server definition for all protocols, and reuses its
  configured TLS certificate/key for QUIC. Two H3 requests completed
  on one QUIC connection through public on_headers/on_request callbacks.
  Graceful shutdown test and socket/timer leak checks pass.
- HTTP3 is not fully hardened: H3-only and wildcard listeners, alternate
  source addresses/migration, comprehensive TLS failure, cancellation,
  timeout, congestion, multi-connection stress and precise graceful-drain
  timing still need explicit coverage. No conformance/performance gate
  claim was made.
- Stage B throughput remains OPEN. Stage C h2spec unchanged:
  146 total, 134 pass, 1 skip, 11 fail, equal to baseline. Stage E
  WebSocket/generic handoff, HTTP1 INPUT_SWITCH, and Stage F cleanup
  remain undone. Do not accelerate Stage F; original plan still holds.

## 2026-10-24 Stage D real QUIC test pending CI

- Added t/rebuild/70-http3-loopback.t using the private Linux UDP bridge
  on BOTH ends, the actual Net::QUIC::Driver, Unblock::HTTP::QUIC manager,
  Unblock::HTTP3 engine, an ephemeral verified localhost certificate, and
  two concurrent HTTP3 GET transactions sharing a QUIC connection.
- The fixture checks callback ordering, Uniform/Unblock identity, exact
  response bodies, and release of UDP/timer watchers after close.
- The test is gated by optional Net::QUIC >= 0.06 and Unblock::HTTP3 >= 0.13;
  latest non-threaded CI explicitly installs these dependencies and requires
  the test rather than treating a skip as success. The ordinary HTTP1-only
  installation must remain unaffected.
- _QUICSocket now accepts finite non-negative scientific notation timeouts
  (such as 1e-3 seconds) and rejects NaN/infinity, matching Net::QUIC
  dynamic relative timer semantics. t/rebuild/60 covers this edge case.
- This is a concrete H3 transport/engine test, NOT public HTTP3 Server/Client
  integration. Those remain disabled until full ownership, cancellation,
  shutdown and verification are implemented and tested.
- Verified in CI run 40143923528, GREEN in all seven Perl lanes:
  https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40143923528
  The latest non-threaded Perl 5.44 lane installed Net::QUIC 0.06 and
  Unblock::HTTP3 0.13 from CPAN, REQUIRED the real HTTP3 loopback test,
  and passed all 19 assertions. The ordinary rebuild test suite passed
  7 files / 32 subtests with H3 optional when its deps were absent,
  and both HTTP1 input paths plus optional HTTP2 passed.
  This is actual QUIC/TLS/HTTP3 evidence, not a mocked handshake.
- Existing Stage B throughput and Stage C conformance gates remain open.
  Stage F cleanup remains deferred as originally approved.

## 2026-10-24 Stage D public Client initial integration

- Optional public http3 => 1 enables the existing Unblock::HTTP::Client
  H3 connection-pool/transaction path. No replacement H3 pool was created.
- Linux Event _QUICSocket->connect now delegates hostname resolution to the
  asynchronous Linux::Event Datagram connector, uses the resulting concrete
  local/peer sockaddr pair, maintains dynamic QUIC timers, validates outgoing
  destinations on connected sockets, and reports driver progress.
- Client connect_quic constructs Net::QUIC::Driver->client using the original
  origin hostname for TLS identity and the selected UDP peer destination.
  The factory calls Unblock's ready callback only after authenticated QUIC
  readiness. Connection cancellation and release own the UDP socket/timer.
- The H3 optional runtime/metadata requirements are Unblock::HTTP3 >= 0.13
  and Net::QUIC >= 0.06. No H3 dependency is loaded for HTTP1-only clients.
- Public H3 Server, graceful QUIC ownership/drain and broad failure tests
  remain pending. This commit needs live CI before the Client can be called
  verified. Core, upstream engines and main remain unchanged.

## Stage D public HTTP3 Server initial integration

- Added optional H3 Server transport alongside the ordinary TCP/TLS
  listener on one explicitly concrete address and port. Credentials
  reuse TLS cert_file/key_file; native QUIC transport policy is configured
  separately via quic => hashref.
- Unblock::HTTP::QUIC->server attaches ready QUIC connections to the same
  Unblock::HTTP::Server definition used by H1/H2. Linux::Event owns one UDP
  socket and relative timer. No H3 parser or per-transaction wrapper exists.
- H3 close sends GOAWAY and rejects future ready sessions. Shutdown uses
  H3 drain/QUIC close when drained and force releases the UDP socket at
  the grace deadline. H3-only/wildcard listeners remain unsupported.
- This needs focused real public Server tests and CI verification before
  the capability can be called verified. No main/upstream source changed.

## Current h2spec failure grouping (not a fix)

The recorded 11 h2spec 2.6.0 failures are not all the same condition:
six are in HTTP/2 section 5.1 (half-closed/closed stream handling), one
in section 5.1.1 (decreasing stream ID), one in 5.3.1 (self-dependent
PRIORITY), one in 6.1 (DATA on a non-open stream), one in 6.3 (PRIORITY
on stream zero), and one in 6.9.1 (stream WINDOW_UPDATE overflow).
The baseline, rebuilt native path, and rebuilt Perl path have identical
diagnostics for each. That rules out a new regression in the rebuilt
input bridge for these cases; it does not establish which engine policy,
harness fixture, or wire-order issue explains each failure. Before
proposing read-only HTTP2 source changes, reduce the specific failing
case(s) against the current upstream engine.

## Stage D Linux UDP transport foundation (2026-10-24)

A new private _QUICSocket supplies the Linux::Event datagram and one-shot
timer callback contract for Net::QUIC::Driver / Unblock::HTTP::QUIC. It
forwards packed packet addresses without parsing QUIC; preserves full packet
boundaries; maps false from the Linux::Event send queue as accepted but
congested and resumes the QUIC manager at on_drain; and replaces/cancels
relative-seconds timers on each driver update. It also closes owned UDP and
timers idempotently. Concrete bound source addresses only: wildcard local
and outgoing local-address changes are rejected until pktinfo/multihoming
support exists. The new isolated regression uses actual Linux UDP sockets
and a mock manager so HTTP3 is not mandatory for HTTP1 installations.

The Stage C seven-lane HTTP2 workflow 40142345620 passed. New Stage D
CI run 40143058003 also passed all seven Perl lanes (5.36, 5.38, 5.40,
5.42, 5.44, latest and latest-threaded), with the real UDP mock-manager
test included in both input paths. Perl 5.40 logs report 6 files / 31
subtests on each path. H1-only isolation and optional H2 checks passed.
Public http3 remains disabled;
real QUIC handshake, HTTP3 request/response, timeout/credit recovery and
service shutdown are still pending. Stage B and h2spec limitations are unchanged.

## HTTP2 integration milestone (2026-10-24)

Optional HTTP2 now works through the unified layer with TLS ALPN, HTTP1
fallback, strict version selection, multiplexed streams, streaming uploads,
flow control, sibling cancellation, GOAWAY drain and grace expiry. The native
bridge validates the distinct H2 ABI and borrows input without a payload SV.
Output uses only the attached host and resumes only when transport congestion
has cleared. A real eval boundary contains malformed-input exceptions; the
adapter defers ordered Stream->end when H2 no longer wants input or output.
No HTTP2/core/Uniform source changes were made. The bundled ABI header is a
licensed public-contract snapshot from HTTP2 0.12 at 7bc0b6ccd653a74ad1e7399d27aa9d94c941b513.

Current suite: 5 files / 28 subtests, both native and Perl paths, Perl 5.38.2
threaded and 5.44.0 non-threaded. Root 5.38 disttest passes the same 5 files / 28 subtests. The new HTTP2 tests cover concurrency,
TLS verification, callback ordering, ownership, congestion, forced and graceful
shutdown, and continued listener service after an invalid connection preface.
H1-only tests continue to pass without the optional dependency. The unchanged
HTTP2 standalone suite passes 30 files / 525 tests on 5.38.

h2spec 2.6.0: **146 tests / 134 passed / 1 skipped / 11 failed** on the
untouched main baseline, rebuilt native input and rebuilt Perl input. Failing
case identities and diagnostics match exactly across all three runs. This
establishes same-environment parity, not clean protocol conformance; the
historical 144/1/1 result must not be substituted for these current results.
See bench/results/unblock-stage-c/h2spec-parity.json. The conformance server
responds at headers and drains the body, preserving the old fixture behavior.
The public on_request callback still waits for body completion.

The workflow now tests optional HTTP2 on every supported Perl lane after
checking HTTP1-only behavior. Published implementation: `38ef7d3035190132a658c12e80e487eb254c7069`.
Remote CI is queued/in progress and must be checked:
https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40142345620
Prior retention CI is green: root run 40135515145, HTTP1 standalone
40135426474 and framework examples 40135426480. Main remains untouched.
Cleartext H2 prior knowledge/h2c, H3, WebSockets and generic handoff are pending.
The Stage B performance gate remains open; no H2 throughput claim is made.

## Output ownership milestone (2026-10-24)

Unblock HTTP1 feature commit `06a0f5d7c0509ad0deaebe4a8269c03fbe07ea14`
transfers serialized wire payloads out of retained transaction plans into the
output queue. Empty batches preserve Perl copy-on-write storage; existing
batches still coalesce. Canonical Uniform bodies and streaming framing state
remain intact. This avoids retaining a second serialized body after sending.

Validation: HTTP1 40 files / 349 top-level tests on Perl 5.38.2 threaded and
5.44.0 non-threaded; 5.38 disttest passes. Linux HTTP 4 files / 18 subtests
pass on both input paths and both Perls. Upper HTTP 30 files / 870 tests pass
on 5.38 (optional real engines still skipped in this run).

New `bench/run-unblock-retention.pl` is a Linux socket-free diagnostic. Each
fresh process holds 256 completed transactions with distinct 256 KiB canonical
bodies (64 MiB total). Three before/after samples used the previous HTTP1
`0edca539...` Perl modules versus the changed modules with identical XS.
Median additional RSS: server 133444 -> 67896 KiB; client 133448 -> 67644 KiB.
Bodies are checked after measurement. RSS includes allocator overhead and is
not peak RSS or evidence about unrelated workloads. Raw samples are under
`bench/results/unblock-stage-b-retention/`.

Matched native GET/16 KiB, 100 connections, pipeline 1, 10000 requests after
1000 warmup, three repeats: 9454 -> 9772 median req/s; server CPU 106.419 ->
103.208 us/request. This small change on the shared host does not establish
reliable throughput improvement. The original performance gap remains open.
Before source is reproducible with a read-only worktree at `0edca539...` and
`perl -I/path/to/before/lib` ahead of the same HTTP1 XS in PERL5LIB.

Retention feature branch published; main unchanged. Remote CI passed in root
run 40135515145 and HTTP1 runs 40135426474 / 40135426480.

## Earlier Stage B milestone

Required development dependencies (both on `feature/linux-event-integration`):

| Repository | Local commit | Added behavior |
| --- | --- | --- |
| Unblock::HTTP1 | `1eb332872257087bb13ccde0f74f235c353d6e67` | Native simple-response serialization; public idempotent Server drain |
| Unblock::HTTP | `6fa6c452236f9ecc2830d250fefc7d79d1167676` | on_transaction admission callback; optional H2/H3 metadata |

These feature commits are now published. Versions remain 0.12/0.02; published
releases do not contain the additions. Linux HTTP CI pins these source commits.
The user authorized ongoing feature-branch pushes on 2026-10-24; main still
requires permission. The upper
H1-only installation lane now uses ordinary dependency resolution, not --nodeps.
No Linux::Event, Uniform, HTTP2/3, Net::QUIC or WebSocket source was changed.

Implemented and verified:
- Queued streamed uploads begin in `on_transaction($tx)` after assignment of
  the actual engine transaction. No provisional transaction or body buffer.
  Cancellation and producer exceptions clean up once; H3 credit-blocked undef
  does not notify until real admission (tested with engine doubles).
- `Server->shutdown(grace => 30, on_complete => sub ($server) { ... })`
  stops listening, drains admitted H1 work, and closes stalled sockets at the
  deadline. `close` remains listener-only. Completion may be synchronous when
  idle; it runs after transaction cleanup and owned socket removal.
- A new stalled-TLS test exposed a Stage A ownership error: transport-ready
  fires after TLS, so it cannot own pending handshakes. Ownership now begins
  at Listener on_accept. Shutdown closes these unfinished handshakes immediately.
- H1 drain excludes unadmitted pipelined tails, reads an admitted body to its
  end, preserves delayed/streamed responses and waits for output acceptance.
  Manual output remains available after logical engine closure. Synchronous
  host close cannot turn an accepted response into a premature terminal error.
- XS simple response serialization uses Uniform's public native inspection
  API, avoids temporary Perl view arrays and leaves real Uniform objects
  intact. Framing fields, HEAD/CONNECT, special statuses, streaming, trailers,
  HTTP1.0, adapters/subclasses and unsupported layouts retain general handling.
  No native ABI layout change. Interpreter-local handles reset after cloning.

Validation:
- Linux HTTP: **4 files / 18 subtests / 80 inner assertions**, both native and
  Perl input, Perl **5.38.2 threaded** and **5.44.0 non-threaded**.
- HTTP1: **39 files / 346 top-level tests** on both Perls; 5.38 disttest passes.
- Upper HTTP: **30 files / 870 top-level tests** on both Perls; 5.38 disttest
  **27 files / 753 tests**. Real optional H2/H3/WebSocket suites skip locally;
  mocked protocol tests do not establish real multiplexed transport coverage.
- POD/ASCII checks and git diff --check pass.
- Remote Linux HTTP matrix **PASS**: 5.36, 5.38, 5.40, 5.42, 5.44, latest,
  latest threaded. Both input paths, H1-only runtime and harness smoke pass.
  [Run 40105849132](https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40105849132)
  tested published source `faa457abda2aa4f7bb441c174d6b61c8cf2b47a0`.
- HTTP1 standalone cross-platform and framework CI **PASS**:
  [standalone](https://github.com/haxmeister/perl-Unblock-HTTP1/actions/runs/40105783566),
  [frameworks](https://github.com/haxmeister/perl-Unblock-HTTP1/actions/runs/40105783602).
- Upper H1-only installation **PASS** on Perl 5.20/5.44 with ordinary
  prerequisite resolution, disttest and optional-package absence checks:
  [run 40105784783](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/40105784783).
  Real H2/H3/WebSocket integration remains untested for these changes.

Publication used the connected GitHub Git-data API because shell Git lacked
credentials. Every uploaded tree was checked against the tested local tree;
API commit IDs differ from the earlier local checkpoint IDs. No force-push
or main update was performed. Later handoff-only commits use [skip ci]; the
linked runs above validate their unchanged runtime source.

Matched GET/32 server comparisons, 100 connections, pipeline 1, 10,000 measured
requests, 1,000 warmup, 3 repeats. Before uses unchanged HTTP1 `826fb573...`;
after uses the HTTP1 feature source. Both use the same Linux HTTP harness and
upper source. A reverse-order pair was collected because the host varied:

| Run order | Before median req/s | After median req/s | Before/after CPU us/request |
| --- | ---: | ---: | ---: |
| Before then after | 15,164 | 16,610 | 66.481 / 60.360 |
| After then before | 9,922 | 11,340 | 101.155 / 88.508 |

Observed improvements were about 9.5% and 14.3%, respectively. Shared-host
variation is large; do not combine these pairs into a precise forecast or
claim the original-performance gap is solved. Original Stage A GET/32 was
62,924 req/s. The performance gate is still open. No additional sweep is
needed without another code change or a specific unresolved measurement.

An NYTProf subroutine profile of the existing socket-free diagnostic identified
Uniform view materialization and response planning among the costs. The
recorded engine-only before/after samples also show a large change in the
unchanged response-constructor control case; they are retained as raw
observations, not evidence for a reliable microbenchmark speedup.
Raw data: `bench/results/unblock-stage-b/*.json`.

## Stage A implementation and baseline (historical detail)


- Replaced public Server and Client with the approved Unblock-based API.
  No request, response, transaction or operation wrapper is introduced.
- Server defines one Unblock Server and attaches accepted Linux::Event streams.
  on_headers/on_request are passed directly through the unified definition;
  the latter runs after body/trailers. A registry owns accepted sockets,
  and releases them on close. Stage B corrected pre-TLS ownership as noted above.
- Client subclasses Unblock Client and supplies connect_stream, defer,
  schedule_timer and release_connection. There is no second pool. Timeouts
  and cancellation use the original Unblock operations.
- TCP and TLS HTTP1 work. HTTPS verifies both trust and original hostname;
  the origin-verification flag is set only after verified readiness.
- Ordinary Perl transport fallback and a default native borrowed-input bridge.
  The bridge consumes Unblock's public NativeABI discovery/header, validates
  table version/size, and creates one Unblock context per live stream.
  Linux::Event retains incomplete prefixes. No HTTP parser exists in the bridge.
- C host retain/release spans callback-capable input, including exception
  unwinding and reentrant close. The stream reference is weak; the engine
  reference is released with the native context. EOF/error/drain callbacks
  enter the same engine through its ordinary lifecycle API exactly once.
- Whole-buffer write acceptance maps directly to Linux::Event's queue. False
  means accepted but congested; on_drain resumes Unblock. No resend buffer.
- Client pool observations, shutdown/network_changed and request shorthand
  methods reuse Unblock behavior. Server close remains listener-only; shutdown now performs service drain.
- Replaced primary README/POD and branch CI for the implemented contract.
  Old private implementations and t/*.t remain migration references. The
  default test target explicitly runs t/rebuild/*.t; it does not claim the
  obsolete public API suite passes against the replacement.

## Dependency inventory

Initial source inventory (subsequent authorized HTTP1/upper commits are above):

| Distribution | Version | Commit used |
| --- | --- | --- |
| Linux::Event | 0.117 | 66af732c2dbc7475dfd285841b7b0bf1ecb3b6b0 |
| Unblock::HTTP | 0.02 | 98a21ac8eb4a0bad6b49ab17b30819f79609c37d |
| Unblock::HTTP1 | 0.12 | 826fb5733daac62d9f5b51538dffbe1dc189c6d9 |
| Uniform::HTTP | 0.06 | 670c8eed8aeae6edc6d5e15ff9d8be5e7346c8b5 |

Current H2/H3 NativeABI modules, H2 public C header and Net::QUIC::Driver
were also inspected from GitHub main. Unblock metadata requires HTTP2 >=0.12,
HTTP3 >=0.13; Net::QUIC Driver declares 0.06. These engines were not built or
exercised by the new slice. H2's ABI appends native output/readiness methods
and must not be cast to the H1 or Linux::Event table. Native H2 output must
not be combined with its attached Perl transport. H3's ABI is a connection /
transaction service interface, not a borrowed TCP-input interface. QUIC
Driver needs datagrams and one dynamically replaced relative-seconds timer.

At the Stage A checkpoint, Unblock HTTP's runtime factory lazy-loaded engines,
but its Makefile.PL unconditionally required all three. Thus a normal CPAN installation
is NOT H1-only. CI's --nodeps installation of the upper layer intentionally
isolates H1 runtime tests and is not a packaging fix.

The actual Perl floor remains 5.36 because of Linux::Event. Unblock::HTTP
requires 5.20; HTTP1 and Uniform require 5.16. MIN_PERL_VERSION was not changed.

## Verification

- Original baseline against the same current dependency environment:
  **57 files / 1,489 tests PASS**, Perl 5.38.2 threaded.
- Rebuild: **3 files / 13 subtests (57 inner assertions)** on both native and
  Perl input paths, Perl 5.38.2 threaded and Perl 5.44.0 non-threaded.
- Covered: GET/POST and object identity, full-body callback order, pooling,
  streamed reception and responses, queue cancellation, timeout, fragmented
  headers, chunked bodies/trailers, pipelined tails, truncated-body EOF,
  request/response bounds, ambiguous framing rejection, reentrant native
  close and weak-reference release, 2 MiB forced output congestion, trusted
  HTTPS, untrusted certificate rejection and hostname mismatch rejection.
- The CI matrix includes 5.36, 5.38, 5.40, 5.42, 5.44, latest and latest
  threaded. It has NOT run remotely for this local checkpoint. No claim of
  full Perl-matrix, H2/H3, WebSocket, conformance or disttest success is made.

## Same-environment performance

Linux x86_64, system Perl 5.38.2 threaded, same core/Uniform/dependency paths,
optimized XS builds. Server workload: 10,000 measured requests after 1,000
warmup, 100 persistent sockets, pipeline depth 1, three repeats. Separate
server and raw TCP driver processes. Values below are medians; samples were
run sequentially without CPU pinning on a shared machine, so treat them as
diagnostic measurements, not a precise production forecast.

| Server workload | Original req/s | Rebuild native req/s |
| --- | ---: | ---: |
| GET -> 32 B | 62,924 | 12,819 |
| GET -> 16 KiB | 49,642 | 10,950 |
| POST 4 KiB -> 32 B | 40,188 | 10,397 |

Rebuilt Perl input GET/32: 11,378 req/s. Native input helps within the rebuild,
but the default server is still about 80% slower on GET/32. Do not claim the
performance gate passed. POST compares the actual defaults: the old harness
drains input while the new default buffers the complete request within its
bound. Wire workload, connections and driver are otherwise identical.

High-level buffered client workload: one persistent connection, raw independent
TCP responder, 32-byte replies, 5,000 measured requests after 500 warmup,
three repeats, explicit defer between requests for both implementations:

| Client | Median req/s | Median client CPU us/request |
| --- | ---: | ---: |
| Original | 4,409 | 211.709 |
| Rebuild native | 5,743 | 163.548 |
| Rebuild Perl input | 5,527 | 166.464 |

This one-connection client result does not establish multiplexing or saturated
client capacity. The benchmark does not claim an ecosystem-wide speedup.

An independent engine-only diagnostic (no Linux::Event, no sockets) found:

| Operation | CPU us/iteration |
| --- | ---: |
| Unblock HTTP1 portable input + ordinary response | 54.229 |
| Uniform response construction | 6.919 |
| Response construction + HTTP1 wire plan | 15.178 |

These are separate microbenchmarks, not additive profiler buckets. They show
substantial cost exists inside the upstream path; they do not identify every
hot function or predict the gain from a proposed optimization.

Raw results: `bench/results/unblock-stage-a/*.json`.

Reproduction with the dependency versions/SHAs above in PERL5LIB:

```sh
# Untouched baseline checkout/worktree:
perl Makefile.PL && make
perl -Mblib bench/run-http-end-to-end.pl --requests 10000 --warmup 1000 --repeats 3
# Repeat with --response-bytes 16384, or --request-body-bytes 4096.

# Rebuild checkout:
perl Makefile.PL && make
perl -Mblib bench/run-unblock-end-to-end.pl --requests 10000 --warmup 1000 --repeats 3
# Same additional workload options; --no-native-input selects Perl input.
perl -Mblib bench/run-rebuild-client.pl
perl -I/path/to/baseline/blib/lib -I/path/to/baseline/blib/arch bench/run-rebuild-client.pl --legacy
perl bench/run-unblock-engine.pl --requests 20000
```

## Authorized upstream work and remaining items

The user authorized these five proposals. Items 1-4 have the implementations
and validation described above; item 1 still has an open performance gap.
Item 5 remains pending for Stage E. Preserve standalone/event-loop-neutral engines.

1. **Unblock::HTTP1 performance:** profile the receive/transaction/response path
   with the captured workload, then reduce redundant validated-message work
   and add an XS simple-response serialization path using the existing Uniform
   native FastPath. Keep all framing/header checks and real Uniform response
   objects; retain a portable/general path. No XS is proposed for Uniform.
   Measure each change against this baseline; gains are not assumed.
2. **Unblock::HTTP Client admission:** accept `on_transaction($tx)` in request
   callbacks; invoke exactly once after the real engine Transaction is assigned
   to the operation. Never invoke for queued cancellation, connection failure
   or H3 credit-blocked undef. Permit write/end and cancellation there; route
   callback exceptions through the ordinary error/finish cleanup once. This
   removes polling and avoids a duplicate preconnection request-body buffer.
3. **Unblock::HTTP dependency metadata:** keep HTTP1/Uniform as base requirements;
   move H2/H3 requirements to optional features and check availability when those
   protocols are enabled. Preserve the existing lazy runtime factory. Add an
   installation/runtime H1-only test and explicit missing-enabled-engine errors.
4. **Unblock::HTTP1 Server drain:** add a public idempotent drain operation that
   stops admitting new requests (including a pipelined suffix), permits the
   currently admitted request body and response to finish, and then invokes
   transport finish after queued output acceptance. Idle connections finish
   immediately; cancellation/EOF/errors remain terminal once. H2 already
   exposes drain/GOAWAY and H3 has shutdown facilities. The Linux adapter can
   then implement a grace timer and final socket cleanup without replacing an
   application's sole on_finish callback or inspecting private engine state.
5. **Generic handoff (Stage E):** expose a protocol-neutral transition hook in
   the unified layer; currently the upper layer wires on_switch only for its
   WebSocket path and forbids generic connection hooks in policy options.
   The contract must distinguish H1 whole-transport ownership/remainder from
   H2/H3 stream-local ownership. Nail down that hook with focused tests before
   enabling it; do not bypass the unified layer here. Native INPUT_SWITCH is
   explicitly unsupported in this checkpoint and must not be treated as an
   ordinary consumed window. No post-upgrade-tail correctness claim is made.

Next work: resolve the Stage B upstream performance/admission/drain boundaries,
rerun the matched measurements and lifecycle tests, then continue Stages C-E.
Retain old private code until replacement coverage reaches its required
capabilities; complete its removal and the remaining docs in Stage F.
