# ACTIVE REBUILD HANDOFF - 2026-10-25

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


This section supersedes historical release/development instructions below.
Repository: haxmeister/perl-Linux-Event-HTTP
Branch: feature/unblock-http-rebuild
Published HTTP2 implementation: 38ef7d3035190132a658c12e80e487eb254c7069
Previous published checkpoint: dda70401c7d86db6a5600dc15874e93589e14344
Untouched main baseline: c0bf714e0f08f9031684e2eb4fd70dea3c68449f
Approved plan: docs/UNBLOCK-REBUILD-PLAN.md
Detailed evidence: docs/UNBLOCK-REBUILD-STATUS.md

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

## Authorization

Continue implementation, not architecture discussion or release preparation.
Feature-branch pushes are authorized as needed; main still requires permission.
No merges, tags, version bumps or releases. Source changes are authorized in:
- Linux::Event::HTTP, feature/unblock-http-rebuild.
- Unblock::HTTP1, feature/linux-event-integration: the approved performance
  and Server drain changes only.
- Unblock::HTTP, feature/linux-event-integration: the approved admission
  callback, optional dependency metadata and generic handoff changes only.

All other sources remain read-only, including core, Uniform, HTTP2/3,
Net::QUIC and WebSocket. HTTP2 was built and tested without source changes.
Generic HTTP1 Server/Client handoff is implemented and tested on the
  authorized upper feature branch. Generic H2/H3 stream-local CONNECT remains.

## Published dependencies

- HTTP1 latest implementation: 06a0f5d7c0509ad0deaebe4a8269c03fbe07ea14.
- Upper HTTP implementation: 6fa6c452236f9ecc2830d250fefc7d79d1167676
  (branch head includes docs-only 0b636373f39a117ef062f2b5e8bebc3655675aa2).
- Optional HTTP2 0.12, read-only main: 7bc0b6ccd653a74ad1e7399d27aa9d94c941b513.
- Linux::Event 0.117: 66af732c2dbc7475dfd285841b7b0bf1ecb3b6b0.
- Uniform::HTTP 0.06: 670c8eed8aeae6edc6d5e15ff9d8be5e7346c8b5.

HTTP1/upper versions remain 0.12/0.02; their released versions do not contain
these feature additions. Root CI pins the published feature source commits.

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

## Implemented

Stage A/B:
- TCP/TLS HTTP1 Server/Client, actual Unblock operations/transactions and
  Uniform messages, bounded buffers, streaming bodies, pooling, cancellation,
  timeouts, ownership/backpressure and native borrowed input.
- on_transaction starts queued streamed uploads after actual admission.
- Server shutdown closes the listener, drains admitted work and force-closes
  at the grace deadline. Ownership starts at on_accept, including stalled TLS.
- HTTP1 native simple-response serialization and public idempotent drain.
- Upper H1-only installation metadata and admission callback are implemented.
- Latest HTTP1 retention fix transfers serialized bytes out of send_plan into
  the output queue; empty batches use copy-on-write assignment. Retaining a
  transaction no longer retains a second serialized canonical body.

Stage C initial integration:
- Optional http2 => 1/hashref on Server/Client; TLS ALPN, HTTP1 fallback,
  strict client http_version => '2', multiplexing and stream cancellation.
- Server HTTP2 requires TLS. Cleartext prior knowledge/h2c are not implemented.
- Native bridge selects the actual engine after ALPN and validates distinct
  H1/H2 ABI tables. A licensed public H2 ABI header snapshot is bundled so
  HTTP1-only builds do not require HTTP2 development dependencies.
- H2 input is borrowed; output uses the attached Perl host, never native output
  at the same time. Host congestion is retained until on_drain. Native H2 input
  explicitly flushes only a ready output host through public resume_output.
- A real eval boundary contains malformed H2 input exceptions to that socket.
  It passes a stack-frame address, not a payload SV/copy. Perl input has the
  corresponding exception containment. Invalid prefaces cannot stop service.
- When H2 wants neither input nor output, the adapter defers Stream->end to
  preserve queued writes and leave protocol callbacks first. This fixed
  GOAWAY/error cleanup and completion without waiting for the grace deadline.
- H2 error callbacks may carry a third protocol-code argument; documented
  examples use a slurpy tail so Perl signatures accept it.

## 2026-10-24 Stage D transport groundwork

- The HTTP2 milestone workflow 40142345620 completed successfully in all
  seven Perl lanes (5.36, 5.38, 5.40, 5.42, 5.44, latest, latest-threaded).
  Both input-path and HTTP1-only checks were included in that workflow.
- A private _QUICSocket adapter now binds a concrete IPv4/IPv6 Linux::Event
  datagram socket, forwards packed local/peer addresses to a QUIC manager,
  maps the whole-datagram send/accepted-but-blocked contract, resumes on
  UDP drain, and implements replaceable relative-second timers.
- The adapter rejects wildcard local bindings because Linux::Event's current
  datagram callback does not supply per-packet destination/source information
  required by Net::QUIC. It also refuses outgoing datagrams requesting a
  different local source from the bound socket. No migration/multihoming
  support is claimed.
- t/rebuild/60-quic-socket.t exercises real UDP forwarding with a mock
  manager, timer replacement/cancel, source-address rejection and cleanup.
  Runtime test verified in remote CI on both input paths, seven Perl lanes.
  CI run 40143058003: https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40143058003
  Perl 5.40 build logs show 6 files / 31 subtests on each input path,
  including the new real UDP mock-manager test. Optional H2 and H1-only
  isolation checks also passed. No real QUIC/H3 handshake was tested.
- This is Stage D groundwork only. Public http3 remains explicitly disabled.
  No actual QUIC/TLS handshake, H3 HTTP transaction, or H3 shutdown test
  has yet passed. Do not promote it to an implemented H3 feature.
- Next: wire this adapter to Unblock::HTTP::QUIC and the unified Client/Server
  with concrete
  local path handling and real QUIC loopback tests. Preserve optional installs.
  Stage B throughput and Stage C conformance gates remain open.

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

## Stage D public H3 Client targeted verification

- Added t/rebuild/80-http3-client.t using a real authenticated QUIC/TLS
  server and the public Linux::Event::HTTP::Client request API.
- The test explicitly requires HTTP3 engines in CI, checks four strict H3
  operations on one multiplexed QUIC connection, preserved transaction
  identity, responses, and watcher cleanup.
- Pending actual CI test result; no verified public H3 claim yet.

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

## Stage D public Server targeted test

- New t/rebuild/90-http3-server.t exercises Linux::Event::HTTP::Server
  with http3 => 1 and a real Unblock::HTTP::QUIC Client over Linux UDP.
- It requires a real authenticated QUIC/TLS handshake, two HTTP3
  transactions, public on_headers/on_request callback ordering, and
  shutdown completion plus watcher release.
- Pending CI verification; do not claim public H3 Server is green yet.

## Stage D H3 identity and cancellation regression

- Added t/rebuild/95-http3-errors.t to exercise mismatched hostname
  verification on the public H3 Client against a real QUIC/TLS server,
  plus immediate queued cancellation before the UDP connection is ready.
- Checks no unauthorized HTTP admission, one terminal callback, and
  absence of socket/timer watcher leaks after cleanup.
- Required test runs in the latest Perl H3 CI lane. Verification pending.

## Verified

- Current root: 5 files / 28 subtests on Perl 5.38.2 threaded and 5.44.0
  non-threaded, both native and Perl paths. Ten new HTTP2 subtests cover eight
  concurrent streams on one verified TLS connection; callback/object identity;
  fallback/strict selection; 2 MiB flow-controlled/congested output; sibling
  cancellation; streamed upload and GOAWAY; forced expiry; reentrant socket
  close/weak-reference release; malformed preface followed by healthy traffic;
  certificate and hostname rejection. Graceful test expires its guard BEFORE
  the grace deadline, proving completion is not merely forced cleanup.
- H1-only configuration still passes with optional H2 absent/skipped.
- HTTP1: 40 files / 349 tests on both Perls; 5.38 disttest passes.
- Upper HTTP after retention change: 30 files / 870 tests, Perl 5.38;
  real optional engines were skipped in that particular run.
- Unchanged HTTP2 standalone: 30 files / 525 tests, Perl 5.38.
- POD and git diff --check pass. Root 5.38 disttest passes all 5 files / 28 subtests.
- h2spec 2.6.0: 146 tests, 134 pass, 1 skip, 11 fail. The exact failing cases
  AND diagnostics match the untouched main baseline and both rebuilt input
  paths in this environment. This is parity, NOT a clean conformance pass.
  JSON evidence: bench/results/unblock-stage-c/h2spec-parity.json.
  Historical 144/1/1 results are not this environment's current result.
- The H2 conformance fixture responds at headers and drains the body, matching
  the old fixture, since some test requests deliberately leave the body open.
  Production on_request still fires only after full request completion.

Remote CI for the previous retention milestone is GREEN:
- Root seven Perl lanes, both H1 input paths and harness smoke:
  https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40135515145
- HTTP1 Linux 5.16/latest, macOS latest, Windows 5.40 and disttest:
  https://github.com/haxmeister/perl-Unblock-HTTP1/actions/runs/40135426474
- HTTP1 framework examples:
  https://github.com/haxmeister/perl-Unblock-HTTP1/actions/runs/40135426480
Current H2 milestone remote CI is queued/in progress (not yet verified):
https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40142345620
The workflow now adds
optional HTTP2 tests on ALL seven Perl lanes after the HTTP1-only check.
Do not claim these H2 remote lanes passed until their run is inspected.

## Performance

Stage B throughput gate remains OPEN. Original GET32 was 62,924 req/s versus
initial rebuilt native 12,819. Prior serializer changes improved matched
pairs incrementally but did not close the gap.
Retention fix: 256 retained transactions with distinct 256 KiB bodies (64 MiB
canonical data), three fresh-process samples. Median additional RSS:
server 133444 -> 67896 KiB; client 133448 -> 67644 KiB. This is retained RSS,
not peak memory. Raw results: bench/results/unblock-stage-b-retention.
Matched GET16KiB: 9454 -> 9772 median req/s, CPU 106.419 -> 103.208 us/request.
Small/noisy difference: no reliable throughput speedup or release-gate claim.
No new H2 throughput claim has been made. Avoid broad repeated sweeps without
new changes or a specific unresolved question.

## Next work

1. Verify the published H2 milestone and its remote CI; fix any feature-branch
   CI failures. Keep H1-only packaging/runtime checks intact.
2. Continue Stage B performance and Stage C remaining conformance/performance
   work from the recorded evidence. Do not silently waive the 11 h2spec cases
   or implement another parser to make them pass. Establish exact upstream
   fixes before requesting authorization for any read-only repository.
3. Continue Stage D real H3/UDP/Net::QUIC Driver and dynamic relative timers,
   then Stage E optional WebSockets and generic handoff. Neither is implemented.
   Native HTTP1 INPUT_SWITCH still explicitly fails; no tail-handoff claim.
4. Stage F cleanup remains pending. Keep old private implementations/tests until
   replacement capabilities have coverage; no backward compatibility required.

## Local continuation / publication

Workspace: /workspace/scratch/9be1ecae0d40; root checkout http; upstream deps/
http1 and deps/unblock. Read-only baseline is baseline. Read-only H2 checkout
is deps/http2. env.sh selects system Perl 5.38 and base dependencies; for H2
prepend deps/http2/blib/lib and deps/http2/blib/arch to PERL5LIB.
env544.sh selects Perl 5.44; prepend deps/perl544/http2/blib/lib and blib/arch.
Root 5.44 build copy: build544. Use make test with the correct generated Perl
Makefile; system-shebang prove would select the wrong interpreter.

Shell Git fetch works but push lacks credentials. Publish through connected
GitHub create_tree/create_commit/update_ref(expected_sha, force=false).
publication/tree_payload.py emits tree diffs. Verify API tree SHA equals the
local tested tree before updating refs, then fetch/reset --soft to the API
commit (author/time means SHA differs). Never force-push or update main.
Current generated untracked HTTP1.bs and upper disttest directory are not
source changes. Check all trees and remote refs before editing.

---

# Linux::Event::HTTP handoff

Updated: 2026-09-26 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Repository: `haxmeister/perl-Linux-Event-HTTP`

Canonical branch: `main`

Project boundary: modify only Linux::Event::HTTP unless the user explicitly
authorizes another repository in the current chat.

### 0.003 release candidate state

HTTP/2 work is merged to `main`.

Merge commit:

`4312c07f0793790d76009dd60c6a3415f91b540b`
"Merge HTTP/2 support via Net::HTTP2::nghttp2"

Release-prep commits on `main`:

- `868d95653682568b1f8a84b15c1fc7736d0c4c14`
  "Bump Linux::Event::HTTP to 0.003"
- `93cf55003b4efb6d69e70e5df9cabcf5f6fa059e`
  "CI: test production HTTP/2 on main and pull requests"
- `76ae2f42b359e2fbaca103554f9059a92fbfbb52`
  "Prepare 0.003 changelog"

Version 0.003 includes both the native HTTP/1 client response-head path merged
after 0.002 and the production HTTP/2 implementation.

Final release-candidate CI:

GitHub Actions run `36252364092`, run #791.

- Perl 5.36 PASS
- Perl 5.38 PASS
- Perl 5.40 PASS
- Perl 5.42 PASS
- Perl 5.44 PASS
- latest Perl PASS
- latest threaded Perl PASS
- HTTP/1-only without Net::HTTP2::nghttp2 PASS
- latest-Perl main suite: 57 files / 1,489 tests, PASS
- distribution integrity / disttest PASS
- h2spec v2.6.0: 146 tests, 144 passed, 1 skipped, 1 known
  libnghttp2 stream-ID policy failure; CI gate PASS

PR #39 is merged. PR #40, the private native libnghttp2 experiment, is closed
as superseded and must not be merged into the release path.

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
