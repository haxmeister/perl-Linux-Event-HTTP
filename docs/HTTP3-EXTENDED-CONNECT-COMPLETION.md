# Unblock::HTTP3 CONNECT completion recheck defect

Status: RESOLVED; the fix is published in Unblock::HTTP3 0.14.
The account below preserves the original feature-branch investigation.
Unblock::HTTP3 is READ-ONLY under the current authorization. Do not edit
its source without explicit permission for its own feature branch.

## Verified resolution — 2026-10-25

The suspected ordering race was confirmed. In Unblock::HTTP3
feature/connect-completion-recheck, commit
b0585f6083c91a7bdfea0ddbccfefea76ab92362, an outgoing
Body::Stream->complete() tells its owning Transaction to recheck
the existing Connection completion predicate AFTER the body writer
complete bit becomes true.

Standalone real QUIC regression t/28-connect-completion.t verifies
the response and reader can finish before request FIN and ensures
on_complete/on_finish fire synchronously and once after Client
writer finalization. Standalone CI 40152896247 PASS in four Perl
lanes (5.20, 5.28, 5.36, 5.44).

The original mandatory downstream t/rebuild/102-websocket-multiplex.t
now PASSES with BOTH native and Perl input paths. Full root CI
40152960105 PASS all seven Perl jobs with H3 feature source installed
after CPAN dependencies. The resolved Client WebSocket Close path
finishes normally instead of expiring by timeout. At that checkpoint the fix remained on an authorized feature branch.
It has since been included in the published 0.14 release.

The remainder of this document records the original failure and
candidate analysis for engineering context.

## Exact reproduction

Root: feature/unblock-http-rebuild
Test: t/rebuild/102-websocket-multiplex.t
CI: https://github.com/haxmeister/perl-Linux-Event-HTTP/actions/runs/40150770545
Versions tested: Unblock::HTTP3 0.13; Net::QUIC 0.06; upper Unblock::HTTP
feature/linux-event-integration; actual QUIC/TLS, not a mock.

The test opens an HTTP3 Extended CONNECT WebSocket and an ordinary H3
sibling on one QUIC connection. Both deliver valid responses; the
WebSocket echo and bidirectional Close frames succeed; the Server's
Unblock::HTTP3::Transaction reaches complete. The Client's WebSocket
operation instead times out after 5 seconds. H2 equivalent passes.

A one-second pre-timeout snapshot establishes that Client H3 transaction
state is still active even though ALL completion prerequisites hold:

    callback_depth                         0
    response->is_complete                 1
    incoming response reader is_complete  1
    outgoing request writer is_complete   1
    output_finished                       1
    stream_lifecycle.closed_seen          1
    WebSocket close_sent/received         1 / 1

The Client's WebSocket bridge recorded transport_finished=1 and
transport_blocked=0. Delaying the WebSocket Close initiation to the
next Linux::Event defer() turn does NOT resolve the regression.
Five-second timeout cancellation is not a successful close.

## Likely underlying ordering race

In read-only Unblock::HTTP3 0.13:

- lib/Unblock/HTTP3/Body/Stream.pm, complete(): invokes
  $transaction->_write_body($kind, $bytes, 1, ...), THEN sets
  $self->{complete} = 1.
- lib/Unblock/HTTP3/Connection.pm, _write_transaction_body():
  calls _maybe_complete_transaction($id) while the outgoing writer's
  is_complete is still false. A concurrently received response may
  have completed earlier. No further packet/event is guaranteed
  to invoke _maybe_complete_transaction() once Body::Stream::complete
  flips the final writer flag.
- Connection::_maybe_complete_transaction() correctly checks that
  the H3 Client has a complete response, completed incoming reader,
  and (for CONNECT) a completed outgoing request writer. It cannot
  complete the transaction until invoked again after those flags
  become true.

The observed state strongly indicates this missing recheck; the
candidate implementation has NOT been applied or tested.

## Candidate fix, ONLY after H3 repo authorization

Add a post-writer-complete lifecycle notification in Unblock::HTTP3,
e.g. Body::Stream::complete calls an internal Transaction method
_after the final complete=1 mutation_. The Transaction method should
ask its owning Connection to re-run _maybe_complete_transaction for
this stream, respecting existing callback depth, terminal state,
and connection lifetime protections. Do not call private engine methods
from the Linux::Event adapter or upper Unblock layer as a workaround.

Add a regression to Unblock::HTTP3 with the response reader reaching
complete BEFORE the CONNECT request writer finishes; then verify
exactly one completion after request FIN without needing an unrelated
UDP packet/timer, plus no cross-stream regressions.
Re-test Linux::Event::HTTP t/rebuild/102 in both native/Perl input
modes and all existing real-QUIC lifecycle tests.

## Constraints

- Do NOT change Unblock::HTTP3, Net::QUIC, or Linux::Event core now.
- Do NOT silence the required failing Stage E H3 regression.
- Existing Stage D ordinary HTTP3 tests remain verified green.
- Main branches, tags, versions, and releases require their separate
  permissions and process.
