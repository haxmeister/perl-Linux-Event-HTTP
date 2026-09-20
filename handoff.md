# Linux::Event::HTTP handoff

Updated: 2026-09-20 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Active branch: `experiment/native-raw-http1-current`.

Raw-input implementation anchor:
`73576736bd173e1624ff9cdbb575d91d39a38859`
("perf: keep raw activation off the ordinary HTTP hot path").

Current validated branch head before this handoff update:
`a84196b9c4b3e0fa04b4f2be638bfa54727061f7`
("test: fix raw transition subtest terminator").

Exact pre-raw HTTP baseline:
`c391b2d8fe6b56b6088569cdadeb86160630be26`
on `experiment/sparse-response-construction`.

Draft validation PR: #31, "Experiment: current-lifecycle raw HTTP input".
It is intentionally draft and MUST NOT be merged without explicit authorization.
Nothing from this experiment has been merged to main. Modify only this HTTP
repository unless the user explicitly authorizes another repository.

All current tests and measurements use Linux::Event commit:
`51f2e1eab28f6f1234024a0cf37be03b36780e84`,
Linux::Event 0.115,
"Allow native consumer retirement to ordinary Stream input".

That core commit is the direct child of the previously pinned
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55` and adds the transition
semantics required by raw HTTP Upgrade/CONNECT.

### Raw native HTTP/1 experiment: completed result

The old raw-input experiment was NOT transplanted wholesale. Its stale
`_http_native_request` path eagerly created Transactions and repeated old
Expect/request-completion work that the current HTTP lifecycle has since removed.

The current experiment instead integrates raw native HTTP/1 parsing with the
current optimized Connection lifecycle:

- the HTTP parser can consume directly from Linux::Event's ordered-byte native
  input buffer before request-head bytes are surfaced into a Perl byte buffer;
- parsed native Request objects enter the current server activation semantics;
- body-bearing requests fall back into the existing Perl request-body state
  machine, then return to native request-head parsing afterward;
- the ordinary production `Connection::on_data` path remains on its original
  hot-path shape and pays no helper-call tax for this experiment;
- the raw consumer provider retains the host across reentrant Perl callbacks;
  provider state is finalized before `release()`, and `release()` is the
  final access through the provider context, matching the current core ABI;
- focused coverage proves persistent request ordering across native head parsing,
  Perl body fallback, return to native parsing, and reentrant Stream close.

The raw path is still opt-in for experiment/test/benchmark subclasses. It has
NOT replaced the default HTTP Connection.

### Correctness validation

GitHub Actions run `35536933321` is green against Linux::Event
`51f2e1eab28f6f1234024a0cf37be03b36780e84`.

Candidate suite:

- Perl 5.36: success;
- latest Perl: success;
- latest threaded Perl: success;
- 41 test files / 1,019 tests;
- end-to-end benchmark smoke: success;
- transaction lifecycle diagnostic smoke: success;
- distribution integrity / disttest: success.

The exact pre-raw baseline was also built and tested successfully in the same
latest-Perl job before the A/B measurements.

Raw-input coverage now includes:

- `t/15-native-raw-server.t`: native parsing, body fallback, return to native
  parsing, persistent ordering, and reentrant close;
- `t/42-upgrade.t`: raw native HTTP Upgrade to an ordinary `on_data` target,
  with post-head bytes retained natively and delivered exactly once after the
  transition;
- `t/72-server-connect.t`: raw native CONNECT to an ordinary tunnel target,
  with same-read post-CONNECT bytes retained and delivered exactly once.

The Upgrade and CONNECT raw tests explicitly count entry through
`_http_native_request`, so these are not ordinary-path passes accidentally
masquerading as raw-provider coverage.

### Final same-run performance result

Current authoritative measurement: run `35536933321`; seven rotated repeats;
100 loopback TCP connections; pipeline 1; candidate and exact pre-raw baseline
built in the same job; both use Linux::Event
`51f2e1eab28f6f1234024a0cf37be03b36780e84`.

All comparison responses include `Content-Type: application/octet-stream`.

| Workload | Exact pre-raw baseline | Ordinary current path | Raw native input | Raw vs baseline |
| --- | ---: | ---: | ---: | ---: |
| GET, 32-byte response | 31,383.0 req/s | 31,290.9 req/s | 33,603.3 req/s | +7.1% |
| GET, 16 KiB response | 22,394.7 req/s | 22,866.8 req/s | 25,718.8 req/s | +14.8% |
| POST, 4 KiB request / 32-byte response | 18,391.1 req/s | 18,621.0 req/s | 17,739.3 req/s | -3.5% |

The ordinary path remains effectively neutral relative to the exact baseline
(-0.3%, +2.1%, +1.3% respectively). The new core transition support therefore
does not impose a visible ordinary HTTP hot-path cost.

The prior run `35523554541` against core `1c3de59e...` remains useful
historical confirmation: it measured +10.8% / +14.4% GET gains and -5.6% POST.
The direction of all three workloads reproduced after the core change.

Conclusion:

- raw native input is materially worthwhile for bodyless/common GET traffic;
- the current body-bearing fallback is slower than the ordinary path and is a
  separate optimization problem;
- do not make raw input the default until protocol transition semantics are
  resolved.

A rejected intermediate routing experiment at
`a89e90a32b29ff43eab2d94a93de0160494dc822` fed raw Requests back through the
whole Perl driver to avoid mirrored activation logic. It removed most of the
small-response gain and made POST materially worse. Do not restore that design.
The final branch keeps raw activation off the ordinary HTTP hot path.


A second rejected body-fallback experiment ended at
`d842ea4816f1a6dbcc84877e950dcf21e36210c7`. It attempted to pass body bytes
already present after a parsed request head through the same retained raw-provider
callback, avoiding one outer core provider re-drive. Correctness remained green,
but run `35537248202` measured:

- GET 32 bytes: 31,262.0 baseline -> 33,580.1 raw (+7.4%);
- GET 16 KiB: 23,465.9 baseline -> 26,509.7 raw (+13.0%);
- POST 4 KiB: 18,861.1 baseline -> 17,582.4 raw (-6.8%).

The POST result was worse than the already validated fallback design, while GET
did not gain. The candidate was reverted. Do not revive the nested inline-tail
approach without new evidence.

The code after the revert is functionally back to the validated raw-input design
from `12e12753bbd43b6fc3735f9da35b7ebdcdaf7789`, plus commit history documenting
the rejected experiment.

### Core transition blocker: resolved

Linux::Event commit
`51f2e1eab28f6f1234024a0cf37be03b36780e84`
implements the deliberately narrow transition contract requested by this HTTP
experiment:

- native-consumer -> different native-consumer remains supported;
- native-consumer -> ordinary Perl Stream/`on_data` is now supported;
- unread ordered input remains native until the transition and is re-driven
  under the target descriptor;
- provider flush/frame/retain lifetime settling is preserved;
- ordinary -> native remains intentionally rejected.

The raw HTTP tests now prove the two generic HTTP handoffs that were previously
blocked:

1. raw native HTTP -> ordinary Upgrade target;
2. raw native HTTP -> ordinary CONNECT tunnel target.

In both cases the HTTP request head and the target protocol bytes are sent in
the same TCP write. The HTTP native consumer consumes only its own request head;
the target bytes remain in Linux::Event's native ordered-byte buffer and are
delivered exactly once after `transition_to()` retires the HTTP consumer.

This removes the remaining correctness blocker to making raw native HTTP input
a production Connection capability.

### Next action

Do NOT modify Linux::Event core further for this item; the required core change
is complete and validated from HTTP.

The next HTTP-local decision is production enablement of raw input.

Current evidence:

- bodyless/common GET traffic benefits materially and repeatably;
- Upgrade and CONNECT to both native-capable and ordinary targets now have a
  viable core transition contract;
- the ordinary HTTP path remains performance-neutral when the experiment is
  present;
- body-bearing POST still pays a measured fallback penalty (-3.5% in the current
  run).

Before making raw input the default for every server Connection, investigate
the body-bearing fallback cost. The first attempt to collapse provider re-entry
was negative and has been reverted.

Next, measure body-bearing traffic by application behavior rather than optimizing
the current discard-style POST benchmark in isolation. At minimum distinguish:

- request body ignored/drained;
- request body delivered through `on_body`;
- response generated from `on_request_end` after body completion;
- more than one representative body size.

Use that evidence to determine whether the remaining penalty is byte-copy cost,
callback/lifecycle cost, or mainly an artifact of the current POST benchmark.
Prefer removing a demonstrated general cost without adding ordinary read-hot-path
bookkeeping. If the fallback cannot be made neutral without disproportionate
complexity, make an explicit API/default-policy decision rather than silently
accepting a body-bearing regression.

Do not merge PR #31 or merge this experiment to main without explicit
authorization.

Current distribution metadata requires Linux::Event 0.116 because the
shipped HTTP raw-input capability and transition regressions depend on the
raw-consumer ABI and native-consumer retirement semantics. Until Linux::Event
0.116 is released, CI pins exact core commit
`51f2e1eab28f6f1234024a0cf37be03b36780e84`.

Everything below is experiment/history context. This section is authoritative.

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
was about 5.8% at that point in the work. At the time, Linux::Event could not
transition away from an active native consumer during same-object
Upgrade/CONNECT. That limitation has since been removed in current Linux::Event
main via native-consumer provider replacement during `transition_to()`; treat
this paragraph as historical context, not a current blocker.

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

## Bodyless completion retirement

After the native scalar-final builder, the remaining common bodyless completion
cleanup was isolated separately. The no-Transaction/bodyless case now keeps the
response-started flag only across `write()` for exception safety and then
retires the live Request/Response/request-state references directly instead of
running the general exchange cleanup sequence.

Focused same-run A/B, run `35488854169`, exact pre-direct-retire baseline
`02de3b566039c6d1fdde77e7997cf488bddc47c1`, current Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`:

- pre-direct-retire: 40,556.8 req/s;
- direct bodyless retirement: 41,504.7 req/s (+2.3%);
- both full test suites pass.

Conclusion: keep the cleanup because it is small, simple, and positive, but do
not spend more time micro-optimizing `_clear_transaction`. The earlier
~13-14% scalar-final improvement came primarily from moving eligibility,
framing validation, Content-Length generation, and wire construction out of
the Perl hot path.

## Current lifecycle after scalar-final work

Latest-core lifecycle ladder, run `35488914267`, Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`, all tests green:

- C1 parse + prebuilt Content-Type write: 65,195.3 req/s;
- C2 + trusted sparse Response: 55,189.2 (-15.4%);
- C3 + Content-Type header setter: 50,349.7 (-8.8%);
- C4 + scalar body setter: 46,114.7 (-8.4%);
- C5 + generated Content-Length metadata: 43,374.3 (-5.9%);
- C6 + native Response head serialization: 39,853.7 (-8.1%);
- C7 + active bodyless exchange / guarded application callback:
  28,239.3 (-29.1%);
- C8 + current scalar-final send/completion: 26,940.6 (-4.6%);
- C9 + production request checks: 24,163.9 (-10.3%);
- C10 production Connection driver: 22,592.7 (-6.5%);
- C11 full Server wrapper: 22,722.7 (+0.6%).

The scalar-final item is therefore largely resolved: the send/completion step is
now only about 4.6%. The next large HTTP-local target is the combined active
bodyless exchange/application-dispatch stage. Earlier callback-fusion testing
showed only about a 1% effect, so split this stage before changing callback
semantics: separately measure exchange activation/request-completion bookkeeping
and the actual guarded application call.

## Lean bodyless exchange activation

Production bodyless request setup now avoids two costs that the split lifecycle
benchmark proved unnecessary:

- native bodyless Requests no longer receive a redundant
  `Request->_mark_complete` fieldhash override; their native body mode
  already makes `is_complete` true;
- a new request no longer resets transaction/response-state/output-progress
  fields that the connection lifecycle invariant has already returned to their
  neutral values.

Focused same-run validation, run `35489292962`, exact pre-activation baseline
`be28cafc5082ec530e76f9c31687a27f38cdda17`, current Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`, both full suites green:

- 32-byte GET + Content-Type:
  54,818.8 -> 62,532.5 req/s (+14.1%);
  Feersum 142,247.5 req/s.
- 16 KiB GET + Content-Type:
  47,554.2 -> 51,630.8 req/s (+8.6%);
  Feersum 112,790.4 req/s.
- 4 KiB POST + Content-Type / 32-byte response:
  42,272.8 -> 42,300.1 req/s (neutral, +0.06%).

The POST neutrality is expected: body-bearing requests genuinely need request
body lifecycle state. Keep this optimization specifically as a bodyless hot
path simplification.

## Lifecycle after lean bodyless activation

Current-core lifecycle run `35495214087`, Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`, all tests green:

- parse + prebuilt Content-Type write: 67,782.3 req/s;
- + trusted sparse Response: 57,884.0 (-14.6%);
- + Content-Type setter: 54,636.4 (-5.6%);
- + scalar body setter: 52,785.3 (-3.4%);
- + Content-Length metadata: 51,030.9 (-3.3%);
- + native head serialization: 48,219.5 (-5.5%);
- + minimal bodyless active fields: 44,213.4 (-8.3%);
- + full fields without Request mark: 44,064.7 (-0.3%);
- + legacy Request completion mark: 40,179.2 (-8.8%);
- + guarded application callback: 38,438.4 (-4.3%);
- + scalar-final send: 37,020.9 (-3.7%);
- + production request checks: 34,644.9 (-6.4%);
- production Connection: 35,152.9;
- full Server: 36,226.7.

The production bodyless path no longer performs the legacy Request completion
mark, so the next measured HTTP-local target is the request-check boundary:
parser exception trapping/status decoding, request-head limits, and Expect
policy. The active experiment moves those checks into the existing HTTP native
parser without changing public Request parsing behavior.

## Native server request-check fast path

Branch: `experiment/server-request-check-fastpath`.

The production server parser now has an internal native result path that:

- returns incomplete without throwing;
- returns protocol status 400/501 for malformed/semantic failures;
- applies the incomplete-head 431 limit natively;
- records Expect policy in the native Request during semantic scanning;
- exposes the supported/unsupported Expect result without materializing header
  value lists in Perl.

The public `parse_request` behavior remains unchanged. The rare successfully
parsed over-limit head still returns a Request so Connection can preserve the
original HTTP/1.0 vs HTTP/1.1 response version for 431.

Same-run validation, run `35495433344`, exact pre-request-check baseline
`d8e73f1fc37b629c129e0cfcdb0bba41c8bccef6`, current Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`, both full suites green:

- 32-byte GET + Content-Type:
  34,727.3 -> 37,523.4 req/s (+8.1%);
  Feersum 76,390.7 req/s.
- 4 KiB POST + Content-Type / 32-byte response:
  24,649.8 -> 26,265.7 req/s (+6.6%).

Added direct coverage for native server parse status, incomplete heads,
malformed 400, unsupported-transfer 501, incomplete-head 431, valid
100-continue, unsupported expectations, and HTTP/1.0 Expect rejection.

Conclusion: keep the native server request-check path. The next largest measured
HTTP-local stage remains trusted sparse Response construction.

## Compact server Response

Branch: `experiment/sparse-response-construction`.

A focused lower-bound benchmark proved that Response object allocation itself is
nearly free; the previous server cost came from eagerly populating default hash
fields.

Run `35495614308`, current Linux::Event main
`1c3de59e395e05e79c735f5d5ef35cd5021e8c55`:

- parse + prebuilt Content-Type write: 120,227.4 req/s;
- + empty blessed Response hash: 119,423.2 (-0.7%);
- + one compact server flag key: 118,580.3 (-0.7%);
- + prior trusted sparse Response defaults: 104,014.0 (-12.3%).

The production server Response now carries only one compact native-created
`_server_flags` key until application mutation requires real metadata storage.
Status 200, request HTTP version, and empty headers are implicit. Public
Response behavior is unchanged; mutation materializes storage as needed.
HTTP/1.0 version identity is retained in the compact flags.

End-to-end validation run `35495843785`, exact pre-compact baseline
`6005c2f64ebf120f0dbc01ed8145a0d8275adf37`, both full suites green:

- 32-byte GET + Content-Type:
  68,855.7 -> 71,633.6 req/s (+4.0%);
  Feersum 144,417.2 req/s.
- 16 KiB GET + Content-Type:
  56,819.7 -> 59,467.2 req/s (+4.7%);
  Feersum 114,457.5 req/s.
- 4 KiB POST + Content-Type / 32-byte response:
  46,424.4 -> 48,017.7 req/s (+3.4%).

Conclusion: keep compact server Response construction. It removes a real local
cost while preserving the public message API, but the end-to-end gain is now
small enough that further Response-constructor micro-optimization is not the
next priority.

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Release-candidate code commit: `a6273a739981d88ede641c23590c9137dcb6a110`
- That commit performs the 0.001 release-readiness audit and fixes found issues.
- PR #29 (Uniform authentication) and PR #30 (Uniform message conformance) are merged.
- No active feature branch is required.
- Linux::Event minimum: `0.116`.
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
