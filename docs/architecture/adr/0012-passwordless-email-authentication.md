# ADR 0012 — Passwordless email authentication

* Status: Accepted
* Date: 2026-10-07
* Ticket: SF-21 (SF-18 epic; builds on ADR 0009 identities, ADR 0010
  sessions, ADR 0011 email templates; amends ADR 0007 CORS)

## Context

SimpleFit has no passwords. Claude Design Version 66
(https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY, `1791292422-dc85`;
`project/FlowAuthModel.dc.html`, O02/O03/O01b/O01c, WA3/WA4/WA4b/WA1/WA1b,
`AuthCodeInput`, `AuthStatesMobile`, `AuthStatesWeb`, E01, E17) defines
email authentication as two different security purposes that share one
6-digit code input and never present as the same operation.

## Decision

### Two purposes, isolated

| | Email verification (registration) | Email sign-in |
| --- | --- | --- |
| Proves | ownership of a new address | control of an existing email identity's address |
| Email | E01: code **and** "Verify email" link | E17: code only, no link |
| Outcome | the user and its email identity exist | an SF-20 session |
| Session | only for the registration client that entered the code (below) | yes |

No passwords, password hashes, resets or policies; no passkeys,
authenticator apps, recovery codes or magic-login links. A credential of
one purpose never satisfies the other: the code verifier binds the
purpose, and each purpose has its own challenges.

### Challenges (`email_auth_challenges`)

```
id, purpose ('verification' | 'sign_in'),
target_digest      HMAC of the canonical email (both purposes)
email              canonical email, verification only (redacted)
code_hash          keyed verifier of the 6-digit code
link_token_hash    SHA-256 of the E01 link token, verification only (unique)
registration_token_hash
                   SHA-256 of the registration token, verification only (unique)
failed_attempts    0..5
expires_at, closed_at, closed_reason, session_created_at, inserted_at
```

* **Targets.** Verification targets the canonical email: no user or
  identity exists until the address is verified, so a pending
  registration never reserves an address; it expires or is replaced.
  Sign-in stores only the digest (no email, no identity id): the identity
  is resolved from the submitted address after a correct code. Digests let
  decoys (below) look exactly like real challenges.
* **One open challenge per purpose and target** (partial unique index
  `WHERE closed_at IS NULL`). A request supersedes the open challenge and
  inserts a new one in one transaction; a concurrent request that loses the
  index retries.
* **Terminal state:** `closed_at` + `closed_reason`:
  * `code_verified` - the code was entered by the client that requested
    the challenge. The only state with a session (`session_created_at`);
  * `link_verified` - the E01 link verified the address. Never a session;
  * `superseded`, `exhausted`, `conflict`.

  Expiry is derived from `expires_at`, never written.
* **Database invariants (checks):**
  * verification rows carry the email and both token hashes, sign-in rows
    none of them;
  * verifiers are 32 bytes;
  * `failed_attempts` is `0..5`;
  * `expires_at > inserted_at`;
  * closed fields are set together with a known reason, and `link_verified`
    only for verification;
  * `session_created_at` only with `code_verified`: a link-verified
    challenge can never carry a session.
* **Policy** (`config :simple_fit, SimpleFit.Accounts.EmailAuth`,
  `config/config.exs`, checked at boot; no environment variables):
  `challenge_ttl` 600 s (the design's 10 minutes), `max_failed_attempts`
  5, `resend_cooldown` 60 s. E01 and E17 receive `expires_in_minutes`
  from `challenge_ttl`.

### Credentials

Keys are 32-byte keys derived from `SECRET_KEY_BASE` with
`Plug.Crypto.KeyGenerator` (PBKDF2-HMAC-SHA256), one salt each:
`"simplefit email auth code v1"`, `"simplefit email auth target v1"`,
`"simplefit auth rate limit v1"`.

* **Code:** 6 digits, `000000`–`999999`, from `:crypto.strong_rand_bytes/1`
  with rejection sampling (values ≥ 4,294,000,000 are redrawn, so there is
  no modulo bias).
* **Code verifier:** `HMAC-SHA256(code_key, "sfec1" ‖ 0 ‖ purpose ‖ 0 ‖
  challenge_id (16 bytes) ‖ 0 ‖ code)`, compared with
  `Plug.Crypto.secure_compare/2`. Only a million codes exist, so an unkeyed
  hash would fall to brute force from a database copy; the key prevents
  that. Binding the purpose and challenge id means a code never verifies
  another challenge or purpose.
* **Link token:** `sfv_` + 32 random bytes, base64url without padding.
  Stored as SHA-256 (it has 256 bits of entropy, as SF-20 refresh tokens),
  looked up through a unique index. Independent of the code; same
  challenge, same expiry.
* **Registration token:** `sfg_` + 32 random bytes, returned only to the
  client that requested the registration; stored as SHA-256.
* The code, tokens, verifiers, digests and keys are never logged; queries
  that carry them run with `log: false`; schema fields are redacted.

### Registration and the Version 66 device rule

```
POST /registrations {email}            → registration_token; E01 (code + link)
POST /registrations/verify {token, code} → user + identity + the one session
POST /verification-links/verify {token}  → verified; never a session
POST /registrations/status {token}       → pending | completed | verified_elsewhere | expired
```

* **Same device (code).** The client that started the registration sends
  its registration token and the code. In one transaction:
  1. lock the challenge;
  2. check it is open, unexpired and the code matches;
  3. create the user and the email identity;
  4. close the challenge as `code_verified`;
  5. create the SF-20 session.

  Exactly one session per registration.
* **Link (any device).** The token from `/verify-email#token=...` is posted
  by the web app. It verifies the address (user and identity created) and
  closes the challenge as `link_verified`. It creates no session, neither
  for the browser that opened it nor for the device that started the
  registration.
* **Verified elsewhere.** The registration device sees
  `verified_elsewhere` (status, or its code is refused with that code). Its
  registration token can never produce a session any more. Fresh mailbox
  proof is an email **sign-in** (E17), never another verification E01.
  `email_verified` and "this registration token may get a session" are
  different facts: only `code_verified` with the token's own code issues a
  session.
* **Code and link race.** Both lock the same challenge row. The first
  closes it; the second sees it closed:
  * the link gets `already_verified`;
  * the code gets `verified_elsewhere`;
  * a replayed code gets `code_expired`.

  No second user, identity or session.
* **Identity appeared meanwhile.** The identity insert is `ON CONFLICT DO
  NOTHING` inside the transaction, so the unique index decides without
  aborting it. On conflict the new user row is removed, the challenge
  closes as `conflict`, and the result is `conflict` (code) or
  `already_verified` (link). Nothing is linked, moved or merged; this is
  not a linking primitive.
* **Existing account at sign-up.** The response is identical, with a
  registration token. A decoy challenge is stored whose verifiers match
  nothing, and no email is sent. No user, identity or session is created.
  Sign-up never becomes sign-in.

### Sign-in

```
POST /sign-in {email}                  → identical 202; E17 if an email identity exists
POST /sign-in/verify {email, code}     → SF-20 session
```

* For an address without an identity (unknown, or only a pending
  registration) a decoy sign-in challenge is stored and nothing is sent.
* Verification locks the target's latest sign-in challenge, so concurrent
  correct submissions and replays yield exactly one session.

### Attempts, expiry, resend

* A wrong code increments `failed_attempts`. The fifth closes the challenge
  (`exhausted`); from then on even the right code is refused. Clients are
  never told how many attempts remain. This is separate from request
  throttling.
* Resend is a new request: the old challenge is superseded and a new code,
  link and registration token are issued with a fresh 10 minutes. Delayed
  emails of the old challenge fail deterministically.

### Enumeration resistance

* Requests answer the same status and body for every well-formed address.
  Decoys behave like real challenges:
  * they expire;
  * they count wrong codes and exhaust;
  * they are superseded.

  Their verifiers match nothing.
* Limits are keyed by target, whatever the account state.
* Expected outcomes map to fixed codes:

  | Outcome | Response |
  | --- | --- |
  | wrong code | `code_invalid` (422) |
  | expired, superseded, exhausted, used or unknown | `code_expired` (422) |
  | registration verified through the link | `verified_elsewhere` (409) |
  | the address was taken during registration | `conflict` (409) |

  `verified_elsewhere` and `conflict` are only reachable after mailbox
  proof (a correct code, or the link).
* Residual timing: only real requests render and enqueue an email (about a
  millisecond). Per-target limits (10 per day) make a remote timing oracle
  impractical.

### Abuse limits (`SimpleFit.RateLimit`, `auth_rate_limits`)

Fixed windows in PostgreSQL, so every app instance shares the counters.
Each hit is one atomic `INSERT ... ON CONFLICT DO UPDATE ... RETURNING
count`, never read-then-write. Keys are HMAC digests: no email or IP is
stored.

| Bucket | Key | Limit |
| --- | --- | --- |
| verification request (and resend) | target | 1 / 60 s, 5 / hour, 10 / day |
| sign-in request (and resend) | target | 1 / 60 s, 5 / hour, 10 / day |
| any code request | client IP | 20 / 10 min |
| code or link verification | client IP | 60 / 10 min |
| registration status | client IP | 120 / 10 min |
| wrong codes | challenge | 5 (on the challenge row) |

Over a limit: `429 rate_limited` with `retry-after` (the design's "Too many
attempts. Try again shortly.").

### Client IP (`SimpleFitWeb.ClientIP`, `TRUSTED_PROXY_HOPS`)

* **Default `0`:** the direct peer address. `X-Forwarded-For` is ignored,
  so no client can choose its IP. Behind a proxy all clients share the
  proxy's IP bucket. That is coarse but safe, and per-target and
  per-challenge limits still apply.
* **`n > 0`:** the client is the `n`-th address from the right of
  `X-Forwarded-For` (the entry the outermost trusted proxy appended).
* **Before setting it in production:** verify the topology. Every request
  must cross exactly `n` proxies that append the client address, and the
  app must not be reachable around them.
* **Misconfiguration:**
  * a value too high lets clients spoof their IP and dodge IP limits;
  * a value too low collapses users into the proxy's bucket.

  The value is never enabled by default for any host.

### SF-20 sessions

Both session-issuing endpoints call `Sessions.create/1` inside the
challenge transaction and render `SessionJSON` through `SessionTransport`.
`refresh_token_transport` is `body` (mobile, default) or `cookie` (web).
The cookie transport requires an allow-listed `Origin` and
`x-simplefit-csrf: 1` before anything is verified. CORS allows credentials
on these two paths (amends ADR 0007, as ADR 0010 did). There is no other
session, token or JWT.

### Email delivery

`Templates.verify_email/1` (E01) and `Templates.sign_in_code/1` (E17) run
through `SimpleFit.Email.deliver_later/1`, which stores an encrypted
payload and uses the Oban `mailers` queue (ADR 0011). The job is enqueued
in the challenge transaction: a challenge exists only if its email was
queued. Provider failures follow SF-35 retries.

`verify_url` is `<WEB_APP_URL>/verify-email#token=<link token>`. The
fragment never reaches a server by itself, and the 6-digit code is never in
a URL. `WEB_APP_URL` is required in production (https origin, checked at
boot).

### Cleanup

An hourly Oban Cron job (`EmailAuth.CleanupWorker`) deletes challenges
closed or expired more than an hour ago, and rate-limit windows older than
two days.

### Observability

Telemetry `[:simple_fit, :auth, :email, :requested | :sent | :verified |
:rejected | :rate_limited]` carries only the purpose, channel (`code` /
`link`) and rejection reason. Expected outcomes are returned, never
raised, and never reach Sentry. `code` and `email` are filtered request
parameters (`token` already was).

## Deferred: staff invitations

The future staff-invite flow (OS1/OS1b, E06) can reuse email ownership
proof. Its OS1b design still shows a `verified-link` state that continues
on the invitation device. That integration **must not treat external link
verification as authentication of the invitation device**: the device
needs its own fresh proof (code entered there, or an email sign-in), the
same rule as registration above. SF-21 provides no invitation API.

## Out of scope

Google (SF-22), Apple (SF-23), auth UI (SF-24), onboarding and profiles
(SF-25+), account recovery (SF-28), passkeys, passwords, authenticator
apps, recovery codes, account linking, sponsor/admin auth, frontend routes
(including `/verify-email`), and broader abuse hardening such as
reputation, CAPTCHA or adaptive risk (SF-29).

## Consequences

* Registration needs the device that started it to enter the code, or a
  sign-in after a link verification elsewhere. This closes pre-hijacking
  through the link.
* Rotating `SECRET_KEY_BASE` invalidates open codes (10 minutes at most)
  and resets rate-limit keys.
* Rate limiting costs one indexed upsert per rule on auth endpoints.
