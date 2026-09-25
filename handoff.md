# Linux::Event::HTTP handoff

Updated: 2026-09-25 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Repository: `haxmeister/perl-Linux-Event-HTTP`

Canonical branch: `main`

Project boundary: modify only Linux::Event::HTTP unless the user explicitly
authorizes another repository in the current chat.

### Released baseline

Linux::Event::HTTP **0.002 has been uploaded to CPAN and is the current released
baseline**.

Release 0.002 is stamped `2026-09-20` in Changes at commit:

`3f18be8c1677f9e2704dcf718d3071a9e19359ad`
"release: stamp 0.002"

The release-state documentation commit is:

`d6f0f849e0da4260927e681a1337126b700d6c6c`
"docs: record stamped 0.002 release state"

Do not treat 0.002 as pending release work. New development is post-0.002 and is
expected to become the 0.003 development cycle unless the user decides otherwise.

Linux::Event::HTTP 0.002 requires:

`Linux::Event >= 0.116`

Do not lower that dependency without a specific compatibility investigation.

### Current production architecture

Production native server-input implementation:

`71ec89135be61094a1599e3cee74dadd46addf02`
"Make native HTTP input the production server path"

`Linux::Event::HTTP::Server::Connection` owns HTTP byte input through the
Linux::Event native-consumer ABI:

- the class declares the HTTP raw native consumer directly;
- the base class no longer defines ordinary `on_data`;
- application subclasses customize `on_request`, `on_body`,
  `on_request_end`, transport lifecycle callbacks, and `stream_tuning`;
- defining `on_data` on an HTTP Server::Connection subclass is invalid because
  HTTP owns protocol byte input;
- request heads are parsed before native input is unnecessarily surfaced into
  Perl;
- Content-Length bodies remain native for draining/direct on_body delivery;
- chunked bodies remain native with persistent pico decoder state;
- Upgrade and CONNECT preserve same-read post-HTTP bytes across
  `transition_to()`.

The public HTTP/1 feature set includes server/client execution, persistent
connections, streaming request and response bodies with backpressure, bounded
client buffering, redirects, cookies through HTTP::CookieJar, authentication
through Uniform::HTTP::Auth, explicit/default forward proxies, proxy
authentication, client/server CONNECT, Upgrade, HTTPS/TLS, protocol handoff, and
server ordered persistent request processing.

### Remaining HTTP/1 performance asymmetry

Server input is native, but `Linux::Event::HTTP::Client::Connection` still owns
an ordinary Perl `on_data` path:

```text
Linux::Event native input
    -> Perl on_data bytes
    -> _http_client_input concatenation
    -> Perl response-head parsing
    -> response body framing/dispatch
```

The client response-head parser is deliberately still Perl code. Project policy
is not to add parser XS merely because it is possible; native work must be
justified by measurement.

### Client receive-path measurement result

Experiment branch:

`experiment/client-receive-path`

Validated benchmark commit:

`a09b16d328e648c3babf3e56f1bdd892ed6e5704`
"bench: retain client connection across terminal callbacks"

Draft experiment PR: #38.

GitHub Actions run `36188055780` on Perl 5.44.0 / Linux::Event 0.116
passed the normal 41-file / 1,029-test suite, the client benchmark smoke, the
five-case directional matrix, artifact upload, and `make disttest`.

Directional matrix configuration:

- 10,000 measured responses per repeat;
- 1,000 warmup responses;
- 100 persistent connections;
- 3 repeats;
- separate raw responder process;
- client-process CPU measured with CLOCK_PROCESS_CPUTIME_ID.

Median current-client results:

- 32 B Content-Length, drained: 6,507.3 responses/s; 153.612 us client CPU/response;
- 16 KiB Content-Length, drained: 6,222.9 responses/s; 160.665 us CPU/response;
- 16 KiB Content-Length, on_body: 6,077.0 responses/s; 164.471 us CPU/response;
- 16 KiB Content-Length, buffer_body: 5,880.3 responses/s; 169.954 us CPU/response;
- 16 KiB chunked, drained: 6,322.1 responses/s; 158.111 us CPU/response.

The isolated current Perl response-head parse plus transfer/framing decision
cost 33.849 us/response over 50,000 iterations. On the 32-byte workload this is
about 22% of total measured client CPU/response.

The instrumentation run observed exactly 1.000 Perl `on_data` call per response
for all five workloads. The 32-byte response delivered 95 bytes/call; the
16-KiB Content-Length response delivered 16,450 bytes/call; the chunked response
delivered 16,492 bytes/call. Therefore this experiment is not primarily about
reducing callback fragmentation. It is about avoiding the ordinary
native-buffer -> Perl scalar -> _http_client_input -> Perl response-head parser
path and unnecessary Perl buffer manipulation.

Conclusion: the measurement threshold is met. A native Client::Connection
receive-path prototype is justified. The experiment must still prove correctness
and repeatable end-to-end improvement before anything is promoted to production.

### Native client response-head prototype result

The first native client prototype keeps the scope deliberately narrow:

- response heads are parsed directly from Linux::Event's borrowed native input
  buffer by a dedicated HTTP/1 client raw-consumer provider;
- the parsed head is materialized as the existing public
  `Linux::Event::HTTP::Response` object;
- Content-Length, chunked, close-delimited, buffering, and `on_body` behavior
  still use the existing client body state machine through native fallback;
- Upgrade and successful CONNECT pause HTTP input while the zero-delay handoff
  is pending, preserving same-read post-head bytes for `transition_to()`.

The client uses a separate native-consumer operations table from the server.
HTTP request and response wire roles are therefore explicit rather than selected
by a server/client branch inside one provider.

Important prototype commits include:

- `61caa490694c2deb8f7f13b4bd7bbb60057b3e44`
  "experiment: add native HTTP client response consumer";
- `cabfc41bc7cc6e215e45151aa497a14912f12590`
  "experiment: expose native client consumer definition";
- `8d36e852c4baac0d6bd77dbcca98e92f28aa285e`
  "experiment: route client response heads through native input";
- `f7a8d035a1cef05aad45dd2b93353c04b7943e27` and
  `4a6541e889b75d9c4cb7a52f616882de1e4ee6ca`
  add pause/resume discipline to client Upgrade/CONNECT handoff;
- `afad8a3f5173aeb64062491309f634fc9c717897`
  updates the benchmark to instrument native fallback input.

The initial native prototype exposed one real handoff bug: after a successful
CONNECT or 101 head, the raw consumer could immediately see same-read target
protocol bytes and try to parse them as another HTTP response before the
scheduled handoff ran. Pausing HTTP input while the handoff is pending and
restoring the previous read state after `transition_to()` fixes this and matches
the server-side transition discipline.

After that fix the full suite passes, including Upgrade and CONNECT:
41 test files / 1,029 tests.

#### Same-run baseline versus native-head A/B

Decision-quality comparison run:

`36189414550`

Environment for both trees in the same GitHub Actions job:

- Perl 5.44.0;
- Linux::Event 0.116;
- same hosted runner;
- exact pre-native baseline commit
  `a09b16d328e648c3babf3e56f1bdd892ed6e5704`;
- native-head experiment from the current branch;
- 10,000 measured responses per repeat;
- 1,000 warmup responses;
- 100 persistent connections;
- 3 repeats per case.

Same-run medians:

| Workload | Baseline resp/s | Native resp/s | Throughput | Baseline CPU us/resp | Native CPU us/resp | CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 B Content-Length drain | 6,187.6 | 7,593.1 | +22.7% | 161.567 | 131.651 | -18.5% |
| 16 KiB Content-Length drain | 6,188.9 | 7,003.6 | +13.2% | 161.543 | 142.727 | -11.6% |
| 16 KiB Content-Length on_body | 6,054.9 | 6,959.9 | +14.9% | 165.140 | 143.657 | -13.0% |
| 16 KiB Content-Length buffer_body | 5,975.5 | 6,579.5 | +10.1% | 167.308 | 151.938 | -9.2% |
| 16 KiB chunked drain | 6,285.6 | 7,318.0 | +16.4% | 159.027 | 136.615 | -14.1% |

The same run passed the current full test suite and `make disttest`. Both
baseline and native benchmark JSON reports were uploaded from the same job.

Conclusion: native response-head input is worth keeping. The gain is broad,
repeatable on a same-run A/B, and achieved without rewriting body framing.
Before promotion, remove or clearly isolate stale ordinary response-head parsing,
add focused native-client regression coverage, update architecture/user
documentation, and decide whether native body handling should be a separate
follow-on experiment rather than part of this change.

### Cleaned native-client production candidate

The native client response-head change has now passed its cleanup and final
candidate gate.

Current candidate head:

`c20af7f6fad53598dbd30eade62db19a7bc4163f`
"experiment: allow reentrant next client transaction"

Follow-on documentation/test commits through:

`1bedc32dd5d01db9757dbc820bfa293b4e98cce1`
"docs: document client receive benchmark"

plus the reentrant-next-Transaction correction above remain on
`experiment/client-receive-path` / draft PR #38.

Cleanup completed:

- removed the obsolete Perl response-head parser from Client::Connection;
- kept the existing Perl body framing/delivery state machine as the fallback
  after a native final response head;
- retained immediate next-Transaction behavior when an `on_complete` callback
  starts another request before the prior body driver unwinds;
- added `t/16-native-raw-client.t` covering fragmented native heads,
  informational + final heads in one read, native input ownership, and
  reentrant close from `on_response`;
- updated README, architecture, client policy, benchmark documentation, and
  MANIFEST.

Final candidate CI run:

`36190306057`

Results:

- Perl 5.36: PASS;
- latest Perl: PASS;
- latest threaded Perl: PASS;
- full suite: 42 files / 1,033 tests;
- focused client receive benchmark smoke: PASS;
- exact pre-native baseline build: PASS;
- same-run baseline matrix: PASS;
- same-run cleaned native matrix: PASS;
- paired benchmark artifact upload: PASS;
- `make disttest`: PASS, again 42 files / 1,033 tests.

Final cleaned same-run A/B medians:

| Workload | Baseline resp/s | Native resp/s | Throughput | Baseline CPU us/resp | Native CPU us/resp | CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 B Content-Length drain | 9,911.4 | 12,197.4 | +23.1% | 100.871 | 81.961 | -18.7% |
| 16 KiB Content-Length drain | 9,141.9 | 10,772.7 | +17.8% | 109.330 | 92.778 | -15.1% |
| 16 KiB Content-Length on_body | 8,638.0 | 9,992.7 | +15.7% | 115.690 | 99.947 | -13.6% |
| 16 KiB Content-Length buffer_body | 8,007.8 | 9,668.6 | +20.7% | 124.660 | 103.403 | -17.1% |
| 16 KiB chunked drain | 9,067.7 | 11,094.1 | +22.3% | 110.263 | 90.131 | -18.3% |

Decision: keep native response-head input. Do **not** expand this change into a
native response-body rewrite. The current boundary already produces a large,
repeatable gain while preserving the mature Content-Length, chunked,
close-delimited, bounded buffering, callback, redirect/auth retry, and connection
reuse body lifecycle. Native body handling, if investigated later, must be a
separate measured experiment with its own correctness and maintenance case.

This branch is now a production candidate rather than an exploratory
performance branch. It has not been merged to main yet.

### Next agenda

The agreed post-0.002 sequence is:

1. measure the current client receive path with a focused persistent-connection
   benchmark;
2. cover at least tiny Content-Length, 16 KiB Content-Length, chunked,
   `buffer_body`, and streaming `on_body` response workloads;
3. identify the cost of Perl `on_data`, `_http_client_input` concatenation,
   response-head parsing, and buffer consumption;
4. only if measurement shows a meaningful opportunity, prototype
   Client::Connection as a Linux::Event raw native consumer and compare it
   against the exact released-style baseline;
5. keep or reject the native-client experiment based on correctness,
   maintainability, and repeatable measurements;
6. after the HTTP/1 receive-path decision, begin an HTTP/2 architecture
   investigation.

### HTTP/2 distribution decision

HTTP/2 belongs in **Linux::Event::HTTP**, not in a separate Linux::Event::HTTP2
distribution.

The intended architectural rule is one HTTP distribution and one public
message/application model, with version-specific protocol executors underneath
it. Request, Response, Transaction, Client::Operation, Client, and Server should
remain conceptually shared where their semantics genuinely survive the protocol
version change.

HTTP/2 is expected to need separate connection/stream/framing/HPACK/flow-control
machinery internally. Exact package names and implementation boundaries are not
yet decided.

TLS ALPN should eventually select between HTTP executors, for example `h2` and
`http/1.1`, without forcing applications to choose a separate HTTP library.

Do not begin HTTP/3/QUIC work before the HTTP/2 architecture has been explored
and the shared abstractions have been validated.

### Validation baseline for 0.002

The native-default implementation passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- 41 test files / 1,029 tests;
- `make disttest`;
- transaction-lifecycle diagnostic smoke;
- end-to-end benchmark smoke;
- same-run production-native comparisons.

Release-prep latest-Perl same-run medians against the exact pre-native server
baseline were:

- GET / 32-byte response: 31,133.8 -> 33,842.8 req/s (+8.7%);
- GET / 16 KiB response: 23,032.8 -> 26,717.6 req/s (+16.0%);
- POST / 4 KiB request, 32-byte response:
  19,051.8 -> 20,186.5 req/s (+6.0%).

These are server-path measurements and do not answer whether the client receive
path warrants native conversion.

### Deferred client policy

Keep these separate until a real workload requires them:

- HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment discovery;
- NO_PROXY matching;
- PAC;
- SOCKS;
- preemptive authentication caches;
- Authentication-Info / Proxy-Authentication-Info handling;
- richer connection-pool policy;
- parser XS that is not justified by measurement.

The next work item is measurement of the client receive path, not expansion of
these policy features.
