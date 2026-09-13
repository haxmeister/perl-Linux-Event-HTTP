# Client policy

Linux::Event::HTTP keeps transport execution and HTTP message identity separate
from higher-level client policy. Client policy belongs above Client::Connection
and must not turn Request, Response, or Transaction into routing/session objects.

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

Target origin controls Host, redirects, target credentials, cookies, and
Operation URLs. Route origin controls connection acquisition and idle reuse.
Redirect hops retain the selected route for the operation.

This remains explicit configuration. Linux::Event::HTTP does not inspect proxy
environment variables, evaluate PAC or NO_PROXY policy, add SOCKS semantics, or
silently convert ordinary proxy routing into CONNECT.

## Implemented: injected HTTP::CookieJar

Cookie policy is delegated to `HTTP::CookieJar` rather than reimplemented here.
The jar is explicit application-owned state:

```perl
use HTTP::CookieJar;

my $jar = HTTP::CookieJar->new;
my $client = Linux::Event::HTTP::Client->new(
    loop       => $loop,
    cookie_jar => $jar,
);
```

Linux::Event::HTTP does not create a hidden jar. The application decides jar
lifetime, sharing, persistence, preloading, and clearing.

For each ordinary request hop, Client asks the jar for:

```perl
$jar->cookie_header($target_url)
```

and synthesizes the Cookie field only when the returned string is non-empty.
For every Set-Cookie field in an ordinary final or redirect Response, Client
calls:

```perl
$jar->add($target_url, $set_cookie)
```

before redirect planning or application response callbacks run.

The URL supplied to the jar is always the target URL. A forward proxy is only a
route and never becomes the cookie origin. Redirect hops ask the jar again for
the new target URL, so domain, path, expiry, Secure handling, and cookie ordering
remain `HTTP::CookieJar` responsibilities.

When a cookie jar is configured, caller-supplied Cookie fields are rejected so
cookie selection has exactly one owner. Applications that need to seed or alter
cookie state should do so through the jar.

`connect_tunnel()` does not consult the cookie jar. CONNECT is an explicit
exchange with the named proxy endpoint and then a protocol handoff, not an
ordinary target-resource request.

## Proxy authentication

Caller-supplied `Proxy-Authorization` already works for ordinary forward-proxy
requests and explicit CONNECT. It remains associated with the selected proxy
route across redirect hops while target Authorization and cookies obey target
origin policy.

Automatic 407 challenge negotiation is deliberately deferred. General proxy
authentication can involve multiple schemes, challenge parsing, credential
lookup, retries, and replayability questions for streamed Request bodies. That
is substantially more policy than generating one header.

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
