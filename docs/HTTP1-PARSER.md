# HTTP/1 parser implementation

The current HTTP/1 request-head implementation uses picohttpparser together with
Linux::Event::HTTP framing and semantic validation.

picohttpparser is vendored under `vendor/picohttpparser/` at a recorded upstream
revision so builds do not fetch source from the network. Its upstream license is
retained with the vendored files.

## What pico provides

pico parses the HTTP/1 request line and header structure and returns slices into
the received bytes. Linux::Event::HTTP then applies additional protocol policy
needed by the server, including:

- rejection of obsolete folded headers
- header count limits
- HTTP/1.1 Host requirements
- Content-Length validation
- Transfer-Encoding validation
- rejection of ambiguous Transfer-Encoding plus Content-Length framing
- keep-alive semantics

Chunked request bodies are decoded by the HTTP/1 implementation while preserving
bytes belonging to later pipelined requests.

## Public API boundary

picohttpparser is not part of the public API. Applications receive
`Linux::Event::HTTP::Request` objects and should not depend on pico structures,
offsets, function names, or parser-specific behavior beyond the documented HTTP
semantics.

This allows the parser implementation to be replaced if a more suitable
community library becomes available.

## Dependency policy

The Linux::Event ecosystem charter prefers suitable established community
libraries over custom protocol machinery. The current vendored parser predates
that policy and should be periodically reevaluated on:

- correctness and standards behavior
- security-sensitive framing behavior
- maintenance and provenance
- licensing
- ease of wrapping behind Linux::Event::HTTP
- dependency weight
- realistic performance where material

A small parser microbenchmark advantage is not sufficient reason by itself to
retain or replace an implementation.

## Security testing

HTTP request framing is security-sensitive. Changes involving Host,
Content-Length, Transfer-Encoding, chunked decoding, header syntax, request
boundaries, or persistence require focused behavioral tests, including malformed
and ambiguous inputs.

Correct rejection behavior matters more than accepting unusual malformed input
for compatibility.
