# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- Current branch head before this handoff-only commit: `b72faa0cb76e7d7d317d2233b795de42d39e9b00`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint. Update it after every meaningful benchmark, experiment, or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize C/XS maintenance; do not add native code unless measurements make it necessary.
3. Preserve the general Response/streaming model while providing a cheaper complete-response path when measurements justify it.
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
- `1b42865` - checkpoint decision-grade fast-final comparison
- `c870226` - benchmark safe early bodyless completion through ordinary Response API
- `45555c9` - integrate optional fast-final callback and safe early bodyless completion directly into real `Connection::_drive_http1`; no new XS/C and no duplicated parser/driver
- `5e206d2` - move fast-final semantic tests onto the real `Connection` implementation
- `b72faa0` - make the focused fast-final benchmark compare only real `Connection` paths

PR #13 and PR #11 remain unmerged.

## Results already closed

### Native default-final response

Earlier controlled end-to-end work showed the native default-final response is a real win (roughly +4% alone; ~+6% with fused callbacks in that run). Keep it as the worthwhile native candidate. Callback fusion is smaller and more semantically risky.

### Small Perl cost buckets

Representative microcosts are bounded:

- parser direct ~0.4-0.6 us depending on runner
- parser under eval ~0.5-0.8 us
- no-Expect validation ~0.2-0.35 us
- `Response->_new_bound` ~0.6-1.0 us
- cached bodyless state reset ~0.09-0.15 us
- active transaction assign/clear ~0.3-0.5 us

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

## Earlier private fast-final Connection experiment

The branch originally used a private duplicated-driver module:

`Linux::Event::Net::HTTP::_Experiment::FastFinalConnection`

Explicit callback shape:

`on_request_final($connection, $request)`

The private experiment established the semantic contract and justified integration, but it is no longer the measured implementation. The real `Connection::_drive_http1` now contains the branch-only production-shaped experiment.

### Decision-grade same-stack comparison - commit 0f65517 / CI 34083452101

20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- `on_request -> Response->end`: `25,324.8 req/s`
- no-op `on_request`, then `on_request_end -> Response->end`: `50,498.8 req/s`
- private integrated `on_request_final -> scalar body`: `73,722.1 req/s`

Fast-final was `+45.99%` over the optimized current `on_request_end` path in the identical focused harness.

## Safe early-bodyless-completion experiment - commit c870226 / CI 34083753111

Goal: test whether we can avoid a new public callback by making the ordinary natural API native-eligible earlier.

Benchmark-only subclass behavior:

- used the unmodified production `_drive_http1`
- intercepted only the normal `on_request` callback boundary
- when the current request state was `mode eq 'none'`, `body_done` was false, and **no `on_request_end` handler was configured**, it set `body_done = 1` immediately before calling the ordinary user `on_request`
- then ordinary `$response->end(...)` could engage the existing native default-final shortcut
- if `on_request_end` existed, the optimization was disabled so callback semantics were not changed
- no production code changed and no new XS/C was added

Same focused harness, 20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- natural `on_request -> Response->end`: **`36,386.1 req/s`**
- optimized `on_request_end -> Response->end`: **`66,595.2 req/s`**
- safe early-body-done `on_request -> Response->end`: **`67,531.8 req/s`**
- private integrated fast-final callback return: **`90,671.7 req/s`**

Same-harness deltas:

- early-body-done vs natural on_request: **`+85.60%`**
- early-body-done vs optimized on_request_end: **`+1.41%`**
- fast-final vs optimized on_request_end: **`+36.15%`**
- fast-final vs early-body-done: **`+34.27%`**

This proved the ordering fix and complete-response fast path were independent opportunities.

## Production-shaped integration in real Connection - commits 45555c9, 5e206d2, b72faa0

`Connection::_drive_http1` now implements both opportunities directly with no duplicate driver and no new XS/C.

### Ordinary path change

For a bodyless request with **no configured `on_request_end` handler**, the reusable bodyless request state is marked `body_done = 1` before ordinary `on_request` runs. This allows ordinary `$response->end($body)` to use the existing native default-final shortcut. If `on_request_end` exists, the old callback ordering is preserved.

### Complete-response path

`Connection->new` now discovers/caches an optional `on_request_final` callback/method. For validated bodyless requests it runs before Response allocation:

- scalar return => attempt existing native default-final serialization/write
- `undef` => fall through to ordinary `on_request` / Response transaction path
- HEAD, HTTP/1.0, or other native-ineligible returned bodies => construct the ordinary Response transaction only as fallback and serialize the already-returned body without invoking the general application callback again
- body-bearing requests always use the ordinary streaming path
- callback exception or invalid returned body => protocol-safe 500
- invalid Expect is rejected before the complete-response callback

`t/50-fast-final-experiment.t` now tests this against the real `Connection`, including GET success, undef fallback, HEAD, HTTP/1.0, body-bearing POST, callback exception, invalid returned body, and invalid Expect.

### CI 34085015017 - integrated production-shaped focused result

All jobs are green: Perl 5.36, latest, latest threaded, standard tests/dist checks, focused diagnostics, and cross-server diagnostics.

Focused benchmark:

- 20,000 measured requests
- 2,000 warmup
- 100 connections
- pipeline=1
- 32-byte response
- 3 rotated repeats

Median results:

- real `on_request -> Response->end`: **`35,589.8 req/s`**, p50 `2719.2 us`, p95 `2828.8 us`, p99 `5452.2 us`
- real `on_request_end -> Response->end`: **`33,436.7 req/s`**, p50 `2900.1 us`, p95 `3031.0 us`, p99 `5818.8 us`
- real integrated `on_request_final -> scalar body`: **`46,963.4 req/s`**, p50 `2009.2 us`, p95 `2342.0 us`, p99 `4059.1 us`

Same-harness deltas:

- fast-final vs improved ordinary `on_request`: **`+31.96%`**
- fast-final vs `on_request_end`: **`+40.45%`**
- improved ordinary `on_request` vs `on_request_end`: **`+6.44%`**

### Integrated conclusion

This is the decision-grade result because all three modes now run through the real `Connection` implementation.

1. **The safe early-bodyless ordering change works in production-shaped code.** The natural `on_request -> Response->end` API is now faster than the old `on_request_end` workaround in this run.
2. **The complete-response path remains materially faster even after fixing the natural API.** It is ~32% faster than improved ordinary `on_request` in the identical focused harness.
3. The fast-final gain therefore comes from avoiding eager Response allocation/binding and most general transaction bookkeeping, not from papering over the old bodyless-ordering problem.
4. No additional XS/C was needed.
5. The complete-response API is now justified on performance grounds if we are willing to expose a deliberately narrower bodyless/default-final response contract.

For context, same-run object microbenchmark medians included:

- direct parse: ~`637 ns`
- parse under eval: ~`756 ns`
- `Response->_new_bound`: ~`1016 ns`
- reusable bodyless state reset: ~`147 ns`
- active transaction assign/clear: ~`471 ns`

The same-run direct API-shape diagnostic measured:

- checked callback returning body: `50,335.9 req/s`
- checked driver-direct final: `52,824.4 req/s`

The real integrated fast-final result (`46,963.4`) is now reasonably close to that stripped checked upper bound, so the giant missing cost bucket has been removed without native driver code.

## Same-run cross-server context - CI 34085015017

The existing shared cross-server harness still exercises the **ordinary Linux::Event benchmark server**, which currently responds through `on_request_end`; it does **not** yet exercise the new fast-final API.

Directional medians, 10k measured, 1k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- Linux::Event::Net::HTTP ordinary benchmark server: `32,547.0 req/s`
- Feersum: `74,375.4 req/s`
- libh2o evloop: `73,792.6 req/s`
- Go net/http: `60,716.5 req/s`
- Node.js http: `22,935.5 req/s`
- Python aiohttp: `19,549.1 req/s`
- Mojolicious: `1,900.3 req/s`

Do not compare the focused `46,963.4` directly to these as an exact competitive percentage because the server entry/harness path differs. The important next measurement is to add a Linux::Event fast-final candidate to this same shared harness and compare it directly with Feersum/libh2o/Go.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified.
2. libh2o is useful as an upper-bound/reference but is not the current HTTP/1 implementation direction.
3. The duplicated bodyless-driver approach is closed.
4. Safe early bodyless completion is now integrated into real `Connection` and is a worthwhile ordinary-API optimization.
5. The natural `on_request -> Response->end` path no longer needs `on_request_end` as a performance workaround for bodyless requests.
6. A specialized complete-response callback remains justified: in the real production-shaped driver it is **+31.96%** over the improved natural path in CI 34085015017.
7. The complete-response gain is achieved without adding XS/C and without duplicating the parser/driver.
8. The old private `_Experiment::FastFinalConnection` module is now obsolete as an implementation; remove it after the public API/benchmark direction is settled.
9. The current name `on_request_final` is still experimental. Do not cement the public name until the apples-to-apples cross-server result is recorded.
10. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Add a Linux::Event fast-final server candidate to `bench/run-http-comparison.pl` without replacing the existing ordinary Linux::Event baseline.
2. Run the shared comparison so ordinary Linux::Event, Linux::Event fast-final, Feersum, libh2o, Go, Node, aiohttp, and Mojolicious are measured by the same client/harness on the same runner.
3. Update this handoff with that result immediately.
4. If the shared result confirms the focused gain, decide the public callback/API name and surface it through `Server` constructor callbacks while keeping ordinary `on_request` as the general/body-bearing fallback.
5. Then remove the obsolete private experiment module and branch-only duplicate artifacts, rerun semantic/full CI, and prepare the experiment for review.

Do not merge PR #13 or PR #11 without explicit authorization.
