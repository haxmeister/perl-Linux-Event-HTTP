# Linux::Event::Net::HTTP benchmarking handoff

Updated: 2026-09-06 (America/Chicago)

## Repository / branch

- Repo: `haxmeister/perl-Linux-Event-Net-HTTP`
- Current branch: `experiment/native-final-response`
- Branch head before this handoff commit: `aa8f991d233202b420babaa29e57e96ae234e041`
- Draft PR: #13, `Experiment: native default final-response fast path`
- Base branch: `feature/http-comparison-benchmarks`
- DO NOT merge PR #13 or PR #11 without explicit authorization.

## Strategic goals

1. Keep Linux::Event::Net::HTTP among the highest-performance servers in the ecosystem.
2. Minimize long-term C/XS maintenance burden across the entire Linux::Event ecosystem.
3. Do not add new XS/C unless benchmarks demonstrate it is materially necessary.
4. Consolidate native code where practical; logical Perl module boundaries do not require separate native extensions.

## Current experiment

We are measuring where the remaining full HTTP transaction cost lives after introducing the native default final-response fast path.

The latest commit before this file was:

- `aa8f991` - `Benchmark fused HTTP callback dispatch`

That commit adds a `fused` transaction-ladder stage and a corresponding hot-path benchmark. Instead of invoking the two HTTP callbacks through two separate `_invoke_http_callback` calls, the fused stage executes both callbacks under one localized `_http_dispatching` flag and one `eval` boundary.

Files changed by that experiment:

- `bench/run-http-hotpath.pl`
- `bench/run-http-transaction-ladder.pl`
- `bench/servers/linuxevent-transaction-stage.pl`

The transaction ladder is now:

- parse
- bound
- state
- callbacks
- fused
- eligibility
- build
- mark
- commit
- end
- full HTTP

The benchmark contract version for the transaction ladder is now 3.

## Immediate next work

1. Run the hot-path benchmark and transaction lifecycle ladder with the new `fused` stage.
2. Compare `callbacks -> fused` to quantify the cost of the second callback dispatch wrapper / second eval boundary.
3. Compare `fused -> eligibility -> build -> mark -> commit -> end -> http` to identify the largest remaining gap.
4. Only after measurement, decide whether any production callback-dispatch fusion is justified.
5. Run the cross-server HTTP comparison again after any production-worthy optimization to see whether it materially changes competitive position.

## Important architecture constraint

Do not turn benchmark-only fusion into production behavior merely because it is faster. Preserve callback/error semantics unless a production design can keep the same externally observable behavior. The purpose of the fused stage is first to isolate cost.

## Handoff policy

After each meaningful benchmark, implementation experiment, or conclusion, update this file immediately with:

- command / benchmark configuration
- relevant throughput / latency results
- comparison deltas
- conclusion
- next action

This file exists so another chat can continue without reconstructing the entire conversation if the current session stops.
