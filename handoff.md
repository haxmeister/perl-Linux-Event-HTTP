# Linux::Event::HTTP handoff

Updated: 2026-09-20 (America/Chicago)

## CURRENT STATE - READ THIS FIRST

Repository: `haxmeister/perl-Linux-Event-HTTP`

Canonical branch: `main`

Release-prep branch: merged; no active release branch is required.

Project boundary: modify only Linux::Event::HTTP unless the user explicitly
authorizes another repository in the current chat.

### Release target

The next release is **0.002**.

Linux::Event::HTTP 0.001 is already published on CPAN/MetaCPAN. It was uploaded
on 2026-09-13 America/Chicago (2026-09-14 UTC). Do not overwrite or reissue
0.001.

The release-prep branch:

- synchronizes every distribution module from version 0.001 to 0.002;
- keeps `Changes` at `0.002 UNRELEASED` until the user explicitly authorizes
  the actual release;
- restores 0.001 as historical release `2026-09-13`;
- gives 0.002 only the changes made after the 0.001 release.

Do not upload to CPAN, create a release tag, or create a GitHub release until the
user explicitly authorizes the release.

### Current production architecture

Current release-prepared `main` integration commit:

`9d179aa78c0fe6cd10da0b6a7b5952c73aa525ba`
"Prepare Linux::Event::HTTP 0.002 release"

The pre-release-prep native-default main commit was
`e1deabae5de9758b5aa2f594e166e4b056728393`.

Production native-input implementation:

`71ec89135be61094a1599e3cee74dadd46addf02`
"Make native HTTP input the production server path"

`Linux::Event::HTTP::Server::Connection` now owns HTTP byte input through the
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

No Linux::Event core modification is needed for the current HTTP release.

### Linux::Event dependency

Linux::Event::HTTP 0.002 requires:

`Linux::Event >= 0.116`

The validated core commit is:

`007db40e22374c6d7bf8e056b2d354681d20c852`
"Finalize 0.116 release handoff [skip ci]"

Do not lower this dependency.

As of 2026-09-20, normal public CPAN/MetaCPAN lookup still exposes Linux::Event
0.114 as the newest indexed release and does not expose 0.116. Therefore
Linux::Event 0.116 availability is a **release blocker** for HTTP 0.002: the HTTP
distribution can be fully prepared and validated, but should not be uploaded
until a normal CPAN client can resolve Linux::Event 0.116.

`Uniform::HTTP::Auth 0.02` from the `Uniform-HTTP` distribution is now
normally indexed and is no longer a release blocker.

### Validation baseline

Current main CI run:

`35547723361`

Result: PASS.

The native-default implementation had already passed:

- Perl 5.36;
- latest Perl;
- latest threaded Perl;
- 41 test files / 1,029 tests;
- `make disttest`;
- transaction-lifecycle diagnostic smoke;
- end-to-end benchmark smoke;
- same-run production-native comparisons.

Same-run latest-Perl medians against the exact pre-native server baseline:

- GET / 32-byte response: 31,472.7 -> 33,506.0 req/s (+6.5%);
- GET / 16 KiB response: 23,029.0 -> 25,705.8 req/s (+11.6%);
- POST / 4 KiB request, 32-byte response:
  19,000.9 -> 20,582.9 req/s (+8.3%).

### 0.002 release-prep checklist

Completed on `release/0.002-prep`:

- identify 0.002 as the next release because 0.001 is already on CPAN;
- synchronize module versions to 0.002;
- split `Changes` into post-release 0.002 notes and preserved 0.001 history;
- audit public documentation for stale pre-native server-input wording;
- verify `Makefile.PL` requires Linux::Event 0.116,
  HTTP::CookieJar 0.014, Uniform::HTTP::Auth 0.02, and URI;
- verify public modules are present in META `provides` and private helper
  packages remain `no_index`;
- verify MANIFEST contains the public modules, tests, native source, vendored
  picohttpparser license/source, documentation, and advertised benchmark
  backends.

Final release-prep branch gate: GitHub Actions run `35551331335`.

- Perl 5.36: PASS;
- latest Perl: PASS;
- latest threaded Perl: PASS;
- full current suite: 41 files / 1,029 tests;
- exact pre-native baseline: PASS (40 files / 1,015 tests);
- end-to-end benchmark smoke: PASS;
- transaction-lifecycle diagnostic smoke: PASS;
- distribution integrity / `make disttest`: PASS;
- disttest explicitly built and tested `Linux-Event-HTTP-0.002`.

Latest-Perl same-run production-native medians from the release-prep gate:

- GET / 32-byte response: 31,133.8 -> 33,842.8 req/s (+8.7%);
- GET / 16 KiB response: 23,032.8 -> 26,717.6 req/s (+16.0%);
- POST / 4 KiB request, 32-byte response:
  19,051.8 -> 20,186.5 req/s (+6.0%).

The 0.002 repository state is therefore release-ready from the HTTP code,
metadata, test, disttest, and native-input regression perspectives.

The release-prep branch has been squash-merged to main.

Release 0.002 is now stamped `2026-09-20` in Changes at commit
`3f18be8c1677f9e2704dcf718d3071a9e19359ad`.

Remaining steps:

1. confirm Linux::Event 0.116 is publicly resolvable from CPAN before uploading HTTP 0.002;
2. run the final stamped-tree CI gate;
3. the user can then run `make dist` and upload `Linux-Event-HTTP-0.002.tar.gz`;
4. after upload, tag `v0.002` and create the GitHub release if desired.

## Release summary draft

Linux::Event::HTTP 0.002 moves the production HTTP/1 server input path onto
Linux::Event's native ordered-byte consumer ABI. Request heads, Content-Length
bodies, and chunked bodies now remain native through their normal parsing and
framing paths, avoiding the old Perl `on_data` handoff. Upgrade and CONNECT
retain same-read bytes across live protocol transitions. The release also
includes HTTP server lifecycle optimizations and a threaded-Perl native Response
context fix while preserving the public Request/Response/Transaction and server
callback APIs.
