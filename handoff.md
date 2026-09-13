# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Current main baseline: `8a39aa272d99a9303ac38eb7bb32f3fc371dc244`
- That baseline is the merge of PR #29, client Uniform authentication integration.
- Active branch: `feature/uniform-message-contract`
- Draft PR: #30, `Conform native HTTP messages to Uniform 0.02 contract`
- Do not merge PR #30 without explicit user authorization.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

## Uniform message contract work

The current branch makes `Linux::Event::HTTP::Request` and
`Linux::Event::HTTP::Response` conform by behavior to the Uniform::HTTP 0.02
message contract without replacing the native/live classes and without adding
inheritance.

Public message behavior now includes:

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

## Authentication simplification

PR #29 is already merged. The dependency is now:

- distribution/repository: `haxmeister/perl-Uniform-HTTP`
- module: `Uniform::HTTP::Auth 0.02`

`Linux::Event::HTTP::_ClientAuth` now passes the actual
`Linux::Event::HTTP::Request` message to Uniform 0.02 instead of reconstructing
method/request-target/entity-body arguments. Bodyless Requests still provide an
explicit empty entity body where needed; streaming producers remain outside the
message buffer and remain non-replayable.

Uniform owns authentication mechanics. Linux::Event::HTTP owns 401/407 receipt,
protection-space selection, replayability, response draining, connection reuse,
retry Transactions, and callback/Operation lifecycle.

## Validation

Executable conformance head:

`c4530551081fce199cca57b02fd31a1243ef8086`

passed CI #424 / run `34784790047` across the complete repository matrix.

Focused coverage includes:

- updated Request/Response tests for the arrayref `header_values` contract;
- exact replacement/order semantics;
- body-buffer capability distinction;
- mutability/lossless capability reporting;
- Response 100..599 status validation;
- `t/79-uniform-message-contract.t`, including an XS-parsed native Request.

Documentation cleanup after that green executable head has begun. Client policy
has been updated for Uniform 0.02 and the direct native Request integration. The
branch head moved beyond the executable checkpoint for documentation, so run CI
again on the final documentation-complete head before marking PR #30 ready.

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

## Next actions

1. Finish README / architecture / Changes wording for Uniform message conformance
   and remove stale Uniform 0.01 references.
2. Update PR #30 body with the final documentation scope and CI checkpoints.
3. Run CI on the final branch head.
4. If fully green, mark PR #30 ready for review but do not merge without explicit
   user authorization.
5. After merge, perform the planned 0.001 release-readiness audit rather than
   automatically adding another protocol-policy subsystem.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when supported
by available tooling. Do not reuse old merged feature refs for new work.
