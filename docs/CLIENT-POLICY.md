# Client policy roadmap

Linux::Event::HTTP keeps transport execution and HTTP message identity separate
from higher-level client policy. This document records the policy layers built
above Client::Connection after redirects, Upgrade, CONNECT, and forward-proxy
routing.

## Implemented: explicit and default forward proxy routes

Ordinary requests may select a proxy per operation:

```perl
$client->get(
    'http://origin.example/path',
    proxy => 'http://proxy.example:3128',
);
```

A Client may also configure one default route:

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop  => $loop,
    proxy => 'http://proxy.example:3128',
);
```

A per-request proxy overrides the Client default, while `proxy => undef`
explicitly bypasses it for that operation.

Target origin controls Host, redirects, Authorization/Cookie security, and
Operation URLs. Route origin controls connection acquisition and idle reuse.
Redirect hops retain the route selected for the operation.

This remains explicit configuration. Linux::Event::HTTP does not inspect proxy
environment variables, evaluate PAC or NO_PROXY policy, add SOCKS semantics, or
silently convert ordinary proxy routing into CONNECT.

## Next candidate: cookies

Cookie policy is standards-heavy and should not be reimplemented here when a
suitable independent CPAN implementation exists.

`HTTP::CookieJar` is a strong fit because it provides user-agent cookie storage
and lookup without requiring `HTTP::Request` or `HTTP::Response` objects. That
allows Linux::Event::HTTP to retain its direction-neutral Request/Response
classes.

The likely integration should accept an injected jar object on the high-level
Client. For each target URL, Client would synthesize a Cookie field from the jar
before the Request is committed. Each Response would feed its Set-Cookie fields
back into the jar using that Transaction's target URL.

Cookie decisions are target-URL policy, not route/proxy policy. A proxy must
never become the cookie origin merely because the transport connects to it.

Do not silently create a persistent or hidden cookie store. Jar creation,
persistence, and sharing should remain explicit application policy.

## Proxy authentication

Caller-supplied `Proxy-Authorization` already works for ordinary forward-proxy
requests and explicit CONNECT. It remains associated with the selected proxy
route across redirect hops while target Authorization and Cookie fields obey
target-origin security rules.

Automatic 407 challenge negotiation should not be the next default feature.
General proxy authentication can involve multiple schemes, challenge parsing,
credential lookup, retries, and replayability questions for streamed Request
bodies. That is substantially more policy than generating one header.

A future authentication layer should be driven by a concrete need and should
keep credentials associated with the proxy route rather than the target origin.
It must define replay rules before retrying Requests with bodies.

## Deferred policy

Keep these separate until a real workload requires them:

- HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment discovery;
- NO_PROXY matching;
- PAC;
- SOCKS;
- automatic 407 challenge/retry machinery;
- origin authentication managers;
- richer connection-pool policy;
- parser XS that is not justified by measurement.

The guiding rule remains: high-level policy may make correct use easy, but it
must not change Request/Response identity, expand Transaction beyond one
exchange, or duplicate Linux::Event transport machinery.
