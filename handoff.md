# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- Current implementation/benchmark head before this handoff-only commit: `bf6868d667a8fb78c4378f8f2b7f1e17b1a28ce1`
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
- `bf6868d` - make the default Linux::Event cross-server candidate use the optimized natural `on_request -> Response->end` API; retain request-end and fast-final modes

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

The ~31-34% fast-final advantage over the optimized natural API has now reproduced on three separate CI runs.

## Fair shared cross-server comparison - commit bf6868d / CI 34085638210

This is the current decision-grade competitive comparison. The first shared-harness pass uses the optimized natural Linux::Event API (`on_request -> Response->end`, no `on_request_end`). The second uses the integrated fast-final callback. Both run the same client, competitors, workload, and runner.

Workload:

- 10,000 measured requests per server/repeat
- 1,000 warmup
- 100 connections
- pipeline=1
- 32-byte response
- 3 rotated repeats

### Optimized natural Linux::Event pass

- Linux::Event natural: **`34,396.5 req/s`**, p50 `2795.9 us`, p95 `2977.1 us`, p99 `5613.1 us`
- Go net/http: `59,268.8 req/s`
- Feersum: `73,422.0 req/s`
- libh2o evloop: `57,312.5 req/s`
- Node.js http: `22,309.4 req/s`
- Python aiohttp: `19,430.6 req/s`
- Mojolicious: `1,812.8 req/s`

Note: libh2o was unusually unstable in this pass (`73,086.5`, `57,312.5`, `52,870.6`), so treat its median cautiously.

### Integrated fast-final pass on the same runner

- Linux::Event fast-final: **`46,034.3 req/s`**, p50 `2039.0 us`, p95 `2321.0 us`, p99 `4143.0 us`
- Go net/http: `59,429.7 req/s`
- Feersum: `73,843.8 req/s`
- libh2o evloop: `69,404.4 req/s`
- Node.js http: `22,677.7 req/s`
- Python aiohttp: `19,596.6 req/s`
- Mojolicious: `1,813.3 req/s`

Note: libh2o again had one anomalously low repeat (`46,013.4`) between `69,404.4` and `72,671.2`, so its median is noisier than Feersum/Go/Linux::Event.

### Same-run deltas

- fast-final vs optimized natural Linux::Event: **`+33.83%`**
- fast-final is **22.54% below Go**
- fast-final is **33.67% below libh2o** using the noisy median
- fast-final is **37.66% below Feersum**
- fast-final is **102.99% faster than Node.js**
- fast-final is **134.91% faster than aiohttp**

### Competitive conclusion

1. The specialized complete-response path is now validated by both focused and exact shared cross-server comparisons.
2. It reliably produces roughly **+31-34%** over the optimized natural Linux::Event API for this bodyless fixed-response workload.
3. It more than doubles Node and is far ahead of aiohttp in this benchmark, but remains materially behind Go and Feersum.
4. Feersum is the cleanest current high-performance reference because its repeats are stable. libh2o remains useful but had substantial runner variance in CI 34085638210.
5. We have extracted a large performance win through API/transaction architecture alone; no new native HTTP driver was required.

## Next low-risk cost bucket: native response builder body copy

Linux::Event's core Stream write engine was inspected after CI 34085638210. Its immediate-write path obtains `SvPVbyte(bytes_sv)` and writes directly from the supplied scalar when no older output is queued; it copies only a partial/EAGAIN remainder into an owned queue segment. Therefore there is not an unconditional extra Stream copy after HTTP constructs the final wire scalar.

The existing `Response1.xs::build_default_final`, however, currently does this for every ordinary byte body:

1. `newSVsv(body)` copies the body into a temporary SV;
2. `SvPVbyte(body_copy, ...)` reads it;
3. `sv_catpvn(wire, body_bytes, body_len)` copies it again into the final response wire;
4. temporary body copy is decref'd.

For a non-UTF8 byte scalar, the first copy appears unnecessary. A bounded experiment should change only this behavior:

- undef body => use empty bytes directly
- non-UTF8 scalar => read `SvPVbyte(body, len)` directly with no temporary copy
- UTF8 scalar => retain the current copy-then-downgrade behavior so the caller's scalar is not modified and wide-character validation remains identical

Benchmark before keeping it. This changes the existing tiny response XS implementation; it does not add a new native subsystem.

The direct API-shape benchmark remains an upper-bound clue. CI 34085638210 medians:

- callback returns prebuilt wire: `54,750.0 req/s`
- callback returns body: `51,804.6`
- checked callback returns body: `48,582.3`
- checked driver-direct final: `50,528.2`

Do **not** expose raw-wire return as a public API merely for this speed difference; use it only to bound serialization/build overhead.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified as a broad architectural move.
2. libh2o is a benchmark/reference, not the current HTTP/1 integration direction.
3. The duplicated bodyless-driver approach is closed.
4. Safe early bodyless completion belongs in the ordinary natural API; it is integrated and repeatedly green.
5. Natural `on_request -> Response->end` is now the correct normal bodyless benchmark shape; `on_request_end` is no longer a performance workaround.
6. The specialized complete-response API is strongly justified: ~31-34% over the optimized natural API across repeated focused and shared-harness runs.
7. The complete-response gain required no new XS/C and no duplicated driver.
8. Current fair shared numbers are approximately `34.4k` natural, `46.0k` fast-final, `59.4k` Go, and `73.8k` Feersum on CI 34085638210.
9. There is still a meaningful gap, but remaining work should stay measurement-driven and target bounded costs before contemplating a larger native implementation.
10. The current callback name `on_request_final` is experimental; do not cement it until the next response-builder experiment and API review.
11. The old private `_Experiment::FastFinalConnection` module is obsolete and should be deleted after the API direction is finalized.
12. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Benchmark the byte-body no-temporary-copy change in `Response1.xs::build_default_final` while preserving UTF8 semantics.
2. Update this handoff immediately with the result and revert the change if the gain is not worthwhile or semantics become less clear.
3. If useful, inspect one or two remaining bounded Perl/native crossings in the fast-final path before considering anything larger.
4. Then decide the public complete-response callback/API name and surface it through `Server` constructor callbacks as well as Connection subclass methods.
5. Remove the obsolete private experiment module and stale benchmark artifacts after the API decision.
6. Rerun full semantic CI and the natural/fast-final cross-server comparison before preparing PR #13 for review.

Do not merge PR #13 or PR #11 without explicit authorization.
