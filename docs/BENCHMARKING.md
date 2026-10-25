# Linux::Event::HTTP benchmarking (Unblock rebuild)

The approved rebuild treats correctness and HTTP1 throughput as release
gates. Never compare standalone measurements from different machines as
if they were an A/B performance result.

## Rebuilt end-to-end benchmark

After `perl Makefile.PL && make`, run:

```sh
perl -Mblib bench/run-unblock-end-to-end.pl \
    --requests 10000 --warmup 1000 --connections 100 \
    --pipeline 1 --response-bytes 32 --repeats 2
```

The same harness accepts `--no-native-input` to compare the Perl path.
For historical performance, compare with the untouched
`main` baseline at the same time on the same CI runner using the
equivalent `bench/run-http-end-to-end.pl` from that baseline checkout.
The rebuild CI performs a legacy/rebuild/rebuild/legacy sequence.

The new client benchmark is `bench/run-rebuild-client.pl`.
`bench/run-unblock-engine.pl` isolates the protocol engine without
TCP socket costs; `bench/run-unblock-retention.pl` examines retained
memory during server/client request workloads.

## Independent Perl HTTP server comparison

For a peer baseline, the development workflow
`.github/workflows/http1-peer-benchmark.yml` uses the unchanged shared
client from [Benchmark::Web](https://github.com/haxmeister/perl-Benchmark-Web)
(revision `ceb8b2f9c4cd0764441844dd91dacc1240ebc4c7`).
It compares the rebuilt Server's normal public API (a fresh Uniform
response for each request) against the original Linux::Event::HTTP,
Feersum, Hyperman and Mojolicious. No Unblock engines were modified.

Validated 2026-10-25 on one GitHub-hosted Ubuntu runner:
https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40211468264

All servers used one process and one application execution slot,
100 persistent HTTP/1.1 loopback connections, pipeline depth 1,
a 32-byte HTTP 200 response body, a shared raw Perl client, and
rotated target order. GET: 20,000 measured, 2,000 warmup, 5 repeats;
POST: 4,096-byte complete body, 10,000 measured, 1,000 warmup,
3 repeats. The table shows the median requests per second:

| Server | GET /bench | POST /bench, 4 KiB |
| --- | ---: | ---: |
| Hyperman | 111,289 | 67,543 |
| Feersum | 108,622 | 99,643 |
| Original Linux::Event::HTTP | 40,413 | 34,617 |
| Linux::Event::HTTP (Unblock rebuild) | 9,666 | 7,991 |
| Mojolicious | 2,483 | 2,334 |

This is a comparative protocol-stack workload, not identical
application-level processing across frameworks. The rebuild passes
canonical Uniform messages through a generic transaction lifecycle;
other adapters use their normal documented APIs. The result identifies
a meaningful throughput gap against the faster Perl servers but does
not, on its own, establish a defect in the Unblock::HTTP1 engine or
justify rewriting the shared architecture.

These absolute numbers apply to that hosted runner only. Do not
treat them as deployment capacity or cross-machine rankings. The
complete JSON records and latency percentiles are preserved in the
GitHub Actions artifact `stage-b-http1-perl-peers`. Historical
`bench/results/` JSON files are retained in Git but deliberately
excluded from the CPAN source archive. The benchmark-only adapter
also remains in Git, not in the shipped distribution.

## Cost-boundary diagnostics

```sh
perl -Mblib bench/run-unblock-cost-breakdown.pl \
    --iterations 12000 --rounds 3
```

This measures canonical Uniform::HTTP::Response construction, wire-plan
work, direct Unblock::HTTP1 and the upper Unblock facade under matched
conditions. The temporary
`--diagnostic-prebuilt-response` option of the end-to-end harness
uses a single frozen canonical Response **only to bound constructor cost**.
It is not a production caching recommendation; engines must not reuse or
mutate application responses behind callers.

Recorded evidence in Git (not shipped in the source archive):
`bench/results/unblock-stage-b/20261025-cost-boundary.json`
and `bench/results/unblock-stage-b/20261025-bodyless.json`,
plus the active status and handoff documents.
In the paired runs so far, the upper Unblock facade added no meaningful
per-request penalty versus direct HTTP1. Native input outperformed the
Perl bridge, but the rebuilt real-socket throughput remained well below
the legacy baseline, so Stage B is **not passed**.

HTTP/2 h2spec results are tracked separately; baseline parity is not a
conformance pass. HTTP/3 QUIC/TLS, WebSocket and generic CONNECT regressions
are required correctness checks, not substitutes for the throughput gate.
