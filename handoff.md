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
- `f455a29` - `Checkpoint semantic bodyless driver result`
- `60bfeca` - `Add libh2o benchmark server`
- `1ea8d91` - `Add libh2o comparison target`
- `cb99a0c` - `Benchmark libh2o upper bound in PR CI`
- `4fa08af` - `Build libh2o benchmark against evloop API`
- `b9f6ba7` - `Checkpoint libh2o feasibility spike`

`bd11439` and `a0be02c` are benchmark-only changes. They do not change the production HTTP driver.

The libh2o commits are also benchmark/diagnostic-only. They do not make libh2o a distribution dependency and do not change production request handling.

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

## libh2o feasibility spike - CI run 34080176589

The smallest useful upper-bound experiment is implemented as an explicit-only benchmark competitor:

- `bench/servers/libh2o-http.c` embeds libh2o directly.
- H2O owns HTTP parsing, keep-alive, protocol transaction state, and response serialization.
- The handler only sets a 200 response and fixed payload and calls `h2o_send_inline`.
- The existing raw shared benchmark client is reused unchanged.
- `bench/run-http-comparison.pl --servers=...,h2o` builds the C server with `pkg-config --cflags --libs libh2o-evloop`.
- H2O is not in the default competitor list and is not a project/runtime dependency.
- PR diagnostic CI installs Ubuntu 24.04 `libh2o-evloop-dev` and includes H2O in smoke/directional comparisons.

The first attempt, CI run `34080016461`, failed only while compiling the new H2O benchmark because Ubuntu's `libh2o-evloop.pc` does not define the backend macro and H2O headers defaulted to libuv. Commit `4fa08af` explicitly defines `H2O_USE_LIBUV 0`. All project tests were already green in the failed run.

Corrected CI run `34080176589` is fully green, including the H2O smoke and latest threaded Perl.

Same-run directional benchmark, 10k measured, 1k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- Linux::Event::Net::HTTP: `51,256.1 req/s`
- Feersum: `98,551.3 req/s`
- libh2o evloop: `97,387.0 req/s`
- Go net/http: `80,660.8 req/s`
- Node.js: `40,562.7 req/s`
- aiohttp: `37,221.6 req/s`
- Mojolicious: `2,957.4 req/s`

Same-run ratios:

- libh2o is about `1.90x` Linux::Event.
- Feersum is about `1.92x` Linux::Event.
- libh2o is about `98.8%` of Feersum; they are effectively in the same throughput tier on this test.
- Linux::Event remains ahead of Node.js, aiohttp, and Mojolicious.

### Critical same-run transaction-ladder observation

The transaction ladder in the same CI run measured:

- parsed Request + prebuilt write: `87,584.9 req/s`
- + Response binding: `80,496.5 req/s`
- + transaction state: `75,450.4 req/s`
- + guarded callbacks: `66,594.1 req/s`
- fused callbacks: `70,414.9 req/s`
- full HTTP transaction: `51,533.5 req/s`

This is the strongest architectural result so far:

- the existing pico parser + Linux::Event transport baseline is already about `89.9%` of libh2o and `88.9%` of Feersum on the same runner;
- therefore replacing pico or Linux::Event's socket loop with libh2o cannot explain most of the current full-stack gap;
- most of the gap appears after parsing, in Perl transaction/API machinery: Response binding, active transaction state, guarded callback boundaries, response eligibility/build/mark/commit work, and generic lifecycle semantics.

### libh2o architecture finding

H2O's evloop is not a generic externally-driven readiness callback abstraction. On Linux its evloop backend directly owns socket polling state and invokes `epoll_ctl` / `epoll_wait` itself. Therefore libh2o does **not** drop cleanly into the existing Linux::Event reactor as a parser-only replacement.

Because standalone libh2o merely ties Feersum before any Perl callback bridge or Linux::Event integration cost, and our current parser/transport baseline is already within roughly 10% of it, **do not pursue production libh2o integration now**. It would trade our current small pico/parser native surface for substantial event-loop integration complexity without attacking the largest measured cost bucket.

libh2o remains useful as a benchmark upper bound and as a future HTTP/2/HTTP/3 architecture reference, but it is not currently justified as the HTTP/1 performance solution.

## Current conclusions

1. Native default-final response remains the worthwhile production candidate from this experiment.
2. Callback fusion is measurable but remains a semantic-risk experiment, not an automatic production change.
3. Response allocation, weak references, cached bodyless state, parser `eval`, Expect checking, and generic Perl bodyless-driver branches are individually bounded.
4. No remaining small Perl micro-optimization has demonstrated enough gain by itself to justify complexity.
5. More bespoke HTTP XS/C is not justified by these measurements.
6. The generic bodyless-driver experiment closes the duplicated-driver path: the semantic duplicate recovered only about `2.44%` in the controlled run.
7. libh2o's standalone ceiling is real but essentially identical to Feersum's and only about 11% above our parser+raw-write stage.
8. The largest remaining opportunity is architectural simplification of the Perl transaction API/control path, not replacing pico or the Linux::Event reactor.
9. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Add a benchmark-only Feersum-shaped path: one parsed Request object, one guarded Perl application callback, and a direct default-final response operation, omitting the separately allocated/bound Response object and generic active-transaction machinery.
2. Keep normal parser/error/size/Expect checks in a second semantic version of that stage if the first ceiling is promising.
3. Compare it against the existing `87.6k` parsed/write baseline, `70.4k` fused-callback stage, `51.5k` full HTTP, `97.4k` libh2o, and `98.6k` Feersum.
4. Use that result to decide whether a lower-overhead public API shape could recover meaningful performance without adding native code. Do not change the production API until the benchmark proves the value and semantics are reviewed.
5. Keep PR #13 and PR #11 unmerged until explicit authorization.
