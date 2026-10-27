# HTTP1 performance with the published stack

Date: 2026-10-25 (America/Chicago).
Stage B remains OPEN. The published dependencies pass correctness gates,
but the rebuild remains substantially slower than the original server.
No production speedup or upstream defect is claimed by this investigation.

## Dependencies and correctness

Runtime checkpoint: d9f3e4fb4ddf2209e27ae8c51a8526383fe6f4c2.
All dependencies were installed from published CPAN archives into an isolated
local prefix: Linux::Event 0.117, Uniform::HTTP 0.06, Unblock::HTTP 0.03,
HTTP1 0.13, HTTP2 0.13, HTTP3 0.14, Net::QUIC 0.06, WebSocket 0.02.
Archive URLs and SHA256 digests are retained in
`bench/results/published-stack-20261025/provenance.json` (Git only).

- Local Perl 5.38.2 threaded: 22 files / 183 top-level tests PASS for native
  and Perl input, all optional protocols required; full `make disttest` PASS.
- [Rebuild CI](https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40264577767):
  all seven Perl jobs PASS. Latest nonthreaded includes the complete optional
  stack on both input paths and another complete packaged-source test.
- [Strict h2spec](https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40264404647):
  standalone, rebuild native, rebuild Perl, standalone repeat EACH 147/147
  PASS, zero failures/skips and zero outcome differences, using CPAN HTTP2.

The first CPAN CI run exposed an old benchmark overlay that mixed HTTP1 0.12
Perl source with 0.13 XS. Their version checks correctly rejected it. This
was repaired in CI, not worked around in production. Historical engine
comparisons remain reproducible from the exact earlier Git revision listed
in `BENCHMARKING.md`. The h2spec checkout supplies only the missing upstream
fixture; its engine is the CPAN installation.

## Independent hosted peer comparison

[Published-stack peer run](https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40264404641)
uses Benchmark::Web ceb8b2f9c4cd0764441844dd91dacc1240ebc4c7 and the unchanged
shared raw TCP driver. One server process, one execution slot, 100 persistent
connections, pipeline depth 1, 32 response bytes, rotating server order.
GET: 20,000 measured + 2,000 warmup, five repeats. POST: 4,096 request body
bytes, 10,000 measured + 1,000 warmup, three repeats. All-five-server strict
GET and POST smoke passed before measurements.

| Server | GET median req/s | POST median req/s |
| --- | ---: | ---: |
| Hyperman | 97,131 | 69,371 |
| Feersum | 96,283 | 90,919 |
| Original Linux::Event::HTTP | 43,426 | 38,416 |
| Rebuilt Linux::Event::HTTP | 11,891 | 9,845 |
| Mojolicious | 3,502 | 3,508 |

The rebuild delivers about 27% of original GET and 26% of original POST
throughput on this runner. These are normal framework APIs, not identical
application internals. Absolute values must not be compared with earlier
hosted runs as evidence of a change. Full JSON/latencies remain in the
Actions `stage-b-http1-perl-peers` artifact.

## Local paired measurements

System Perl 5.38.2 threaded, one shared host, optimized XS builds, published
stack above. The original root is unchanged c0bf714e0f08f9031684e2eb4fd70dea3c68449f.
Each row lists two separate three-repeat medians, collected in
legacy/rebuild/rebuild/legacy order. Each repeat uses 20,000 measured +
2,000 warmup requests, 100 connections, pipeline 1 and 32 response bytes.
No profiler, CPU affinity or concurrent task-owned builds/benchmarks.

| Workload | Original req/s | Rebuild native req/s | Original CPU us/request | Rebuild CPU us/request |
| --- | ---: | ---: | ---: | ---: |
| GET | 63,053 / 54,833 | 20,600 / 18,268 | 17.30 / 19.25 | 48.45 / 56.27 |
| POST 4 KiB | 43,839 / 46,394 | 16,261 / 16,812 | 23.44 / 23.34 | 60.58 / 61.34 |

Variation is material; retain both pairs instead of picking the fastest
sample. Original POST drains its request body while the rebuilt default
buffers it within its limit. GET has no body and still shows the gap.

A separate reversed-order input/construction diagnostic used the same
GET configuration. Order: native fresh, Perl fresh, native prebuilt,
native prebuilt, Perl fresh, native fresh. Three repeats per sample:

| Variant | Median req/s samples | CPU us/request samples |
| --- | ---: | ---: |
| Native, fresh canonical response | 21,922 / 19,364 | 46.05 / 52.24 |
| Perl, fresh canonical response | 16,391 / 16,963 | 61.27 / 59.37 |
| Native, diagnostic frozen response | 29,248 / 27,999 | 34.68 / 36.96 |

The frozen response bounds constructor AND response-argument handling
cost; it is not a clean isolated constructor measurement, nor a proposal
for production caching. Even this artificial shortcut does not approach
the earlier local original-server medians. Native input is already useful.
Raw samples are in `bench/results/published-stack-20261025/` (Git only).

## CPU attribution independent of Linux::Event

The new server-only NYTProf mode excludes the load generator and startup.
The socket-free engine benchmark can now select just one case and use the
released HTTP1 diagnostic BorrowedDriver. It loads no Linux::Event code.
This avoids the earlier engine profile mixing engine requests with separate
response-construction/control loops. The private driver is diagnostic only;
production still uses the public native ABI.

Profiles use NYTProf 6.16, `start=no:stmts=0:calls=2:clock=2`, 10,000 measured
plus 1,000 warmup requests, fresh canonical responses. Every profile records
exactly 11,000 Response constructors; none includes the raw load generator.
Independent profiles contain no Linux::Event subroutines. Exclusive shares:

| Attributed namespace | Native sockets | Perl sockets | Independent native engine | Independent portable engine |
| --- | ---: | ---: | ---: | ---: |
| Unblock::HTTP1 | 52.77% | 56.78% | 67.89% | 66.71% |
| Uniform::HTTP | 22.32% | 23.30% | 27.53% | 29.05% |
| Unblock::HTTP | 0.15% | 0.10% | 0.41% | 0.34% |
| Linux::Event | 19.14% | 13.39% | absent | absent |
| Linux::Event::HTTP | 3.07% | 3.75% | absent | absent |

These are instrumented attribution shares, NOT predicted speedups.
Subroutine instrumentation multiplies elapsed CPU cost; C work without its
own Perl frame is attributed to its enclosing call. In particular some
borrowed-input C work appears under Linux::Event's native read function.
Do not treat the adapter percentage as a precise Amdahl bound. Inclusive
subroutine times overlap and must not be added.

The independent native engine still spends time in `_transaction_respond`,
`_drive`, `_complete_request`, `_input_native_head`, output acceptance,
transaction allocation/retirement and canonical Response construction.
It exercises the same simple native response serializer (one call/request).
The existing serializer is active; the adapter is not accidentally forcing
the general Perl response serializer for this workload.

Unprofiled independent native input samples were 31.112 and 30.043 CPU
us/request; portable input between them was 36.101 and 41.117. Both paths
use the same ordinary engine/facade/canonical response callback and output
sink. The native driver includes one Perl-to-XS call and consumed-byte
validation per request; it is not a hypothetical zero-overhead engine.

The rotated cost-boundary control (three rounds, 20,000 iterations) measured
median CPU us/iteration: canonical response constructor 6.527; constructor
plus wire plan 8.477; prebuilt wire plan 1.856; direct portable engine with
fresh response 34.331; facade with fresh response 34.054. Direct prebuilt
engine 26.175, facade prebuilt 27.766. Separate microbenchmarks are not
additive timing buckets. There is no measured reason to bypass the facade.

## Next work, separately scoped upstream

The evidence supports investigating shared costs, not assuming a protocol
bug or adding Linux-specific bypasses. No upstream source was modified.
Two bounded candidates for separate authorization:

1. Uniform::HTTP's public pure-Perl response construction: avoid redundant
   named-argument copying and repeated mutability dispatch while preserving
   every input check, real canonical objects and subclass/adapter behavior.
   Profiles show two `_named_args` and four `is_mutable` calls per simple
   response. Constructors alone are not enough to close the observed gap.
2. Unblock::HTTP1's ordinary response/transaction path: reduce redundant
   option materialization and state/helper dispatch where proven safe.
   Preserve byte acceptance before terminal notification, delayed/streamed
   responses, pipelining, reentrant close, retained objects and all validation.
   The same costs occur in the independent native and portable engine cases.

Any trial needs standalone regression tests plus matched unprofiled native
and portable engine measurements, followed by this integration's complete
correctness and socket gates. Keep Uniform pure Perl, the native ABI stable,
and all behavior framework neutral. Do not promise parity from these
profiles, weaken validation, introduce response caches or recreate a parser.
No root-only production optimization with evidence sufficient to recover
the throughput deficit was found in this pass. Stage B remains open.
