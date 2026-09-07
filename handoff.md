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
5. GitHub hosted runner absolute throughput varies dramatically; prefer same-run ratios/A-B measurements.

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

This is production-shaped, but the public name `on_request_final` is still experimental.

### Native default-final builder copy reduction

Commit `2a04725` changed `Response1.xs::build_default_final` so an already-materialized, non-magical, non-UTF8 byte string is read directly instead of first being copied with `newSVsv(body)`. UTF8, magical, numeric/non-PV, and other cases retain copy-based safety behavior. Commit `5c35e9d` expanded scalar/UTF8 semantic tests. Perl 5.36/latest/latest-threaded are green.

## Decision-grade complete-response results

Focused production-shaped runs before the builder-copy experiment:

- CI 34085015017: natural `35,589.8`, fast-final `46,963.4` req/s => **+31.96%**
- CI 34085371457: natural `34,484.1`, fast-final `46,363.5` => **+34.45%**
- CI 34085638210: natural `35,271.3`, fast-final `46,119.1` => **+30.76%**

Fair shared cross-server CI 34085638210, same runner/harness, 10k measured, 1k warmup, 100 conns, pipeline=1, 32-byte body, 3 repeats:

- Linux::Event natural: `34,396.5 req/s`
- Linux::Event fast-final: `46,034.3`
- Go: `59,429.7`
- Feersum: `73,843.8`
- libh2o: `69,404.4` (noisy on this run)
- Node: `22,677.7`
- aiohttp: `19,596.6`

Fast-final vs natural: **+33.83%**.

CI 34085985640 landed on much faster hardware; absolute numbers roughly doubled across competitors. Same-run ratios still held: focused fast-final **+26.33%**, shared fast-final **+29.00%** over natural. Do not use the cross-run absolute jump as evidence for any code change.

## CLOSED: response-builder temporary-body-copy A/B - CI 34086436382

To isolate commit `2a04725`, a temporary private `_build_default_final_copy_reference` reproduced the old unconditional `newSVsv(body)` behavior in the same XS binary. `bench/run-response1-copy-ab.pl` alternated old-copy and production no-copy implementations on the same parsed Request and runner: 200k calls, 20k warmup, 5 repeats.

Same-run median builder results:

- 0-byte body: no-copy `3,439,673.9 ops/s`, copy `3,033,010.0` => **+13.41%**
- 32-byte body: no-copy `3,051,201.8`, copy `2,660,744.2` => **+14.67%**
- 256-byte body: no-copy `2,558,984.8`, copy `2,259,119.6` => **+13.27%**
- 4096-byte body: no-copy `2,362,721.9`, copy `1,844,456.8` => **+28.10%**

For the 32-byte benchmark response, this is approximately `327.7 ns/build` vs `375.8 ns/build`: about **48 ns saved per response build**. At 4 KiB the saving is about **119 ns/build**.

### Decision

**Keep the production no-copy optimization.** It is clearly real, stable, small, and semantically covered. Do not describe it as a large end-to-end server gain; at the 32-byte workload its absolute saving is only ~48 ns. Remove the temporary copy-reference XSUB, A/B benchmark, and CI step now that the question is closed.

CI 34086436382 remained fully green. On that runner:

Focused:
- natural `35,725.5 req/s`
- request-end `32,006.8`
- fast-final `45,629.5`
- fast-final vs natural **+27.72%**

Shared:
- natural Linux::Event `34,696.4`
- fast-final Linux::Event `44,668.0`
- Go `59,118.4`
- Feersum `70,995.1`
- libh2o `70,105.1`

Shared fast-final vs natural: about **+28.74%**.

## Other closed conclusions

1. A duplicated production bodyless Perl driver was tested and is not worthwhile (~2.4% over full HTTP in its decision run). Do not pursue it.
2. pico + Linux::Event transport gets close to Feersum/libh2o before the general Perl transaction layer. Do not pursue production libh2o HTTP/1 integration now.
3. Realistic Perl application callback return-body shapes preserve essentially all stripped-path performance; callback invocation itself is not the large cost.
4. `Response->_new_bound` is roughly ~1 us on representative runners, while reusable bodyless state reset is ~0.15 us. Avoiding eager Response/general transaction machinery explains the large complete-response gain.
5. Linux::Event core Stream already writes directly from the supplied scalar when no output is queued and copies only a partial/EAGAIN remainder. Queued segments drain with `writev`; there is no unconditional extra Stream copy after HTTP builds a wire scalar.
6. Splitting head/body into two ordinary `write()` calls would likely exchange memcpy work for another syscall. Do not pursue without a dedicated segmented-submit measurement/core primitive.

## Next bounded experiment: HTTP input-buffer adoption/clearing

Current `Connection::on_data` always does:

    $self->{_http_input} .= $bytes;

and after parsing a request head `_drive_http1` always removes the consumed prefix with:

    substr($self->{_http_input}, 0, $consumed, '');

For the common empty-buffer + one-complete-request read, a possible pure-Perl optimization is:

- if `_http_input` is empty, assign `$bytes` rather than concatenate, allowing Perl COW/value sharing;
- after parsing, if `$consumed == length(_http_input)`, clear by assignment rather than prefix `substr` mutation;
- retain concatenation/substr behavior for split or coalesced input.

This adds branches, so **benchmark before changing production**. Use a same-run microbenchmark exercising the real pico parser with at least:

1. one complete request per incoming chunk;
2. multiple coalesced requests per chunk;
3. a request split across chunks.

Only integrate if the common case wins materially and split/coalesced behavior is neutral/acceptable.

## Current conclusions

1. More bespoke HTTP XS/C is still not justified as a broad move.
2. Safe early bodyless completion belongs in the ordinary API and remains green.
3. The specialized complete-response API remains strongly justified: roughly **+26-34%** over optimized natural depending on runner/harness.
4. The no-temporary-copy response builder improvement is worth keeping, but it is a small local optimization, not the explanation for the remaining gap.
5. The next work should remain low-risk and measurement-driven; the input-buffer copy/mutation path is the next candidate.
6. The old private `_Experiment::FastFinalConnection` implementation is obsolete and should be removed after the public API direction is finalized.
7. `on_request_final` remains an experimental name. Do not cement it until the remaining bounded experiments and API review are complete.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Remove the temporary response-copy reference XSUB, A/B benchmark, and CI step while keeping the production no-copy implementation/tests.
2. Add and run the same-run input-buffer adoption/clearing benchmark described above.
3. If useful, integrate the input-buffer optimization into real `Connection` and validate semantic/full CI plus focused/shared performance.
4. Then decide the public complete-response API name and surface it through `Server` constructor callbacks as well as Connection subclass methods.
5. Remove the obsolete private fast-final experiment module/stale artifacts after API decision.
6. Rerun full semantic CI and natural/fast-final cross-server comparison before preparing PR #13 for review.

Do not merge PR #13 or PR #11 without explicit authorization.
