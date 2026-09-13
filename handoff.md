# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Current main baseline: `8070e6a182c11768904c6dd02330253a6b4ac1d6`
- That baseline is the merge of PR #30, native Uniform::HTTP 0.02 message-contract conformance.
- PR #29, client Uniform authentication integration, is also merged.
- No active feature branch is required for the current baseline.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

## Uniform message contract

`Linux::Event::HTTP::Request` and `Linux::Event::HTTP::Response` now conform by
behavior to the Uniform::HTTP 0.02 message contract without replacing the
native/live classes and without adding inheritance.

Public message behavior includes:

- `header_values($name)` always returns an array reference, including an empty
  array reference when the field is absent;
- `header($name,$value)` replaces all matching occurrences while retaining the
  first occurrence position and using the caller-supplied field spelling;
- `header_name($index)` / `header_value($index)` return undef beyond the end and
  reject invalid indexes;
- `has_buffered_body`, `is_mutable`, and `headers_are_lossless` capability
  methods on both message types;
- `target_is_exact` on Request;
- no buffered body is distinct from an explicitly buffered empty body;
- body setters require defined byte strings;
- message version may be explicitly cleared to undef;
- Response status is constrained to 100..599;
- Response metadata/body setters consistently enforce the byte-string contract.

Parsed native server Requests remain lazy XS-backed objects. They report
`is_mutable == 0`, preserve exact header spelling/order/duplicates, and expose
the same public Uniform-compatible methods. The native XSUB list behavior is
kept behind the private `_header_values_list` path for HTTP executor hot paths.

Request/Response remain transport-independent. Connection, Transaction,
streaming body producer, retry, pool, Upgrade, and CONNECT state stay outside
message objects.

## Uniform authentication

Authentication mechanics are supplied by the `Uniform-HTTP` distribution:

- repository: `haxmeister/perl-Uniform-HTTP`
- module: `Uniform::HTTP::Auth 0.02`

`Linux::Event::HTTP::_ClientAuth` passes the actual
`Linux::Event::HTTP::Request` message to Uniform 0.02 instead of reconstructing
method/request-target/entity-body arguments. Bodyless Requests still provide an
explicit empty entity body where needed; streaming producers remain outside the
message buffer and remain non-replayable.

Uniform owns authentication mechanics. Linux::Event::HTTP owns 401/407 receipt,
protection-space selection, replayability, response draining, connection reuse,
retry Transactions, and callback/Operation lifecycle.

## Validation

PR #30 exact final head
`59d900f4ccaa5aa23ca3866d1b8a704587d7ce3c` passed CI #427 / run
`34788358803` across Perl 5.36, latest, and latest threaded. Latest also passed
end-to-end smoke and distribution integrity.

Earlier checkpoints also passed:

- executable conformance head `c4530551081fce199cca57b02fd31a1243ef8086`:
  CI #424 / run `34784790047`;
- documentation-aligned head `38f72adc488f99802718968c6515f8ee6d398b9b`:
  CI #426 / run `34788300925`.

Focused coverage includes:

- updated Request/Response tests for the arrayref `header_values` contract;
- exact replacement/order semantics;
- body-buffer capability distinction;
- mutability/lossless capability reporting;
- Response 100..599 status validation;
- `t/79-uniform-message-contract.t`, including an XS-parsed native Request.

## Design constraints that remain fixed

- Do not replace Request/Response with Uniform classes.
- Do not add inheritance solely for Uniform interoperability; behavioral
  conformance is the contract.
- Do not add Uniform-specific state to the HTTP message objects.
- Do not convert native parsed Requests into Perl adapter objects.
- Keep HTTP executor list-oriented header access private so the public arrayref
  contract does not force avoidable hot-path allocation.
- Do not modify Linux::Event core from this Project unless explicitly requested.
- Do not add CONNECT relay/proxy bridging to Transaction.

## Next action

Perform the planned `0.001` release-readiness audit. In particular, reconcile
remaining historical/release-note wording such as stale Uniform 0.01 references,
review README/POD/docs against the actual public API, confirm MANIFEST and
`disttest`, and verify that no unreleased experimental wording or stale branch
references remain before setting the release version/date.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when supported
by available tooling. Do not reuse old merged feature refs for new work.
