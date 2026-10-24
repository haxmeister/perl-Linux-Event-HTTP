# Reconstruction implementation checkpoint

Updated: 2026-10-24 (America/Chicago)
Measurements: Stage A 2026-10-22; Stage B 2026-10-23/24
Branch: `feature/unblock-http-rebuild`
Starting checkpoint: `634228c90070e0136175a4611e7079f33370a7d9`
Untouched baseline: `c0bf714e0f08f9031684e2eb4fd70dea3c68449f`

Stage A's executable HTTP1 GET/POST gate passes. Stage B is in progress;
HTTP1 lifecycle and service draining are implemented, but the performance
gate has NOT passed. Stages C-F are not implemented. The user authorized
the specified upstream feature-branch changes. No release, version bump,
main change has occurred. Feature-branch publication is authorized.

## Latest Stage B milestone

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
