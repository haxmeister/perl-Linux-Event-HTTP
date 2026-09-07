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

Key correction: the older ladder dramatically overstated transaction-state cost because it allocated a new state hash for every bodyless GET. Production already reuses `_http_bodyless_state`. After fixing the benchmark, the state cost is much smaller than the old result implied.

## Cross-server directional comparison from the same CI run

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

Linux::Event::Net::HTTP is therefore about:

- `52.9%` of Feersum throughput (Feersum ~`1.89x` faster)
- `63.4%` of Go throughput (Go ~`1.58x` faster)
- `28.2%` faster than Node on throughput in this run
- `88.8%` faster than aiohttp on throughput in this run

Do not compare these absolute CI numbers directly to older local-machine runs; use same-run ratios for directional conclusions.

All three ordinary CI test jobs passed, including latest threaded Perl.

## New object/state cost benchmark

Commit `195c6ce` adds `bench/run-http-object-cost.pl` to isolate inexpensive pure-Perl design questions before any production rewrite.

It measures:

- benchmark loop/no-op floor
- Response-shaped blessed hash allocation with a strong connection reference
- the same hash plus `weaken(connection)`
- production `Response->_new_bound`
- an eight-slot blessed-array Response representation proxy, strong and weak variants
- `_new_request_state` allocation for the bodyless GET
- production-style cached bodyless-state reset
- active transaction hash assignment/clear using cached objects

The array cases are representation proxies only; no production Response methods have been ported. Their purpose is to determine whether an array-backed internal representation has enough allocation advantage to justify a real prototype.

No production code is changed by this benchmark.

## Current conclusions

1. We have made real headway: on this controlled CI runner the gap to Feersum is now under 2x, not the 3-5x picture seen in earlier local runs.
2. Response binding is measurable but only about a 10% throughput step in this ladder.
3. Correct production-style transaction-state handling is another ~10% step, not the enormous cost suggested by the old benchmark.
4. Guarded callback dispatch costs about 14.5% relative to the preceding rung; benchmark-only fusion recovers about 8.4%, but production semantic preservation remains a concern.
5. Native response eligibility/build/mark/commit/end after fused callbacks is comparatively modest in aggregate.
6. The largest remaining unexplained gap is `public Response->end -> full Connection::_drive_http1`, about 20% in this ladder. That means control-flow/bookkeeping in the real driver is now a major target.
7. Do not respond to the remaining gap by adding more custom XS/C yet. There are still significant Perl-side costs to isolate.
8. `libh2o` is now an explicit fallback architecture candidate if the only route to Feersum-class performance is extensive bespoke C/XS. Any libh2o evaluation should compare maintenance burden, HTTP/1+2 capability, integration semantics, and measured throughput—not just peak speed.

## Immediate next work

1. Run `bench/run-http-object-cost.pl` on the same CI class and record medians.
2. Use the result to decide whether `weaken`, hash representation, or state allocation deserves any production prototype.
3. Inspect the real `_drive_http1` bodyless GET path for work absent from the `end` ladder stage: input-buffer handling, `_expect_continue`, body-mode accesses, driving/dispatch flags, repeated active-transaction checks, finalize/resume/loop control.
4. Build cumulative benchmark rungs for those missing production-driver operations before changing production code.
5. Prefer pure-Perl representation/control-flow changes first. Consider new custom XS only if a specific measured residual remains materially large.
6. If pure-Perl headroom proves insufficient, run a focused libh2o feasibility benchmark before committing to additional bespoke native HTTP machinery.

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
