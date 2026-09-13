# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Current main before this handoff refresh: `eee485823c3ba1cff4ba508aa4094a18e861002c`
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.
- Client CONNECT PR #23 merged as `bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
- Server CONNECT PR #24 merged as `cb57f65c622d483bc77d2a8669ccb0e4494949bd`.
- Conflicted forward-proxy PR #25 was closed as superseded.
- Clean integration PR #26 merged server CONNECT plus forward-proxy Client work as `a57863cdeb568f8bafcf31ed2d7bb2bbc34ee0f8`.
- Combined CONNECT documentation was then added on main as `eee485823c3ba1cff4ba508aa4094a18e861002c`.

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

Do not move URL, redirect-chain, proxy-route, pool, socket, or endpoint-role lifecycle into Request/Response. Do not redefine Transaction to span redirects.

## CONNECT support

Client CONNECT is explicit:

```perl
$client->connect_tunnel(
    'http://proxy.example:3128',
    'target.example:443',
    tunnel_to => 'MyTunnelProtocol',
);
```

Any successful 2xx response ends HTTP framing at the response-head boundary and transitions the same live stream. Non-2xx responses remain ordinary HTTP and may leave a reusable proxy connection.

Server CONNECT is explicit through the active Transaction:

```perl
if ($req->method eq 'CONNECT') {
    $conn->transaction->tunnel('MyTunnelProtocol');
}
```

Server tunnel acceptance validates HTTP/1.1 authority-form CONNECT, matching Host, absent request framing/body, and a bodyless 2xx response. The HTTP Transaction completes before Linux::Event `transition_to()` hands the same accepted stream to the target class. Destination authorization, upstream connection creation, and byte relaying remain outside Linux::Event::HTTP.

Detailed combined behavior is documented in `docs/CONNECT.md`.

## Explicit forward proxy routing

Ordinary high-level Client requests may explicitly select a route:

```perl
$client->get(
    'http://origin.example/path',
    proxy => 'http://proxy.example:3128',
);
```

Rules:

- direct requests keep origin-form request targets;
- proxied ordinary requests use HTTP/1 absolute-form request targets;
- Host is regenerated from the target URL in proxy mode;
- target origin remains the redirect/security identity;
- route origin selects the actual connection and idle-pool entry;
- one persistent proxy connection may serve sequential requests for different target origins;
- cross-origin redirects strip Authorization and Cookie;
- caller-supplied Proxy-Authorization remains associated with the same explicit proxy route;
- HTTP and HTTPS proxy endpoints are allowed;
- an HTTPS target used with `proxy` is still forwarded in absolute-form and is not an implicit CONNECT tunnel;
- CONNECT through ordinary `proxy` is rejected in favor of `connect_tunnel()`;
- Client::Connection remains proxy-unaware;
- no automatic environment proxy discovery, proxy authentication, PAC/NO_PROXY policy, SOCKS policy, constructor-wide proxy default, extra output queue, or proxy-specific XS is introduced.

Focused coverage: `t/73-client-forward-proxy.t`.

## Validation history

- Server CONNECT exact head `c7fa07f5ae50873d2acebeda768c1201aa37fcdc` passed CI #383 / run `34740746617` across Perl 5.36, latest, and latest threaded; latest also passed smoke and `disttest`.
- Forward-proxy exact pre-integration head `5b19a6a70d98bc5ae801a8ebef43c8f9e69142af` passed CI #392 / run `34742787560` across the same matrix, including latest smoke and `disttest`.
- Combined integration head `2c75feab9432788241d251e2c2e49e4c103f0285` passed CI #394 / run `34745011679` across Perl 5.36, latest, and latest threaded; latest also passed end-to-end smoke and distribution integrity.

## Next work

Evaluate the next client-policy layer from main. The leading candidates are:

1. Client-level default proxy with explicit per-request override, building only on the already-correct per-request proxy mechanics.
2. Proxy-authentication convenience/policy, while avoiding automatic credential guessing or a large challenge framework.
3. Cookie handling, preferably by reusing a mature CPAN implementation rather than reimplementing cookie RFC behavior.

Keep automatic environment proxy discovery, PAC/NO_PROXY policy, SOCKS, richer pool behavior, and parser XS separate and measurement/need driven.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when the available GitHub tooling permits it. The current connector can close superseded PRs but does not expose branch-ref deletion. Do not reuse old merged feature branches for new work.
