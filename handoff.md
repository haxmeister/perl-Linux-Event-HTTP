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
5. Keep the existing general Response/streaming model available; investigate a cheaper complete-response path for the common case.
6. libh2o remains a benchmark/reference, not the current HTTP/1 integration direction.

## Important branch commits

- `bd11439` - add semantic bodyless driver benchmark stage
- `a0be02c` - wire semantic bodyless driver into ladder
- `f455a29` - checkpoint semantic bodyless result
- `60bfeca` / `1ea8d91` / `cb99a0c` / `4fa08af` - optional libh2o benchmark spike
- `d5c895b` - record libh2o upper-bound result
- `b753467` / `e8f0a22` / `e18fcf1` - request-only direct API benchmark and syntax fix
- `419f1b8` - checkpoint request-only result
- `b930e2d` - benchmark callback-return API shapes

`bd11439` and `a0be02c` were made after the earlier handoff and have been inspected. They are benchmark-only and do not change the production driver.

## Native final-response result

Earlier controlled end-to-end result, 100k requests, 100 connections, pipeline=1, 32-byte body:

- baseline: `54,777 req/s`
- native callback experiment: `55,391 req/s` (`+1.1%`)
- native final response: `57,087 req/s` (`+4.2%`)
- native final + fused callbacks: `58,004 req/s` (`+5.9%`)

Native default-final response is a real production candidate. Callback fusion is smaller and carries more semantic risk.

## Small-cost buckets already bounded

Representative microcosts:

- parser direct: roughly `0.63-0.66 us`
- parser in production-style `eval`: roughly `0.74-0.81 us`
- `_expect_continue` no-Expect path: roughly `0.35 us`
- `Response->_new_bound`: roughly `1.0 us`
- cached bodyless request-state reset: roughly `0.15 us`
- active transaction assign/clear: roughly `0.48-0.51 us`

Conclusion: none of these isolated items justify more native code or a broad representation rewrite.

## Semantic bodyless driver - CI 34079490485

The benchmark-only bodyless driver preserves parser/error boundaries, head-size checks, Expect validation, cached bodyless state, both guarded callbacks, post-callback checks, and public/native-final `Response->end`, while removing generic body branches after proving the request is bodyless.

Medians:

- production request checks: `35,229.5 req/s`
- semantic bodyless driver: `34,248.5 req/s`
- full production `_drive_http1`: `33,433.6 req/s`

The bodyless duplicate was only about `+2.44%` over full HTTP. **Stop pursuing a duplicated production bodyless Perl driver.** The maintenance/semantic divergence is not worth that gain.

## libh2o upper bound - CI 34080176589

Same-run directional medians:

- Linux::Event::Net::HTTP: `51,256.1 req/s`
- Feersum: `98,551.3 req/s`
- libh2o evloop: `97,387.0 req/s`
- Go net/http: `80,660.8 req/s`

The same run's transaction ladder showed:

- parsed Request + prebuilt write: `87,584.9 req/s`
- + Response binding: `80,496.5 req/s`
- + transaction state: `75,450.4 req/s`
- + guarded callbacks: `66,594.1 req/s`
- fused callbacks: `70,414.9 req/s`
- full HTTP transaction: `51,533.5 req/s`

Critical conclusion: pico + Linux::Event transport is already close to Feersum/libh2o before the Perl transaction layer. Most of the gap appears after parsing.

H2O's evloop owns its own epoll/socket state and does not cleanly drop into the Linux::Event reactor. Since standalone H2O merely ties Feersum before any Perl bridge cost, **do not pursue production libh2o integration for HTTP/1 performance now**.

## Request-only direct API shape - CI 34080762331

The benchmark removes the separately bound Response object and generic active transaction machinery while retaining pico parsing, Linux::Event transport, one guarded application boundary, native default-final serialization, and in the checked stage the production parser/error/head-size/Expect checks.

Medians, 20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response:

- request-only direct final: `56,118.4 req/s`
- request-only checked final: `52,986.8 req/s`
- parsed Request + prebuilt write: `71,633.3 req/s`
- full HTTP transaction: `34,275.5 req/s`

Checked request-only was about `+54.6%` / `1.55x` full HTTP. This proved the transaction/API shape is a major performance lever rather than another 2-6% micro-optimization.

## Realistic callback-return API shape - CI 34081024432

Commit `b930e2d` extended the request-only experiment so the application boundary looks like a plausible public API instead of having the driver fabricate the application result internally.

Measured stages:

- `direct`: driver performs guarded native default-final build/write
- `return_wire`: one guarded application method returns a prebuilt HTTP response wire; driver writes it
- `return_body`: one guarded application method returns the response body; driver performs native default-final build/write
- `checked_return_body`: same return-body shape plus production parser/error/head-size/Expect checks
- `checked`: checked driver direct-final reference

CI run `34081024432` is fully green, including Perl 5.36, latest Perl, latest threaded Perl, disttest/smokes, the direct API experiment, and cross-server diagnostics.

Same-run direct API medians, 20k measured, 2k warmup, 100 connections, pipeline=1, 32-byte response, 3 repeats:

- driver direct final: `52,592.8 req/s`
- callback returns wire: `55,460.7 req/s`
- callback returns body: `52,392.1 req/s`
- checked callback body: `49,791.9 req/s`
- checked driver final: `49,821.8 req/s`

Same-run transaction ladder:

- parsed Request + prebuilt write: `66,528.9 req/s`
- Response binding: `58,748.7 req/s`
- transaction state: `54,054.3 req/s`
- guarded callbacks: `46,420.6 req/s`
- fused callbacks: `47,850.3 req/s`
- full HTTP transaction: `31,951.3 req/s`

Same-run cross-server directional medians:

- Linux::Event::Net::HTTP production: `31,628.0 req/s`
- Feersum: `70,278.0 req/s`
- libh2o evloop: `68,448.1 req/s`
- Go net/http: `50,815.3 req/s`

Important ratios within the direct/ladder workload:

- checked callback-return-body vs full HTTP: about `+55.8%` (`1.56x`)
- callback-return-body vs driver-direct: essentially equal (`52.39k` vs `52.59k`)
- checked callback-return-body vs checked driver-direct: essentially equal (`49.79k` vs `49.82k`)
- callback-return-wire ceiling is only about `5.9%` above callback-return-body
- checked callback-return-body reaches about `74.8%` of parsed/prebuilt ceiling

### Callback-return conclusion

**A realistic single Perl application callback returning a response body preserves essentially all of the stripped request-only gain.**

The application callback itself is not the expensive part. The large cost is the current general transaction machinery surrounding it: eager Response allocation/binding, active transaction bookkeeping, the second request-end callback boundary for bodyless requests, response state/eligibility/mark/commit work, and generic lifecycle handling.

This is now strong enough to justify an experimental production-shaped fast-final callback path on this experiment branch, provided it coexists with and falls back to the existing Response/streaming path. Do not replace the general API yet.

## Current conclusions

1. Native default-final response remains worthwhile.
2. More bespoke XS/C is not justified by current measurements.
3. The duplicated bodyless-driver idea is closed; it only recovered ~2.4%.
4. libh2o is not the HTTP/1 performance solution; parser/transport are already near its ceiling before transaction overhead.
5. A complete-response callback-return path can recover roughly 55% over the current full transaction path without new native code.
6. The callback itself is cheap enough; Response/lifecycle machinery is the major target.
7. The next experiment should be an actual optional fast-final callback integrated into `Connection`/`Server`, with the existing general path retained as fallback.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

Implement an experimental optional fast-final callback in production code on this branch only, then benchmark it through the ordinary Server/Connection stack.

Preferred experimental semantics:

- add an explicit callback/method distinct from existing `on_request` so accidental existing return values cannot change behavior;
- invoke it only after normal parse/error/head-size/Expect validation;
- for a bodyless request, call it before allocating/binding a Response;
- callback receives `($connection, $request)` and returns a scalar byte-string body for a default `200 OK` final response;
- if it returns `undef`, fall through to the existing general `on_request`/Response path;
- if native default-final serialization is ineligible (HEAD, HTTP/1.0/close, etc.), preserve the returned body by constructing the ordinary Response transaction and ending it through the existing general machinery rather than losing semantics;
- body-bearing requests use the existing general path;
- callback exceptions become the same 500/protocol-error behavior as a callback failure before a response starts;
- no new XS/C.

Benchmark the actual integrated fast-final path against ordinary `on_request + $res->end`, then add semantic tests for fallback, HEAD/HTTP/1.0, body-bearing requests, callback exception, and `undef` fallback before considering API naming/finalization.

Keep PR #13 and PR #11 unmerged until explicit authorization.
