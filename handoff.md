# Linux::Event::HTTP handoff

Updated: 2026-09-19 (America/Chicago)

## Active HTTP server lifecycle performance work

Branch: `experiment/http-server-lifecycle-fast-constructors`.

The branch now contains several independently measured HTTP-local optimizations.
The public Request/Response/Transaction API remains unchanged and strict.

Validated changes:

- private trusted sparse server Response construction;
- private trusted sparse active Transaction construction;
- fused callback/readiness exception boundary (small effect only);
- trusted-default Response marker with invalidation on metadata mutation;
- collapsed native-final eligibility and completion bookkeeping;
- direct trusted scalar-response dispatch from response-readiness handling;
- lazy server Transaction materialization: ordinary exchanges do not allocate a
  Transaction unless application/protocol behavior actually requests one.

Correctness remains green after lazy Transaction materialization: GitHub Actions
run `35479564228` passed all 40 test programs / 975 tests, including server
Transaction semantics, request-body lifecycle, deferred responses, Upgrade, and
CONNECT.

Key same-run measurements:

Trusted constructors, run `35476298230`:

- main: 27,168.3 req/s;
- trusted constructors: 31,214.7 req/s (+14.9%);
- Feersum native HTTP: 97,252.8 req/s;
- 4 KiB request body: 14,116.1 -> 15,495.8 req/s (+9.8%).

Callback fusion, run `35476854038`:

- old callback boundary: 15,853.0 req/s;
- fused boundary: 16,059.2 req/s (+1.3%);
- 4 KiB request-body result was slightly lower with fusion.

Conclusion: callback fusion is not a major performance lever.

Native-final eligibility/completion, safe final version run `35479265021`:

- old checks: 15,781.9 req/s;
- optimized checks/completion: 19,278.2 req/s (+22.2%);
- Feersum: 73,160.0 req/s;
- all 975 tests pass, including explicit custom-status/custom-header fallback
  coverage.

Response-readiness dispatch, run `35479427018`:

- old readiness path: 19,239.3 req/s;
- direct trusted readiness path: 21,868.2 req/s (+13.7%);
- Feersum: 71,995.5 req/s;
- all 975 tests pass.

Lazy Transaction materialization, run `35479564228`:

- exact pre-lazy baseline: 20,978.5 req/s;
- lazy Transaction: 22,793.5 req/s (+8.7%);
- Feersum: 73,212.0 req/s;
- 4 KiB request body: 8,156.8 -> 8,108.3 req/s (-0.6%, effectively neutral).

Cumulative comparison driver commit: `7f24885d73dc7b5a4594102c79e77bda91ba4cbc`.

Cumulative same-run comparison, run `35479723733`:

- 32-byte response: main 13,285.2 req/s -> optimized 23,333.3 req/s
  (+75.6%); Feersum 74,809.1 req/s. The Feersum ratio narrowed from about
  5.6x to about 3.2x.
- 16 KiB response: main 11,581.9 req/s -> optimized 18,775.5 req/s
  (+62.1%); Feersum 63,613.9 req/s. The Feersum ratio narrowed from about
  5.5x to about 3.4x.
- 4 KiB request body / 32-byte response: main 7,573.8 req/s -> optimized
  8,256.7 req/s (+9.0%).
- optimized branch: 975 tests pass; untouched main: 971 tests pass.

The cumulative result confirms that the HTTP lifecycle work is material and
not an artifact of comparing separate GitHub runners.

Early native-final experiment commit: `012522ac0b0af1c1b955c83919795ba336475b9f`.

Early native-final response experiment, run `35479938375`:

- bodyless GET: 52,076.5 -> 51,593.8 req/s (-0.9%, effectively neutral);
- 4 KiB POST / 32-byte response: 16,245.8 -> 32,697.7 req/s (+101.3%);
- 64 KiB POST / 32-byte response: 12,572.9 -> 19,754.2 req/s (+57.1%);
- all experiment and baseline tests passed.

The optimization lets the existing native default-final response builder answer
an HTTP/1.1 keep-alive request before its request body has finished arriving.
The generic response path already allowed response-before-request-body-
completion; this change preserves that lifecycle while avoiding the generic
response serialization path. A Transaction is materialized only when needed to
track the early response until the request body reaches its boundary.

Conclusion: keep this optimization. It is nearly neutral for the bodyless GET
hot path and removes a major avoidable cost from realistic POST/upload-style
workloads.

The earlier raw-native-input experiment remains separate. Its full-server gain
was only about 5.8%, and Linux::Event currently cannot transition away from an
active native consumer during same-object Upgrade/CONNECT. Do not make raw input
the default Server::Connection path without resolving that core transition
contract.

Benchmark fairness note:

- Feersum, Node, Go, and aiohttp comparison adapters emit
  `Content-Type: application/octet-stream` for the benchmark response.
- the historical Linux::Event::HTTP natural adapter emitted no Content-Type,
  which slightly favored its narrow default-final fast path.
- the active realistic-scalar benchmark therefore measures an explicit
  Linux::Event::HTTP Content-Type response and keeps the old no-header response
  only as a diagnostic ceiling.

Realistic Content-Type baseline, run `35483079246` before the
Connection-owned output-state refactor:

- 32-byte no-header diagnostic: 18,246.3 req/s;
- 32-byte Content-Type response: 6,693.2 req/s;
- 16 KiB no-header diagnostic: 13,650.5 req/s;
- 16 KiB Content-Type response: 6,108.2 req/s.

This exposed the generic final scalar-response path as a major real-world
bottleneck: one ordinary application header forced a roughly 63% / 55%
throughput collapse.

Connection-owned response output state, exact same-run A/B run
`35483238544`:

- 32-byte Content-Type: 8,689.4 -> 10,014.3 req/s (+15.2%);
- 16 KiB Content-Type: 7,823.1 -> 8,715.8 req/s (+11.4%);
- no-header diagnostic on that runner: 22,149.1 / 17,837.0 req/s;
- Feersum with Content-Type: 73,217.7 / 62,204.1 req/s;
- experiment and exact baseline test suites both passed.

Conclusion: keep Connection-owned response output state. It extends lazy
Transaction materialization into ordinary scalar responses and is materially
faster, but the generic scalar final-response machinery remains the next major
target.

Active follow-up branch work adds a common persistent HTTP/1.1 scalar-final
fast path for ordinary status/custom-header responses. It reuses the existing
native Response head serializer and retains the generic response state machine
for Transfer-Encoding, explicit Connection semantics, HTTP/1.0, streaming, and
other uncommon cases.

General scalar-final fast path, run `35483452146`:

- exact pre-fast-path Content-Type baseline, 32-byte response:
  19,553.7 req/s;
- fast scalar-final Content-Type path: 35,205.3 req/s (+80.0%);
- no-header diagnostic ceiling on the same runner: 48,324.7 req/s;
- Feersum with the same Content-Type header: 122,949.2 req/s;
- 16 KiB Content-Type response: 17,678.6 -> 31,707.4 req/s (+79.4%);
- 4 KiB POST / Content-Type / 32-byte response:
  16,478.1 -> 26,275.3 req/s (+59.5%);
- experiment and exact pre-fast-path baseline test suites both pass.

This fast path is intentionally HTTP/1.1 persistent scalar-response work, not
an echo-only shortcut. It supports ordinary custom status/reason and arbitrary
non-framing headers, preserves generated Content-Length in Response metadata,
supports response-before-request-body-completion, and falls back to the general
state machine for Transfer-Encoding, explicit Connection handling, HTTP/1.0,
streaming, malformed/tampered metadata, and other uncommon cases.

The benchmark entry label inherited from an earlier experiment still says
"pre-output-state"; the exact baseline used here is commit
`9663590bdbfab9e705c0760efa06a118c08f310c`, which already includes the
Connection-owned output-state optimization. Treat these numbers strictly as
pre-general-scalar-fast-path vs general-scalar-fast-path.

Follow-up correctness hardening is green in run `35483660328`.
Coverage now explicitly includes custom status, arbitrary non-framing headers,
generated Content-Length visibility, custom-header HEAD responses, 204
body-forbidden responses without Content-Length, mismatched explicit
Content-Length rejection, explicit Connection: close fallback, late
Transaction materialization after an early response, plus the existing
streaming/Upgrade/CONNECT suites.

Current-architecture lifecycle ladder, run `35484049649`, all green:

- C1 parse + prebuilt Content-Type write: 64,632.1 req/s;
- C2 + trusted sparse Response: 58,052.7 req/s (-10.2%);
- C3 + public Content-Type header/body API: 43,417.7 req/s (-25.2%);
- C4 + generated Content-Length metadata: 36,797.4 req/s (-15.3%);
- C5 + guarded application callback: 35,332.1 req/s (-4.0%);
- C6 + native Response head serialization: 35,214.7 req/s (-0.3%);
- C7 + current scalar-final send/completion: 26,774.4 req/s (-24.0%);
- C8 + production request checks: 25,365.8 req/s (-5.3%);
- C9 production Connection driver: 24,132.3 req/s (-4.9%);
- C10 full Server wrapper: 24,177.8 req/s (+0.2%).

Interpretation: the Server wrapper and native head serializer are effectively
free, and callback protection is now a minor cost. The three dominant remaining
HTTP-local costs are public Response header/body mutation, Content-Length
metadata insertion, and scalar-final send/completion bookkeeping. The parser
plus prebuilt write ceiling remains about 64.6k req/s on this run, so a second
transport/buffer-side ceiling also remains above the HTTP object/lifecycle
costs.

Do not compare the ladder's 24.2k full-Server figure directly with the earlier
35.2k Content-Type comparison run because they were separate GitHub jobs with
different cumulative-stage benchmark mechanics. Use the ladder's relative
stage deltas diagnostically.

## Response mutation optimization

Branch: `experiment/response-mutation-fastpath`.

The current realistic scalar-response path showed that public Response mutation
was still a major cost. A refined current-architecture ladder split the cost
into individual operations. Before native setters, the first Content-Type
setter cost about 21-22% of throughput by itself and the scalar body setter
cost another 8-13%.

Pure-Perl cleanup (avoid rebuilding distinct header lists, direct generated
Content-Length append, and repeated body-length work) was correct but produced
only modest end-to-end gains. The measured setter cost remained large enough
to justify moving the validation/storage hot path into the existing
Linux::Event::HTTP::_HTTP1 XS extension without changing the public API.

Current implementation:

- `Response->header($name, $value)` keeps the same public Perl API but delegates
  setter validation and lossless header-list mutation to XS.
- `Response->body($bytes)` likewise delegates scalar byte validation/storage
  to XS.
- getters and all public semantics remain unchanged.
- duplicate header replacement still preserves the first matching field
  position and unrelated field order.
- no new extension/library was added; the implementation lives in the existing
  HTTP/1 XS unit.
- the full distribution suite is green.

Refined ladder after native setters, run `35487353561`:

- parse + prebuilt Content-Type write: 83,124.9 req/s;
- + trusted sparse Response: 74,355.1 (-10.6%);
- + Content-Type setter: 70,123.0 (-5.7%);
- + scalar body setter: 65,450.8 (-6.7%);
- + generated Content-Length metadata: 63,926.9 (-2.3%);
- + native head serialization: 59,038.1 (-7.7%);
- + guarded callback: 48,453.3;
- + current scalar-final send: 39,379.3;
- production Connection: 35,028.4;
- full Server: 35,883.4.

The important comparison is the relative setter cost: the first-header stage
fell from roughly 22% to 5.7%. Absolute ladder rates vary substantially across
hosted runners and should not be compared between jobs as if they were one
machine.

Same-run end-to-end validation, run `35487442283`, exact baseline commit
`9ad7cdffacda7a29e7f64d4b3b6731171637f088`:

- 32-byte GET + Content-Type:
  31,490.2 -> 35,835.6 req/s (+13.8%);
  Feersum 98,966.0 req/s.
- 16 KiB GET + Content-Type:
  26,363.7 -> 29,325.6 req/s (+11.2%);
  Feersum 82,623.0 req/s.
- 4 KiB POST + Content-Type / 32-byte response:
  25,295.5 -> 28,718.5 req/s (+13.5%).

Conclusion: keep the native Response setters. They improve realistic GET and
POST workloads materially while preserving the public message API and
correctness suite. The remaining same-response Feersum gap is about 2.8x on
these runs. The next measured costs are active callback/exchange setup and
scalar-final send/completion bookkeeping rather than Response mutation.

## Scalar-final completion optimization

Branch: `experiment/scalar-final-completion-fastpath`.

All current HTTP testing on this branch is pinned to the current Linux::Event
`main` commit:

`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`
(`Fix reentrant raw-consumer close accounting`, Linux::Event 0.115).

This current core also includes native-consumer provider replacement during
`transition_to()`, so the older raw-HTTP Upgrade/CONNECT blocker described
earlier in this handoff is no longer a core limitation. Revisit raw HTTP input
after the current HTTP-local lifecycle work rather than carrying the old
restriction forward.

The common trusted persistent HTTP/1.1 scalar-response path now performs its
request eligibility checks, ordinary-header validation, generated
Content-Length metadata insertion, response-head construction, HEAD/body
suppression, and body concatenation in the existing HTTP XS unit. Public
Response semantics remain unchanged. Responses with explicit framing or
Connection headers continue to fall back to the general response state machine.

Same-run validation, GitHub Actions run `35488509750`, exact pre-completion
baseline commit `2ba493944588aad15256c0456845d67e0ce252db`, all tests green
for both trees against the same current Linux::Event core:

- 32-byte GET + Content-Type:
  27,706.6 -> 31,548.0 req/s (+13.9%);
  Feersum 76,319.7 req/s.
- 16 KiB GET + Content-Type:
  22,439.9 -> 25,358.1 req/s (+13.0%);
  Feersum 65,054.2 req/s.
- 4 KiB POST + Content-Type / 32-byte response:
  21,604.2 -> 24,582.6 req/s (+13.8%).

Conclusion: keep the native common scalar-final builder. The remaining work in
this item is to isolate Connection-side output/completion bookkeeping now that
wire/framing validation has been removed from that Perl hot path.

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Release-candidate code commit: `a6273a739981d88ede641c23590c9137dcb6a110`
- That commit performs the 0.001 release-readiness audit and fixes found issues.
- PR #29 (Uniform authentication) and PR #30 (Uniform message conformance) are merged.
- No active feature branch is required.
- Linux::Event minimum: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED` until the actual release is authorized.

## 0.001 release-readiness audit

The audit covered public API/POD/docs consistency, dependency and PAUSE metadata,
MANIFEST contents, CI/disttest coverage, benchmark diagnostics, stale pre-release
wording, and the current Uniform::HTTP integration.

Release-candidate fixes in `a6273a739981d88ede641c23590c9137dcb6a110`:

- add `Linux::Event::HTTP::Body::Stream` and
  `Linux::Event::HTTP::Client::Operation` to generated META `provides`;
- mark `_ClientConnect`, `_ClientUpgrade`, and `_ServerConnect` no_index along
  with the existing private helper packages;
- include the tracked Feersum, Go, and libh2o benchmark backends in MANIFEST so
  the CPAN tarball contains the advertised comparison suite;
- update Changes and architecture documentation from the old standalone
  `Uniform::HTTP::Auth 0.01` wording to `Uniform::HTTP::Auth 0.02` from the
  `Uniform-HTTP` distribution;
- document the direct Uniform::HTTP 0.02 Request/Response behavioral contract and
  the direct native Request handoff to Uniform authentication;
- make the picohttpparser evaluation branch-neutral and replace the obsolete
  public `http_version` name with `version`;
- repair the transaction-lifecycle ladder after response output state moved from
  Response into Transaction;
- make the ladder's `bodyless` case run the real production
  `Server::Connection` driver through a raw Listener instead of maintaining a
  second copied bodyless driver;
- bump the transaction-ladder benchmark contract to 7 and update stage
  descriptions to the current lifecycle;
- add transaction-ladder `--smoke` to regular latest-Perl CI so future internal
  API drift is detected;
- update pre-1.0 security support wording;
- clean minor stale test/release wording while preserving the full 0.001 history.

## Validation

Push CI #430 / run `34790481247` on exact release-candidate code commit
`a6273a739981d88ede641c23590c9137dcb6a110` is fully green:

- Perl 5.36 build and tests: success;
- latest Perl build and tests: success;
- latest threaded Perl build and tests: success;
- latest end-to-end benchmark smoke: success;
- latest transaction lifecycle diagnostic smoke: success;
- latest `make disttest`: success.

The repaired transaction-lifecycle diagnostic therefore has executable coverage
in ordinary CI rather than only the manual workflow-dispatch comparison job.

## Uniform integration baseline

Messages:

- Request and Response conform by behavior to the Uniform::HTTP 0.02 message
  contract without inheritance or replacement;
- parsed native server Requests remain lazy XS-backed and immutable;
- executor hot paths retain private list-oriented header access while public
  `header_values` returns an array reference.

Authentication:

- distribution/repository: `haxmeister/perl-Uniform-HTTP`;
- module: `Uniform::HTTP::Auth 0.02`;
- `_ClientAuth` passes the actual `Linux::Event::HTTP::Request` to Uniform;
- Linux::Event::HTTP retains ownership of 401/407 receipt, replayability,
  response draining, connection selection/reuse, retry Transactions, and
  Operation/callback lifecycle.

## External CPAN indexing caveat

`Uniform-HTTP` 0.02 has been uploaded by the user, but CPAN mirror/index
propagation is currently unhealthy. CI therefore first tries normal CPAN
resolution and then falls back to the exact Uniform repository commit
`b2b243957a8f82dfef6081431d7e5e6f84dc1b08`.

This is not a Linux::Event::HTTP code defect, but it can cause installation
friction if Linux::Event::HTTP is uploaded before standard CPAN clients can
resolve `Uniform::HTTP::Auth 0.02`. Prefer waiting for the CPAN index to expose
that dependency before the public 0.001 upload unless temporary installation
friction is acceptable.

## Design constraints that remain fixed

- Do not replace Request/Response with Uniform classes.
- Do not add inheritance solely for Uniform interoperability.
- Do not add Uniform-specific transport/lifecycle state to message objects.
- Do not convert native parsed Requests into Perl adapter objects.
- Keep HTTP executor list-oriented header access private for hot paths.
- Linux::Event remains the only transport output queue.
- Do not modify Linux::Event core from this Project unless explicitly requested.
- Do not add CONNECT relay/proxy bridging to Transaction.

## Next action

The repository code is ready for the 0.001 release process. Keep
`0.001 UNRELEASED` in Changes until the actual release is authorized. Before the
CPAN upload, recheck whether `Uniform::HTTP::Auth 0.02` is visible through normal
CPAN indexing; then stamp the release date, build the distribution, and create
the tag/release as explicitly authorized.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when supported
by available tooling. Do not reuse old merged feature refs for new work.
