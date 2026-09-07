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

## Current experiment

We are measuring where the remaining full HTTP transaction cost lives after introducing the native default final-response fast path.

Relevant implementation/benchmark commits:

- `aa8f991` - `Benchmark fused HTTP callback dispatch`
- `cbda5d4` - `Match bodyless transaction benchmark to production state reuse`

The fused commit adds a `fused` transaction-ladder stage and a corresponding hot-path benchmark. Instead of invoking the two HTTP callbacks through two separate `_invoke_http_callback` calls, the fused stage executes both callbacks under one localized `_http_dispatching` flag and one `eval` boundary.

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

## Recovered benchmark results

These results were produced earlier in this experiment and are recorded here so a new chat does not have to reconstruct them.

### Native final-response hot path

Earlier hot-path comparison:

- old/default final response path: about `42.28 us/op` / `23.7k ops/s`
- native default final-response path: about `17.04 us/op` / `58.7k ops/s`
- `Response->end` specifically improved from about `29.41 us/op` to `7.78 us/op`

Conclusion: the response-ending machinery itself had a very large removable Perl-side cost, and the native default final-response path successfully removes much of it.

### Real HTTP server, early native-final result

One earlier cross-server run reported approximately:

- Linux::Event::Net::HTTP: `31,923.8 req/s`
- Feersum: `99,269 req/s`
- Go net/http: roughly `64k-67k req/s` depending on the comparison run
- Node HTTP: `26,236 req/s` in that run

The Feersum throughput gap improved from roughly `5.40x` before the native-final work to roughly `3.11x` after it.

A recorded pipeline=1 comparison also had Linux::Event::Net::HTTP at `31,924 req/s`, p50 `3,038 us`, p95 `3,437 us`, p99 `6,031 us`; Feersum `99,269 req/s`; Go `67,431 req/s`; aiohttp `17,391 req/s`.

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

The native-final candidate was better in all seven rotated repeats.

Conclusion: the native default-final path is a real but modest end-to-end win. Fusing the two callback wrappers adds only about another `1.6%` beyond native-final-response, so callback wrapper duplication is not the dominant remaining problem.

### Transaction lifecycle ladder - older recorded run

One recorded ladder median set was:

- parse: `89,864 req/s`
- + Response binding: `57,506 req/s` (`-36.0%` from parse)
- + transaction state: `45,581 req/s`
- + callbacks: `41,892 req/s`
- + native end: `33,939 req/s`
- full HTTP: `27,202 req/s`

IMPORTANT: the `state` stage in that older run was not accurately mirroring the current production bodyless-GET path. The benchmark called `_new_request_state` and allocated a new state hash for every request, while production `Connection::_drive_http1` reuses a per-connection `_http_bodyless_state` hash for `body_mode eq 'none'`.

Commit `cbda5d4` corrects `bench/servers/linuxevent-transaction-stage.pl` to use the same cached bodyless state logic as production. Therefore the old `57,506 -> 45,581` bound-to-state drop must not be treated as a valid estimate of current production transaction-state cost until the ladder is rerun.

This correction itself is an important conclusion: part of the apparent transaction-state penalty was benchmark artifact, not necessarily production overhead.

## Current conclusion

The native default final-response experiment succeeded at proving there was substantial avoidable cost in `Response->end`, but end-to-end throughput is now constrained elsewhere. The fused-dispatch result strongly argues against spending much more complexity on callback-dispatch fusion.

The current strongest remaining suspect is Response binding/allocation (`parse -> bound`). The transaction-state stage must now be remeasured after `cbda5d4`; its previous cost estimate is invalid for bodyless GET.

The next target should remain Perl-side unless measurement proves otherwise. Do not add more XS merely because the full HTTP gap remains large.

## Immediate next work

1. Rerun the transaction ladder after `cbda5d4` and record the corrected `bound -> state` delta.
2. If `state` rises close to `bound`, focus directly on `Response->_new_bound` allocation/binding/weakening.
3. Split Response binding cost into allocation/hash initialization vs `weaken(connection)` before considering any production redesign.
4. Only promote an optimization to production if it preserves request/response semantics and shows a meaningful end-to-end gain.
5. Re-run cross-server comparison after any production-worthy optimization.

## Important architecture constraint

Do not turn benchmark-only fusion into production behavior merely because it is faster. Preserve callback/error semantics unless a production design can keep the same externally observable behavior. The purpose of the fused stage is first to isolate cost.

## Handoff policy

After each meaningful benchmark, implementation experiment, or conclusion, update this file immediately with:

- command / benchmark configuration
- relevant throughput / latency results
- comparison deltas
- conclusion
- next action

This file exists so another chat can continue without reconstructing the entire conversation if the current session stops.
