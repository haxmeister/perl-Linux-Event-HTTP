# Linux::Event::HTTP handoff

Updated: 2026-09-13 (America/Chicago)

## Repository state

- Repo: `haxmeister/perl-Linux-Event-HTTP`
- Canonical branch: `main`
- Main baseline for current work: `9e387c6403de7ce48fa88f5ac3f9a3ea205bd102`
- Active branch: `feature/client-uniform-auth`
- Draft PR: #29, `Integrate Uniform HTTP authentication with Client`
- Do not merge PR #29 without explicit user authorization.
- Linux::Event minimum: `0.113`
- Linux::Event::HTTP remains `0.001 UNRELEASED`.

The merged baseline includes client/server Upgrade and CONNECT, explicit/default
forward-proxy routing, and `HTTP::CookieJar 0.014` cookie policy.

## External authentication dependency

HTTP authentication mechanics are supplied by the user's separate distribution:

- CPAN module: `Uniform::HTTP::Auth 0.01`
- Repository: `haxmeister/perl-Uniform-HTTP-Auth`
- API baseline inspected for this integration:
  `d5c555d85711b34127fd134e1c512f98860e8e32`

Do not modify the Uniform repository from this Linux::Event::HTTP Project unless
the user explicitly asks. Linux::Event::HTTP consumes its public API only.

Because CPAN mirror/index propagation has recently been unreliable, CI first
tries `Uniform::HTTP::Auth@0.01` from CPAN and then falls back to the exact
repository commit above. The fallback is intentionally pinned rather than using
a moving `main` archive.

## Authentication ownership boundary

`Uniform::HTTP::Auth` owns:

- WWW-Authenticate / Proxy-Authenticate challenge parsing;
- scheme selection;
- credential lookup;
- Basic, Bearer, and Digest construction;
- Digest nonce/cnonce state and supported algorithms/qop behavior.

`Linux::Event::HTTP::Client` owns:

- receiving 401 and 407 Responses;
- target-versus-route protection-space identity;
- Request replayability;
- draining challenge Responses to their HTTP message boundary;
- connection reuse/acquisition;
- creating retry Transactions;
- Client::Operation and callback lifecycle.

Request, Response, Transaction, Client::Connection, Linux::Event transport
queues, and native `_HTTP1` code remain authentication-unaware.

## Public Client authentication API

Client defaults:

```perl
use Uniform::HTTP::Auth;

my $auth = Uniform::HTTP::Auth->new(
    credentials => sub ($context) {
        return lookup_credentials($context);
    },
);

my $client = Linux::Event::HTTP::Client->new(
    loop             => $loop,
    auth             => $auth,
    proxy_auth       => $auth,
    max_auth_retries => 3,
);
```

- `auth` handles target 401 / `WWW-Authenticate`.
- `proxy_auth` handles route 407 / `Proxy-Authenticate`.
- both can be overridden per ordinary request or explicitly disabled with undef;
- `connect_tunnel()` uses `proxy_auth`, not target `auth`, and can override or
  disable it per call;
- `max_auth_retries` defaults to 3, can be overridden per operation, and zero
  disables automatic challenge retry.

When a manager is active, it owns its field: caller Authorization is rejected
under `auth`, and caller Proxy-Authorization is rejected under `proxy_auth`.
Disable the manager for an operation when manually constructing the field.

## Operation / replay semantics

Every successful automatic authentication retry is another HTTP Transaction in
the same Client::Operation. Transaction remains exactly one Request/Response
exchange.

Client::Operation now tracks:

- `redirect_count` independently;
- `auth_retry_count` independently;
- `max_redirects`;
- `max_auth_retries`;
- the complete Transaction and URL history.

Authentication retries repeat the same URL and do not increment redirect_count.
Redirects use their normal count and do not increment auth_retry_count.

Uniform receives the exact wire request-target:

- direct ordinary request: origin-form;
- proxied ordinary request: absolute-form;
- CONNECT: authority-form.

Target 401 uses the normalized target origin. Proxy 407 uses the selected route
origin. A proxy-authenticated request that then receives target 401 retains its
Proxy-Authorization for that same request while adding target Authorization.

Generated authentication fields are attempt-local and are not copied across
redirects. Uniform 0.01 deliberately has no preemptive-auth cache and Digest
includes request-target state, so a redirected endpoint can challenge again.

Complete scalar bodies are replayable and supplied to Uniform as `entity_body`,
which supports Digest `qop=auth-int`. Streaming Request producers are never
automatically replayed, even after production completes; a satisfiable challenge
terminates the Operation with a replayability error instead.

Intermediate satisfiable 401/407 Responses are drained but not delivered through
final `on_response`/`on_body`/`on_complete`. `on_redirect` remains redirect-only.
`on_informational` remains per Transaction.

## CONNECT authentication

`connect_tunnel()` can answer proxy 407 through `proxy_auth` before tunnel
handoff. A 407 is ordinary HTTP, is drained to its normal boundary, and can leave
a reusable proxy connection for the next CONNECT attempt. A successful 2xx then
uses the existing same-stream tunnel transition and leaves the HTTP pool.

Cookie policy remains separate: `connect_tunnel()` does not consult the cookie
jar.

## Focused tests

- `t/76-client-auth.t`
  - proxy 407 followed by target 401 in one Operation;
  - separate protection-space credential contexts;
  - independent auth/redirect accounting;
  - final-only response/body callbacks;
  - Digest SHA-256 `qop=auth-int` and exact direct request-target;
  - disabled retries and managed Authorization ownership.
- `t/77-client-connect-auth.t`
  - 407 -> authenticated CONNECT -> 2xx tunnel;
  - persistent proxy connection reuse between CONNECT attempts;
  - final-only response callback and same-stream post-2xx handoff.
- `t/78-client-auth-stream-replay.t`
  - satisfiable challenge for a completed streaming Request body is rejected as
    non-replayable;
  - no retry Transaction is created.

## Validation checkpoints

Executable head `979e042d35630d7c743d0f2aec7cb9f731cdee20` passed CI #411 / run
`34777499838` across Perl 5.36, latest, and latest threaded; latest also passed
end-to-end smoke and `disttest`.

Executable head with explicit streaming replay regression
`d195381f041157c7168b682e1c12653131656a17` passed CI #413 / run
`34777592918` across the same matrix, including latest smoke and `disttest`.

Documentation was then aligned in README, Client POD, Client::Operation POD,
`docs/CLIENT-POLICY.md`, `docs/ARCHITECTURE.md`, top-level POD, `Changes`,
`Makefile.PL`, CI, MANIFEST, and focused tests. This handoff is excluded from
MANIFEST.

## Deferred client policy

Keep these separate unless a real workload requires them:

- HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment discovery;
- NO_PROXY;
- PAC;
- SOCKS;
- preemptive authentication caches;
- Authentication-Info / Proxy-Authentication-Info handling;
- richer connection-pool policy;
- client response-parser XS without measurement justification.

After PR #29 is accepted, the next useful phase is a 0.001 release-readiness
audit rather than automatically adding another client policy subsystem.

## Branch policy

The user dislikes stale branches. Delete merged feature branches when available
tooling permits it. Do not reuse old merged feature refs for new work.
