# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Start here next session

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main currently ends at client CONNECT merge commit
  `bb44d15bb51d51a8d4ea0ddfa531532adc801963`.
- Active branch: `feature/client-forward-proxy`
- Draft PR: #25, `Add explicit client forward proxy routing`.
- Current executable PR #25 head before this handoff refresh:
  `c1ec67477007690bc6e6bde8c3ece55323b10b4f`.
- Do not merge PR #25 without explicit user authorization.
- Separate draft PR #24, `Add server CONNECT tunnel handoff`, remains open,
  green, and unmerged on `feature/server-connect-tunnel` at
  `c7fa07f5ae50873d2acebeda768c1201aa37fcdc`.
- Do not merge PR #24 without explicit user authorization.
- Linux::Event minimum prerequisite: `0.113`.
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

Core object identities remain settled:

```text
Request / Response
    direction-neutral HTTP messages

Transaction
    exactly one Request/Response HTTP exchange
    owns exchange lifecycle and explicit protocol handoff operations

Client::Operation
    one high-level client action
    one or more Transactions when redirects are followed

Client::Connection / Server::Connection
    HTTP protocol executors on Linux::Event stream transports
```

Do not move URL, redirect-chain, pool, socket, route, or endpoint-role lifecycle
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

PR #24 is intentionally not part of the active forward-proxy branch. It adds:

```perl
if ($req->method eq 'CONNECT') {
    $conn->transaction->tunnel('MyTunnelProtocol');
}
```

Its boundary is settled:

- CONNECT arrives through ordinary `on_request($conn,$req,$res)`;
- successful server CONNECT is a Transaction lifecycle handoff;
- the same accepted Linux::Event stream transitions to the target class;
- already-read post-CONNECT bytes are preserved;
- Response and Transaction complete before handoff;
- rejection remains ordinary non-2xx HTTP and can keep the connection alive;
- `tunnel()` does not authorize destinations, open upstream sockets, relay
  bytes, or implement proxy authentication policy.

Exact PR #24 head
`c7fa07f5ae50873d2acebeda768c1201aa37fcdc` passed CI #383 / run
`34740746617` across Perl 5.36, latest Perl, and latest threaded Perl; latest
also passed end-to-end smoke and distribution integrity.

If PR #24 is merged later, delete its feature branch through GitHub's normal
branch cleanup UI if the connector still lacks branch deletion.

## PR #25 - explicit client forward proxy routing

The active branch adds explicit forward-proxy routing for ordinary high-level
Client requests without making proxy use automatic or environmental.

Current API:

```perl
my $operation = $client->get(
    'http://origin.example/items?limit=10',
    proxy => 'http://proxy.example:3128',
    headers => [
        [ 'Proxy-Authorization' => $value ],
    ],
);
```

`proxy` is currently a per-request option only. No constructor-wide default
proxy has been added.

The design deliberately separates:

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
continues to serialize a normal Request and execute the ordinary response/body
state machine.

## Forward-proxy request rules

Without `proxy`:

- existing direct behavior is unchanged;
- the target path/query is sent in origin-form;
- connection/TLS/pool identity is the target origin;
- an explicit caller Host override continues to be preserved for direct use.

With `proxy => $proxy_url`:

- target URL must still be an absolute `http` or `https` URL;
- proxy URL must be an absolute `http` or `https` URL;
- proxy URL must not contain a path or query;
- the Client connects to the proxy host/port rather than the target host/port;
- an `https` proxy means TLS is established to the proxy;
- ordinary requests use absolute-form request targets such as
  `http://origin.example/path` or `https://origin.example/path`;
- URL fragments remain client-side and are not transmitted;
- Host is regenerated canonically from the target URL, not from the proxy and
  not from a caller-provided Host override;
- CONNECT cannot be expressed as `request('CONNECT', ..., proxy => ...)`;
  callers use the existing `connect_tunnel()` API instead.

An HTTPS target used with `proxy` is an absolute-form HTTPS URI forwarded to the
proxy. It does not imply end-to-end TLS to the target and is not silently
converted to CONNECT. `connect_tunnel()` remains the explicit tunnel primitive.

RFC basis checked during this work:

- RFC 9112 section 3.2.2 requires absolute-form when an ordinary HTTP request is
  sent to a proxy and still requires Host to identify the target authority.
- RFC 9110 section 7.3.2 describes connecting to the configured proxy endpoint
  and sending a request whose request target matches the target URI.

## Proxy connection reuse

The Client now distinguishes target origin from route origin.

For direct requests:

```text
route origin = target origin
```

For forward-proxied requests:

```text
route origin = proxy origin
```

The existing bounded pool therefore retains at most one idle connection per
route origin. Sequential requests to different target origins can reuse one
persistent proxy connection. Concurrent operations still use additional
connections instead of HTTP/1 pipelining.

This is route reuse only. Redirect/security identity remains the target origin.

## Redirect and credential behavior through a proxy

Redirect URLs are resolved against the target URL exactly as before. Each
followed redirect remains a new Transaction in the same Client::Operation.

When the target origin changes:

- `Authorization` is stripped;
- `Cookie` is stripped;
- Host is regenerated from the redirected target;
- HTTP framing/connection-specific fields are regenerated;
- the explicit proxy route is retained;
- caller-supplied `Proxy-Authorization` is retained because it authenticates
  the unchanged explicit proxy, not the redirected target.

For direct requests, the previous policy remains: Proxy-Authorization is never
propagated automatically.

There is no automatic proxy authentication negotiation or credential source.
The Client only preserves a caller-supplied Proxy-Authorization field while the
same explicit proxy continues to be used.

## Focused PR #25 test

`t/73-client-forward-proxy.t` covers:

- rejection of proxy URLs with path/query;
- rejection of unsupported proxy schemes;
- rejection of CONNECT through the ordinary `proxy` option;
- absolute-form HTTP request target with fragment removed;
- canonical target Host replacing a caller Host override in proxy mode;
- absolute-form HTTPS target sent to an explicit HTTP proxy;
- ordinary incremental response handling through the proxy;
- persistent reuse of one proxy connection across different target origins;
- cross-origin redirect through the same proxy;
- target Authorization/Cookie stripping across that redirect;
- preservation of caller Proxy-Authorization for the same proxy;
- Transaction-per-redirect-hop and Client::Operation history invariants.

## PR #25 validation checkpoints

Initial PR head `beb11c317c3ea08a485670eb5c2f6a78298c3afd`
ran CI #384 / run `34742395212`. All pre-existing tests passed up to the new
`t/73-client-forward-proxy.t`, which failed to compile on Perl 5.36 because the
test declared `my $first = ...` while closing over `$first` inside an initializer
callback. This was a test lexical-scope mistake, not a Client implementation
failure.

The test was changed to predeclare and then assign `$first`, matching the pattern
already used for the later operations. Executable head
`c1ec67477007690bc6e6bde8c3ece55323b10b4f` passed CI #385 / run
`34742447070` across Perl 5.36, latest Perl, and latest threaded Perl; latest
also passed end-to-end smoke and distribution integrity.

After this checkpoint, align README, architecture, Changes, top-level POD, and
this handoff with the implemented per-request proxy semantics. Run a final exact
branch-head CI before presenting PR #25 as ready for merge.

## Scope boundaries for PR #25

Do not grow this PR into a general proxy framework.

Not included:

- environment-variable proxy discovery;
- constructor-wide/default proxy policy;
- automatic proxy authentication or 407 retry loops;
- PAC / NO_PROXY policy;
- automatic CONNECT for HTTPS target URLs;
- SOCKS;
- a public proxy object hierarchy;
- a second output queue or proxy-specific Client::Connection subclass;
- parser XS changes.

Those can be evaluated separately if a concrete use case justifies them.

## Native boundary

Keep one private `_HTTP1` extension. It owns pico server request parsing/lazy
Request accessors, shared chunked decoding, server response serialization, and
the narrow server scalar-response fast path.

Forward-proxy routing is high-level URL/route policy and should remain Perl-side.
It does not justify another native extension.

## Likely next work after current draft PRs

Do not merge PR #24 or #25 without explicit authorization.

If proxy work continues after PR #25, evaluate policy layers separately rather
than bundling them into the base route mechanism. Possible later slices are:

- an optional Client-level default proxy;
- explicit proxy-authentication helpers / 407 retry policy;
- NO_PROXY-style selection policy;
- cookie policy/jar;
- richer connection-pool policy only when a real workload justifies it.

A reusable two-stream relay/bridge for accepted server CONNECT belongs closer to
Linux::Event core or another reusable communications layer, not inside the HTTP
Transaction handoff itself. Do not modify Linux::Event from this project unless
the user explicitly asks.

Client parser XS remains measurement-driven, not a default next step.
HTTP/2 is future protocol work. WebSocket remains a separate protocol
distribution.

## Parked Linux::Event core question

Do not reopen the paused-read / EPOLLRDHUP question absent a demonstrated HTTP
protocol requirement. Do not add polling, duplicate transport buffers, or a
second HTTP output queue.

## Branch cleanup

The user dislikes stale branches. The GitHub connector currently does not expose
branch deletion. Merged feature refs may require GitHub's normal `Delete branch`
control. Do not reuse stale merged branches for new work.
