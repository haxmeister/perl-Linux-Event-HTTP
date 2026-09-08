# Linux::Event::HTTP handoff

Updated: 2026-09-07 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Working branch: `feature/response-body-stream`
- Draft PR: #16, `Prototype Response body and stream_body API`
- Base branch: `main`
- Main baseline: `aff0249bb151371b1297d5efda50d8bfd4d711e7`
- Current code-bearing feature head: `9a24f4ff9499714a973626373977a026cced492a`
- DO NOT merge PR #16 without explicit user authorization.

The current experiment changes the conceptual Response model. The key statement that drove the design is:

> A Response can be a complete HTTP message whose body happens to be a stream.

The proposed application API is now:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');
    $res->body("hello\n");
};
```

and streaming output is:

```perl
on_request => sub ($conn, $req, $res) {
    $res->status(200);
    $res->header('Content-Type', 'text/plain');

    $res->stream_body(
        on_drain => sub ($body) {
            # Resume a paused producer.
        },
        on_cancel => sub ($body) {
            # Stop producer work because this HTTP connection abandoned
            # the unfinished streaming body.
        },
    );

    $res->stream_body->write("one\n");
    $res->stream_body->complete("two\n");
};
```

`Response` is no longer conceptually a writable socket/handle. Status, headers, and body selection belong on Response. `write` and streaming completion belong on the response's body stream.

## Current feature implementation

New module:

```text
Linux::Event::HTTP::Body::Stream
```

Applications normally do not construct it directly. The first call to:

```perl
$res->stream_body(
    on_drain  => sub ($body) { ... },
    on_cancel => sub ($body) { ... },
);
```

creates it lazily. Later argumentless calls return the same object:

```perl
$res->stream_body->write($bytes);
$res->stream_body->complete;
```

The current body-stream methods are:

```text
write
complete
is_complete
is_cancelled
```

`body($bytes)` and `stream_body(...)` are mutually exclusive.

The body stream deliberately has no independent byte queue. `write()` delegates through HTTP framing directly to the existing Linux::Event ordered-byte output destination. Its boolean return preserves Linux::Event's cooperative high-watermark contract: false means the bytes were accepted, but the producer should stop until `on_drain` runs.

`on_cancel` currently means the HTTP connection abandons/closes an unfinished body stream. Do not document it as an independently guaranteed immediate peer-disconnect detector while transport reads are paused; see the Linux::Event observation below.

## Linux::Event core investigation

The existing Linux::Event ordered-byte engine already supplies what HTTP needs for output-side streaming:

- immediate write fast path
- native segmented pending-output queue
- `pending_bytes`
- high/low-watermark cooperative backpressure
- `max_pending_bytes`
- `on_drain`
- write ordering and `writev` queue drain
- socket/TLS transport ownership

Therefore the first HTTP `Body::Stream` does NOT need a new core queue or an HTTP-local duplicate buffering layer.

The existing native consumer ABI is not the answer for response bodies. It is specifically an inbound framed-message extension boundary, primarily useful to integrations such as Linux::Event::Async, and deliberately is not a general queue/transport abstraction.

### Paused-read terminal observation found during testing

The cancellation test exposed a separate generic Linux::Event behavior worth evaluating later:

- HTTP pauses application reads while a completed request waits for an unfinished response so a later pipelined request cannot overtake it.
- `Linux::Event::_ByteStream::pause_read` disables read readiness.
- epoll terminal/error readiness remains wired, but `_on_read_terminal_ready` deliberately does not run the read path while `read_paused` is true.
- Consequently, immediate remote EOF/half-close observation can be delayed while reads are paused.

Do not solve this in HTTP by adding a second unbounded input/output queue. If immediate peer-shutdown observability while payload delivery is paused is important, investigate it as a reusable Linux::Event socket/reactor capability with correct unread-data and TLS semantics.

For the HTTP prototype, `on_cancel` is validated deterministically when the HTTP connection itself closes/aborts the unfinished body.

## Validation

First prototype commit:

```text
d59dfcf0536a2803ecbfdd5ee8678ca5a7283cad
Prototype Response body and stream_body API
```

The first PR CI run was `34179490937`. All existing tests and the new body-stream unit test passed, but the new end-to-end integration test failed because it called `refaddr` unqualified inside a test package where it had not been imported. That exception correctly produced an HTTP 500. The same run also demonstrated that a peer-close-only cancellation test can be delayed while HTTP has transport reads paused.

The test was corrected in:

```text
9a24f4ff9499714a973626373977a026cced492a
Fix body stream integration coverage
```

CI run `34179695220` on that head is fully green:

- Perl 5.36: success
- latest Perl: success
- latest threaded Perl: success
- new `t/21-response-body-stream-unit.t`: success
- new `t/34-response-body-stream.t`: success
- ordinary end-to-end benchmark smoke: success
- distribution integrity/disttest: success
- cross-server diagnostic comparison: intentionally skipped in normal CI

The new integration coverage proves:

1. a scalar `$res->body(...)` response is serialized correctly;
2. metadata set later in the same HTTP callback is retained before commit;
3. `stream_body` returns one stable object;
4. streaming output uses normal HTTP/1.1 chunk framing;
5. `stream_body->write` exposes the Linux::Event flow-control return;
6. `stream_body->complete` terminates the HTTP body correctly;
7. a scalar body supplied from a later timer callback can finish a waiting response in the current prototype;
8. closing an HTTP connection cancels an unfinished body stream exactly once.

The focused unit test also covers mutual exclusion, option validation, one-shot drain notification after a blocked interval, completion/cancellation state, and post-terminal write rejection.

## Important API status

The feature branch currently RETAINS the old public `Response->write` and `Response->complete` methods temporarily so the existing suite and benchmarks could validate the new mechanism before a full migration. They are marked transitional in the feature POD.

This is not intended as a compatibility promise. The distribution is unreleased and the standing ecosystem rule is to avoid compatibility cruft. Before merging this design, decide whether to finish the migration by:

- converting ordinary response sites to `$res->body($bytes)`;
- converting streaming sites to `$res->stream_body->write(...)` / `complete(...)`;
- removing public `Response->write` / `Response->complete`;
- updating README, POD, tests, Changes, and benchmark adapters accordingly.

One semantic point deserves deliberate review before that final removal: the current prototype lets a later asynchronous `$res->body($bytes)` act as the readiness/completion signal for a waiting scalar response. Inside an HTTP callback, commit is deferred until the callback returns so metadata may still be changed after `body()`. Outside an HTTP callback, `body()` commits immediately. This works and is tested, but the differing commit timing should be judged as API semantics before freezing it.

## Charter

Linux::Event is the Linux-native communications engine whose purpose is to make Perl good at speaking many protocols and bridging between them. Reusable low-level performance work belongs in Linux::Event core so multiple protocol layers can benefit.

Linux::Event::HTTP is an HTTP protocol distribution. Prioritize protocol correctness, ease of correct use, a simple API, maintainability, and composability over isolated benchmark wins.

Do not add routing, middleware, sessions, templates, PSGI/PAGI, or web-framework responsibilities here. There is no planned PSGI layer in this distribution.

Prefer established CPAN/community libraries for standards and utilities when suitable, but do not force generic HTTP message libraries into live wire state where they damage semantics or performance.

Do not add HTTP-specific XS merely to win a benchmark. First ask whether the expensive primitive is generic transport, buffer, framing, or write machinery that belongs in Linux::Event core.

## Public structure

Current server-side modules:

```text
Linux::Event::HTTP
Linux::Event::HTTP::Server
Linux::Event::HTTP::Server::Connection
Linux::Event::HTTP::Request
Linux::Event::HTTP::Response
Linux::Event::HTTP::Body::Stream   # feature branch prototype
```

Reserved future native client structure:

```text
Linux::Event::HTTP::Client
Linux::Event::HTTP::Client::Connection
```

The client is not implemented.

## Existing architecture that remains valid

- `Server::Connection` is a `Linux::Event::IO::Sock::Stream` subclass.
- Linux::Event owns socket/TLS transport, readiness, native ordered-byte queueing, backpressure, and protocol transition mechanics.
- HTTP owns request parsing, request-body HTTP framing, response serialization, persistence, pipelining/transaction order, and HTTP Upgrade validation.
- The distribution has one private HTTP native extension, `xshttp1/HTTP1.xs -> Linux::Event::HTTP::_HTTP1.so`, owning pico request parsing/lazy Request accessors, chunked request decoding, response-head serialization, and the narrow default scalar final-response builder.
- Upgrade uses Linux::Event `transition_to()` and preserves the live socket/TLS/output queue/deadlines/application data/pre-read bytes.
- WebSocket semantics belong in a separate distribution; HTTP owns only Upgrade.
- No PSGI/PAGI layer is planned here.

## Request API / CPAN audit

The prior CPAN audit remains useful, but its old conclusion that Response itself must be a live writable transaction is now superseded by this feature experiment.

Keep Linux::Event::HTTP's own Request because the native parser preserves wire distinctions and lazy head access that generic HTTP::Headers-family objects may normalize away. Do not replace native request header storage with an object that conflates legal names such as `X_Foo` and `X-Foo`.

Response is now being evaluated as an HTTP message object whose body is either a complete scalar or a streaming body object. This makes generic CPAN HTTP message interoperability more plausible at an application boundary, but does not justify putting HTTP::Message objects into the live native wire path.

## Closed performance experiments

Do not reopen without a new measured hypothesis:

- duplicated bodyless Perl driver: small gain, rejected
- HTTP input-buffer COW/adopt/clear: small gain in one shape with regressions elsewhere, rejected
- libh2o as HTTP/1 engine: benchmark/reference competitor only
- split ordinary HTTP head/body writes: memcpy vs syscall trade; revisit only if a generic Linux::Event segmented/gathered submit primitive appears
- broad native HTTP connection driver: not justified

## Branch policy

Do not merge PR #16 without explicit authorization.

Do not keep merged or abandoned branches merely as history. Delete them after merge/abandon unless they contain unique work with a concrete reason to preserve it.

`experiment/fused-request-index` remains a notable exception because it contains unique request-index fusion research.

A previous temporary branch `tmp/response-complete-verify` was known to contain no unique work and point at the old main baseline. Do not claim it is deleted unless verified.

## Next steps

1. Review the scalar `body()` commit timing question described above.
2. If the body/stream_body model is accepted, finish the no-compat migration and remove Response-level `write`/`complete` rather than keeping aliases.
3. Restore/update the simple README and detailed POD around the final API after the migration.
4. Optionally investigate paused-read peer-terminal observability in Linux::Event core as a separate generic capability; do not block the response-body model on an HTTP-local workaround.
5. Keep this handoff current after each test/conclusion.
