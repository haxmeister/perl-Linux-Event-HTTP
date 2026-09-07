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

No production HTTP implementation changed in the recent request-check benchmark commits.

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

## Production request-check / driver split

CI run `34078945128` first isolated the remaining guarded-end gap:

- guarded public `Response->end`: `37,338.7 req/s`
- production request checks: `35,540.3`
- full production HTTP: `33,267.4`
- end -> checked: `-4.82%`
- checked -> full HTTP: `-6.40%`

This showed two moderate buckets rather than one large hotspot: request validation and generic `_drive_http1` control flow.

## Request-check microbenchmark - CI run 34079189363

Commit `64771bc` extended `bench/run-http-object-cost.pl` to split the request-validation cost. Ubuntu 24.04, Perl 5.44.0 non-threaded, 300k iterations, 30k warmup, 5 rotated repeats.

Median microcosts:

- no-op benchmark floor: `78.8 ns/op`
- direct pico `parse_request`: `613.5 ns/op`
- same parse inside production-style Perl `eval`: `742.7 ns/op`
- `Request->_consumed`: `163.1 ns/op`
- `Request->body_mode`: `192.5 ns/op`
- `Request->http_version`: `243.6 ns/op`
- `Request->header_values('Expect')` with no Expect header: `219.7 ns/op`
- production `_expect_continue` with no Expect header: `334.5 ns/op`

Derived results:

- Parser exception boundary overhead: `742.7 - 613.5 = 129.2 ns/request`.
- Full normal-GET `_expect_continue` work above the common benchmark-call floor is about `334.5 - 78.8 = 255.7 ns/request`.
- `_expect_continue` wrapper work beyond the underlying `header_values('Expect')` call is about `114.8 ns/request`.
- Parser `eval` plus the no-Expect check therefore account for only about `0.385 us/request` in this microbenchmark.

The same CI run's transaction ladder was internally consistent:

- guarded public end: `44,418.1 req/s`
- checked: `43,402.2` (`-2.29%`)
- full HTTP: `39,534.9` (`-8.91%` from checked)

The end -> checked wall-cost difference on this run is about `0.53 us/request`, which is reasonably explained by the ~`0.385 us` parser-eval + Expect microcost plus the remaining branch/max-head/error scaffolding.

### Request-check conclusion

**Do not optimize this bucket in C/XS.**

- Removing the parser `eval` would at best target roughly `0.13 us/request` and would weaken/complicate error semantics.
- Folding Expect detection into native Request state could at best avoid roughly `0.26 us/request` on the common no-Expect case.
- Even recovering both completely would be only around `0.4 us/request`, roughly a low-single-digit end-to-end gain on these runs and not worth extra native API/state complexity at this point.
- Keep the production request validation semantics intact and move on.

This is important strategically: the current benchmark does **not** justify extending custom parser C merely to cache Expect state or avoid the Perl eval boundary.

## Object/state baseline

Latest same-run medians remain similar to prior measurements:

- Response-shaped hash strong: `629.8 ns`
- same + weak connection: `677.6 ns`
- production `Response->_new_bound`: `985.5 ns`
- weak array proxy: `379.2 ns`
- `_new_request_state` bodyless allocation: `728.3 ns`
- cached bodyless-state reset: `155.2 ns`
- active transaction assign + clear: `500.1 ns`

Conclusions: `weaken` is negligible; an array Response could save roughly 0.6 us/request but is not worth a representation rewrite yet; production bodyless-state reuse is already correct.

## Cross-server status - CI run 34079189363

Same run, 10k measured, 1k warmup, 100 connections, pipeline=1, response=32B, 3 repeats:

- Linux::Event::Net::HTTP: `40,061.2 req/s`
- Feersum: `76,037.5`
- Go net/http: `60,882.4`
- Node.js: `30,907.4`
- aiohttp: `28,379.8`
- Mojolicious: `2,134.2`

Same-run ratios:

- Linux::Event is about `52.7%` of Feersum throughput; Feersum ~`1.90x` faster.
- Linux::Event is about `65.8%` of Go throughput; Go ~`1.52x` faster.
- Linux::Event remains faster than Node.js and aiohttp on throughput.

GitHub runner absolute throughput varies heavily. Use same-run ratios and within-run deltas, not absolute comparisons between separate runs.

All standard CI jobs remain green, including latest threaded Perl.

## Current conclusions

1. Native default-final response is worthwhile and should remain the candidate.
2. Response allocation, weak references, bodyless state, parser `eval`, and normal no-Expect checking are now individually quantified; none is large enough to justify a broad/native rewrite.
3. The request-check bucket is effectively closed for now: there is only about 0.4-0.5 us/request of common-path work there, and removing it would cost semantic/native complexity.
4. The most promising remaining target is the **generic `_drive_http1` control-flow bucket**, measured around 6-9% after request checks depending on runner.
5. Guarded callback dispatch is also measurable, but callback fusion remains a semantic-risk experiment rather than an automatic production change.
6. More bespoke XS/C is premature.
7. `libh2o` remains the fallback architecture if the remaining performance gap ultimately requires substantial custom native HTTP code.

## Immediate next work

1. Build a benchmark-only **common bodyless driver** stage that preserves:
   - parser `eval` and protocol error semantics
   - max-head and Expect validation
   - production bodyless-state reuse
   - both guarded callback boundaries
   - native default-final `Response->end`
   but removes generic branches/state checks that are unnecessary once the parsed request is known to be bodyless.
2. Compare that stage against `checked` and full `_drive_http1` to determine how much of the remaining 6-9% generic driver bucket is actually recoverable with a clean Perl fast path.
3. Do not alter production until that benchmark demonstrates a meaningful gain and the fast-path semantics can be shown equivalent.
4. If the benchmark-only bodyless path recovers little, stop micro-optimizing this driver and evaluate `libh2o` before adding more custom XS/C.
5. If it recovers a meaningful amount, prototype the smallest production Perl change and run full tests plus cross-server benchmarks before deciding whether to keep it.
