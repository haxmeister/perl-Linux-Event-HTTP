# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint. Update it after every meaningful benchmark, experiment, or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize C/XS maintenance; do not add native code unless measurements make it necessary.
3. Preserve the general Response/streaming model while investigating a cheaper complete-response path.
4. libh2o remains a benchmark/reference, not the current HTTP/1 integration direction.

## Important commits

- `bd11439` / `a0be02c` - semantic bodyless driver benchmark; inspected after earlier handoff
- `f455a29` - checkpoint semantic bodyless result
- `60bfeca` / `1ea8d91` / `cb99a0c` / `4fa08af` - optional libh2o benchmark spike
- `d5c895b` - record libh2o upper-bound result
- `b753467` / `e8f0a22` / `e18fcf1` - request-only direct API benchmark and fix
- `419f1b8` - checkpoint request-only result
- `b930e2d` - benchmark callback-return API shapes
- `71dc181` - checkpoint callback-return result
- `5cbff47` - add private integrated fast-final Connection experiment, semantic tests, and focused benchmark

PR #13 and PR #11 remain unmerged.

## Results already closed

### Native default-final response

Earlier controlled end-to-end work showed the native default-final response is a real win (roughly +4% alone; ~+6% with fused callbacks in that run). Keep it as the worthwhile native candidate. Callback fusion is smaller and more semantically risky.

### Small Perl cost buckets

Representative microcosts are bounded:

- parser direct ~0.63-0.66 us
- parser under eval ~0.74-0.81 us
- no-Expect validation ~0.35 us
- `Response->_new_bound` ~1.0 us
- cached bodyless state reset ~0.15 us
- active transaction assign/clear ~0.48-0.51 us

None individually justifies more XS/C.

### Semantic bodyless duplicate - CI 34079490485

- checked production-style path: `35,229.5 req/s`
- semantic bodyless duplicate: `34,248.5 req/s`
- full `_drive_http1`: `33,433.6 req/s`

Only ~+2.44% over full HTTP. **Do not pursue a duplicated production bodyless Perl driver.**

### libh2o upper bound - CI 34080176589

Same-run directional medians:

- Linux::Event::Net::HTTP: `51,256.1 req/s`
- Feersum: `98,551.3 req/s`
- libh2o evloop: `97,387.0 req/s`
- Go net/http: `80,660.8 req/s`

Same-run parser/transport floor:

- parsed Request + prebuilt write: `87,584.9 req/s`
- Response binding: `80,496.5`
- transaction state: `75,450.4`
- guarded callbacks: `66,594.1`
- fused callbacks: `70,414.9`
- full HTTP: `51,533.5`

pico + Linux::Event transport is already close to Feersum/libh2o before the Perl transaction layer. H2O also owns its own epoll/socket state. **Do not pursue production libh2o integration for HTTP/1 performance now.**

## Request-only/callback-return experiments

### CI 34080762331

- request-only direct final: `56,118.4 req/s`
- checked request-only final: `52,986.8`
- parsed Request + prebuilt write: `71,633.3`
- full HTTP: `34,275.5`

Checked request-only was ~+54.6% / 1.55x full HTTP.

### CI 34081024432

Realistic application callback return shapes:

- callback returns wire: `55,460.7 req/s`
- callback returns body: `52,392.1`
- checked callback returns body: `49,791.9`
- checked driver-direct reference: `49,821.8`
- full HTTP ladder: `31,951.3`

A real Perl application callback returning a body preserves essentially all of the stripped-path performance. The callback itself is not the large cost. Eager Response allocation/binding and the general transaction lifecycle are.

## Integrated fast-final Connection experiment - commit 5cbff47 / CI 34083140432

A private branch-only module now exists:

`Linux::Event::Net::HTTP::_Experiment::FastFinalConnection`

It uses the actual `Server -> Listener -> Connection` stack and tests an explicit method/callback:

`on_request_final($connection, $request)`

Semantics implemented and tested:

- only considered for bodyless requests after normal parse/head-size/Expect validation
- scalar return => default `200 OK` final response
- `undef` => ordinary `on_request` / Response path
- HEAD and HTTP/1.0/native-ineligible cases preserve the returned body through ordinary Response serialization
- body-bearing requests stay on ordinary streaming callbacks
- callback exceptions become protocol-safe 500 responses
- invalid Expect is rejected before the fast callback
- no new XS/C

`t/50-fast-final-experiment.t` exercises these cases using the real Server and socket stack.

CI `34083140432` is fully green across Perl 5.36, latest, latest threaded, disttest, all semantic tests, and benchmark smokes.

### Focused integrated benchmark

20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- ordinary `on_request -> Response->end`: `14,568.8 req/s`
- integrated fast-final callback return: `46,858.1 req/s`
- reported change: `+221.63%` / about `3.22x`

Latency medians:

- ordinary p50: `6,732.9 us`
- fast-final p50: `2,003.0 us`

### Important interpretation caveat

The +222% number is real for the simplest natural `on_request -> $res->end(...)` API, but it is **not yet the fair comparison against the fastest existing ordinary usage**.

Reason: during `on_request`, the current bodyless request state still has `body_done = 0`. `Response->end` therefore cannot use the native default-final shortcut there. The existing cross-server benchmark instead does a no-op `on_request` and calls `Response->end` from `on_request_end`, after `body_done = 1`, which enables the native shortcut.

Same CI run for context:

- transaction-ladder full HTTP: `32,874.0 req/s`
- cross-server production Linux::Event (uses `on_request_end`): `32,071.9 req/s`
- integrated fast-final focused path: `46,858.1 req/s` (different focused harness; do not directly claim a percentage yet)

Thus the integrated experiment is clearly promising, but the next benchmark must put all three API shapes in the **same focused harness**:

1. `on_request -> Response->end` (natural current API)
2. `on_request` no-op + `on_request_end -> Response->end` (current optimized/native-eligible API)
3. `on_request_final -> scalar body` (experimental fast-final API)

Only that same-harness result should determine the production value of the new callback.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified.
2. libh2o is not the current HTTP/1 solution.
3. The duplicated bodyless-driver path is closed.
4. A complete-response callback-return path has repeatedly shown large headroom and now works through the real Server stack with semantic fallback tests.
5. The integrated private fast-final implementation is viable enough to keep testing, but it is not a public API yet.
6. The current natural `on_request -> end` path has an additional performance problem: it misses the native final shortcut because bodyless completion is marked only after `on_request` returns.
7. Before changing public API, benchmark fast-final against the optimized `on_request_end` baseline in the same focused harness.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

Modify `bench/run-http-fast-final-experiment.pl` to compare these three same-stack modes:

- `ordinary_request`
- `ordinary_request_end`
- `fast_final`

Keep the same real `Linux::Event::Net::HTTP::Server`, client workload, rotation, request count, connection count, pipeline, and response size for all three.

If fast-final still shows a substantial gain over `ordinary_request_end`, then evaluate the cleanest production design. Also separately consider whether marking bodyless input complete before `on_request` could safely allow the existing natural `on_request -> end` API to use the native final shortcut; benchmark that idea before deciding that a new public callback is necessary.

Do not merge PR #13 or PR #11 without explicit authorization.
