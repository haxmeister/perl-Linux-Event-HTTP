# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint. Update it after every meaningful result or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize long-term C/XS maintenance across the Linux::Event ecosystem.
3. Do not add new XS/C unless benchmarks prove it is materially necessary.
4. Prefer Perl-side/control-flow simplification while measurable headroom remains.
5. If closing the remaining gap requires a growing bespoke native HTTP implementation, evaluate `libh2o` before adding more custom XS/C.

## Relevant branch commits

- `aa8f991` - `Benchmark fused HTTP callback dispatch`
- `cbda5d4` - `Match bodyless transaction benchmark to production state reuse`
- `4bcdbb8` - `Run transaction ladder in PR diagnostics`
- `195c6ce` - `Add HTTP object allocation cost benchmark`
- `a568fed` - `Run HTTP object cost diagnostic in PR CI`
- `503eb9f` - `Match end-stage callback semantics to production`
- `a2cd2cd` - `Add checked HTTP transaction benchmark stage`
- `4746a80` - `Benchmark production request checks separately`
- `64771bc` - `Split HTTP request-check microcosts`

The transaction ladder contract is version 4:

`parse -> bound -> state -> callbacks -> fused -> eligibility -> build -> mark -> commit -> end -> checked -> full HTTP`

The `checked` stage is benchmark-only. It starts from the guarded public `Response->end` path and additionally performs the production driver's parser `eval`/error boundary, incomplete-request handling, maximum request-head guard, and `_expect_continue` validation. No production HTTP implementation changed.

## Native final-response result

Earlier hot-path measurements:

- old/default final response: about `42.28 us/op` / `23.7k ops/s`
- native default final response: about `17.04 us/op` / `58.7k ops/s`
- `Response->end`: about `29.41 us/op -> 7.78 us/op`

Controlled same-host end-to-end run, 100k requests, 100 connections, pipeline=1, 32-byte body:

- baseline: `54,777 req/s`
- native callback experiment: `55,391 req/s` (`+1.1%`)
- native final response: `57,087 req/s` (`+4.2%`)
- native final + fused callbacks: `58,004 req/s` (`+5.9%`)

Conclusion: native default-final response is a real end-to-end win. Callback fusion adds a smaller increment and must not be promoted unless callback/error semantics remain equivalent.

## Request-check / driver split - CI run 34078945128

Ubuntu 24.04, Perl 5.44.0 non-threaded, Linux::Event 0.112, 20k measured + 2k warmup, 100 connections, pipeline=1, response=32B, 3 rotated repeats.

Median ladder:

- parse: `69,553.8 req/s`
- Response binding: `61,468.3` (`-11.62%`)
- transaction state: `54,416.7` (`-11.47%`)
- guarded callbacks: `46,741.8` (`-14.10%`)
- fused callbacks: `49,953.4` (`+6.87%` vs guarded)
- native eligibility: `44,255.7` (`-11.41%`)
- native wire build: `40,286.0` (`-8.97%`)
- response marking: `40,691.7` (`+1.01%`, noise)
- transaction commit: `39,659.6` (`-2.54%`)
- guarded public `Response->end`: `37,338.7`
- production request checks: `35,540.3`
- full production HTTP: `33,267.4`

Crucial isolated deltas:

- **guarded end -> checked: `-4.82%`**
- **checked -> full HTTP: `-6.40%`**

Interpretation:

- About 4.8% of the remaining common-path throughput cost is attributable to production parser/error/request-validation scaffolding: parser `eval`, incomplete/error branching, max-head validation, and `_expect_continue`.
- About another 6.4% remains in generic `_drive_http1` loop/state/control-flow work not present in the staged checked server.
- There is no single huge driver hotspot left. The residual is split into two moderate Perl-side/control-flow buckets.
- This does not justify adding more custom XS/C.

Latency medians:

- guarded public end: p50 `2,558.9 us`, p95 `2,929.9 us`, p99 `5,152.0 us`
- checked: p50 `2,714.9 us`, p95 `2,867.9 us`, p99 `5,451.9 us`
- full HTTP: p50 `2,906.1 us`, p95 `3,071.1 us`, p99 `5,825.0 us`

## Cross-server result from CI run 34078945128

10k measured, 1k warmup, 100 connections, pipeline=1, response=32B, 3 repeats:

- Linux::Event::Net::HTTP: `32,481.0 req/s`
- Feersum: `73,447.3`
- Go net/http: `58,333.9`
- Node.js: `21,759.7`
- aiohttp: `19,549.5`
- Mojolicious: `1,750.2`

Same-run ratios: Linux::Event was about `44.2%` of Feersum and `55.7%` of Go. GitHub-hosted runner performance varies substantially; use same-run ratios and within-run stage deltas, not absolute cross-run req/s.

## Object/state microbenchmark baseline

The latest pre-split run reconfirmed:

- no-op: `75.6 ns/op`
- Response-shaped hash, strong connection: `659.6 ns`
- same + `weaken(connection)`: `724.0 ns`
- production `Response->_new_bound`: `1006.0 ns`
- 8-slot array proxy weak: `389.1 ns`
- `_new_request_state` bodyless allocation: `776.6 ns`
- cached bodyless-state reset: `144.9 ns`
- active assign + clear: `500.6 ns`

Conclusions: `weaken` is negligible; an array Response might save ~0.6 us/request but is not worth rewriting yet; production already benefits from cached bodyless state.

## Current microbenchmark experiment

Commit `64771bc` extends `bench/run-http-object-cost.pl` without changing production code. New cases isolate:

- `parse_direct`: pico `parse_request` / native Request construction with no Perl `eval`
- `parse_eval`: same parse inside the production-style `eval` boundary
- `request_consumed`: `_consumed`
- `request_body_mode`: `body_mode`
- `request_http_version`: `http_version`
- `expect_header_values`: `header_values('Expect')` on a normal GET without Expect
- `expect_continue`: production `_expect_continue` on the same request

The existing CI comparison job already runs this benchmark, so the branch push will produce nanosecond medians for the new cases.

## Current conclusions

1. Native default-final response is worthwhile and should remain the candidate.
2. Response allocation and weak-reference handling are not dominant.
3. Bodyless state reuse is already correct.
4. Guarded callback dispatch is measurable, but fusion remains a semantic-risk experiment rather than an automatic production change.
5. The production-driver residual is decomposed into about 4.8% request-check scaffolding plus about 6.4% generic driver control flow on the latest run.
6. Optimization should now be surgical rather than broad.
7. More bespoke XS/C is premature.
8. `libh2o` remains the fallback architecture if useful progress would otherwise require substantial custom native HTTP code.

## Immediate next work

1. Let CI measure commit `64771bc` and record the nanosecond medians immediately.
2. Compare `parse_direct -> parse_eval` to isolate exception-boundary cost.
3. Compare `expect_header_values` with `expect_continue` to determine whether Expect header lookup or wrapper logic dominates.
4. Use `_consumed`, `body_mode`, and `http_version` numbers to estimate smaller request-accessor contributions.
5. If request checks contain a worthwhile semantic-safe Perl optimization, prototype it benchmark-only first.
6. Then address the remaining ~6.4% generic driver bucket with a benchmark-only common-bodyless path only if it avoids large protocol-logic duplication.
7. Only consider native changes if a specific residual remains large and cannot be removed cleanly in Perl; at that point evaluate `libh2o` before adding more bespoke XS/C.
