# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main baseline for current work: `5e3809aaf60073da2f4ed5b6f93b724780ca3861`
- Active branch: `feature/client-default-proxy`
- Draft PR: #27, `Add Client default forward proxy`
- Do not merge PR #27 without explicit user authorization.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Merged baseline includes:

- client CONNECT via `connect_tunnel()`;
- server CONNECT via `Transaction->tunnel()`;
- explicit per-request forward-proxy routing;
- combined CONNECT documentation in `docs/CONNECT.md`;
- client-policy roadmap in `docs/CLIENT-POLICY.md`.

The combined server-CONNECT + forward-proxy integration head
`2c75feab9432788241d251e2c2e49e4c103f0285` passed CI #394 / run
`34745011679` across Perl 5.36, latest, and latest threaded; latest also passed
end-to-end smoke and distribution integrity.

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

Do not move URL, redirect-chain, proxy-route, pool, socket, or endpoint-role
lifecycle into Request/Response. Do not redefine Transaction to span redirects.

## PR #27 - Client default forward proxy

The active branch adds configuration convenience on top of the already-correct
per-request proxy route.

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop  => $loop,
    proxy => 'http://proxy.example:3128',
);

# Uses the Client default.
$client->get('http://origin.example/path');

# Overrides the Client default for this operation.
$client->get(
    'http://origin.example/path',
    proxy => 'http://other-proxy.example:3128',
);

# Explicitly bypasses the Client default.
$client->get(
    'http://origin.example/path',
    proxy => undef,
);
```

A new read-only `Client->proxy` accessor returns the configured default proxy URL
or undef.

Semantics remain unchanged beneath the high-level Client:

- target origin controls Host, redirects, target credentials, and Operation URL;
- route origin controls actual connection acquisition and idle reuse;
- redirect hops retain the route selected for the operation;
- Client::Connection remains proxy-unaware;
- `connect_tunnel()` keeps its own explicit proxy endpoint and does not consult
  the Client default;
- ordinary CONNECT routed through a selected default proxy is rejected in favor
  of `connect_tunnel()`;
- no environment proxy discovery, PAC/NO_PROXY, SOCKS, automatic proxy auth,
  extra output queue, proxy object, or proxy-specific XS is added.

Focused test: `t/74-client-default-proxy.t` covers constructor validation,
default routing, per-request override, explicit bypass, correct absolute/origin
request-target forms, Host identity, and ordinary CONNECT rejection.

Executable head `8d93edaefa5cdfd51e9286cb1908ce4bf2df21c5` passed CI #399 / run
`34745480988` across Perl 5.36, latest, and latest threaded; latest also passed
end-to-end smoke and `disttest`.

Documentation-complete head `df35f43f98f13b1db9fceb6c98ef2b198582e2da`
passed CI #400 / run `34745650383` across Perl 5.36, latest, and latest threaded;
latest also passed end-to-end smoke and distribution integrity. README, Client
POD, `docs/CLIENT-POLICY.md`, MANIFEST, and the focused test are aligned.

The commit after that checkpoint only refreshes this handoff and is excluded
from MANIFEST.

## Client policy after PR #27

The strongest next policy candidate is injected cookie-jar support using
`HTTP::CookieJar`, which is attractive because it does not require
HTTP::Request/HTTP::Response objects and therefore fits this distribution's
message model. Cookie origin must remain the target URL, never the proxy route.

Automatic proxy 407 challenge negotiation remains deferred. Caller-supplied
`Proxy-Authorization` already works; challenge negotiation introduces scheme,
credential, retry, and streamed-body replay policy that should be driven by a
concrete need.

Environment proxy discovery, NO_PROXY, PAC, SOCKS, richer pool behavior, and
client parser XS remain separate/deferred.

## Release-note cleanup

`Changes` should receive consolidated bullets for explicit forward-proxy routing
and Client default proxy behavior before the eventual 0.001 release. Do not lose
the existing detailed unreleased history when doing that cleanup.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when the
available GitHub tooling permits it. The current connector can close superseded
PRs but does not expose branch-ref deletion. Do not reuse old merged feature
branches for new work.
