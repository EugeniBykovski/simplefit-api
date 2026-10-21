# ADR 0010 — SimpleFit sessions and the current-user API

* Status: Accepted
* Date: 2026-10-06
* Ticket: SF-20 (builds on ADR 0009; amends ADR 0007 for the refresh cookie)
* Amended: 2026-10-19, SF-75: lost-response recovery (see "Reuse" and
  "Lost-response recovery (SF-75)"), approved as a change to strict rotation

## Context

Email, Google and Apple sign-in (SF-21, SF-22, SF-23) each end with a known
user. From that point on, SimpleFit needs its own session: revocable,
rotatable, the same for every provider, and safe on web and mobile.

## Decision

### SimpleFit owns the session

```
Identity → User → Session → authenticated viewer
```

* Provider credentials (Google/Apple ID tokens, access tokens, authorization
  codes, provider refresh tokens) end at the provider-verification step.
  They are never a SimpleFit session or bearer credential.
* `SimpleFit.Accounts.create_session(user)` is the only way to start a
  session. It takes just the user: the session does not know or store which
  provider established it.
* One session resolves exactly one user. A user can hold any number of
  sessions (devices); each is revoked independently.

### Storage

```
sessions                id, user_id → users (ON DELETE CASCADE), expires_at,
                        revoked_at, revoked_reason ('logout' | 'refresh_reuse'),
                        timestamps
session_refresh_tokens  id, session_id → sessions (ON DELETE CASCADE),
                        token_hash (SHA-256, unique), expires_at,
                        consumed_at, parent_id → session_refresh_tokens,
                        superseded_at, recoveries, inserted_at
```

* Database invariants:
  * at most one unconsumed refresh token per session (partial unique index);
  * `token_hash` is exactly 32 bytes and unique;
  * revocation fields are set together with a known reason;
  * only a consumed token can be superseded, and recoveries are bounded
    (SF-75);
  * a session expires after it was created.
* Indexes: `token_hash` (refresh lookup), the partial one-live-token index,
  and `user_id` / `session_id` for the cascades and a future "sign out
  everywhere".
* Expired sessions and consumed tokens accumulate. A periodic cleanup job is
  left to a later ticket; deleting a session deletes its tokens.

### Credentials

| | Access token | Refresh token |
| --- | --- | --- |
| Format | `sfa_` + `Plug.Crypto.sign/4` token | `sfr_` + 32 random bytes, base64url (43 chars) |
| Proof | HMAC-SHA256, key derived from `SECRET_KEY_BASE` with the salt `simplefit access token v1` | SHA-256 of the token, looked up through a unique index |
| Content | the session id only (signed, not encrypted) | none: opaque |
| Lifetime | 15 minutes | 30 days, never beyond the session |
| Use | `Authorization: Bearer` on every authenticated request | only `POST /api/auth/session/refresh` and logout |
| Stored | nowhere | only its SHA-256 |

* **Why not JWT:** the access token is checked against the session on every
  request anyway, so a standard self-contained format adds nothing; signing
  uses `plug_crypto`, already a dependency. No new library.
* **Prefixes:** `sfa_` and `sfr_` make the two kinds impossible to confuse
  (and easy to catch with secret scanners). Each endpoint accepts only its
  own kind.
* **Hashing:** the refresh secret has 256 bits of entropy, so a fast hash is
  enough. The lookup is by hash, so no comparison leaks timing about the
  secret. Signatures are verified by `Plug.Crypto` in constant time.
* **Randomness:** `:crypto.strong_rand_bytes/1`.

### Lifetime policy

`config :simple_fit, SimpleFit.Accounts.Sessions` (`config/config.exs`) is
the production policy, used unchanged by tests:

| Setting | Value | Why |
| --- | --- | --- |
| `access_token_ttl` | 900 s (15 min) | Short exposure if an access token leaks; refreshes stay infrequent |
| `refresh_token_ttl` | 30 days | A user who opens the app at least monthly stays signed in |
| `session_lifetime` | 90 days | Absolute bound: sign in again at least quarterly |

The signing secret comes from `SECRET_KEY_BASE` (at least 64 bytes) in
production and from fixed non-secret values in dev and test. The application
validates the whole policy at boot (`Sessions.config!/0`) and refuses to
start when it is missing or inconsistent. There is no "remember me" option.

### Refresh rotation

1. In one transaction:
   * find the token by hash and lock its session row (`FOR UPDATE`); check
     the session is neither revoked nor expired (otherwise `401`, nothing
     changes);
   * read the token again under the lock;
   * a live, unexpired token: consume it, insert its successor (a child,
     `parent_id`) and sign a new access token;
   * a consumed token: a lost-response recovery or a reuse (below).
2. Every refresh, recovery and logout of a session queues on its row lock,
   on any node or connection, so the decisions are serialized. Concurrent
   presentations of one live token: the first rotates; the next find it
   consumed with an unused child, which is a recovery (within its bounds) that
   supersedes that child. Exactly one live token remains: the partial unique
   index makes two impossible even if the code were wrong. The holder of a
   superseded child is detected on its next refresh. This is tested on real,
   separate connections.

### Reuse (replay): strict rotation

A refresh token is single use. Once A has rotated to B and **B has been
presented**, A is permanently retired, and any later presentation of A, at
any time, is reuse. Presenting a superseded token, or a consumed token
outside the recovery bounds below, is reuse too:

* the response is the same `401 unauthorized` as for any invalid token;
* the session is revoked (`refresh_reuse`): the successor B can no longer
  refresh, and every access token of the session stops working through the
  per-request session check.

There is no grace window: acceptance never depends on time alone. The only
exception is the lost-response recovery below, which is defined by the
token chain (the presented token's successor was never used) and only
bounded by time and count.

**Clients must serialize and coalesce refreshes:**

* one refresh in flight per session;
* other requests wait for its result;
* the web app coordinates across tabs.

Unknown and expired tokens fail without revoking anything.

### Lost-response recovery (SF-75)

A response can be lost after the server committed a rotation: a web page is
unloaded mid-refresh and the browser never applies `Set-Cookie`, or an app
is killed before it stores the new token. The client still holds A, already
consumed. Under strict rotation its next refresh revoked a legitimate
session (SF-54 investigation; reproduced in Chromium, Firefox and WebKit).

A consumed token A is **recovered** when, under the session lock:

* its child is the session's live token: none of A's children was ever
  presented, so nothing proves the response carrying it arrived;
* A itself was not superseded;
* A is unexpired, was consumed at most `refresh_recovery_window` (60 s)
  ago, and has fewer than `refresh_recovery_limit` (10) recoveries.

A recovery marks the unused child superseded (consumed), issues a new child
of A and increments A's `recoveries`. Anything else is reuse.

Security argument:

* **One chain.** A recovery replaces the only live token atomically; two
  live tokens cannot exist.
* **Two holders always collide.** If an owner and a thief both hold A, at
  most one holds the live child. The other's next refresh presents a
  superseded child (reuse), A after a child was used (reuse), or A again
  (a recovery that supersedes the first holder's child, whose next use is
  reuse). The session is revoked; detection is delayed by at most one
  refresh, never lost.
* **Bounded exposure.** Only the token a session presented last is
  recoverable, only until its child is used and only for 60 s. This extends
  the risk already accepted below ("a stolen refresh token used before its
  owner refreshes") to the predecessor for at most 60 s. A token older than
  one completed refresh can never be recovered.
* **Not proof of possession.** Inside the window the server cannot tell the
  owner's retry from a copy of the cookie used elsewhere; IP, User-Agent or
  tab ids would not prove it either. Only a device-bound key would; it is
  not part of this design.
* A late response for a superseded child that a browser applies after the
  newer cookie is presented as a superseded token: reuse, as before SF-75.
  Clients must not make refresh responses outlive their page (no
  `keepalive`).

Tokens issued before SF-75 have no `parent_id`, so their first rotation
after the deploy is strict. Code rollback is safe: older code sees
superseded tokens as consumed (reuse).

### Revocation and logout

* The authentication plug loads the session on every request, so a revoked
  or expired session is rejected immediately, not when the access token
  expires.
* `POST /api/auth/logout` revokes the session identified by any credential in
  the request: the bearer access token, a body `refresh_token`, or the web
  cookie (with the CSRF proof below). It always answers `204` and clears the
  cookie: logging out twice, or with an unknown or expired credential, is
  not an error and reveals nothing.
* Logout affects the current session only. The model already supports
  "sign out everywhere" and device lists (sessions per user); they need
  their own endpoints and UI.

### Transport: web and mobile

The session is shared; only the refresh token's transport differs.

* **Mobile (body):** the refresh token is sent and returned as JSON
  `refresh_token`. The app keeps it in secure storage (Keychain/Keystore).
* **Web (cookie):** the refresh token lives only in an `HttpOnly` cookie,
  never in JavaScript or localStorage:
  * `__Secure-sf_refresh`, `Secure`, `SameSite=Strict`, `Path=/api/auth`,
    host-only (no `Domain`), `Max-Age` up to the token's expiry;
  * in development (plain `http://localhost:4000`) `secure_cookie: false`
    names it `sf_refresh` without `Secure`; this is set only in
    `config/dev.exs`;
  * the web app and the API must share a registrable domain
    (`app.example.com` / `api.example.com`, or `localhost` ports), because the
    cookie is same-site only.
* The transport is where the refresh token came from. Sending both a cookie
  and a body token is `400 bad_request`, so a response never mixes them.
  Cookie responses omit `refresh_token` from the body
  (`refresh_token_transport: "cookie"`).
* The access token is always returned in the body and sent as a bearer
  header; web keeps it in memory.

### CSRF

Only cookie requests carry an ambient credential. They must have:

* an `Origin` header on the CORS allow-list, and
* `x-simplefit-csrf: 1`.

A cross-site form cannot set the header. A cross-site script cannot send it
without a CORS preflight that the API refuses for unknown origins.
`SameSite=Strict` is defence in depth, not the boundary: same-site but
foreign origins (other subdomains) are stopped by the `Origin` check.
Bearer and body requests need no CSRF protection because browsers never
attach those credentials automatically.

CORS sends `access-control-allow-credentials: true` only for allowed origins
on `/api/auth/session/refresh` and `/api/auth/logout` (amending ADR 0007);
every other path stays credential-free. `x-simplefit-csrf` is an allowed
request header.

### Endpoints and errors

| Endpoint | Auth | Success |
| --- | --- | --- |
| `GET /api/me` | bearer | `200 CurrentUserResponse` |
| `POST /api/auth/session/refresh` | refresh token (body or cookie) | `200 SessionTokens` |
| `POST /api/auth/logout` | any session credential, optional | `204` |

* Every authentication failure is the same `401 unauthorized` envelope with
  `www-authenticate: Bearer`, whether the credential is missing, malformed,
  expired, revoked, replayed or unknown. Failed cookie refreshes also clear
  the cookie.
* CSRF failures are `403 forbidden`; an ambiguous transport is
  `400 bad_request`.
* These are expected outcomes: they are not logged at `:error` and never
  reach Sentry.
* The endpoints live under `/api`, not `/api/v1`: like `/api/health`, they
  are session infrastructure rather than versioned product resources.

### `/api/me`

Returns `{"user": {"id", "created_at"}}`: only what the user record holds.
Identities (`provider_subject`), provider data and session secrets are never
included. Profiles, workspace memberships and other capabilities will be
added as sibling fields of `user` by the tickets that create them; there is
no role field.

### Privacy

* Tokens, hashes, cookies and the `Authorization` header are never logged,
  traced or sent to Sentry:
  * request logs carry the route only;
  * the span sanitizer strips headers;
  * Sentry drops the request interface;
  * `refresh_token` and `authorization` are filtered parameters.
* Queries that carry a refresh-token hash run with `log: false`, so Ecto's
  debug query log never prints the verifier.
* `token_hash` is a redacted field, so it never appears in `inspect/2`.
* Tests exercise every flow at debug log level and assert that no secret or
  hash appears in logs, traces, Sentry or error bodies.
* Nothing personal is left to HTTP caches (SF-70). Every response that
  carries new credentials (email, Google and Apple sign-in, registration
  verification, refresh; both transports) and every answer of the
  `:authenticated` pipeline is `Cache-Control: no-store`; Phoenix's default
  `private` still lets a client's own cache write it to disk. The header is
  necessary, not sufficient: on iOS `expo/fetch` used the shared `URLCache`,
  and in debug dev-client builds Expo's network inspector stores every
  response, `no-store` included. The mobile app therefore also gives its
  `fetch` session no cache and purges what earlier builds stored
  (simplefit-mobile `modules/sensitive-http-cache`; SF-70 report in
  simplefit-platform `docs/investigations/sf70-coach-fighter-e2e-hardening.md`).

### Rate limiting

Not added here; the API has no rate-limit infrastructure yet. Guessing a
refresh token (256 bits) or forging an access token is infeasible, and a
per-IP limit first needs the trusted-proxy configuration (`remote_ip`). Auth
abuse limits belong to SF-29.

## Consequences

* Every later authentication flow ends with `create_session/1` and renders
  `SessionJSON` through `SimpleFitWeb.SessionTransport`.
* Every authenticated request costs one indexed query (session joined with
  user). In exchange, revocation is immediate.
* Rotating `SECRET_KEY_BASE` invalidates all access tokens, which last at
  most 15 minutes. Refresh tokens survive, because they are not derived from
  it.
* A stolen refresh token used before its owner refreshes is not detected
  until the owner presents the consumed one; then both lose the session.
  Rotation shortens that window to one refresh cycle.
* A client that refreshes twice concurrently gets one live token and one
  superseded token; if it ever presents the superseded one, its user is
  signed out. Clients must still coordinate refreshes (see reuse above).
  The server relaxes strict rotation only for the bounded lost-response
  recovery (SF-75).

## Lifecycle semantics (SF-28)

SF-28 audited the lifecycle across the API, web and mobile clients and
changed no server behaviour; this section states the contract the clients
build on, and `test/simple_fit_web/session_lifecycle_test.exs` plus the
logout cases of `session_race_test.exs` assert it on PostgreSQL.

* **One session per sign-in, per device.** Browser A, browser B and a phone
  each hold their own session. Signing in again on a device creates a new
  session; it never reuses or extends an old one.
* **Logout is current-device only.** `POST /api/auth/logout` revokes the
  session behind the presented credential and nothing else; the user's other
  sessions keep working. There is no "sign out everywhere" and no session
  list (Claude Design WS1 marks both as not current).
* **Rotation and reuse.** A refresh rotates the token within the same
  session. Presenting a consumed token revokes that session (`refresh_reuse`)
  and only that one.
* **Logout and refresh race safely.** A refresh waiting while the session is
  revoked rolls back without consuming its token; a refresh that won first
  issues credentials that die with the session, and a logout with the
  consumed token still finds and revokes the session.
* **Expiry.** Access tokens last 15 minutes, refresh tokens 30 days, a
  session at most 90 days; an expired session can no longer refresh.
* **Revocation from another device** is not an operation yet; a session ends
  by its own logout, reuse, expiry or the deletion of its user.
* **Provider sign-out is not SimpleFit sign-out.** Signing out of Google or
  Apple on a device revokes no SimpleFit session, and a SimpleFit logout
  signs nobody out of their Google or Apple account.
* **Deleted users.** Deleting a user cascades to its sessions and refresh
  tokens: every credential is then the same `401`, and nothing recreates the
  account. Disabling or suspending an account is not a domain state yet
  (no field, no operation); WS4 / ST14 belong to a later ticket.
* **Offline logout.** A client that cannot reach the API discards its
  credentials locally; the server session then stays valid until it expires,
  and no client queues a credential to retry the logout later. The web app
  cannot delete the `HttpOnly` cookie itself, so it remembers that a logout
  is pending, never refreshes with that cookie, and retries the logout on the
  next load.
* **Passwordless.** There is no password, so password reset and password
  change are not applicable; recovery is a new email code (ADR 0012) or the
  provider sign-in again.
