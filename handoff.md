# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-07 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- Current implementation/test head before this handoff-only commit: `5c35e9db330f6c3f6a3b91a781c2aa4f1e2812f1`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint. Update it after every meaningful benchmark, experiment, or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize C/XS maintenance; do not add a new native subsystem unless measurements make it necessary.
3. Preserve the general Response/streaming model while providing a cheaper complete-response path where measurements justify it.
4. libh2o remains a benchmark/reference, not the current HTTP/1 integration direction.

## Important commits

- `bd11439` / `a0be02c` - semantic bodyless driver benchmark
- `f455a29` - checkpoint semantic bodyless result
- `60bfeca` / `1ea8d91` / `cb99a0c` / `4fa08af` - optional libh2o benchmark spike
- `d5c895b` - record libh2o upper-bound result
- `b753467` / `e8f0a22` / `e18fcf1` - request-only direct API benchmark and fixes
- `419f1b8` - checkpoint request-only result
- `b930e2d` - benchmark callback-return API shapes
- `71dc181` - checkpoint callback-return result
- `5cbff47` - private integrated fast-final Connection experiment
- `0f65517` / `1b42865` - decision-grade private fast-final comparison/checkpoint
- `c870226` - benchmark safe early bodyless completion
- `45555c9` - integrate optional fast-final callback and safe early bodyless completion directly into real `Connection::_drive_http1`; no new XS/C and no duplicated parser/driver
- `5e206d2` - move fast-final semantic tests onto the real `Connection`
- `b72faa0` - make focused fast-final benchmark compare only real `Connection` paths
- `5467931` - add selectable fast-final mode to the existing Linux::Event cross-server benchmark server
- `80a0678` - run ordinary and fast-final shared cross-server comparisons on the same CI runner
- `bf6868d` - make default cross-server Linux::Event candidate use optimized natural `on_request -> Response->end`
- `2a04725` - avoid the temporary body SV copy in `Response1.xs::build_default_final` for ordinary already-materialized non-UTF8 byte strings
- `5c35e9d` - expand native response-builder scalar/UTF8 semantic coverage

PR #13 and PR #11 remain unmerged.

## Results already closed

### Native default-final response

Earlier controlled end-to-end work showed the native default-final response is a real win (roughly +4% alone; ~+6% with fused callbacks in that run). Keep it as the worthwhile native candidate. Callback fusion is smaller and more semantically risky.

### Small Perl cost buckets

Representative microcosts across CI runners:

- parser direct ~0.4-0.7 us
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

## Safe early-bodyless completion

The benchmark-only experiment established that for a bodyless request with no `on_request_end` callback, marking the input boundary complete before ordinary `on_request` allows ordinary `$response->end(...)` to engage the existing native default-final path safely.

CI 34083753111 focused medians:

- natural pre-fix `on_request -> Response->end`: `36,386.1 req/s`
- request-end workaround: `66,595.2 req/s`
- safe early-body-done natural path: `67,531.8 req/s`
- private fast-final: `90,671.7 req/s`

The ordering fix and complete-response fast path are separate wins.

## Production-shaped integration in real Connection

Commits `45555c9`, `5e206d2`, `b72faa0` integrate both opportunities directly into the real `Connection::_drive_http1`, with no duplicated parser/driver and no new XS/C.

### Ordinary natural API

For bodyless requests with **no configured `on_request_end` handler**, the reusable bodyless state is marked `body_done = 1` before ordinary `on_request`. This enables native default-final `Response->end` while preserving existing callback semantics whenever `on_request_end` is configured.

### Complete-response path

`Connection->new` discovers/caches optional experimental `on_request_final`. For validated bodyless requests it runs before Response allocation:

- scalar return => attempt existing native default-final serialization/write
- `undef` => fall through to ordinary `on_request` / Response transaction path
- HEAD, HTTP/1.0, or other native-ineligible returned bodies => construct ordinary Response only as fallback and serialize the returned body without invoking the application callback twice
- body-bearing requests always use ordinary streaming callbacks
- callback exception or invalid returned body => protocol-safe 500
- invalid Expect is rejected before the callback

`t/50-fast-final-experiment.t` exercises these semantics against real `Connection`.

### Repeated focused results

CI 34085015017:

- natural: `35,589.8 req/s`, p50 `2719.2 us`
- request-end: `33,436.7`, p50 `2900.1 us`
- fast-final: `46,963.4`, p50 `2009.2 us`
- fast-final vs natural: `+31.96%`

CI 34085371457:

- natural: `34,484.1 req/s`, p50 `2784.0 us`
- request-end: `32,446.8`, p50 `2992.2 us`
- fast-final: `46,363.5`, p50 `2044.9 us`
- fast-final vs natural: `+34.45%`

CI 34085638210:

- natural: `35,271.3 req/s`, p50 `2727.0 us`, p99 `5482.0 us`
- request-end: `33,093.0`, p50 `2920.9 us`, p99 `5864.9 us`
- fast-final: `46,119.1`, p50 `2063.0 us`, p99 `4165.9 us`
- fast-final vs natural: `+30.76%`
- natural vs request-end: `+6.58%`

The ~31-34% fast-final advantage over the optimized natural API reproduced on three slower CI runners before the response-builder copy experiment.

## Fair shared cross-server comparison - CI 34085638210

Workload: 10,000 measured, 1,000 warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats.

Optimized natural pass:

- Linux::Event natural: **`34,396.5 req/s`**, p50 `2795.9 us`
- Go net/http: `59,268.8 req/s`
- Feersum: `73,422.0 req/s`
- libh2o: `57,312.5 req/s` (very noisy on this runner)
- Node: `22,309.4 req/s`
- aiohttp: `19,430.6 req/s`

Fast-final pass:

- Linux::Event fast-final: **`46,034.3 req/s`**, p50 `2039.0 us`
- Go net/http: `59,429.7 req/s`
- Feersum: `73,843.8 req/s`
- libh2o: `69,404.4 req/s` (one anomalously low repeat)
- Node: `22,677.7 req/s`
- aiohttp: `19,596.6 req/s`

Same-run delta: fast-final vs natural **`+33.83%`**. This is the clean decision-grade API comparison from that runner.

## Response-builder no-temporary-copy experiment - commits 2a04725, 5c35e9d / CI 34085985640

### Change

`Response1.xs::build_default_final` now skips `newSVsv(body)` when the body is already an ordinary materialized non-UTF8 byte string. UTF8, magical, numeric/non-PV and other cases retain the old copy-based path. The goal is to remove one unnecessary body copy without mutating caller data or broadening semantics.

Expanded tests cover:

- ordinary byte body
- undef body
- numeric scalar stringification
- downgradable UTF8 bytes
- caller UTF8 flag preservation
- wide-character rejection
- reference rejection
- HEAD fallback
- non-persistent request fallback

All semantic suites are green on Perl 5.36, latest, and latest-threaded.

### CI 34085985640 absolute results

This CI run landed on a **much faster Azure runner** than CI 34085638210. Nearly every server roughly doubled, so absolute before/after numbers across those runs are **not valid evidence for the copy optimization**.

Focused medians on the fast runner:

- natural: `69,888.2 req/s`, p50 `1387.1 us`
- request-end: `63,367.2 req/s`, p50 `1533.0 us`
- fast-final: `88,290.9 req/s`, p50 `1075.0 us`
- fast-final vs natural: **`+26.33%`**

Shared cross-server medians on the same fast runner:

Natural pass:

- Linux::Event natural: `69,597.2 req/s`
- Go: `107,619.4`
- Feersum: `131,235.6`
- libh2o: `122,405.0`
- Node: `54,776.5`
- aiohttp: `34,728.2`

Fast-final pass:

- Linux::Event fast-final: `89,781.9 req/s`
- Go: `107,208.7`
- Feersum: `129,038.8`
- libh2o: `121,235.6`
- Node: `54,824.6`
- aiohttp: `34,857.1`

Same-run fast-final vs natural: **`+29.00%`**.

### Conclusion so far

1. The fast-final architectural advantage remains real on very different runner hardware: ~26% focused and ~29% shared on this fast runner.
2. **Do not claim the no-copy response builder itself produced the absolute throughput jump.** Runner performance changed dramatically.
3. A true **same-run A/B** between the old copy implementation and the no-copy implementation is required before deciding whether commit `2a04725` is worth retaining.
4. Best next measurement: expose the old builder as a temporary private benchmark reference and add a same-driver `checked callback body (copy)` stage to `run-http-direct-api-experiment.pl`, so the only variable is old-copy vs no-copy serialization.

## Linux::Event write-engine inspection

Core `Stream` immediate writes already call the transport directly from the supplied Perl scalar when no older bytes are queued. Only a partial/EAGAIN remainder is copied into an owned queue segment. Queued segments drain with `writev`.

Therefore:

- there is no unconditional extra Stream copy after HTTP builds the final wire scalar;
- splitting HTTP head/body into two ordinary `write()` calls would likely trade a memcpy for an extra syscall in the immediate path;
- do not pursue split writes without a dedicated segmented-submit measurement/core primitive.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified as a broad architectural move.
2. libh2o is a benchmark/reference, not the current HTTP/1 integration direction.
3. The duplicated bodyless-driver approach is closed.
4. Safe early bodyless completion belongs in the ordinary natural API; it is integrated and repeatedly green.
5. Natural `on_request -> Response->end` is the correct normal bodyless benchmark shape; `on_request_end` is no longer a performance workaround.
6. The specialized complete-response API remains strongly justified across multiple runners: ~26-34% over optimized natural depending on runner/harness.
7. The complete-response gain required no new native driver and no duplicated production parser/driver.
8. The response-builder no-copy change is semantically safe so far, but its performance value is **not yet established** because the first post-change CI used much faster hardware.
9. Remaining work should stay measurement-driven and target bounded costs before contemplating a larger native implementation.
10. The current callback name `on_request_final` is experimental; do not cement it until the response-builder A/B and API review.
11. The old private `_Experiment::FastFinalConnection` module is obsolete and should be deleted after the API direction is finalized.
12. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Add a temporary private old-copy reference entry point in `Response1.xs` and a same-run A/B stage in `bench/run-http-direct-api-experiment.pl`.
2. Run CI and compare no-copy vs copy under the identical checked callback-return-body path. Update this handoff immediately.
3. Keep `2a04725` only if the measured gain is repeatable/worth the added branch complexity; otherwise revert the optimization while retaining the expanded semantic tests.
4. Inspect one or two remaining bounded Perl/native crossings in fast-final if useful.
5. Decide the public complete-response callback/API name and surface it through `Server` constructor callbacks as well as Connection subclass methods.
6. Remove obsolete private experiment module and stale benchmark artifacts after the API decision.
7. Rerun full semantic CI and natural/fast-final cross-server comparison before preparing PR #13 for review.

Do not merge PR #13 or PR #11 without explicit authorization.
