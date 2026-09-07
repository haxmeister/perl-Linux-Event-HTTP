# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Repository / branch

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Current branch: `experiment/native-final-response`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base branch: `feature/http-comparison-benchmarks`
- DO NOT merge PR #13 or PR #11 without explicit authorization.

## Strategic goals

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize long-term C/XS maintenance burden across the entire Linux::Event ecosystem.
3. Do not add new XS/C unless benchmarks demonstrate it is materially necessary.
4. Consolidate native code where practical; logical Perl module boundaries do not require separate native extensions.
5. If closing the remaining gap requires a growing pile of bespoke XS/C, evaluate `libh2o` as the cleaner native HTTP engine instead of continuing to accrete custom native code.

## Current experiment

We are measuring where the remaining full HTTP transaction cost lives after introducing the native default final-response fast path.

Relevant commits:

- `aa8f991` - `Benchmark fused HTTP callback dispatch`
- `cbda5d4` - `Match bodyless transaction benchmark to production state reuse`
- `4bcdbb8` - `Run transaction ladder in PR diagnostics`
- `195c6ce` - `Add HTTP object allocation cost benchmark`
- `a568fed` - `Run HTTP object cost diagnostic in PR CI`

The transaction ladder is:

- parse
- bound
- state
- callbacks
- fused
- eligibility
- build
- mark
- commit
- end
- full HTTP

The benchmark contract version is 3.

## Recovered earlier benchmark results

### Native final-response hot path

- old/default final response path: about `42.28 us/op` / `23.7k ops/s`
- native default final-response path: about `17.04 us/op` / `58.7k ops/s`
- `Response->end` specifically improved from about `29.41 us/op` to `7.78 us/op`

Conclusion: the response-ending machinery itself had a very large removable Perl-side cost, and the native default final-response path successfully removes much of it.

### Controlled native-final / fused comparison

Same-host controlled run, 100k requests, 100 connections, pipeline=1, 32-byte response:

- baseline median: `54,777 req/s`
- native-callback: `55,391 req/s` (`+1.1%` vs baseline)
- native-final-response: `57,087 req/s` (`+4.2%` vs baseline)
- native-final-response + fused callback dispatch: `58,004 req/s` (`+5.9%` vs baseline)

For baseline vs native-final-response, latency moved approximately:

- p50: `1.81 ms -> 1.76 ms`
- p95: `1.93 ms -> 1.86 ms`
- p99: `2.00 ms -> 1.93 ms`

Conclusion: the native default-final path is a real but modest end-to-end win. Callback fusion adds only a small further gain and is not the dominant remaining problem.

## Corrected transaction lifecycle diagnostic - CI run 34078143517

Environment:

- Ubuntu 24.04 GitHub runner
- Perl 5.44.0 non-threaded for comparison job
- Linux::Event 0.112 from CPAN
- 20,000 measured requests
- 2,000 warmup requests
- 100 connections
- pipeline=1
- response body=32 bytes
- 3 rotated repeats

Median results after correcting the bodyless request-state benchmark to match production reuse:

- parse: `150,303.6 req/s`
- + Response binding: `134,913.7 req/s` (`-10.24%`)
- + transaction state: `121,527.4 req/s` (`-9.92%`)
- + guarded callbacks: `103,884.2 req/s` (`-14.52%`)
- + fused callbacks: `112,583.5 req/s` (`+8.37%` vs guarded callbacks)
- + native eligibility: `102,634.5 req/s` (`-8.84%`)
- + native wire build: `97,779.5 req/s` (`-4.73%`)
- + response marking: `96,724.9 req/s` (`-1.08%`)
- + transaction commit: `96,089.7 req/s` (`-0.66%`)
- + public `Response->end`: `93,574.2 req/s` (`-2.62%`)
- full production HTTP: `74,616.8 req/s` (`-20.26%` from end stage)

Key correction: the older ladder dramatically overstated transaction-state cost because it allocated a new state hash for every bodyless GET. Production already reuses `_http_bodyless_state`.

IMPORTANT BENCHMARK CAVEAT: the current `end` rung uses fused callbacks, while full production HTTP uses the ordinary guarded callback path. Therefore the reported `end -> http` gap is not pure `_drive_http1` overhead; it includes the loss of the fusion advantage. This must be corrected before treating the full 20% gap as driver cost.

## Cross-server directional comparison - CI run 34078143517

Configuration:

- 10,000 measured requests
- 1,000 warmup
- 100 connections
- pipeline=1
- 32-byte response
- 3 rotated repeats

Median throughput:

- Linux::Event::Net::HTTP: `76,656.6 req/s`
- Feersum: `144,902.0 req/s`
- Go net/http: `120,846.1 req/s`
- Node.js http: `59,796.4 req/s`
- Python aiohttp: `40,607.5 req/s`
- Mojolicious: `3,629.2 req/s`

Linux::Event::Net::HTTP was `52.9%` of Feersum throughput and `63.4%` of Go throughput in this particular run. Do not compare these absolute CI numbers directly to older local-machine runs.

## Object/state cost benchmark - CI run 34078368402

Command:

```text
perl -Mblib bench/run-http-object-cost.pl \
  --iterations=300000 \
  --warmup=30000 \
  --repeats=5
```

Environment: Ubuntu 24.04 GitHub runner, Perl 5.44.0 non-threaded.

Median results:

- no-op floor: `78.9 ns/op`
- Response-shaped blessed hash, strong connection: `661.1 ns/op`
- same hash plus `weaken(connection)`: `733.7 ns/op`
- production `Response->_new_bound`: `1043.5 ns/op`
- eight-slot blessed-array proxy, strong connection: `345.3 ns/op`
- eight-slot blessed-array proxy plus weak connection: `391.1 ns/op`
- `_new_request_state` allocation for bodyless GET: `771.6 ns/op`
- production-style cached bodyless-state reset: `150.2 ns/op`
- active transaction assign + clear with cached objects: `504.6 ns/op`

Derived costs:

- `weaken(connection)` adds only about `72.6 ns` to the Response-shaped hash allocation.
- production `_new_bound` is about `309.8 ns` slower than the equivalent manually inlined weak hash creation; this is largely constructor/call-path overhead, not weak-reference cost.
- the weak array proxy is about `342.6 ns` faster than the weak hash proxy (`46.7%` lower representation/allocation cost).
- the weak array proxy is about `652.4 ns` faster than production `_new_bound` (`62.5%` lower in this microbenchmark).
- cached bodyless state reset is about `5.1x` faster than allocating `_new_request_state`, saving about `621 ns`; production already gets this benefit.

Conclusion: do NOT rewrite Response around arrays yet. The maximum measured constructor/representation saving is well under `1 us/request`; that can matter later, but it is not large enough to justify a broad internal representation rewrite before we finish isolating control-flow cost. `weaken` is definitively not a worthwhile optimization target.

The same CI run had much lower absolute server throughput than run 34078143517 because GitHub-hosted runner performance varies substantially:

- Linux::Event::Net::HTTP: `31,263.7 req/s`
- Feersum: `73,160.5 req/s`
- Go net/http: `57,488.4 req/s`

Same-run ratios were Linux::Event at `42.7%` of Feersum and `54.4%` of Go. This variance reinforces that CI absolute req/s values are directional only; microbenchmark deltas and same-run ratios are more useful than cross-run absolute comparisons.

All normal CI jobs passed again, including latest threaded Perl.

## Current conclusions

1. The native default-final response fast path is a real end-to-end improvement and should remain the candidate under evaluation.
2. `weaken(connection)` is negligible at ~73 ns and should be ignored as an optimization target.
3. An array-backed Response could save roughly 0.65 us per construction versus current `_new_bound`, but that is not enough to justify the semantic/code churn yet.
4. Production bodyless-state reuse is already doing the right thing and avoids roughly 0.62 us/request versus allocation.
5. Callback guarding remains a meaningful Perl-side cost; fusion benchmarks recover roughly 8-13% at the corresponding ladder rung, but production error/callback semantics must not be weakened casually.
6. The previously reported ~20% `end -> full HTTP` gap is contaminated by fused-vs-guarded callback differences. Correct this benchmark before attributing the entire gap to `_drive_http1`.
7. There is still enough plausible Perl-side/control-flow headroom that adding more custom XS/C is premature.
8. `libh2o` remains an explicit fallback architecture candidate if achieving the desired performance requires a growing bespoke native HTTP implementation.

## Immediate next work

1. Correct the lifecycle comparison so a public `Response->end` stage uses the same guarded callback semantics as production; retain fused end as a separate experimental stage if useful.
2. Re-measure the true guarded-end -> full `_drive_http1` gap.
3. Isolate common bodyless GET driver work absent from the staged path: `_expect_continue`, `_http_driving`, repeated closing/is_closed/active checks, and loop/branch control.
4. Prefer a benchmark-only pure-Perl driver simplification or common-bodyless fast branch before changing Response representation.
5. Only promote an optimization if it preserves semantics and shows a meaningful end-to-end gain.
6. If pure-Perl/control-flow work stops yielding useful gains, run a focused `libh2o` feasibility/benchmark experiment before adding more bespoke XS/C.

## Important architecture constraints

- Do not turn benchmark-only callback fusion into production behavior merely because it is faster. Preserve callback/error semantics unless a production design can keep the same externally observable behavior.
- Do not add new XS/C merely because the full HTTP gap remains large.
- A logical Perl module boundary does not require a separate native extension.
- If a mature native HTTP implementation such as libh2o can replace substantial custom native code while improving HTTP/1+2 performance, that is strategically preferable to accumulating narrowly optimized XS layers, provided integration complexity and API semantics remain acceptable.

## Handoff policy

After each meaningful benchmark, implementation experiment, or conclusion, update this file immediately with:

- command / benchmark configuration
- relevant throughput / latency results
- comparison deltas
- conclusion
- next action

This file exists so another chat can continue without reconstructing the entire conversation if the current session stops.
