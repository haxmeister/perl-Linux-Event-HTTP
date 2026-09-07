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
- `c87c3c9` - checkpoint first integrated result
- `0f65517` - compare fast-final with natural and optimized current APIs in one focused harness

PR #13 and PR #11 remain unmerged.

## Results already closed

### Native default-final response

Earlier controlled end-to-end work showed the native default-final response is a real win (roughly +4% alone; ~+6% with fused callbacks in that run). Keep it as the worthwhile native candidate. Callback fusion is smaller and more semantically risky.

### Small Perl cost buckets

Representative microcosts are bounded:

- parser direct ~0.6 us
- parser under eval ~0.7-0.8 us
- no-Expect validation ~0.3-0.35 us
- `Response->_new_bound` ~0.9-1.0 us
- cached bodyless state reset ~0.13-0.15 us
- active transaction assign/clear ~0.44-0.50 us

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

## Integrated fast-final Connection experiment

Private branch-only module:

`Linux::Event::Net::HTTP::_Experiment::FastFinalConnection`

Explicit callback shape:

`on_request_final($connection, $request)`

Semantics implemented/tested through the real `Server -> Listener -> Connection` stack:

- considered only for bodyless requests after normal parse/head-size/Expect validation
- scalar return => default `200 OK` final response
- `undef` => ordinary `on_request` / Response path
- HEAD and HTTP/1.0/native-ineligible cases preserve the returned body through ordinary Response serialization
- body-bearing requests stay on ordinary streaming callbacks
- callback exceptions become protocol-safe 500 responses
- invalid Expect is rejected before fast callback
- no new XS/C

`t/50-fast-final-experiment.t` covers these cases. CI is green on Perl 5.36, latest, latest threaded, and disttest.

### First focused run - CI 34083140432

- natural `on_request -> Response->end`: `14,568.8 req/s`
- integrated fast-final: `46,858.1 req/s`
- apparent +221.6%

Important caveat discovered: normal `on_request` runs before the body's `body_done` flag is set for a bodyless request, so `Response->end` there cannot engage the native default-final shortcut. The existing optimized comparison server instead responds from `on_request_end` after `body_done = 1`.

### Decision-grade same-stack comparison - commit 0f65517 / CI 34083452101

The focused benchmark now rotates three modes through the exact same `Linux::Event::Net::HTTP::Server`, client, workload, connection count, pipeline, and response size.

20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- `on_request -> Response->end`: **`25,324.8 req/s`**
- no-op `on_request`, then `on_request_end -> Response->end`: **`50,498.8 req/s`**
- integrated `on_request_final -> scalar body`: **`73,722.1 req/s`**

Throughput deltas:

- fast-final vs natural `on_request -> end`: **`+191.11%`**
- fast-final vs optimized `on_request_end -> end`: **`+45.99%`**

Latency medians:

- natural current API p50: `3,855.9 us`
- optimized current API p50: `1,893.0 us`
- fast-final p50: `1,280.1 us`

This is the key result: **the fast-final architecture retains a very substantial ~46% same-harness gain even against the fastest current normal Response API usage.** It is no longer merely benefiting from the natural `on_request` callback missing the native end shortcut.

Same-run transaction-ladder context (runner was unusually fast; use only same-run ratios):

- parsed Request + prebuilt write: `106,250.3 req/s`
- Response binding: `95,176.9`
- transaction state: `85,908.1`
- guarded callbacks: `73,214.5`
- fused callbacks: `78,929.1`
- full HTTP: `50,616.8`

Same-run direct callback experiment:

- checked callback-return-body: `76,372.0 req/s`
- integrated real-stack fast-final: `73,722.1 req/s`

That close agreement is encouraging: most of the synthetic request-only gain survives integration through the real Server stack.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified.
2. libh2o is not the current HTTP/1 solution.
3. The duplicated bodyless-driver path is closed.
4. A complete-response callback-return path has repeatedly shown large headroom and now works through the real Server stack with semantic fallback tests.
5. Fast-final is ~46% faster than the optimized existing `on_request_end -> Response->end` path in an identical focused harness.
6. The private implementation is technically viable enough to continue toward a design decision, but it is not a public API yet and must not be merged as-is.
7. Before adding a new public callback, test a less invasive ordering change: for a request whose parser has already proven `body_mode eq 'none'`, mark its internal request state `body_done = 1` immediately before invoking normal `on_request`. That should allow ordinary `$response->end(...)` from `on_request` to use the native final shortcut while retaining the existing Response object/API.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

Add a benchmark-only fourth focused mode, using the ordinary production `Connection` driver with one narrow override/hook that marks a bodyless request complete immediately before the normal `on_request` callback. Keep Response allocation/binding and all ordinary transaction machinery intact.

Compare in one harness:

1. natural `on_request -> Response->end`
2. optimized `on_request_end -> Response->end`
3. experimental early-body-done `on_request -> Response->end`
4. fast-final `on_request_final -> scalar body`

If early-body-done closes most of the ~46% gap to fast-final, prefer improving existing API semantics/order over adding a new public callback. If it remains materially slower, the separate complete-response path is justified by measurement.

Do not merge PR #13 or PR #11 without explicit authorization.
