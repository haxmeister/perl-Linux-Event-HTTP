# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-07 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint. Update it after every meaningful benchmark, experiment, or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize C/XS maintenance; do not add a new native subsystem unless measurements make it necessary.
3. Preserve the general Response/streaming model while providing a cheaper complete-response path where measurements justify it.
4. libh2o remains a benchmark/reference, not the current HTTP/1 integration direction.
5. GitHub hosted-runner absolute throughput varies dramatically; prefer same-run ratios and A/B measurements.

## Production-shaped changes currently on this branch

### Safe early bodyless completion

For a bodyless request with no configured `on_request_end`, real `Connection::_drive_http1` marks the reusable request state `body_done = 1` before ordinary `on_request`. Natural `$response->end(...)` can therefore use the existing native default-final shortcut. If `on_request_end` exists, old callback ordering remains intact.

### Experimental complete-response callback

Real `Connection` discovers/caches optional `on_request_final($conn,$request)`. For validated bodyless requests it runs before Response allocation:

- scalar return => native default-final serialization/write when eligible
- `undef` => ordinary Response/application fallback
- HEAD, HTTP/1.0, and other native-ineligible results => ordinary Response fallback without re-invoking the app callback
- body-bearing requests => ordinary streaming path
- callback exception or invalid body => protocol-safe 500
- invalid Expect is rejected before callback dispatch

The implementation is production-shaped. `on_request_final` is still treated as an experimental public name until Server/API cleanup is complete.

### Native default-final builder copy reduction

Commit `2a04725` changed `Response1.xs::build_default_final` so an already-materialized, non-magical, non-UTF8 byte string is read directly instead of first being copied with `newSVsv(body)`. UTF8, magical, numeric/non-PV, and other cases retain copy-based safety behavior. Commit `5c35e9d` expanded scalar/UTF8 semantic tests. Perl 5.36/latest/latest-threaded are green.

## Decision-grade complete-response results

Repeated focused real-Connection results:

- CI 34085015017: natural `35,589.8`, fast-final `46,963.4` req/s => **+31.96%**
- CI 34085371457: natural `34,484.1`, fast-final `46,363.5` => **+34.45%**
- CI 34085638210: natural `35,271.3`, fast-final `46,119.1` => **+30.76%**
- CI 34086436382: natural `35,725.5`, fast-final `45,629.5` => **+27.72%**
- CI 34086824437: natural `36,095.5`, fast-final `48,305.9` => **+33.83%**

The specialized complete-response path is therefore a robust ~28-34% win over optimized natural `on_request -> Response->end` on these runners.

### Fair shared cross-server examples

CI 34085638210, same runner/harness:

- Linux::Event natural `34,396.5`
- Linux::Event fast-final `46,034.3`
- Go `59,429.7`
- Feersum `73,843.8`
- libh2o `69,404.4` (noisy)

Fast-final vs natural: **+33.83%**.

CI 34086824437:

Natural pass:
- Linux::Event `34,680.1`
- Go `59,057.7`
- Feersum `75,253.1`
- libh2o `66,882.4` (one low repeat)

Fast-final pass:
- Linux::Event `46,778.6`
- Go `59,362.0`
- Feersum `74,193.8`
- libh2o `72,448.5`

Fast-final remains materially ahead of Node/aiohttp but below Go/Feersum/libh2o. Do not compare absolute throughput between different GitHub runners.

## CLOSED: response-builder temporary-body-copy A/B - CI 34086436382

A temporary private copy-reference XSUB reproduced the old unconditional `newSVsv(body)` path in the same binary. 200k calls, 20k warmup, 5 alternating repeats:

- 0-byte: no-copy `3,439,673.9`, copy `3,033,010.0 ops/s` => **+13.41%**
- 32-byte: `3,051,201.8` vs `2,660,744.2` => **+14.67%**
- 256-byte: `2,558,984.8` vs `2,259,119.6` => **+13.27%**
- 4096-byte: `2,362,721.9` vs `1,844,456.8` => **+28.10%**

At 32 bytes this saves about **48 ns/build**; at 4 KiB about **119 ns/build**. Decision: **keep the production no-copy optimization**, but describe it as a small local win, not a large end-to-end gain. The temporary copy-reference XSUB and benchmark have been removed.

## CLOSED: HTTP input-buffer adoption/clear experiment - CI 34086824437

A same-run microbenchmark exercised the real pico parser under three input shapes. Proposed strategy: assign incoming bytes when `_http_input` is empty (Perl COW) instead of always `.=`; clear by assignment when the parser consumed all buffered input instead of always mutating with `substr`.

300k parsed requests, 30k warmup, 5 alternating repeats, 45-byte request:

- one complete request per incoming chunk:
  - legacy `934,248.2 req/s`, ~`1070 ns/req`
  - adopt/clear `954,392.6`, ~`1048 ns/req`
  - **+2.16%** (~23 ns saved)
- four coalesced requests per chunk:
  - legacy `1,146,034.8`
  - adopt/clear `1,125,172.1`
  - **-1.82%**
- one request split across two chunks:
  - legacy `715,985.3`
  - adopt/clear `708,374.0`
  - **-1.06%**

### Decision

**Do not integrate this optimization.** The favorable common-case saving is only ~23 ns and it regresses fragmented/coalesced shapes by ~1-2%. This is too workload-sensitive and too small against a ~20 us full transaction to justify branches in `Connection::on_data` / `_drive_http1`. Remove the temporary benchmark and CI step.

## Other closed conclusions

1. A duplicated production bodyless Perl driver was tested and is not worthwhile (~2.4% over full HTTP in its decision run). Do not pursue it.
2. pico + Linux::Event transport gets close to Feersum/libh2o before the general Perl transaction layer. Do not pursue production libh2o HTTP/1 integration now.
3. Realistic Perl application callback-return-body shapes preserve essentially all stripped-path performance; callback invocation itself is not the giant cost bucket.
4. `Response->_new_bound` is roughly ~1 us on representative runners, while reusable bodyless state reset is ~0.15 us. Avoiding eager Response/general transaction machinery explains the large complete-response gain.
5. Linux::Event core Stream already writes directly from the supplied scalar when no output is queued and copies only a partial/EAGAIN remainder. Queued segments drain with `writev`; there is no unconditional extra Stream copy after HTTP builds a wire scalar.
6. Splitting head/body into two ordinary `write()` calls would likely exchange memcpy work for another syscall. Do not pursue without a dedicated segmented-submit measurement/core primitive.
7. Current representative tiny costs from CI 34086824437: parse direct ~649 ns, parse under eval ~762 ns, request `body_mode` ~184 ns, no-Expect validation ~352 ns, `Response->_new_bound` ~1.0 us, bodyless state reuse ~145 ns, active transaction assign/clear ~462 ns.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified as a broad move.
2. Safe early bodyless completion belongs in the ordinary API and remains green.
3. The specialized complete-response API is now strongly justified by repeated real-Connection and shared-harness evidence: roughly **+28-34%** over optimized natural usage.
4. The no-temporary-copy response builder improvement is worth keeping, but is a small local optimization.
5. The input-buffer COW/clear idea is closed and should not be integrated.
6. Remaining microcosts are mostly hundreds of nanoseconds; do not accumulate complexity chasing them without a credible aggregate win.
7. The old private `_Experiment::FastFinalConnection` implementation is obsolete.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Remove `bench/run-http-input-buffer-ab.pl` and its CI step.
2. Finalize the complete-response API surface. `on_request_final` is currently the leading name because HTTP uses “final response” distinctly from interim responses, while `complete` would collide conceptually with request-body completion / `on_request_end`.
3. Add `on_request_final` support to `Server` constructor callback forwarding with semantic tests and documentation, while preserving ordinary `on_request` as the required general/body-bearing fallback.
4. Remove obsolete private `_Experiment::FastFinalConnection` and stale experiment artifacts.
5. Rerun full semantic CI and natural/fast-final cross-server comparison.
6. Prepare PR #13 for review, but **do not merge it** without explicit authorization.

Do not merge PR #13 or PR #11 without explicit authorization.
