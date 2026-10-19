# ADR 0019 — Identity security, abuse protection and observability (SF-29)

- Status: Accepted
- Date: 2026-10-11
- Ticket: SF-29

## Context

SF-19 to SF-28 built the passwordless identity vertical: one global user
(ADR 0009), SimpleFit sessions with rotating refresh tokens (ADR 0010), email
codes and links (ADR 0012), Google and Apple (ADR 0013, ADR 0014), account
registration and consent (ADR 0016), entry resolution (ADR 0017), first-run
state (ADR 0018), and the web and mobile session lifecycle (SF-24, SF-28).
SF-6 owns the error contract and SF-8 observability (ADR 0003, ADR 0008).

SF-29 audited that vertical as an attacker would, fixed the defects it
found with the smallest architecture-consistent changes, and proved the
invariants with deterministic tests. It does not add infrastructure, a new
security service, a schema or a public API change.

## Threat model

| Actor | Goal | Primary controls |
| --- | --- | --- |
| Unauthenticated remote attacker | Take over an account; flood auth endpoints | Short-lived single-use codes bound to purpose; per-target, per-IP and per-challenge limits in PostgreSQL; provider tokens verified against Google/Apple keys |
| Credential stuffing / OTP brute force | Guess a 6-digit code | 5 failed attempts per challenge (exact under concurrency), 60 verifications / 10 min per client, 10-minute expiry |
| Account-enumeration attacker | Learn whether an address has an account | Identical 202 responses, decoy challenges with the same limits, enumeration-safe status endpoint, no address in logs |
| Email abuse (mail bombing) | Make SimpleFit send mail to a victim | 1/min, 5/h, 10/day per address; 20 requests / 10 min per client; 60 s resend cooldown |
| Holder of a stolen access or refresh token | Use or keep a session | 15-minute access tokens re-checked against the session on every request; single-use refresh tokens; reuse revokes the session and is measured |
| Forged provider credential | Sign in as someone else | Signature, issuer, audience, expiry (and Apple's nonce) verified; subject-keyed identities, never linked by email |
| Spoofed proxy headers | Escape per-IP limits | `X-Forwarded-For` trusted only for a configured hop count; other forwarding headers ignored |
| IPv6 address rotation | Escape per-IP limits with a /64 | Limits keyed by /64 (this ADR) |
| Concurrent requests | Race limits or rotations | Atomic upserts for counters, row locks for challenges and refresh tokens |
| Leaky telemetry pipeline | Harvest credentials or personal data from logs, traces, Sentry | Allow-listed metadata, no bodies or headers, span sanitizer, Sentry filter, and a redaction filter on every log event (this ADR) |
| Misconfigured production | Weaken any of the above | Boot fails on missing secrets, malformed `TRUSTED_PROXY_HOPS` or CORS origins; providers fail closed |

## Control audit

Every sensitive operation was checked for the threats above. "Verified"
means an automated test asserts the control; the tests are listed at the
end.

| Operation | Controls | Status |
| --- | --- | --- |
| `POST /api/auth/email/registrations`, `/sign-in` (request a code) | Per-address windows, per-client limit, cooldown, decoys, generic 202 | Verified; IPv6 key fixed |
| `.../registrations/verify`, `.../sign-in/verify` (verify a code) | Purpose-bound keyed verifier, 5 attempts per challenge, per-client limit, expiry, one-time | Verified, including a 30-guess parallel burst |
| `.../verification-links/verify` | Hashed link token, per-client limit, never starts a session | Verified (ADR 0012 tests) |
| `.../registrations/status` | Per-client limit, generic `expired` for unknown tokens | Verified |
| `POST /api/auth/google`, `/apple` | Per-client and per-subject limits, full token verification, fail closed | Verified (ADR 0013/0014 tests) |
| `POST /api/auth/session/refresh` | 256-bit single-use tokens, hashed, row-locked rotation, reuse revokes (bounded lost-response recovery since SF-75, ADR 0010); CSRF + exact origin on the cookie transport | Verified; reuse now measured |
| `POST /api/auth/logout` | Current session only, idempotent, CSRF on the cookie transport | Verified (SF-28) |
| `GET /api/me`, `/api/v1/me/*` | Bearer token + live session check; every resource is the caller's own (no id in the path) | Verified; no 5xx and no echo on malformed input |
| Account registration and consent | Consent recorded for the authenticated caller only; versions server-side | Verified (ADR 0016 tests) |
| Entry resolution | `intent` is navigation, never authorization; bounded metadata | Verified (ADR 0017 tests) |

Findings, by severity:

| Severity | Finding | Fix |
| --- | --- | --- |
| Medium | Per-IP limits keyed by the full IPv6 address: one host owning a /64 could rotate addresses and escape every per-IP limit (code requests, verifications, provider sign-ins) | `ClientIP.limit_key/1` keys IPv6 by /64 and IPv4-mapped addresses as IPv4; all three auth controllers use it |
| Medium | The Sentry redactor missed SimpleFit's own token formats (`sfa_`, `sfr_`, `sfv_`, `sfg_`), JWTs, `inspect`'s `"key" => "value"` form, Erlang-formatted crash reports and email addresses; production log text (crash reports included) was not redacted at all | `SimpleFit.Observability.Redaction`, shared by Sentry and a new primary `:logger` filter (`LogRedactor`) |
| Low | A refresh-token reuse (the signature of a stolen token) revoked the session silently: no log, no metric | `[:simple_fit, :auth, :session, :refresh]` with `outcome` (`rotated`, `rejected`, `reuse`) and a warning log on reuse |
| Already protected | Everything else in the tables above, including enumeration resistance, CSRF, CORS, provider validation, the SF-28 cross-account client races | — |

No Critical or High finding was found. A malformed-payload sweep (17
endpoints × 9 payload shapes, including credentials, JWTs, emails, names,
nested objects and 20 kB strings) produced no 5xx and no leak.

## Decisions

### Rate-limit policy

All limits are fixed windows in PostgreSQL (`SimpleFit.RateLimit`): shared
by every app instance, kept across restarts, counted exactly under
concurrency (one atomic upsert per hit), keyed by an HMAC of the target or
client (nothing personal stored), and purged hourly. Over the limit the API
answers `429 rate_limited` with `retry-after`; hits over the limit keep
counting. Values are unchanged from ADR 0012-0014; SF-29 changed the client
key only.

| Operation | Limit | Window | Key | Objective | Legitimate impact |
| --- | --- | --- | --- | --- | --- |
| Request a code (registration or sign-in) | 1 / 5 / 10 | 1 min / 1 h / 1 day | Address (purpose-scoped) | Mail bombing, OTP farming | None in normal use |
| Request a code | 20 | 10 min | Client (IPv4 / IPv6 /64) | Spraying many addresses | Shared NATs: 20 people in 10 min |
| Resend | 60 s cooldown | per challenge | Challenge | Resend abuse | Wait one minute |
| Verify a code | 5 failed attempts | per challenge | Challenge | Guessing (10^6 space) | Request a new code after 5 typos |
| Verify a code or link | 60 | 10 min | Client | Guessing across challenges | None |
| Registration status | 120 | 10 min | Client | Token probing | None (clients poll slowly) |
| Google / Apple sign-in | 30 | 10 min | Client | Token floods | None |
| Google / Apple sign-in | 20 | 10 min | Provider subject | Replays of one identity | None |
| Refresh, logout | none | — | — | 256-bit single-use tokens make guessing infeasible; each attempt is one indexed query | — |

Refresh and logout stay unlimited by design (ADR 0010); a flood of refresh
attempts is visible as `simple_fit.auth.session.refresh.count` with outcome
`rejected`.

### Client identity

`SimpleFitWeb.ClientIP.limit_key/1` is the only rate-limit identity: the
direct peer address unless `TRUSTED_PROXY_HOPS = n`, in which case the n-th
`X-Forwarded-For` entry from the right (entries further left are client
text and ignored). `X-Real-IP` and `Forwarded` are never read. Malformed,
port-suffixed or bracketed entries fall back to the proxy address, never to
client text. IPv6 is keyed by /64, IPv4-mapped IPv6 as IPv4.

Deployment requirement: no production deployment exists yet, so the proxy
topology is unverified and `TRUSTED_PROXY_HOPS` stays `0` (the peer). Behind
a load balancer this makes every client share the balancer's address for
per-IP limits (coarse but never spoofable); per-address, per-challenge and
per-subject limits are unaffected. The deployment ticket sets the hop count
after verifying the topology, and the app must not be reachable around the
proxies.

### Secret-redaction contract

Credentials (authorization headers, access and refresh tokens, cookies, the
CSRF header, link and registration tokens, codes, Google and Apple identity
tokens, nonces, provider secrets) and personal data (email addresses, full
name, date of birth) never appear in logs, Sentry, spans, telemetry metadata
or error responses. Layers, outermost last:

1. No bodies, params, headers or query strings are logged; metadata is an
   allow-list (ADR 0008); secret queries run with `log: false`.
2. `SpanSanitizer` strips span attributes; `SentryFilter` strips request,
   user, extra and frame variables from every event.
3. `Redaction` replaces credential formats and personal-data values in any
   free text: `LogRedactor` applies it to every log event (string, format
   and report messages, and the exception inside `crash_reason`), and
   `SentryFilter` to messages, exception values and breadcrumbs. If
   redaction itself fails, the event keeps its level and metadata and its
   text is withheld.

The email job payload is the one place a code and an address are stored:
encrypted at rest (ADR 0011/0012), never logged (`JobLogger` writes outcomes
only).

### Telemetry classification

| Situation | Response | Measured | Sentry |
| --- | --- | --- | --- |
| Missing, invalid, expired or revoked credential | 401 `unauthorized` | Request log (route, status); refresh outcome | No |
| Routine 403 (CSRF, origin) | 403 `forbidden` | Request log | No |
| Rate limited | 429 `rate_limited` | `*.rate_limited.count` (no metadata) + request log | No |
| Invalid code / provider credential | 422 / 401 | `*.rejected.count` with a bounded `reason` | No |
| Provider or key-set outage | 503 `service_unavailable` | `*.unavailable.count`, `*.keys_unavailable.count` with a bounded `reason`; warning log | No (alert on the rate) |
| Refresh-token reuse | 401 | `session.refresh.count{outcome=reuse}`; warning log | No (alert on the rate) |
| Lost-response recovery (SF-75) | 200 | `session.refresh.count{outcome=recovered}`; info log | No (a rising rate means responses are being lost) |
| Unexpected exception, crash, DB failure | 500 | Error log | Yes, redacted |

Labels are bounded enums only: never an address, token, user agent, IP or
free text. No dashboard or alert exists yet; recommended alerts: any
sustained `session.refresh{outcome=reuse}`, `*.unavailable` above a few per
minute, `*.rate_limited` spikes, and any Sentry event on `/api/auth/*`.

### Session invariants (re-verified)

Unchanged from ADR 0010 and SF-28: access tokens expire after 15 minutes and
are checked against a live session on every request; refresh tokens are
stored as SHA-256, single use, rotated under a row lock; reuse revokes the
session; logout revokes the current session only; logout and refresh race
safely; a deleted user's sessions disappear with it; the web and mobile
clients drop late responses of a previous session (SF-28).

## Consequences

* Defence in depth for unexpected failures now lives in one module
  (`Redaction`); new credential formats must be added there.
* `LogRedactor` runs on every log event: a few regular expressions per
  event, negligible next to I/O.
* Per-IP limits treat a /64 as one client: a large IPv6 network behind one
  /64 shares the 20 / 10 min code-request budget, like an IPv4 NAT.

## Remaining risks and non-scope

* Timing: a code request for a deliverable address also enqueues the email
  job (one extra insert in the same transaction). Responses are identical;
  the timing difference is small but not proven constant.
* Without a configured hop count, per-IP limits are coarse behind a proxy
  (see Client identity).
* No CAPTCHA, IP reputation or adaptive limits; no sign-out-everywhere,
  session list or account suspension (WS1, WS4); no audit-event store. Each
  needs its own decision.
* Metrics have no reporter or alerts yet (ADR 0004: deferred).

## Tests (SF-29)

* `test/simple_fit_web/security_observability_test.exs`: malformed-payload
  canary sweep over every endpoint (logs at debug, bodies, Sentry,
  telemetry); refresh outcome and reuse classification; 401/403 not in
  Sentry; 429 measured without the address; exact-origin CSRF.
* `test/simple_fit/observability/redaction_test.exs`: every credential and
  personal-data form; error logs, task crashes and GenServer crash reports
  redacted in logs and Sentry, while still reaching Sentry.
* `test/simple_fit/security/abuse_concurrency_test.exs`: exact parallel
  counting, window expiry, a 30-guess parallel burst on real connections.
* `test/simple_fit_web/client_ip_test.exs`: spoofed and malformed forwarding
  headers, IPv6 /64, IPv4-mapped, multi-line headers.

## Amendment (SF-57)

Coach invitation tokens (`sfi_`) join the redacted token formats, and the
invitation endpoints join the canary probe. Their limits (ADR 0021
amendment) follow this ADR's conventions: PostgreSQL fixed windows, HMAC
keys, `429 rate_limited` with `retry-after`, clients keyed by
`ClientIP.limit_key/1`.

