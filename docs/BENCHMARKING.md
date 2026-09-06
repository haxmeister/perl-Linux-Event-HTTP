# Linux::Event::Net::HTTP benchmarking

The distribution keeps parser microbenchmarks and full HTTP transaction
benchmarks separate. The parser benchmark answers questions about pico and the
native Request representation. The end-to-end harness measures the combined
cost of TCP accept/read/write, HTTP parsing, Request/Response lifecycle,
application callback dispatch, response serialization, persistence, and the
client-visible round trip.

## End-to-end harness

Run from a built checkout:

```sh
perl -Mblib bench/run-http-end-to-end.pl
```

The harness forks the Linux::Event HTTP server into a separate process and runs
the load generator in the parent. This avoids putting the client and server on
the same event loop or in the same Perl interpreter.

Defaults:

```text
measured requests:    20000
warmup requests:       2000
connections:            100
pipeline depth:            1
request body bytes:         0
response body bytes:       32
repeats:                    5
```

Each repeat starts a fresh server process. Connections stay persistent through
warmup and measurement. The server returns a fixed scalar response with
Content-Length so the default result measures the ordinary HTTP/1.1 request and
Response->end path rather than chunked response framing.

Useful variations:

```sh
# Higher concurrency
perl -Mblib bench/run-http-end-to-end.pl \
  --requests=100000 --warmup=10000 --connections=500

# HTTP/1.1 pipelining
perl -Mblib bench/run-http-end-to-end.pl \
  --requests=100000 --connections=100 --pipeline=16

# Request-body path
perl -Mblib bench/run-http-end-to-end.pl \
  --requests=50000 --connections=100 --request-body-bytes=4096

# Larger scalar response
perl -Mblib bench/run-http-end-to-end.pl \
  --requests=50000 --connections=100 --response-bytes=65536
```

The text result reports requests/second, p50/p95/p99/max client-visible latency,
and server process CPU microseconds per request. `--json=PATH` writes the full
configuration, environment, per-repeat records, medians, and Linux::Event loop
statistics.

## Profiling

Normal benchmark runs leave Linux::Event native nanosecond timing disabled so
measurement overhead does not contaminate the throughput baseline. Cheap loop
counters are still recorded.

Use a separate profiling run when event-loop timing is needed:

```sh
perl -Mblib bench/run-http-end-to-end.pl \
  --requests=50000 --connections=100 --profile \
  --json=bench/results/http-profile.json
```

`--profile` enables `$loop->profile(1)` in the server process. Compare profiling
runs only with other profiling runs.

## CI smoke mode

```sh
perl -Mblib bench/run-http-end-to-end.pl --smoke
```

Smoke mode uses a tiny workload and exists only to verify that the harness can
start the server, maintain persistent connections, pipeline requests, parse
responses, collect latency, and receive final server statistics. GitHub-hosted
runner throughput must not be used as a release performance claim.

## Measurement discipline

For publishable numbers:

- use a stable local machine or dedicated runner;
- record CPU model, kernel, Perl version, Linux::Event version, and HTTP version;
- pin or otherwise control CPU placement when comparing small differences;
- run multiple repeats and report medians;
- keep request/response sizes, connection count, and pipeline depth identical;
- compare non-profiled runs with non-profiled runs;
- avoid running unrelated CPU- or network-heavy work at the same time;
- retain the JSON report with the benchmark conclusion.

A single parser microbenchmark number is not a server throughput number, and a
single end-to-end throughput number does not identify where CPU time is spent.
Use the parser benchmark, the end-to-end harness, and Linux::Event profiling as
three separate views of the stack.
