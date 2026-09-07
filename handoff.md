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
- `bd11439` - `Add semantic bodyless driver benchmark stage`
- `a0be02c` - `Measure semantic bodyless HTTP driver candidate`

`bd11439` and `a0be02c` are benchmark-only changes. They do not change the production HTTP driver.

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

## Request-check bucket

CI run `34079189363` split the normal GET request-validation cost:

- parser direct: `613.5 ns/op`
- parser inside production-style `eval`: `742.7 ns/op`
- `_expect_continue` common no-Expect path: `334.5 ns/op`
- parser `eval` overhead: about `129 ns/request`
- parser `eval` + no-Expect checking together: about `0.385 us/request`

Conclusion: do not move request checks into C/XS. The recoverable common-path work is too small relative to semantic/native complexity.

## Object/state baseline

Representative medians from the diagnostic runs:

- production `Response->_new_bound`: about `1.0 us`
- weak-reference overhead is small
- weak array Response proxy: about `0.39 us`
- cached bodyless request-state reset: about `0.15 us`
- active transaction assign + clear: about `0.47-0.50 us`

Conclusion: object representation/state work contains some measurable cost, but no isolated item justifies a broad representation rewrite.

## Semantic bodyless driver experiment - CI run 34079490485

Commits `bd11439` and `a0be02c` implemented the handoff's requested benchmark-only bodyless common-path driver. It preserves:

- parser `eval` / protocol-error boundary
- request-head limit checking
- Expect validation
- production cached bodyless-state reuse
- both guarded callback invocations
- post-callback connection/transaction checks
- public/native-final `Response->end`

It omits generic body-mode branches/state machinery once the benchmark has established the persistent GET request is bodyless.

Ubuntu 24.04, Perl 5.44.0 non-threaded, 20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- guarded public end: `37,054.3 req/s`
- production request checks: `35,229.5 req/s`
- semantic bodyless driver: `34,248.5 req/s`
- full production `_drive_http1`: `33,433.6 req/s`

Step deltas:

- end -> checked: `-4.92%`
- checked -> bodyless: `-2.78%`
- bodyless -> full HTTP: `-2.38%`
- bodyless throughput advantage over full HTTP: about `+2.44%`

Wall-cost interpretation from the medians:

- checked: about `28.39 us/request`
- bodyless: about `29.20 us/request`
- full HTTP: about `29.91 us/request`
- generic checked -> full driver overhead: about `1.53 us/request`
- semantic bodyless path removes only about `0.71 us/request`, roughly half of that bucket

### Bodyless-driver conclusion

**Stop pursuing a duplicated production bodyless Perl driver.**

The semantic fast path proves that stripping generic body handling can recover only about a 2.4% end-to-end throughput gain on this controlled run. A production implementation would also need entry/fallback logic and permanent duplicated control flow, so its real gain would likely be smaller while maintenance and semantic divergence risk would increase substantially.

This satisfies the earlier stop condition: the remaining generic-driver Perl headroom is too small to justify another production fast path.

## Cross-server status - CI run 34079490485

Same-run directional benchmark, 10k measured, 1k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- Linux::Event::Net::HTTP: `32,457.4 req/s`
- Feersum: `72,728.9 req/s`
- Go net/http: `58,536.0 req/s`
- Node.js: `22,879.7 req/s`
- aiohttp: `19,358.4 req/s`
- Mojolicious: `1,731.8 req/s`

Ratios on this runner:

- Linux::Event is about `44.6%` of Feersum; Feersum is about `2.24x` faster.
- Linux::Event is about `55.4%` of Go; Go is about `1.80x` faster.
- Linux::Event remains faster than Node.js, aiohttp, and Mojolicious on throughput.

GitHub runner absolute throughput varies heavily. Use same-run ratios and within-run deltas, not absolute comparisons between separate runs.

CI run `34079490485` is fully green, including latest threaded Perl.

## Current conclusions

1. Native default-final response remains the worthwhile production candidate from this experiment.
2. Callback fusion is measurable but remains a semantic-risk experiment, not an automatic production change.
3. Response allocation, weak references, cached bodyless state, parser `eval`, Expect checking, and generic Perl bodyless-driver branches are now individually bounded.
4. No remaining Perl-side micro-optimization has demonstrated enough gain to justify meaningful extra complexity.
5. More bespoke HTTP XS/C is not justified by these measurements.
6. The generic bodyless-driver experiment closes the current Perl-driver optimization path: the best semantic duplicate recovered only about `2.44%` versus full HTTP.
7. The next architectural question is now `libh2o`: can it replace a growing custom HTTP native layer while keeping Linux::Event integration thin and maintainable?

## Immediate next work

1. Evaluate `libh2o` as an architecture, not yet as a production dependency:
   - current embedding API and maintenance status
   - HTTP/1, HTTP/2, HTTP/3 coverage
   - event-loop integration requirements and whether Linux::Event/epoll can host it cleanly
   - minimum C/XS bridge surface needed for Perl request callbacks and responses
   - packaging/build implications for CPAN/Linux distributions
2. Build the smallest useful benchmark feasibility spike if practical. Prefer a benchmark-only external/native H2O comparison or thin bridge over production integration.
3. Use that spike to answer whether `libh2o` materially closes the Feersum/Go gap without recreating a large custom C HTTP implementation.
4. Keep PR #13 and PR #11 unmerged until explicit authorization.
