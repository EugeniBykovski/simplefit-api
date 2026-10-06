# ADR 0013 — Google authentication

* Status: Accepted
* Date: 2026-10-07
* Ticket: SF-22 (SF-18 epic; builds on ADR 0009 identities, ADR 0010
  sessions, ADR 0012 rate limits; introduces the `SimpleFit.Identity`
  boundary anticipated by ADR 0004/0005)

## Context

Web, iOS and Android sign in with Google using the OAuth clients of the
SimpleFit Google Cloud project. Claude Design Version 66
(`1791292422-dc85`; A01, O02, O01b, O02w, WA1, RouteAuth, FlowAuthModel)
offers "Continue with Google" on sign-up and sign-in, and Google skips the
email code step.

## Decision

### Trust boundary

```
client (GIS on web, Google Sign-In on iOS/Android)
  → Google ID token → POST /api/auth/google
  → SimpleFit.Identity.verify(:google, token)      (independent verification)
  → Identity(provider: :google, provider_subject: sub)
  → resolve or register the user (ADR 0009)
  → SF-20 session (ADR 0010)
```

The Google ID token ends at the API. It is never stored and never a
SimpleFit credential. Nothing a client says about the person (email, name)
is trusted.

### Verification (`SimpleFit.Identity.Google`, `jose`)

* **Signature:** RS256 only (`JOSE.JWT.verify_strict/3`), with the key
  named by the header `kid`. `alg: none`, HMAC and other algorithms are
  rejected before any key is used. `jose` (erlang-jose, MIT, the base of
  Joken/Guardian) does the cryptography; nothing is hand-rolled.
  JokenJwks was not used because it brings Tesla.
* **`iss`:** `accounts.google.com` or `https://accounts.google.com` only.
* **`aud`:** a single string in `GOOGLE_OAUTH_CLIENT_IDS`.
* **`azp`:** when present, also in `GOOGLE_OAUTH_CLIENT_IDS`. A token for
  our audience issued to another client is rejected.
* **Time:** `exp` in the future; `iat` required and `nbf` (if present) not
  in the future; 30 s leeway.
* **`sub`:** required, printable ASCII 1..255 (the SF-19 subject rule).

Rejections are bounded reason atoms (`issuer`, `audience`,
`authorized_party`, `expired`, ...) for telemetry. Externally every
rejection is the same `401 unauthorized`.

### Signing keys (`SimpleFit.Identity.Google.Keys`)

A supervised process caches `https://www.googleapis.com/oauth2/v3/certs`,
fetched through `SimpleFit.HTTP` (TLS verification, timeouts, no retries or
redirects).

* Keys are valid for `Cache-Control: max-age` (300 s when absent).
* An unknown `kid` triggers one refresh, at most once per 60 s, so random
  `kid`s cannot cause a fetch storm.
* A failed or malformed refresh never replaces valid keys. There is no
  grace period beyond their lifetime.
* Without valid keys: `503 service_unavailable` (fail closed). A failed
  refresh is retried at most every 5 s.

### Audiences (`GOOGLE_OAUTH_CLIENT_IDS`)

* Comma separated, trimmed, empty entries dropped, deduplicated.
* Each entry must match `<digits>-<id>.apps.googleusercontent.com`; a
  malformed value fails the boot.
* Unset keeps the API bootable, but `/api/auth/google` answers `503`
  (ADR 0005 fail-closed providers).
* No client secret is used anywhere.

| Client | Appears as |
| --- | --- |
| Web (GIS) | `aud` |
| iOS | `aud` (and `azp`), or the web client when the app passes `webClientId` |
| Android (development; later Google Play) | `azp`; `aud` is the web client (the native library requires `webClientId` to issue an ID token) |

A future Google Play client is a new Android OAuth client (package + Play
App Signing SHA-1) whose id is added to `GOOGLE_OAUTH_CLIENT_IDS`. No code or
schema change is needed.

### Identity and accounts

* `Identity(provider: :google, provider_subject: sub)`. The `sub` is the
  only key. No migration was needed.
* **No email linking.** An email identity with the same address is never
  linked or merged: an unknown `sub` is always a new user. One person may
  temporarily have two users. That is deliberate and safer than trusting a
  provider's email assertion; linking will be an explicit, authenticated
  flow.
* **Order:** resolve, then `register_user/2` on a miss (atomic user +
  identity), then re-resolve on `:conflict`. Concurrent first sign-ins end
  with exactly one user and no orphan. The session is created after the
  account. A crash between the two leaves a valid account that the next
  sign-in resolves.
* Profile claims are never stored and never change the identity.

### Sessions and API

`POST /api/auth/google` (`authenticateWithGoogle`, public):

* request `{id_token, refresh_token_transport: "body" | "cookie"}`;
* response: `SessionTokens` fields plus `account: "created" | "existing"`.

Web uses the cookie transport (allowed `Origin` + `x-simplefit-csrf: 1`,
checked before verification; CORS credentials on this path). Mobile uses
the body transport. Every sign-in is a new independent SF-20 session.

`account` is a temporary routing signal (first-time onboarding vs.
workspaces) until profile/onboarding state is exposed (SF-25+). An account
whose onboarding was abandoned cannot yet be told apart.

### Replay

There is no replay store or nonce. A valid Google token may be exchanged
more than once during its lifetime; each exchange is an independently
revocable session. Refresh-token replay protection (ADR 0010) is a
different, unchanged mechanism.

### Abuse limits (`SimpleFit.RateLimit`)

| Bucket | Key | Limit |
| --- | --- | --- |
| `google_auth:ip` | client IP (`ClientIP`), before verification | 30 / 10 min |
| `google_auth:subject` | HMAC of the verified `sub`, after verification | 20 / 10 min |

Unverified claims never key a limit, so nobody can lock another person
out. Tokens and token fingerprints are never stored.

### Privacy

* `id_token` and `token` are filtered parameters.
* The token never reaches logs, telemetry, Sentry, traces, error bodies or
  OpenAPI examples. Tests cover this at debug log level.
* Telemetry `[:simple_fit, :auth, :google, :verified | :rejected |
  :unavailable | :rate_limited | :keys_unavailable]` carries bounded reasons
  only.

### Clients

* **Web:** the official Google Identity Services script and its rendered
  button. A Google-rendered button is the only way to obtain an ID token
  without a client secret, so it replaces the design's custom olive button.
  This is an intentional, documented deviation.
* **Mobile:** `@react-native-google-signin/google-signin` (free Original
  module) through its Expo config plugin and a development build (not Expo
  Go). Android matches the OAuth client by package `com.simplefit.boxing` +
  signing SHA-1, so the EAS development build (the registered SHA-1) is the
  acceptance path; a local `debug.keystore` fails unless its SHA-1 is
  registered too.
* **Technical debt:** on Android the Original module uses Google's
  deprecated legacy Sign-In API (removal date unannounced). Migrating to
  Credential Manager is a follow-up.

## Out of scope

Apple (SF-23), the full auth UI (SF-24), onboarding and profiles (SF-25+),
recovery (SF-28), account linking/merging, extra Google scopes, storing
Google access or refresh tokens, Google Play signing.

## Consequences

* Apple sign-in (SF-23) adds a provider to `SimpleFit.Identity` with the
  same shape.
* Google outages longer than the key lifetime make Google sign-in
  unavailable (`503`); email sign-in is unaffected.
* Adding a Google OAuth client is a configuration change.
