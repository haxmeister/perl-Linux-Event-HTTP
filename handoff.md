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

`503eb9f` changed only the benchmark transaction-stage server: the public `Response->end` rung now uses the same two guarded `_invoke_http_callback` boundaries as production. No production HTTP code changed.

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

## Corrected guarded-end lifecycle result - CI run 34078645063

Environment:

- Ubuntu 24.04 GitHub runner
- Perl 5.44.0 non-threaded
- Linux::Event 0.112
- 20,000 measured requests
- 2,000 warmup
- 100 connections
- pipeline=1
- response=32 bytes
- 3 rotated repeats

Median ladder:

- parse: `68,600.1 req/s`
- Response binding: `63,764.7` (`-7.05%`)
- transaction state: `59,430.4` (`-6.80%`)
- guarded callbacks: `52,137.0` (`-12.27%`)
- fused callbacks: `55,552.8` (`+6.55%` vs guarded)
- native eligibility: `51,278.2` (`-7.69%`)
- native wire build: `49,030.8` (`-4.38%`)
- response marking: `48,782.9` (`-0.51%`)
- transaction commit: `48,834.9` (`+0.11%`, noise)
- guarded public `Response->end`: `45,238.1` (`-7.37%` from commit; note commit rung still follows fused callback semantics)
- full production HTTP: `39,295.8` (`-13.14%` from guarded end)

This replaces the earlier contaminated ~20% `end -> http` estimate. With callback semantics matched, the true measured production-driver residual is about **13.1%** on this run.

Latency medians for the final comparison:

- guarded public end: p50 `2,120 us`, p95 `2,208.9 us`, p99 `4,264.8 us`
- full HTTP: p50 `2,420.9 us`, p95 `2,682.0 us`, p99 `4,849.0 us`

Conclusion: there is still a meaningful driver/control-flow cost, but it is substantially smaller than the prior 20% estimate. This is still enough headroom to justify more Perl-side isolation before any new C/XS work.

## Cross-server result from the same CI run 34078645063

10,000 measured, 1,000 warmup, 100 connections, pipeline=1, response=32B, 3 repeats:

- Linux::Event::Net::HTTP: `39,653.1 req/s`
- Feersum: `76,594.3`
- Go net/http: `61,956.3`
- Node.js: `30,643.2`
- aiohttp: `28,672.3`
- Mojolicious: `2,204.9`

Same-run ratios:

- Linux::Event is about `51.8%` of Feersum throughput; Feersum ~`1.93x` faster.
- Linux::Event is about `64.0%` of Go throughput; Go ~`1.56x` faster.
- Linux::Event remains faster than Node.js and aiohttp on throughput in this run.

GitHub-hosted runner absolute throughput varies heavily. Never compare absolute req/s across separate runners; use same-run ratios and within-run stage deltas.

## Object/state microbenchmark

CI run `34078368402`, medians:

- no-op: `78.9 ns/op`
- Response-shaped hash, strong connection: `661.1 ns`
- same + `weaken(connection)`: `733.7 ns`
- production `Response->_new_bound`: `1043.5 ns`
- 8-slot array proxy weak: `391.1 ns`
- `_new_request_state` bodyless allocation: `771.6 ns`
- cached bodyless-state reset: `150.2 ns`
- active assign + clear: `504.6 ns`

Conclusions:

- `weaken(connection)` costs only ~`72.6 ns`; ignore it.
- array-backed Response could save ~`0.65 us/request`, not enough to justify a rewrite yet.
- cached bodyless state saves ~`0.62 us/request`; production already gets this benefit.

## Current conclusions

1. Native default-final response is worthwhile and should remain the candidate.
2. Response allocation and weak-reference handling are not the dominant remaining issue.
3. Bodyless state reuse is already correct.
4. Guarded callback dispatch is measurable; fusion recovers roughly 6-13% at that rung across runs, but semantics constrain production changes.
5. The apples-to-apples production-driver residual is now measured at about 13%, not 20%.
6. Production `_drive_http1` performs several operations absent from the staged end path: parser `eval`, incomplete/error branches, max-head checks, `_expect_continue`, outer `_http_driving` localization, repeated closing/is_closed/active checks, and generic loop branching.
7. There is still enough plausible Perl/control-flow headroom that more bespoke XS/C is premature.
8. `libh2o` remains the fallback architecture if future progress would otherwise require substantial custom native HTTP code.

## Immediate next work

1. Add a benchmark-only cumulative stage between guarded `end` and full HTTP that adds the real driver's parser `eval` + request validation/pre-dispatch checks (`consumed` max-head and `_expect_continue`) while retaining the staged bodyless transaction flow.
2. Rerun the ladder and split:
   - guarded end -> checked end = parser/error/request-check overhead
   - checked end -> full HTTP = outer driver loop/state/control-flow overhead
3. If parser `eval`/request checks dominate, microbenchmark them individually before any production change.
4. If outer driver control flow dominates, prototype a pure-Perl common-bodyless fast branch without weakening protocol/error semantics.
5. Only consider native changes if a specific residual remains both large and difficult to remove cleanly in Perl.
6. If that point is reached, benchmark a focused `libh2o` integration before adding more bespoke XS/C.
