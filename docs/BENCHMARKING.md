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

Recorded evidence:
`bench/results/unblock-stage-b/20261025-cost-boundary.json`,
`20261025-bodyless.json` and the active status/handoff documents.
In the paired runs so far, the upper Unblock facade added no meaningful
per-request penalty versus direct HTTP1. Native input outperformed the
Perl bridge, but the rebuilt real-socket throughput remained well below
the legacy baseline, so Stage B is **not passed**.

HTTP/2 h2spec results are tracked separately; baseline parity is not a
conformance pass. HTTP/3 QUIC/TLS, WebSocket and generic CONNECT regressions
are required correctness checks, not substitutes for the throughput gate.
