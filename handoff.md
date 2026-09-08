# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Working branch: `feature/response-body-stream`
- Draft PR: #16
- Base branch: `main`
- Main baseline for PR #16: `aff0249bb151371b1297d5efda50d8bfd4d711e7`
- Validated feature head before this handoff-only commit: `85d8ed654c38b394827782237d32b55da9389a62`
- CI run `34181760630` on that head: success
- DO NOT merge PR #16 without explicit user authorization.

The Response body API design has now been accepted and the no-compat migration has been completed on the feature branch.

## Final public Response body model

The conceptual split is:

```text
Response     = HTTP response message
Body::Stream = streaming body producer
```

Ordinary complete scalar response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->body("hello\n");
};
```

Streaming response:

```perl
on_request => sub ($conn, $req, $res) {
    $res->header('Content-Type', 'text/plain');

    my $body = $res->stream_body(
        on_drain => sub ($body) {
            # Resume a paused upstream producer.
        },
        on_cancel => sub ($body) {
            # Stop upstream work because this HTTP connection
            # abandoned the unfinished streaming body.
        },
    );

    $body->write("one\n");
    $body->complete("two\n");
};
```

Public Response-level `write` and `complete` have been removed. Do not restore them as compatibility aliases. This distribution is unreleased and we do not want compatibility cruft.

Current intended Response surface includes:

```text
status
reason
header
add_header
header_values
body
stream_body
upgrade
connection
request
is_started
is_complete
is_upgrading
```

Current Body::Stream surface:

```text
write
complete
is_complete
is_cancelled
```

## Scalar body commit semantics

The semantic question from the earlier prototype is settled as follows.

`$res->body($bytes)` declares a complete scalar response body.

When `body(...)` is called while an HTTP callback is executing, it does NOT serialize immediately in the middle of that callback. The Response remains configurable until the enclosing HTTP callback returns. Therefore this is intentionally valid:

```perl
$res->body("hello\n");
$res->header('X-After-Body', 'yes');
```

After the callback returns, the connection commits the complete response if the transaction is ready.

When `body(...)` is called later from an asynchronous event callback while a Response is waiting and no HTTP callback dispatch is active, it commits the waiting complete response immediately.

This distinction is intentional and is covered by integration tests.

## Streaming commit semantics

`stream_body()` itself does NOT commit response headers and does NOT start output.

It lazily creates one stable Body::Stream object. Repeated argumentless calls return the same object.

Response metadata may still be changed after selecting the stream:

```perl
my $body = $res->stream_body;
$res->header('X-Late-But-Before-Output', 'yes');
```

The first Body::Stream `write(...)` or `complete(...)` is the streaming response commit point. That first actual body output starts the Response and freezes status/reason/headers.

This behavior is now explicitly tested.

Scalar `body(...)` and streaming `stream_body(...)` are mutually exclusive.

## Output and backpressure rule

DO NOT add another HTTP response-body output queue.

Body::Stream is a protocol-facing producer over Linux::Event's existing ordered-byte output machinery. Linux::Event remains the owner of:

- queued transport bytes
- segmented output
- high/low watermarks
- `pending_bytes`
- write readiness
- `on_drain`
- `max_pending_bytes`
- TLS transport progress

`Body::Stream->write(...)` preserves Linux::Event flow control:

```text
true  = bytes accepted and producer may continue
false = bytes accepted, but producer should stop until on_drain
```

HTTP framing is applied before those bytes enter the existing transport machinery. There is no second body queue.

`on_cancel` means the HTTP connection abandons/closes an unfinished streaming body.

## Connection lifecycle callback composition

HTTP needs transport drain/close notifications for Body::Stream bookkeeping, but custom Connection subclasses are a supported extension point.

The internal and application lifecycle work are composed:

```text
transport drain
    -> HTTP Body::Stream drain handling
    -> custom Connection on_drain, if any

transport close
    -> HTTP Body::Stream cancellation
    -> custom Connection on_close, if any
```

Commit `a52d8a03292d5edf9ff38dbc207612d2b86186ec` added explicit integration coverage for close callback composition.

CI run `34180170242` on `a52d8a0...` was fully green before the final API migration.

## Finalization commits and CI history

The repository-wide no-compat API migration was committed as:

```text
dab163d50080b017f20268888f85fca4a3bbb154
Finalize Response body and streaming API
```

That commit:

- removed public Response `write` and `complete`;
- retained `write`/`complete` only on Body::Stream;
- locked scalar callback-return commit semantics;
- locked stream selection as non-committing;
- locked first stream write/complete as the streaming commit point;
- converted existing tests to the new API;
- converted Linux::Event HTTP benchmark adapters to the new API;
- updated README, Response/Server POD, architecture docs, benchmarking docs, and Changes;
- bumped the transaction-ladder benchmark contract from 5 to 6 because the public scalar completion point changed from an in-callback `complete()` call to callback-return commit after `body()` assignment.

Its first CI run was:

```text
34181577506
```

That run failed for one stale API-presence assertion in `t/00-load.t`:

```text
Failed test 'Response exposes complete'
```

Importantly, every substantive test file in that run passed, including the new scalar/streaming integration tests. The failure was only the old load test still expecting the transitional method.

The stale assertion was fixed in:

```text
85d8ed654c38b394827782237d32b55da9389a62
Update Response API load assertions
```

`t/00-load.t` now asserts that Response exposes `body` and `stream_body`, does not expose `write` or `complete`, and still exposes `is_complete` while omitting ambiguous `end` / `is_ended` aliases.

CI run `34181760630` on `85d8ed65...` completed successfully:

- Perl 5.36: success
- latest Perl: success
- latest threaded Perl: success
- end-to-end benchmark smoke: success
- distribution integrity/disttest: success
- cross-server diagnostic comparison: intentionally skipped in normal CI

This is the current validated API state.

## Tests that now define the body API

Important focused tests:

```text
t/21-response-body-stream-unit.t
t/34-response-body-stream.t
```

Coverage includes:

- scalar body get/set and replacement before output
- body/stream mutual exclusion
- Response does not expose streaming `write` or `complete`
- stable stream object identity
- stream option validation
- stream write delegation without a second queue
- Linux::Event flow-control false propagation
- one-shot drain notification after blocked output
- stream completion
- post-completion rejection
- cancellation and idempotent cancellation
- post-cancellation rejection
- scalar body metadata changes after body assignment but before callback return
- asynchronous later scalar body completion
- `stream_body()` does not start output
- metadata remains mutable after stream selection
- first stream write starts output
- metadata locks after first stream write
- HTTP/1.1 chunk framing
- persistent/pipelined ordering
- custom Connection lifecycle callback composition

## Documentation and benchmark status

README, Response POD, Server POD, `docs/ARCHITECTURE.md`, `docs/BENCHMARKING.md`, Changes, tests, and Linux::Event benchmark adapters were migrated to the body/stream model in `dab163d5...`.

Do not reintroduce Response-level `write`/`complete` examples.

The transaction benchmark still has a stage identifier named `complete`. That is a historical benchmark stage name, not a public Response method. Its callback now uses `Response->body(...)`. The benchmark contract version is 6.

## Linux::Event core follow-up

A separate generic Linux::Event behavior was discovered while testing body cancellation.

HTTP pauses application reads while a completed request waits for a later asynchronous response. This prevents a pipelined request from overtaking the active response.

Linux::Event still receives terminal readiness such as:

```text
EPOLLERR
EPOLLHUP
EPOLLRDHUP
```

but `_ByteStream::_on_read_terminal_ready` currently only enters the read path when `read_paused` is false. Immediate peer EOF/half-close observation can therefore be delayed while application reads are paused.

Do NOT solve this in HTTP with polling, duplicate buffering, or another HTTP queue.

If immediate peer terminal observability while application payload reads are paused is desired, investigate it separately as a reusable Linux::Event core socket/reactor capability with correct unread-data and TLS semantics.

For the HTTP API, `on_cancel` is deterministic when the HTTP connection itself closes/abandons the unfinished body.

## Charter and architecture rules

Linux::Event is the Linux-native communications engine. Reusable low-level performance work belongs in Linux::Event core so multiple protocol layers can benefit.

Linux::Event::HTTP is the HTTP protocol layer. Priorities remain:

1. correctness
2. ease of correct use
3. coherent/simple API
4. maintainability
5. composability
6. performance without HTTP-specific native complexity unless justified

Do not add:

- PSGI
- PAGI
- routing/framework responsibilities
- middleware
- sessions
- templates

There is no planned PSGI layer in this distribution.

Prefer established CPAN/community libraries for standards/utilities where appropriate.

Do not add HTTP-specific XS merely to win benchmarks.

## Native HTTP implementation

Keep one private native extension:

```text
xshttp1/HTTP1.xs
    -> Linux::Event::HTTP::_HTTP1.so
```

It owns:

- pico request parser / lazy Request accessors
- chunked request decoding
- response-head serialization
- narrow default scalar final-response builder

Do not split it back into multiple HTTP native extensions without a new measured reason.

Eligible ordinary `Response->body(...)` responses transparently use the private scalar fast path. Applications do not select a separate performance API.

## Upgrade boundary

HTTP Upgrade remains:

1. validate HTTP/1.1 Upgrade
2. queue valid 101
3. clear HTTP transaction
4. use Linux::Event `transition_to()` on the same live transport object

WebSocket belongs in a separate `Linux::Event::WebSocket` distribution.

## Branch policy

PR #16 remains a draft and MUST NOT be merged without explicit user authorization.

Do not keep merged or abandoned branches merely as history. Delete them after merge/abandon unless they contain unique work with a concrete reason to preserve it.

Do not accidentally add optional benchmark competitors as dependencies.

Do not reopen closed native-performance experiments without a new measured hypothesis.

## Immediate next steps

1. Review the final PR diff for accidental stale Response `write`/`complete` documentation or call sites; distinguish the transaction-ladder stage name `complete` from the removed public method.
2. Keep PR #16 draft/unmerged until the user explicitly authorizes merge.
3. If further HTTP API review finds no issue, the response body redesign is ready for user review rather than another compatibility pass.
4. Separately investigate Linux::Event terminal-readiness behavior while application reads are paused if desired; do not make HTTP own that solution.
5. Keep this handoff current after every major test or conclusion.
