# ADR 0014 — Sign in with Apple

* Status: Accepted
* Date: 2026-10-07
* Ticket: SF-23 (SF-18 epic; builds on ADR 0009 identities, ADR 0010
  sessions, ADR 0012 rate limits and ADR 0013 Google authentication)

## Context

Claude Design `1791292422-dc85` offers "Continue with Apple" next to Google
on web sign-in and sign-up (WA1, O02w) and on iOS (A01, O01b, O02). Apple
skips the email code step. The Apple Developer setup is the App ID
`com.simplefit.boxing` (Sign in with Apple enabled) and the web Services ID
`com.simplefit.boxing.web`, grouped with it.

## Decision

### Flows

```
iOS: AuthenticationServices (expo-apple-authentication)
web: Apple JS, popup mode (response_mode web_message; no redirect callback)
  → identity token (request nonce = lowercase hex SHA-256 of a raw nonce R)
  → POST /api/auth/apple { id_token, nonce: R, refresh_token_transport }
  → SimpleFit.Identity.verify(:apple, %{id_token, nonce})
  → Identity(provider: :apple, provider_subject: sub)
  → resolve or register the user (ADR 0009)
  → SF-20 session (ADR 0010): body transport on iOS, cookie on the web
```

One endpoint serves both platforms and both sign-up and sign-in. There is
**no callback endpoint, no authorization-code exchange and no client
secret**: the identity token from the popup or the native sheet is verified
directly. A `form_post` callback was rejected because it needs
form-urlencoded parsing on the JSON-only API, a `SameSite=None` transaction
cookie (Apple's cross-site POST never carries our `SameSite=Strict` cookies),
the `.p8` client-secret JWT and a redirect back into the app; its only gain,
Apple refresh tokens, matters only for token revocation (out of scope).

### Verification (`SimpleFit.Identity.Apple`)

In order: protected header with `alg: RS256` and a non-empty `kid`;
`JOSE.JWT.verify_strict/3` (RS256 only) with Apple's key for `kid`;
`iss == "https://appleid.apple.com"`; `aud` a single string in
`APPLE_SIGN_IN_CLIENT_IDS`; `exp` in the future and `iat` present and not in
the future (30 s leeway); `sub` per the SF-19 rule; `nonce` equal to the
lowercase hex SHA-256 of the raw nonce, compared in constant time. Apple
tokens carry no `azp`. Email, `email_verified`, `is_private_email`, name,
`real_user_status` and `c_hash` are never read.

The nonce binds the token to the client that made the request: the raw
value only travels from that client to the API, so a token leaked elsewhere
cannot be exchanged. As for Google there is no replay store (ADR 0013); the
legitimate client re-sending its own pair only gets another session.

### Audiences (`APPLE_SIGN_IN_CLIENT_IDS`)

`com.simplefit.boxing` (native tokens) and `com.simplefit.boxing.web` (web
tokens), parsed like the Google list: trimmed, empty entries dropped, deduped,
each must look like a reverse-DNS identifier or the boot fails. Unset means
Apple sign-in answers 503 and a warning is logged at boot and per request
(the SF-22 lesson: a misconfiguration must be diagnosable without exposing
anything). Apple scopes the `sub` to the developer team, and the Services ID
is grouped with the App ID, so one person has one `sub` on web and iOS and
resolves to one SimpleFit user (to be confirmed by the manual acceptance).

### Keys

`https://appleid.apple.com/auth/keys` through `SimpleFit.Identity.KeyCache`,
the signing-key cache now shared with Google (`SimpleFit.Identity.Google.Keys`
keeps its behaviour): RSA/RS256 keys only, one refresh per unknown `kid` per
60 s, 5 s outage backoff, valid keys survive failed refreshes, fail closed.
Apple sends `Cache-Control: no-store`; keys are kept for the 300 s default
rather than fetched per request. Claim checks are never shared between
providers.

### Identity, scopes and attributes

SimpleFit requests **no Apple scopes**. `User` has nowhere to keep a name or
email, `sub` is the identity key, and Hide My Email users need no special
handling. Nothing Apple returns only on the first authorization is used, so
later sign-ins cannot lose or overwrite anything. Accounts are never linked
or merged by email; explicit linking is a future authenticated flow.
Concurrent first sign-ins resolve to one user
(`SimpleFit.Accounts.ProviderAccounts`, shared with Google).

### Limits, privacy

`apple_auth:ip` 30 / 10 min before verification and `apple_auth:subject`
20 / 10 min after it (HMAC key), with the SF-21 `ClientIP` policy. Every
rejection is the generic `401 unauthorized`; key outages and missing
configuration are `503 service_unavailable`; 429 stays distinct. `id_token`
and `nonce` are filtered parameters; identity queries are not logged by Ecto
(their parameters are provider subjects); telemetry carries only `account`
and bounded `reason` values.

## Out of scope

Android Apple sign-in, Apple token revocation and account deletion (they
need the Team ID, Key ID and `.p8` client-secret JWT), server-to-server
notifications, relay-email sender registration, storing Apple names or
emails, explicit linking, the full auth UI (SF-24) and onboarding routing.

## Consequences

* Web Apple sign-in needs a registered HTTPS domain and Return URL on the
  Services ID; `localhost` cannot be used.
* iOS needs a development build with the Sign in with Apple entitlement;
  Expo Go cannot be used.
* Adding an Apple client is a configuration change.
