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
