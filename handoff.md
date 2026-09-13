# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main currently ends at client CONNECT merge commit
  `bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
- Active branch: `feature/client-forward-proxy`
- Draft PR: #25, `Add explicit client forward proxy routing`.
- Final tested implementation/docs head:
  `8b2c95662907cfdc9145c531677e54aa1f8d65cf`.
- CI #391 / run `34742730810` is fully green on that head across Perl 5.36,
  latest Perl, and latest threaded Perl; latest also passed end-to-end smoke and
  distribution integrity.
- This handoff update is metadata only and `handoff.md` is not in MANIFEST.
- Do not merge PR #25 without explicit user authorization.
- Separate draft PR #24, `Add server CONNECT tunnel handoff`, remains open,
  green, and unmerged on `feature/server-connect-tunnel` at
  `c7fa07f5ae50873d2acebeda768c1201aa37fcdc`.
- Do not merge PR #24 without explicit user authorization.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

## Settled object and ownership model

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response HTTP exchange
    exchange lifecycle / outgoing producer / handoff state

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    HTTP protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, pool, route, socket, or endpoint-role lifecycle
into Request/Response. Do not redefine Transaction to span redirects.
Linux::Event remains the only transport-output queue.

## Merged main baseline

Main already includes:

- HTTP/HTTPS high-level Client and low-level Client::Connection;
- scalar and streaming Request bodies;
- incremental Response delivery plus explicit bounded `buffer_body`;
- strict Perl client response-head parsing and shared native chunked decoding;
- one active Transaction per HTTP/1 connection and bounded persistent reuse;
- Client::Operation with bounded 301/302/303/307/308 redirect following;
- redirect method/body policy, relative Location resolution, and cross-origin
  credential stripping;
- client-side HTTP/1.1 Upgrade handoff through Linux::Event `transition_to()`;
- explicit client HTTP/1.1 CONNECT tunnel establishment.

Client CONNECT was merged through PR #23 as
`bb44d15bb51d51a8d4ea0ddfa531532adc801963`.

Keep the client response-head parser in Perl unless measurement justifies XS.

## Separate PR #24 - server CONNECT handoff

PR #24 is independent of the active forward-proxy branch. It adds:

```perl
if ($req->method eq 'CONNECT') {
    $conn->transaction->tunnel('MyTunnelProtocol');
}
```

Its boundary is settled:

- CONNECT arrives through ordinary `on_request($conn,$req,$res)`;
- successful server CONNECT is a Transaction lifecycle handoff;
- same accepted Linux::Event stream transitions to the target class;
- already-read post-CONNECT bytes are preserved;
- Response and Transaction complete before handoff;
- rejection remains ordinary non-2xx HTTP and can keep the connection alive;
- `tunnel()` does not authorize destinations, open upstream sockets, relay
  bytes, or implement proxy authentication policy.

Exact PR #24 head
`c7fa07f5ae50873d2acebeda768c1201aa37fcdc` passed CI #383 / run
`34740746617` across Perl 5.36, latest Perl, and latest threaded Perl; latest
also passed end-to-end smoke and distribution integrity.

## PR #25 - explicit client forward proxy routing

Public API:

```perl
my $operation = $client->get(
    'http://origin.example/items?limit=10',
    proxy => 'http://proxy.example:3128',
    headers => [
        [ 'Proxy-Authorization' => $value ],
    ],
);
```

`proxy` is a per-request option only. No constructor-wide default proxy exists.

The design separates target identity from route identity:

```text
target URL
    Request/Operation identity
    Host
    redirect resolution
    origin credential policy

proxy URL
    physical HTTP/TLS route
    connection acquisition
    idle-pool key
    proxy credentials
```

The low-level `Client::Connection` remains proxy-unaware. The high-level Client
constructs the correct Request target and chooses the route; Client::Connection
continues to serialize a normal Request and execute the ordinary body/response
state machine.

## Forward-proxy request rules

Without `proxy`:

- direct behavior is unchanged;
- path/query is sent in origin-form;
- connection/TLS/pool identity is the target origin;
- caller Host overrides remain possible for direct requests.

With `proxy => $proxy_url`:

- target URL is still absolute `http` or `https`;
- proxy URL must be absolute `http` or `https`;
- proxy URL must not contain a path or query;
- the Client connects to the proxy host/port;
- an `https` proxy means TLS is established to the proxy;
- ordinary requests use absolute-form request targets;
- URL fragments are not transmitted;
- Host is regenerated canonically from the target URL;
- CONNECT cannot be expressed with the ordinary `proxy` option;
  use `connect_tunnel()`.

An HTTPS target used with `proxy` is forwarded as an absolute-form
`https://...` URI. It does not imply end-to-end TLS to the target and is not
silently converted to CONNECT.

RFC basis checked during this work:

- RFC 9112 section 3.2.2: ordinary HTTP requests sent to a proxy use
  absolute-form and Host still identifies the target authority.
- RFC 9110 section 7.3.2: connect to the configured proxy endpoint and send a
  request whose request target matches the target URI.

## Route-origin pooling

For direct requests:

```text
route origin = target origin
```

For forward-proxied requests:

```text
route origin = proxy origin
```

The bounded pool retains at most one idle connection per route origin.
Sequential requests to different target origins can therefore reuse one
persistent proxy connection. Concurrent operations still use additional
connections instead of HTTP/1 pipelining.

Redirect/security identity remains the target origin.

## Redirect and credential behavior through a proxy

Each followed redirect remains a new Transaction in the same Client::Operation.
Redirect URLs resolve against the target URL, not the proxy URL.

When the target origin changes:

- `Authorization` is stripped;
- `Cookie` is stripped;
- Host is regenerated from the redirected target;
- HTTP framing/connection-specific fields are regenerated;
- the same explicit proxy route is retained;
- caller-supplied `Proxy-Authorization` is retained because it authenticates
  the unchanged proxy, not the target.

For direct requests, Proxy-Authorization continues not to propagate
automatically.

There is no automatic proxy authentication negotiation or credential source.

## Focused test

`t/73-client-forward-proxy.t` covers:

- invalid proxy URL path/query and scheme;
- CONNECT rejected through ordinary `proxy` option;
- absolute-form HTTP request target with fragment removed;
- target Host canonicalization in proxy mode;
- absolute-form HTTPS target sent to an explicit HTTP proxy;
- normal incremental Response delivery through the proxy;
- one persistent proxy route reused across different target origins;
- cross-origin redirect through the same proxy;
- target Authorization/Cookie stripping;
- caller Proxy-Authorization retention for that proxy;
- Transaction-per-hop and Operation-history invariants.

## PR #25 validation history

Initial head `beb11c317c3ea08a485670eb5c2f6a78298c3afd` ran CI #384 / run
`34742395212`. All pre-existing tests passed up to the new test, which had a
Perl 5.36 lexical-scope compile error because the test closed over a variable in
its own initializer. This was test-only.

Executable head `c1ec67477007690bc6e6bde8c3ece55323b10b4f` fixed that test
scope and passed CI #385 / run `34742447070` across Perl 5.36, latest Perl, and
latest threaded Perl; latest also passed smoke and distribution integrity.

The documentation sweep aligned README, `docs/ARCHITECTURE.md`, Changes,
Client POD, top-level POD, MANIFEST, focused tests, and this handoff.

Final tested implementation/docs head
`8b2c95662907cfdc9145c531677e54aa1f8d65cf` passed CI #391 / run
`34742730810` across Perl 5.36, latest Perl, and latest threaded Perl; latest
also passed end-to-end smoke and distribution integrity.

PR #25 is a clean merge boundary. Do not merge it without explicit user
authorization.

## Scope boundaries for PR #25

Not included:

- environment-variable proxy discovery;
- constructor-wide/default proxy policy;
- automatic proxy authentication or 407 retry loops;
- PAC / NO_PROXY policy;
- automatic CONNECT for HTTPS target URLs;
- SOCKS;
- a public proxy object hierarchy;
- a proxy-specific Client::Connection subclass;
- a second output queue;
- parser XS changes.

Evaluate those separately only when a concrete use case justifies them.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Forward-proxy routing is high-level URL/route policy and remains Perl-side. It
does not justify another native extension.

## Likely next work after current draft PRs

Do not merge PR #24 or #25 without explicit authorization.

If proxy work continues after PR #25, keep policy layers separate from the base
route mechanism. Possible later slices:

- optional Client-level default proxy;
- explicit proxy-authentication helpers / 407 retry policy;
- NO_PROXY-style selection policy;
- cookie policy/jar;
- richer connection-pool policy only when a real workload justifies it.

A reusable two-stream relay/bridge for accepted server CONNECT belongs closer to
Linux::Event core or another reusable communications layer, not inside the HTTP
Transaction handoff itself. Do not modify Linux::Event from this project unless
the user explicitly asks.

Client parser XS remains measurement-driven. HTTP/2 is future protocol work.
WebSocket remains a separate protocol distribution.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup

The user dislikes stale branches. The GitHub connector currently does not expose
branch deletion. Merged feature refs may require GitHub's normal `Delete branch`
control. Do not reuse stale merged branches for new work.
