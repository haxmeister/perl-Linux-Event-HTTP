# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main baseline for current work: `7e56fc0dc9e56330d1a7e92835142fa3358bc7d3`
- Active branch: `feature/client-cookie-jar`
- Draft PR: #28, `Integrate HTTP::CookieJar with Client`
- Do not merge PR #28 without explicit user authorization.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

PR #27, Client default forward proxy, was explicitly approved by the user and
merged to main as `7e56fc0dc9e56330d1a7e92835142fa3358bc7d3`.

## Settled object model

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response exchange

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    HTTP/1 protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, proxy-route, pool, socket, cookie storage, or
endpoint-role lifecycle into Request/Response. Do not redefine Transaction to
span redirects.

## Current client route policy

Ordinary Client requests support:

- direct routing;
- explicit per-request `proxy => $url`;
- Client default `proxy => $url`;
- per-request proxy override;
- `proxy => undef` explicit direct-route bypass.

Target origin controls Host, redirects, target credentials, cookies, and
Operation URLs. Route origin controls connection acquisition and idle reuse.
Client::Connection remains proxy-unaware.

Client CONNECT remains explicit through `connect_tunnel()` and server CONNECT
remains explicit through `Transaction->tunnel()`.

## PR #28 - HTTP::CookieJar integration

Cookie standards work is delegated to `HTTP::CookieJar 0.014` rather than
implemented in Linux::Event::HTTP.

API:

```perl
use HTTP::CookieJar;

my $jar = HTTP::CookieJar->new;
my $client = Linux::Event::HTTP::Client->new(
    loop       => $loop,
    cookie_jar => $jar,
);
```

Settled behavior:

- the jar is explicitly injected; Client never silently creates cookie state;
- `Client->cookie_jar` returns the configured jar or undef;
- before every ordinary request hop Client calls
  `cookie_header($target_url)` and synthesizes Cookie only when non-empty;
- every Set-Cookie field from ordinary final or redirect Responses is passed to
  `add($target_url,$value)` before redirect planning or application response
  callbacks;
- redirect hops recompute Cookie from the new target URL;
- target URL, never proxy route URL, is the cookie identity;
- HTTP::CookieJar owns domain, path, expiry, Secure handling, and cookie ordering;
- caller Cookie fields are rejected while `cookie_jar` is configured so cookie
  selection has one owner;
- applications seed or modify cookie state through the jar;
- `connect_tunnel()` does not consult the cookie jar;
- Request, Response, Transaction, Client::Connection, output queues, and native
  code are unchanged.

Focused test: `t/75-client-cookie-jar.t` covers injected jar validation, seeded
cookies, redirect Set-Cookie processing, final-response Set-Cookie processing,
same-origin regeneration, cross-origin isolation, proxy-route isolation, and
caller Cookie ownership.

## Validation

Initial cookie implementation head `d11f5523ed486b2f20131b5c37324e306a76ec16`
ran CI #403 / run `34761459148`. Dependency installation and all existing tests
passed; the only failure was a focused test assumption that `cookie_header()`
returns undef for no matches. `HTTP::CookieJar` returns an empty string instead.

Corrected executable head `b271f2282a2eeb6204014eee223bafd96d7575db`
passed CI #404 / run `34761523124` across Perl 5.36, latest, and latest threaded;
latest also passed end-to-end smoke and distribution integrity.

Documentation/release-note head `07c9fd9cf23ffcb8b37b8a3d961748b9856c0f3d`
passed CI #407 / run `34761690321` across Perl 5.36, latest, and latest threaded;
latest also passed end-to-end smoke and distribution integrity.

README, Client POD, `docs/CLIENT-POLICY.md`, `Changes`, `Makefile.PL`, MANIFEST,
and focused tests are aligned. This handoff file is excluded from MANIFEST.

## Next work after PR #28

Do not merge #28 without explicit authorization.

After cookie support is accepted, automatic proxy 407 challenge negotiation
remains deliberately deferred. Caller-supplied Proxy-Authorization already works;
automatic challenge handling would need scheme selection, credential lookup,
retry policy, and safe body replay semantics.

Also keep environment proxy discovery, NO_PROXY, PAC, SOCKS, richer pool policy,
and client response parser XS separate and need/measurement driven.

A useful next review after merging cookie support is release-readiness for the
0.001 distribution: public API coherence, docs/POD consistency, dependency
surface, MANIFEST/disttest, and whether any remaining unreleased experimental
language should be removed.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when available
tooling permits it. The current connector can close superseded PRs but does not
expose branch-ref deletion. Do not reuse merged feature branches for new work.
