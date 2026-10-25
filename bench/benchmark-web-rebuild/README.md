# Stage B: neutral Perl HTTP/1.1 peer comparison

This adapter is **benchmark-only** and uses the ordinary rebuilt
Linux::Event::HTTP Server public API. No production code or Unblock engine
is modified. Benchmark::Web's runner and other servers are unchanged.

A feature-branch-only GitHub Actions workflow checks out the fixed
Benchmark::Web main revision, builds legacy and rebuilt Linux::Event::HTTP
from their selected source revisions, and installs the selected external
Perl HTTP servers. The neutral shared raw client drives all processes.

Two profiles:
- Persistent HTTP/1.1 GET /bench, 32-byte response, 100 connections,
  no pipelining, 20,000 measured requests, 2,000 warmup, 5 repeats.
- Persistent HTTP/1.1 POST /bench with a 4 KiB request body, otherwise
  32-byte response, 100 connections, 10,000 measured requests, 1,000
  warmup, 3 repeats.

Servers: original Linux::Event::HTTP, rebuilt Linux::Event::HTTP,
Hyperman, Feersum, Mojolicious. Each uses one process and one application
execution slot, with default HTTP/1.1 keep-alive and no TLS. Request
bodies are completely received before replies. The runner rotates
server order, reports median throughput and p50/p95/p99 client-visible
latency, and preserves full JSON results for later comparisons.
Smoke runs prove correctness before measurement.

Results from hosted GitHub runners are exploratory, not a promise about
a dedicated deployment host. Absolute numbers may differ even if the
comparison is fair. Match the workload and the runner before drawing
relative conclusions; do not compare numbers from external sites with
these measured values.

The shared runner is fetched unchanged from
https://github.com/haxmeister/perl-Benchmark-Web.
This adapter's `server.pl` and `rebuilt-http.pl` are copied to the
shared runner's `servers/linuxevent-rebuild/` directory at workflow
execution. The original LinuxEvent launcher points via its public
`source-root` mechanism to the compiled legacy baseline.
