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

## Current branch work

Relevant commits:

- `aa8f991` - `Benchmark fused HTTP callback dispatch`
- `cbda5d4` - `Match bodyless transaction benchmark to production state reuse`
- `4bcdbb8` - `Run transaction ladder in PR diagnostics`
- `195c6ce` - `Add HTTP object allocation cost benchmark`
- `a568fed` - `Run HTTP object cost diagnostic in PR CI`
- `503eb9f` - `Match end-stage callback semantics to production`

`503eb9f` is the current experiment to measure next. It changes only the benchmark transaction-stage server: the public `Response->end` rung now invokes `on_request` and `on_request_end` through the same two `_invoke_http_callback` calls used by production instead of using the benchmark-only fused callback boundary. This makes `end -> full HTTP` an apples-to-apples callback-semantics comparison.

No production HTTP code changed in `503eb9f`.

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

Conclusion: native default-final response is a real end-to-end win. Callback fusion adds only a smaller increment and must not be promoted unless callback/error semantics remain equivalent.

## Corrected lifecycle ladder result

CI run `34078143517`, Ubuntu 24.04, Perl 5.44.0 non-threaded, Linux::Event 0.112, 20k measured + 2k warmup, 100 connections, pipeline=1, response=32B, 3 rotated repeats:

- parse: `150,303.6 req/s`
- Response binding: `134,913.7` (`-10.24%`)
- transaction state: `121,527.4` (`-9.92%`)
- guarded callbacks: `103,884.2` (`-14.52%`)
- fused callbacks: `112,583.5` (`+8.37%` vs guarded)
- native eligibility: `102,634.5` (`-8.84%`)
- native wire build: `97,779.5` (`-4.73%`)
- response marking: `96,724.9` (`-1.08%`)
- transaction commit: `96,089.7` (`-0.66%`)
- public `Response->end`: `93,574.2` (`-2.62%`)
- full production HTTP: `74,616.8` (`-20.26%`)

Important: the old state rung was wrong because it allocated `_new_request_state` for every bodyless GET. Production reuses `_http_bodyless_state`; `cbda5d4` fixed the benchmark. Do not use older `57.5k -> 45.6k` state numbers as production evidence.

Also important: the above `end` rung still used fused callbacks. Therefore its `-20.26%` gap to full HTTP was contaminated. `503eb9f` fixes this and the next CI result should replace that conclusion.

## Object/state microbenchmark

CI run `34078368402`:

```text
perl -Mblib bench/run-http-object-cost.pl \
  --iterations=300000 \
  --warmup=30000 \
  --repeats=5
```

Medians:

- no-op floor: `78.9 ns/op`
- Response-shaped blessed hash, strong connection: `661.1 ns`
- same + `weaken(connection)`: `733.7 ns`
- production `Response->_new_bound`: `1043.5 ns`
- 8-slot array proxy strong: `345.3 ns`
- 8-slot array proxy weak: `391.1 ns`
- `_new_request_state` bodyless allocation: `771.6 ns`
- cached bodyless-state reset: `150.2 ns`
- active assign + clear with cached objects: `504.6 ns`

Conclusions:

- `weaken(connection)` costs only ~`72.6 ns`; ignore it as an optimization target.
- array-backed Response representation could save ~`0.65 us/request` vs current `_new_bound`, but that is not enough to justify a broad Response rewrite yet.
- cached bodyless state saves ~`0.62 us/request`; production already gets that benefit.

## Cross-server status

CI run `34078143517` same-run medians:

- Linux::Event::Net::HTTP: `76,656.6 req/s`
- Feersum: `144,902.0`
- Go net/http: `120,846.1`
- Node.js: `59,796.4`
- aiohttp: `40,607.5`
- Mojolicious: `3,629.2`

Linux::Event was about `52.9%` of Feersum and `63.4%` of Go in that run. Another GitHub runner was much slower in absolute terms, so never compare absolute req/s across CI runners; use same-run ratios and within-run stage deltas.

All normal CI jobs have remained green, including latest threaded Perl.

## Current conclusions

1. There is real progress; the native final-response path is worthwhile.
2. Response allocation is measurable but not large enough to justify a representation rewrite now.
3. `weaken` is negligible.
4. Bodyless request-state reuse is already optimized correctly.
5. Callback guarding is meaningful, but fusion is not yet production-safe merely because it is faster.
6. We still have plausible Perl-side/control-flow headroom, so more bespoke XS/C is premature.
7. `libh2o` is the fallback architecture to investigate if further substantial gains require lots of custom native HTTP code.

## Immediate next work

1. Let CI measure commit `503eb9f` and extract the corrected guarded-public-end -> full `_drive_http1` gap.
2. Update this file immediately with that result.
3. If a meaningful residual remains, isolate production-driver work absent from the staged server: `_expect_continue`, `_http_driving`, consumed/max-head checks, repeated closing/is_closed/active checks, and loop/branch control.
4. Build benchmark-only cumulative rungs for those costs before touching production.
5. Prefer a pure-Perl/common-bodyless fast branch experiment before any new XS/C.
6. If Perl/control-flow optimization stops yielding meaningful gains, run a focused `libh2o` feasibility and performance experiment before adding more bespoke native layers.
