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

The next benchmark is a cumulative same-run comparison of untouched `main`
versus the complete optimized branch versus Feersum. Do not infer cumulative
improvement by multiplying the independent experiment percentages because
runner performance varies and the optimizations overlap.

The earlier raw-native-input experiment remains separate. Its full-server gain
was only about 5.8%, and Linux::Event currently cannot transition away from an
active native consumer during same-object Upgrade/CONNECT. Do not make raw input
the default Server::Connection path without resolving that core transition
contract.

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
