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
- `1b42865` - checkpoint decision-grade fast-final comparison
- `c870226` - benchmark safe early bodyless completion through ordinary Response API

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

### Decision-grade same-stack comparison - commit 0f65517 / CI 34083452101

20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- `on_request -> Response->end`: `25,324.8 req/s`
- no-op `on_request`, then `on_request_end -> Response->end`: `50,498.8 req/s`
- integrated `on_request_final -> scalar body`: `73,722.1 req/s`

Fast-final was `+45.99%` over the optimized current `on_request_end` path in the identical focused harness.

## Safe early-bodyless-completion experiment - commit c870226 / CI 34083753111

Goal: test whether we can avoid a new public callback by making the ordinary natural API native-eligible earlier.

Benchmark-only subclass behavior:

- uses the unmodified production `_drive_http1`
- intercepts only the normal `on_request` callback boundary
- when the current request state is `mode eq 'none'`, `body_done` is false, and **no `on_request_end` handler is configured**, it sets `body_done = 1` immediately before calling the ordinary user `on_request`
- then ordinary `$response->end(...)` can engage the existing native default-final shortcut
- if `on_request_end` exists, the optimization is disabled so callback semantics are not changed
- no production code changed and no new XS/C added

CI `34083753111` is fully green across Perl 5.36, latest, latest threaded, disttest, all existing tests, and all benchmark smokes.

Same focused harness, 20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- natural `on_request -> Response->end`: **`36,386.1 req/s`**
- optimized `on_request_end -> Response->end`: **`66,595.2 req/s`**
- safe early-body-done `on_request -> Response->end`: **`67,531.8 req/s`**
- integrated fast-final callback return: **`90,671.7 req/s`**

Same-harness deltas:

- early-body-done vs natural on_request: **`+85.60%`**
- early-body-done vs optimized on_request_end: **`+1.41%`**
- fast-final vs optimized on_request_end: **`+36.15%`**
- fast-final vs early-body-done: **`+34.27%`**

Latency p50:

- natural on_request: `2,680.8 us`
- optimized on_request_end: `1,467.9 us`
- early-body-done: `1,443.1 us`
- fast-final: `1,045.0 us`

### Early-body-done conclusion

**The ordering fix is worthwhile for the natural API, but it does not close the fast-final gap.**

It lifts `on_request -> end` almost exactly to the current optimized `on_request_end` level, proving that the natural API's large penalty is mostly the late bodyless-completion flag. But fast-final remains about **34% faster** because it avoids Response allocation/binding and the general transaction lifecycle entirely.

Therefore the complete-response path is now justified independently of the ordering issue. These are two separate opportunities:

1. improve ordinary bodyless `on_request -> Response->end` by marking completion early only when no `on_request_end` callback exists;
2. retain an explicit complete-response fast path for applications that want maximum request/response throughput and do not need Response mutation/streaming for that transaction.

Same CI run contextual numbers:

- parsed Request + prebuilt write: `124,514.4 req/s`
- Response binding: `112,606.9`
- transaction state: `103,917.7`
- guarded callbacks: `89,513.1`
- full HTTP: `64,995.0`
- cross-server production Linux::Event: `65,674.1`
- Feersum: `130,789.2`
- libh2o: `123,022.1`
- Go net/http: `105,373.9`

Do not directly compare focused and cross-server absolute values as percentages, but the runner context confirms the measurements are internally coherent.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified.
2. libh2o is not the current HTTP/1 solution.
3. The duplicated bodyless-driver path is closed.
4. Safe early bodyless completion should be considered as an ordinary API improvement; it makes natural `on_request -> end` perform like the existing optimized `on_request_end` usage without changing callbacks when `on_request_end` is configured.
5. Early completion does **not** eliminate the need for a complete-response fast path: fast-final remains ~34% faster in the same harness.
6. A complete-response callback-return path has repeatedly shown large headroom, works through the real Server stack, and has semantic fallback tests.
7. The current private fast-final implementation duplicates much of `_drive_http1`; that is not acceptable as the final production architecture.
8. The next step is to integrate the fast-final branch directly into the real `Connection::_drive_http1` before Response allocation, eliminating the duplicate driver while preserving the ordinary path as fallback.
9. PR #13 and PR #11 remain unmerged.

## Immediate next work

Implement a branch-only production-shaped experiment directly in `Connection`:

- discover/cache optional `on_request_final` callback/method in `new`
- keep existing `on_request` required as the general/body-bearing fallback
- after parse/head-size/Expect validation and after removing the request head, inspect `body_mode`
- if bodyless and `on_request_final` exists, invoke it before allocating a Response
- scalar return => attempt existing native default-final serialization/write
- `undef` => fall through to the existing ordinary Response transaction path
- callback exception or invalid returned body => protocol-safe 500 before response start
- if native default-final is ineligible (HEAD, HTTP/1.0, close), preserve the returned body by constructing the ordinary Response transaction and ending it through existing Response serialization without invoking the general application callback a second time
- body-bearing requests always use the ordinary path
- do not duplicate parser/driver control flow
- no new XS/C

Also implement the safe early-bodyless-completion ordering improvement inside the ordinary path only when no `on_request_end` handler exists, with regression tests proving `on_request_end` semantics remain unchanged when configured.

Then replace the private subclass benchmark with the real integrated Connection path and re-run the same focused and cross-server diagnostics before deciding API naming/finalization.

Do not merge PR #13 or PR #11 without explicit authorization.
