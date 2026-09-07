# Linux::Event::Net::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Working branch: `main`
- PR #11 (`Add cross-server HTTP comparison benchmarks`) was merged into `main` as `96b7003ad4481a9024d0476a5fc7a2131e32e8a0`.
- PR #13 (`Add optimized final-response path`) was merged into `main` as `c2098c14801b3f446c9bc381d1ac63b1589ac925`.
- There are no active feature PRs left from today's HTTP work.
- Heavy cross-server/performance CI is now `workflow_dispatch` only. Ordinary CI still covers Perl 5.36, latest Perl, latest threaded Perl, benchmark smoke, and `disttest`.

## What landed

### Cross-server benchmark harness

The repository now has a reproducible shared-client comparison harness for Linux::Event::Net::HTTP, Feersum, Mojolicious, Node.js, Go, aiohttp, and optional libh2o reference runs. GitHub-hosted absolute throughput is treated as directional only; same-run ratios are the useful signal.

### Optimized bodyless final-response API

`Connection` and `Server` support:

    on_request_final($connection, $request)

For a validated bodyless request, a defined scalar return can complete the default response before allocating the general Response transaction machinery. `on_request` remains required as the general fallback for request bodies, custom response metadata, streaming, deferred responses, and declined/ineligible final-response cases.

Semantics retained by tests:

- `undef` falls through to ordinary `on_request`.
- HEAD and HTTP/1.0 preserve the returned body through ordinary Response serialization without invoking the application twice.
- Body-bearing requests remain on the normal streaming path.
- Invalid returned bodies and callback exceptions become protocol-safe 500 responses.
- Invalid `Expect` is rejected before application final-response dispatch.

The focused regression benchmark is `bench/run-http-final-response.pl`. The cumulative transaction diagnostic is `bench/run-http-transaction-ladder.pl` with helper `bench/servers/linuxevent-transaction-stage.pl`.

### Native response builder

A narrow `Linux::Event::Net::HTTP::_Native::Response1` builder handles the eligible default-final response shape. Its ordinary non-magical byte-scalar path avoids a temporary body copy. A same-run A/B measured about 48 ns saved for a 32-byte response body. This is a worthwhile local optimization, not the explanation for the whole server-level gain.

## Performance conclusion

The final-response path repeatedly beat optimized natural `on_request -> Response->end` in real-Connection tests:

- focused runs: roughly +24% to +34%
- one fast shared-harness run: about +21%

The conclusion is architectural: avoiding eager general Response/transaction machinery is materially valuable for the simple complete-response case. The measurements still do not justify replacing the HTTP engine with a broad native C/XS driver or libh2o integration.

## Closed experiments

Do not reopen these without a new measurement reason:

- Duplicated bodyless Perl driver: only a small gain over full HTTP; rejected.
- HTTP input-buffer COW/adopt/clear: about +2% in one shape but regressions for coalesced/split reads; rejected.
- libh2o as the HTTP/1 engine: keep as a reference competitor, not an integration direction.
- Splitting ordinary HTTP head/body writes: likely trades memcpy for another syscall; requires a measured segmented-submit primitive before reconsideration.

## Branch cleanup

The GitHub connector used in this session cannot delete branch refs. Every non-main branch currently in this repository is historical/merged work and can be deleted manually:

- `experiment/native-final-response`
- `experiment/picohttpparser`
- `feature/bound-response`
- `feature/chunked-response-streaming`
- `feature/e2e-benchmark`
- `feature/http1-connection`
- `feature/http1-framing-response`
- `feature/http-comparison-benchmarks`
- `feature/http-server`
- `feature/request-body-streaming`
- `feature/tls-integration`
- `feature/upgrade-handoff`
- `fix/threaded-perl-xs-context`
- `refactor/on-request-end`

After removing those historical refs, `main` should be the only branch needed from today's work.

## Next session

1. `git switch main && git pull` locally.
2. Verify the latest `main` CI is green.
3. Review README/Changes for release-facing presentation of `on_request_final`; implementation/POD/tests are already in place.
4. If continuing performance work, start a fresh branch from `main` and require a measured hypothesis before adding more native code.
5. The broad native-driver/libh2o direction is not justified by current measurements.
