# Client policy roadmap

Linux::Event::HTTP keeps transport execution and HTTP message identity separate from higher-level client policy. This document records the next client-policy layers after redirects, CONNECT, Upgrade, and explicit forward-proxy routing.

## 1. Client-level default proxy

The next implementation slice should make the existing explicit per-request proxy route convenient for clients that use one proxy repeatedly.

Proposed shape:

```perl
my $client = Linux::Event::HTTP::Client->new(
    loop  => $loop,
    proxy => 'http://proxy.example:3128',
);

$client->get('http://origin.example/path');

# Override the default route for one operation.
$client->get(
    'http://origin.example/path',
    proxy => 'http://other-proxy.example:3128',
);

# Explicitly bypass the Client default for one operation.
$client->get(
    'http://origin.example/path',
    proxy => undef,
);
```

The constructor default must reuse the already-established forward-proxy semantics. Target origin still controls Host, redirects, Authorization/Cookie security, and Operation URLs. Route origin still controls connection acquisition and idle reuse. Redirect hops retain the selected route for that operation.

This is configuration convenience only. It must not add environment-variable discovery, PAC/NO_PROXY evaluation, SOCKS, automatic CONNECT, proxy authentication, a new proxy object, or proxy state to Client::Connection.

## 2. Cookies

Cookie policy is standards-heavy and should not be reimplemented in this distribution when a suitable independent CPAN implementation exists.

`HTTP::CookieJar` is a strong fit because it provides user-agent cookie storage and lookup without requiring `HTTP::Request` or `HTTP::Response` objects. That allows Linux::Event::HTTP to retain its direction-neutral Request/Response classes.

The likely integration should accept an injected jar object at the high-level Client. For each target URL, Client would synthesize a Cookie field from the jar before the Request is committed. Each final or intermediate Response would feed its Set-Cookie fields back into the jar using the URL of that Transaction.

Cookie decisions are target-URL policy, not route/proxy policy. A proxy must never become the cookie origin simply because the transport connection is made to the proxy.

Do not silently create an unbounded or persistent cookie store. Jar creation, persistence, and sharing should remain explicit application policy.

## 3. Proxy authentication

Caller-supplied `Proxy-Authorization` already works for ordinary forward-proxy requests and explicit CONNECT. It remains associated with the selected explicit proxy route across redirect hops while target Authorization and Cookie fields obey target-origin security rules.

Automatic 407 challenge negotiation should not be the next default feature. General proxy authentication can involve multiple schemes, challenge parsing, credential lookup, retries, and replayability questions for streamed Request bodies. That is substantially more policy than generating one header.

A future authentication layer should be driven by a concrete need and should keep credentials associated with the proxy route rather than the target origin. It must also define replay rules before retrying Requests with bodies.

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

The guiding rule remains: high-level policy may make correct use easy, but it must not change Request/Response identity, expand Transaction beyond one exchange, or duplicate Linux::Event transport machinery.
