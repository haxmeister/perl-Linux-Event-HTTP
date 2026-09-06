# picohttpparser experiment

This branch evaluates vendored picohttpparser as the native HTTP/1 request-head parser for Linux::Event::Net::HTTP.

## Upstream

The experiment vendors picohttpparser from:

- project: h2o/picohttpparser
- commit: `f4d94b48b31e0abae029ebeafcfd9ca0680ede58`
- upstream commit date: 2026-04-06

The vendored `picohttpparser.c` and `picohttpparser.h` are unmodified copies of that revision. `vendor/picohttpparser/UPSTREAM` records provenance and `vendor/picohttpparser/LICENSE` retains the upstream license.

The distribution must never download picohttpparser while configuring, building, testing, installing, or running.

## Experiment boundary

`Linux::Event::Net::HTTP::_Parser::HTTP1` is private. The experiment does not establish a public parser API.

The XS wrapper uses picohttpparser to identify the request method, request target, HTTP/1 minor version, and header name/value spans. Successful parsing returns offsets and lengths into the original Perl input scalar rather than copying those strings during parsing.

`probe_request` exposes the lowest-overhead parse path for benchmarking and connection-state experiments. `parse_request_offsets` measures the additional Perl allocation cost of exposing parsed spans.

## Strict HTTP policy

picohttpparser can report obsolete folded header lines as continuation entries. Linux::Event::Net::HTTP rejects those entries rather than accepting or normalizing `obs-fold`.

The wrapper also imposes an explicit maximum header count. The current experimental hard ceiling is 256, with a default parse limit of 100.

Protocol limits such as maximum request-head bytes and application-facing header limits belong to the Linux::Event HTTP layer rather than to vendored pico source.

## Evaluation criteria

Keep picohttpparser if it provides all of the following:

1. Correct incremental HTTP/1 request-head parsing for the server connection path.
2. Clean handling of malformed and incomplete input.
3. No build-time or runtime dependency on the upstream repository.
4. Meaningfully lower parsing cost than a Perl-level implementation.
5. A thin enough XS boundary that Linux::Event can retain control over request objects, limits, body handling, keep-alive, pipelining, and upgrade behavior.
6. No need to fork or materially modify the vendored parser for normal HTTP/1 operation.

If adopted, the public documentation should credit picohttpparser and state that the source is vendored so installations are self-contained.

## Benchmark

After building the distribution:

```sh
perl -Mblib bench/pico-parser.pl
```

The benchmark separates three costs:

- `pico_probe`: pico parsing without constructing parsed Perl structures.
- `pico_offsets`: parsing plus Perl arrays containing offsets and lengths.
- `pico_materialize`: offset parsing plus materializing method, target, header names, and values as Perl strings.

This separation is intended to show whether the significant cost is pico itself or the Perl representation chosen above it.
