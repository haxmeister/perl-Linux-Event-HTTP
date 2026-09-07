# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-07 (America/Chicago)

## Resume here

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Branch: `experiment/native-final-response`
- Draft PR: #13, currently titled `Experiment: native default final-response fast path`
- Base: `feature/http-comparison-benchmarks`
- Implementation/cleanup head before this handoff-only commit: `197e2ce736fbe8b2337a2e4e6c7459cf1b6d405b`
- DO NOT merge PR #13 or PR #11 without explicit authorization.
- `handoff.md` is the live checkpoint; update it after every meaningful result or conclusion.

## Strategy

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize C/XS maintenance; do not add a large native HTTP subsystem unless measurement makes it necessary.
3. Preserve the general Response/streaming model while providing a cheaper complete-response path where justified.
4. libh2o remains a benchmark/reference, not the current HTTP/1 integration direction.
5. GitHub hosted-runner absolute throughput varies dramatically; prefer same-run ratios and A/B measurements.

## Final API direction

The specialized bodyless complete-response callback is now named:

    on_request_final($connection, $request)

Reason: “final response” is HTTP terminology and distinguishes this from request-input completion (`on_request_end`). Avoid names containing `fast`, which expose implementation, and `complete`, which is ambiguous with request completion.

`on_request` remains REQUIRED as the general fallback for:

- request bodies
- custom status and headers
- streaming
- deferred responses
- any request where the narrow final-response path is declined or not applicable

For a validated bodyless request:

- defined scalar return => try native default `200 OK` final serialization before Response allocation
- `undef` => ordinary `on_request` / Response path
- HEAD, HTTP/1.0, non-persistent/native-ineligible cases => preserve the returned body through ordinary Response serialization without invoking the application twice
- callback exception or invalid returned body => protocol-safe 500
- invalid Expect is rejected before final-response callback

## Production changes on the branch

### Safe early bodyless completion

For a bodyless request with no `on_request_end`, real `Connection::_drive_http1` marks the reusable request state complete before ordinary `on_request`, allowing natural `$response->end(...)` to use native default-final serialization. If `on_request_end` exists, old callback ordering is preserved.

### Final-response path in real Connection

The complete-response behavior is integrated directly into real `Connection::_drive_http1`. There is no duplicated production parser/driver. The obsolete private `_Experiment::FastFinalConnection` module has been deleted.

### Server support

`Server->new` now accepts and retains `on_request_final`, and `_ServerConnection` forwards it directly into each accepted configured Connection. Server still rejects a final-only configuration with no general `on_request` fallback.

`t/40-server.t` verifies Server forwarding and ordinary fallback serialization without a duplicate application callback.

### Production semantic test

The old experiment-named test was promoted to `t/50-final-response.t` and added to `MANIFEST`. It covers:

- eligible GET final-response success
- `undef` fallback
- HEAD fallback
- HTTP/1.0 fallback
- body-bearing POST staying on ordinary streaming path
- callback exception => 500
- invalid returned body => 500
- invalid Expect rejected before callback

### Documentation

`Connection.pm` and `Server.pm` now document `on_request_final`, its signature, narrow/default-200 contract, fallbacks, errors, and why ordinary `on_request` remains required. Connection POD no longer claims every successful request necessarily allocates a Response.

### Native default-final body-copy reduction

`Response1.xs::build_default_final` reads an ordinary materialized non-magical non-UTF8 byte scalar directly instead of first copying it with `newSVsv`. UTF8/magical/numeric/non-PV cases retain the safe copy path.

A same-run A/B proved this local optimization:

- 32-byte body: +14.67% builder throughput, about 48 ns saved/build
- 4 KiB body: +28.10%, about 119 ns saved/build

Keep it, but do not describe it as a large server-level gain.

## Decision-grade performance evidence

Focused real-Connection final-response vs optimized natural `on_request -> Response->end`:

- CI 34085015017: +31.96%
- CI 34085371457: +34.45%
- CI 34085638210: +30.76%
- CI 34086436382: +27.72%
- CI 34086824437: +33.83%
- CI 34087395935 on much faster hardware: natural `81,177.0`, final `100,964.8` req/s => +24.38%

The benefit has therefore remained substantial across very different hosted runners: roughly +24-34% in the focused real-Connection harness.

Fair shared-harness examples:

### CI 34085638210

- Linux::Event natural: `34,396.5 req/s`
- Linux::Event final-response: `46,034.3`
- Go: `59,429.7`
- Feersum: `73,843.8`
- libh2o: `69,404.4` (noisy)

Final vs natural: +33.83%.

### CI 34087395935 (much faster runner)

Natural pass:
- Linux::Event `80,737.6`
- Go `118,978.2`
- Feersum `146,541.8`
- libh2o `134,903.3`

Final-response pass:
- Linux::Event `97,947.0`
- Go `110,719.7`
- Feersum `141,508.7`
- libh2o `136,755.9`

Final vs natural: +21.32%. Competitor absolute values and Node in particular were noisy; use this primarily as another same-run confirmation of the Linux::Event API delta.

## Closed experiments

### Duplicated bodyless Perl driver

Only ~2.4% over full HTTP in its decision run. Do not pursue.

### libh2o integration

pico + Linux::Event transport already approaches Feersum/libh2o before the Perl transaction layer. H2O would also own event/socket state. Keep libh2o as a reference competitor; do not integrate it as the HTTP/1 engine now.

### Input-buffer COW/adopt/clear

Same-run real-pico microbenchmark:

- complete request/chunk: +2.16% (~23 ns)
- four coalesced requests/chunk: -1.82%
- request split across two chunks: -1.06%

Do not integrate; tiny favorable saving plus real workload regressions.

### Response temporary body copy

Closed via same-run A/B. Keep production no-copy optimization; temporary reference XSUB/benchmark removed.

## Remaining cost picture

The large missing cost bucket was eager Response/general transaction machinery, not the Perl application callback itself. On the fast CI 34087395935 runner:

- parse direct ~348 ns
- parse under eval ~415 ns
- `Response->_new_bound` ~573 ns
- reusable bodyless state ~77 ns
- active transaction assign/clear ~261 ns
- transaction ladder native eligibility -> native wire build only -1.68%

On slower runners the absolute ns values are larger but the structure is similar. Remaining individual costs are mostly hundreds of ns; do not accrete complexity chasing them without a credible aggregate win.

Linux::Event Stream already immediately writes from the supplied scalar when output is empty and only copies a remainder on partial/EAGAIN. Queued segments drain with `writev`. Do not split HTTP head/body into ordinary separate writes without a measured segmented-submit primitive; that likely trades memcpy for another syscall.

## PR cleanup completed

The investigation accumulated a large amount of one-off profiling scaffolding. The following were removed from the branch after their conclusions were recorded here:

- `bench/run-http-direct-api-experiment.pl`
- `bench/run-http-layer-ladder.pl`
- `bench/run-http-object-cost.pl`
- `bench/run-http-transport-floor.pl`
- `bench/servers/linuxevent-parse-floor.pl`
- `bench/servers/linuxevent-perl-buffer-floor.pl`
- `bench/servers/linuxevent-stream-floor.pl`
- `bench/servers/linuxevent-transaction-stage.pl`

`bench/run-http-hotpath.pl` was reverted to the existing base-branch version rather than carrying experiment-only additions.

Kept because they have ongoing value:

- shared `bench/run-http-comparison.pl`
- focused `bench/run-http-fast-final-experiment.pl` for final-response regression evidence (name may still be cleaned up)
- `bench/run-http-transaction-ladder.pl` for cumulative transaction diagnostics
- libh2o as an optional/reference shared-harness competitor

Routine PR CI was trimmed to the transaction ladder, focused final-response comparison, and the natural/final shared cross-server passes. Exploratory direct-API/object-cost stages were removed from routine CI.

## CI status

- CI 34087395935 was fully green on Perl 5.36, latest, latest-threaded, disttest, focused diagnostics, and both shared cross-server passes. It validated Server final-response forwarding/tests before the later test-name/private-module/docs cleanup.
- A final CI run at the current cleanup head is required to prove the shipped `t/50-final-response.t`, MANIFEST, deleted private experiment module, documentation, and trimmed diagnostic set together.

## Current conclusions

1. More bespoke native HTTP driver code is not justified.
2. Safe early bodyless completion belongs in the ordinary API.
3. `on_request_final` is now the selected complete-response API name and is justified by repeated ~24-34% focused gains over optimized natural usage.
4. The no-temporary-copy response builder optimization is worth keeping as a small local win.
5. Input COW/clear and duplicated bodyless-driver ideas are closed.
6. Production semantics are now concentrated in real `Connection`; the private duplicated experiment is gone.
7. PR #13 is being reduced from an investigation branch into a reviewable feature branch.
8. PR #13 and PR #11 remain unmerged.

## Immediate next work

1. Wait for/check final CI at the current cleanup head and fix any real failures.
2. Inspect the remaining PR diff for stale experiment wording/artifacts.
3. Rename or otherwise clean up the focused `run-http-fast-final-experiment.pl` benchmark if worthwhile, without changing its measured contract.
4. Update README/Changes/benchmark docs if the public final-response API is not yet represented there.
5. Update PR #13 title/body from “Experiment” to the reviewable final-response feature once the current-head CI is green.
6. Do NOT merge PR #13 or PR #11 without explicit authorization.
