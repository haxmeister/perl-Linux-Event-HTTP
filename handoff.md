# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Current main baseline: `d66a353b9fa1c90d1b43e2e136349be6a1a65e40`
- No active feature PR is awaiting merge.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

PR #28, `Integrate HTTP::CookieJar with Client`, was explicitly approved by the
user and merged to main as `d66a353b9fa1c90d1b43e2e136349be6a1a65e40`.

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

## Current client policy baseline

Ordinary Client requests support direct routing, explicit per-request forward
proxy routing, a Client default proxy, per-request proxy override, and
`proxy => undef` direct-route bypass.

Target URL controls Host, redirects, target credentials, cookies, and Operation
URLs. Route URL controls connection acquisition, TLS-to-proxy, and idle reuse.
Client::Connection remains proxy-unaware.

Client CONNECT remains explicit through `connect_tunnel()` and server CONNECT
remains explicit through `Transaction->tunnel()`.

## HTTP::CookieJar integration

Cookie standards work is delegated to `HTTP::CookieJar 0.014`.

```perl
use HTTP::CookieJar;

my $jar = HTTP::CookieJar->new;
my $client = Linux::Event::HTTP::Client->new(
    loop       => $loop,
    cookie_jar => $jar,
);
```

Settled behavior:

- cookie state is explicitly injected; Client never creates a hidden jar;
- `Client->cookie_jar` returns the configured jar or undef;
- before each ordinary request hop, Client calls
  `cookie_header($target_url)` and synthesizes Cookie only when non-empty;
- every Set-Cookie field from final and redirect Responses is passed to
  `add($target_url,$value)` before redirect planning or application callbacks;
- redirect hops recompute Cookie from the new target URL;
- proxy route identity never becomes cookie origin identity;
- domain, path, expiry, Secure behavior, and cookie ordering remain entirely in
  `HTTP::CookieJar`;
- caller Cookie fields are rejected while `cookie_jar` is configured so cookie
  selection has one owner;
- applications seed, share, persist, or otherwise manage the jar themselves;
- `connect_tunnel()` does not consult the cookie jar;
- Request, Response, Transaction, Client::Connection, transport queues, and
  native code are unchanged.

Focused test: `t/75-client-cookie-jar.t` covers injected jar validation, seeded
cookies, redirect/final Set-Cookie handling, same-origin regeneration,
cross-origin isolation, proxy-route isolation, and caller Cookie ownership.

## Validation

Cookie implementation validation:

- executable head `b271f2282a2eeb6204014eee223bafd96d7575db` passed CI #404 / run `34761523124`;
- documentation/release-note head `07c9fd9cf23ffcb8b37b8a3d961748b9856c0f3d` passed CI #407 / run `34761690321`;
- exact pre-merge head `4d71d75d41a704e3d3328bd03d926fdf74e20abc` passed CI #408 / run `34761744293`.

All three passed Perl 5.36, latest Perl, and latest threaded Perl; latest also
passed end-to-end smoke and `disttest`.

README, Client POD, `docs/CLIENT-POLICY.md`, `Changes`, `Makefile.PL`, MANIFEST,
and focused tests are aligned. This handoff file is excluded from MANIFEST.

## Next useful work

The strongest next step is a release-readiness review for the initial 0.001
release rather than automatically adding another policy subsystem. Review:

- public API coherence across Client, Server, Request, Response, Transaction,
  Operation, CONNECT, Upgrade, bodies, redirects, proxies, and cookies;
- README/POD/docs consistency;
- dependency surface and metadata;
- MANIFEST and `disttest` integrity;
- unreleased/experimental wording that should be removed before CPAN;
- whether any missing correctness tests should block release.

Automatic proxy 407 challenge negotiation remains deliberately deferred because
it requires scheme selection, credential lookup, retry policy, and safe Request
body replay semantics. Environment proxy discovery, NO_PROXY, PAC, SOCKS,
richer pool policy, and client response parser XS also remain need/measurement
driven.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when available
tooling permits it. The current connector does not expose branch-ref deletion.
Do not reuse merged feature branches for new work.
