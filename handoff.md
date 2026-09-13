# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP version remains `0.001 UNRELEASED`
- Client CONNECT PR #23 merged to main as `bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
- Server CONNECT PR #24 merged to main as `cb57f65c622d483bc77d2a8669ccb0e4494949bd`.
- Conflicted forward-proxy PR #25 is being replaced by the integration branch `feature/client-forward-proxy-integrated`, rebuilt from the post-#24 main so both feature sets coexist cleanly.

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

Client CONNECT is explicit through:

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
- After rebuilding forward-proxy work on the post-#24 main, run the full CI matrix again before merging the integration branch.

## Next work

After the combined branch is green and merged to main, continue from main. The next HTTP-specific client layers worth evaluating are proxy-authentication helpers and broader client policy such as cookies, while keeping automatic proxy discovery and richer pool behavior separate. Parser XS remains measurement-driven.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when the available GitHub tooling permits it. Do not reuse old merged feature branches for new work.
