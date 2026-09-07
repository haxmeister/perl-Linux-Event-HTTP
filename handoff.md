# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- Current implementation/benchmark head before this handoff-only commit: `80a06783a1197ca294dd17a629a85707eca3d4c4`
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
- `b72faa0` - make focused fast-final benchmark compare only real `Connection` paths
- `5467931` - add selectable fast-final mode to the existing Linux::Event cross-server benchmark server
- `80a0678` - run ordinary and fast-final shared cross-server comparisons on the same CI runner

PR #13 and PR #11 remain unmerged.

## Results already closed

### Native default-final response

Earlier controlled end-to-end work showed the native default-final response is a real win (roughly +4% alone; ~+6% with fused callbacks in that run). Keep it as the worthwhile native candidate. Callback fusion is smaller and more semantically risky.

### Small Perl cost buckets

Representative microcosts are bounded:

- parser direct ~0.4-0.7 us depending on runner
- parser under eval ~0.5-0.8 us
- no-Expect validation ~0.2-0.35 us
- `Response->_new_bound` ~0.6-1.1 us
- cached bodyless state reset ~0.09-0.15 us
- active transaction assign/clear ~0.3-0.5 us

None individually justifies a new native subsystem.

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

Goal: test whether the ordinary natural API can become native-eligible earlier without adding a new public callback.

Benchmark-only subclass behavior marked `body_done = 1` immediately before ordinary `on_request` for bodyless requests only when no `on_request_end` handler was configured. That allowed ordinary `$response->end(...)` to engage the existing native default-final shortcut while preserving existing callback ordering whenever `on_request_end` existed.

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

### CI 34085015017 - first integrated production-shaped focused result

All jobs green. Focused medians:

- real `on_request -> Response->end`: **`35,589.8 req/s`**, p50 `2719.2 us`
- real `on_request_end -> Response->end`: **`33,436.7 req/s`**, p50 `2900.1 us`
- real integrated `on_request_final -> scalar body`: **`46,963.4 req/s`**, p50 `2009.2 us`

Same-harness deltas:

- fast-final vs improved ordinary `on_request`: **`+31.96%`**
- fast-final vs `on_request_end`: **`+40.45%`**
- improved ordinary `on_request` vs `on_request_end`: **`+6.44%`**

### CI 34085371457 - repeat after cross-server wiring

All Perl 5.36/latest/latest-threaded jobs and all benchmark steps are green again.

Focused medians on this runner:

- real improved `on_request -> Response->end`: **`34,484.1 req/s`**, p50 `2784.0 us`, p99 `5590.0 us`
- real `on_request_end -> Response->end`: **`32,446.8 req/s`**, p50 `2992.2 us`, p99 `5992.2 us`
- real integrated fast-final: **`46,363.5 req/s`**, p50 `2044.9 us`, p99 `4129.9 us`

Deltas:

- fast-final vs improved natural path: **`+34.45%`**
- fast-final vs request-end path: **`+42.89%`**
- improved natural path vs request-end path: **`+6.28%`**

This independently reproduces the earlier production-shaped conclusion.

## Shared cross-server fast-final comparison - commits 5467931, 80a0678 / CI 34085371457

The existing `bench/servers/linuxevent-http.pl` now supports `BENCH_LINUXEVENT_MODE=fast-final`, so the exact same `bench/run-http-comparison.pl` command can be run twice on the same GitHub Actions runner. Competitor processes, client code, workload, and runner are unchanged; only the Linux::Event connection callback mode changes.

Workload:

- 10,000 measured requests per server/repeat
- 1,000 warmup
- 100 connections
- pipeline=1
- 32-byte response
- 3 rotated repeats

### Existing Linux::Event request-end benchmark pass

- Linux::Event::Net::HTTP: **`33,126.7 req/s`**, p50 `2914.9 us`, p99 `5842.0 us`
- Go net/http: `58,721.0 req/s`
- libh2o evloop: `71,407.7 req/s`
- Feersum: `72,267.4 req/s`
- Node.js http: `23,164.9 req/s`
- Python aiohttp: `19,143.0 req/s`
- Mojolicious: `1,843.0 req/s`

### Linux::Event fast-final pass on the same runner

- Linux::Event fast-final: **`45,210.6 req/s`**, p50 `2100.0 us`, p95 `2235.2 us`, p99 `4238.1 us`
- Go net/http: `59,000.9 req/s`
- libh2o evloop: `73,100.4 req/s`
- Feersum: `74,409.7 req/s`
- Node.js http: `22,868.3 req/s`
- Python aiohttp: `19,554.2 req/s`
- Mojolicious: `1,826.5 req/s`

### Shared-harness deltas

- fast-final vs existing Linux::Event request-end benchmark path: **`+36.48%`**
- fast-final is about **23.37% below Go**
- fast-final is about **38.15% below libh2o**
- fast-final is about **39.24% below Feersum**
- fast-final is about **97.70% faster than Node.js** in this workload
- fast-final is about **131.21% faster than aiohttp** in this workload

### Cross-server conclusion

1. The complete-response path produces a large real-server improvement under the exact shared competitor harness, not only in a special focused benchmark.
2. Its ~36% shared-harness gain agrees closely with the ~32-34% focused gain over the improved ordinary natural API, so the direction is robust across benchmark shapes/runners.
3. It materially closes the gap but does **not** reach Go, Feersum, or libh2o yet.
4. We therefore have a worthwhile pure-architecture/API win without additional native code, but there is still a meaningful remaining performance gap to investigate.
5. The current default cross-server Linux::Event entry is still the old request-end usage; before publishing/recommending competitive numbers, add the improved natural `on_request -> end` mode to the shared harness so both supported API shapes are represented fairly.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified as a broad architectural move.
2. libh2o is useful as an upper-bound/reference but is not the current HTTP/1 implementation direction.
3. The duplicated bodyless-driver approach is closed.
4. Safe early bodyless completion is integrated into real `Connection` and is a worthwhile ordinary-API optimization.
5. The natural `on_request -> Response->end` path no longer needs `on_request_end` as a performance workaround for bodyless requests.
6. A specialized complete-response callback is now strongly justified by both focused and shared cross-server data: about **+34%** over the improved natural API in the focused harness and **+36%** over the old request-end benchmark server in the shared harness.
7. The complete-response gain is achieved without adding XS/C and without duplicating the parser/driver.
8. Fast-final now reaches ~`45.2k req/s` on the CI 34085371457 shared harness versus ~`59.0k` Go and ~`73-74k` libh2o/Feersum. There is still enough gap to justify further targeted profiling/experiments.
9. The old private `_Experiment::FastFinalConnection` module is obsolete as an implementation; remove it after the public API/benchmark direction is settled.
10. The current name `on_request_final` remains experimental. Do not cement it until the natural shared-harness pass and next low-risk optimization checks are complete.
11. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Add a selectable **natural** Linux::Event benchmark mode using real `on_request -> Response->end` with no `on_request_end`, then run it through the exact same shared cross-server harness. Keep the legacy request-end pass only for historical comparison.
2. Update this handoff immediately with the natural-vs-fast-final-vs-competitor result.
3. Investigate the next low-risk fast-final cost bucket before considering more architectural C/XS. A promising candidate is the existing `Response1.xs::build_default_final`, which currently makes an unconditional `newSVsv(body)` copy even for already-byte scalar bodies. Benchmark a copy-only-when-UTF8 variant before adopting it; this modifies existing tiny XS rather than adding a new native subsystem.
4. Also keep the direct callback-return-wire result in mind as an upper-bound clue (~`56.3k req/s` vs ~`53.0k` callback-return-body in CI 34085371457), but do not expose raw-wire return as a public API merely for speed without a stronger design reason.
5. After the natural shared comparison and builder micro-experiment, decide the public complete-response API name/surface, remove the obsolete private experiment module, rerun full CI, and prepare the branch for review.

Do not merge PR #13 or PR #11 without explicit authorization.
