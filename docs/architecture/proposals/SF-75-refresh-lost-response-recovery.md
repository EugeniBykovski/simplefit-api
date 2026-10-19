# SF-75 proposal — lost-response recovery for refresh rotation

* Status: **Accepted** (approved 2026-10-19; amends ADR 0010 "Reuse (replay):
  strict rotation")
* Date: 2026-10-19
* Ticket: SF-75 (release blocker found in SF-54;
  `simplefit-platform/docs/investigations/session-refresh-navigation-race.md`)

## 1. Root cause (proven on real Phoenix + PostgreSQL)

Web transport keeps the access token in memory only, so every full document
load restores the session by spending the `HttpOnly` refresh cookie
(`POST /api/auth/session/refresh`). When a document is unloaded after the API
has committed a rotation (R1 consumed, R2 issued) but before the browser has
processed the response, the browser cancels the request and never applies
`Set-Cookie: R2`. The jar still holds R1. The next document presents R1;
ADR 0010 treats any consumed token as reuse and revokes the session.

The web coordinator cannot close this:

* the Web Lock is owned by a document and released when it is destroyed,
  while the request it guarded is committed on the server;
* BroadcastChannel only reaches live documents, and the dying document never
  received R2 to broadcast;
* the new document cannot learn R2 at all: it exists only in the lost
  response, and the cookie is unreadable by design.

### Reproduction (2026-10-19, `main` api `025a79b` / platform `bea7dec`)

Production Next.js build; real Phoenix (`MIX_ENV=dev`) on a disposable
`simple_fit_sf75_e2e` database; a pass-through TCP-level HTTP proxy in front
of the API that can hold the refresh **response** after the API committed
(no Playwright request interception, so browser cookie handling is real).
Sanitized evidence: method, path, status, timing and DB token counts only.

| # | Scenario | Chromium | Firefox | WebKit |
| - | -------- | -------- | ------- | ------ |
| 1 | Rapid reloads ×10 (natural) | kept | kept | **revoked** |
| 2 | Two consecutive full navigations | kept | kept | kept |
| 3 | Navigation while refresh in flight, before it reaches the API | kept (never forwarded) | kept | kept |
| 4 | Navigation immediately after the refresh starts | kept | kept | kept |
| 5 | Navigation after the API commits, before `Set-Cookie` | **revoked** | **revoked** | **revoked** |
| 6 | Two tabs refreshing at once | kept (Web Lock) | kept | kept |
| 7 | Refresh in tab A while tab B signs out | `logout` wins | `logout` wins | `logout` wins |
| 8 | Back/Forward (natural) | **revoked** | kept | kept |
| 9 | Deep link in a new tab during a restore | kept | kept | kept |
| 10 | Reload Coach Home during a restore | **revoked** | **revoked** | **revoked** |
| 11 | Coach → Fighter → Coach document navigations (dual role) | kept | kept | kept |
| 12 | Reload the invitation page during a restore | **revoked** | **revoked** | **revoked** |
| 13 | Slow network (900 ms), navigation mid-refresh | kept | kept | kept |
| 14 | Replay from an independent client (two cookie jars) | thief replaying consumed R1: 401, session revoked; thief using live R1 first: owner's R1 is reuse, session revoked | — | — |

Every revocation has the same proxy trace: `request → upstream 200
(Set-Cookie) → held → client-aborted → response-lost → request (old cookie) →
upstream 401`, and the session row ends `refresh_reuse`.

The committed `session-navigation-race.spec.ts` passes in WebKit (an
"unexpected pass") because it holds the response with `route.fetch()`, whose
response cookies already reach the context jar before the hold. It is not a
faithful lost response there and will be rewritten.

## 2. Security invariants

| # | Invariant | After the proposal |
| - | --------- | ------------------ |
| 1 | Refresh tokens are unpredictable (256-bit, CSPRNG) | unchanged |
| 2 | Never in localStorage | unchanged |
| 3 | `HttpOnly; Secure; SameSite=Strict; Path=/api/auth` cookie | unchanged |
| 4 | A stolen refresh token cannot silently take over a session | holds: every acceptance supersedes the other holder's token, whose next use revokes (§4.3) |
| 5 | Rotation is atomic | holds: one transaction under the session row lock |
| 6 | No two valid successor chains | holds: at most one live token per session (existing partial unique index) |
| 7 | User A's token cannot restore A after B signs in | unchanged (new session per sign-in; client epochs) |
| 8 | Logout invalidates the intended session | unchanged (logout with any token of the family revokes the session) |
| 9 | Reuse outside the defined recovery still revokes | holds, with the amended definition of reuse (§4.2) |
| 10 | CSRF (allow-listed `Origin` + `x-simplefit-csrf`) | unchanged |
| 11 | Cross-origin refresh rejected | unchanged |
| 12 | A network error is not revocation | unchanged on the client; recovery also stops a lost *response* from becoming one |
| 13 | No privilege escalation | recovery stays inside the same session and user |
| 14 | No unbounded retry/rotation loop | recovery bounded per token (count) and in time |
| 15 | Multiple independent devices | unchanged (sessions are per device) |
| 16 | No secrets in logs, Sentry, telemetry | unchanged; one new bounded outcome label |

## 3. Strategies evaluated

**A. Bounded lost-response recovery (backend), chosen, combined with B's
proof-of-receipt rule.** See §4.

**B. Acknowledgement / continuation protocol.** A token is retired only when
its successor is first presented (the successor's presentation proves the
response arrived). A separate "ack" request does not help: its response can
be lost too, and whatever step returns the access token must stay repeatable
until receipt is proven. B is therefore the same state machine as A, with
"proof of receipt" as the recovery condition. It is folded into A.

**C. Client lifecycle only.**
* `keepalive: true` on the refresh: the response may still apply after unload,
  but the next document starts its refresh before it arrives (no ordering
  guarantee), and a late cookie can then overwrite a newer one. Rejected: it
  narrows the window and adds an ordering hazard.
* Delaying unload / `beforeunload` until the refresh settles: forbidden by
  the ticket (delay as correctness), and unload cannot be blocked anyway.
* A Service Worker as the single refresh owner (survives navigations):
  a second refresh manager, the access token moves into a long-lived worker
  (ADR 0010 / SF-22 decision), no service worker in Firefox private windows,
  workers are terminated by the browser at will and a crash still loses the
  response. Rejected.

**D. Alternatives.**
* *Device-bound proof (DPoP-like):* a non-extractable WebCrypto key per
  browser, registered with the session; recovery (or every refresh) requires
  a signature. This is the only option that distinguishes another device
  holding a copied cookie inside the window. Costs: new proof format and
  verification, key registration in every sign-in flow (email, Google,
  Apple, registration) and the contract, key-loss handling (cleared storage,
  private windows), and mobile parity. Against the realistic thief (someone
  who can read the browser profile from disk, who can usually read the key
  store as well) the gain is small. Not chosen now; a natural follow-up if
  sender-constrained sessions become a requirement.
* *A second "proof" cookie:* lives in the same jar as the refresh cookie,
  so a jar thief has both. Rejected.
* *IP / User-Agent / tab id binding:* not proof of possession (ticket).
  Rejected.
* *Naive grace window ("accept a consumed token for N s"):* forbidden;
  lets a stolen predecessor fork the chain. Rejected.

## 4. Recommended architecture: proof-of-receipt rotation with bounded recovery

### 4.1 Model

`session_refresh_tokens` gains (migration, reversible):

* `parent_id` → `session_refresh_tokens.id` (nullable, `ON DELETE CASCADE`):
  the token whose presentation issued this one (`NULL` for a session's first
  token and for tokens issued before the deploy);
* `superseded_at` (nullable): set, together with `consumed_at`, when a token
  is replaced by a recovery **before it was ever presented**;
* `recoveries` (`smallint`, default 0): recoveries made from this token.

Constraints: `superseded_at` implies `consumed_at`; `0 <= recoveries <=
recovery_limit`; index on `parent_id`. The existing "one unconsumed token per
session" partial unique index is unchanged.

### 4.2 Rotation (one transaction, `SELECT … FOR UPDATE` on the session row)

Look the token up by hash, lock its session, then decide on the locked state:

1. unknown token, expired token → `401`, nothing changes (as today);
2. session revoked or expired → `401`, nothing changes (as today);
3. token live → **rotate**: consume it, issue a child (`parent_id` = token);
4. token consumed, not superseded, **the parent of the session's live
   token** (so none of its children has ever been presented), consumed at
   most `recovery_window` ago, `recoveries < recovery_limit` → **recover**:
   supersede the live child, issue a new child of the same token,
   `recoveries + 1`;
5. anything else (an older ancestor, a superseded token, a token whose child
   was already presented, outside the window, over the limit) → **reuse**:
   revoke the session (`refresh_reuse`), `401` (as today).

Policy (`config :simple_fit, SimpleFit.Accounts.Sessions`, validated at boot):
`refresh_recovery_window` 60 s and `refresh_recovery_limit` 10.

Reuse is redefined from "any consumed token" to "a token after its successor
was presented, a superseded token, or a consumed token outside the recovery
bounds".

### 4.3 Security argument

1. *Single chain.* An acceptance in (3) or (4) leaves exactly one live token,
   because (4) supersedes the only live child atomically under the session
   lock. Two valid chains cannot exist (also enforced by the index).
2. *Two holders always collide.* If an owner and a thief both hold token P,
   at most one holds the live child. The other holds P or a superseded child.
   Their next presentation is either a superseded child (reuse), P after a
   child was presented (reuse), or P again inside the bounds (a recovery that
   supersedes the first party's child, whose next use is reuse). The session
   is revoked within a bounded number of steps. Detection is delayed by at
   most one refresh of the other holder, never lost.
3. *What a thief gains.* Recovery is only possible for the token the owner
   presented last, before the owner presents its child, and only within 60 s
   of its consumption. ADR 0010 already accepts that a thief who uses a
   *live* token before the owner keeps the session until the owner's next
   refresh. Recovery extends that same accepted risk to the predecessor, for
   at most 60 s. A token older than one completed refresh cycle can never be
   recovered.
4. *Where a predecessor can come from.* The token exists only in the owner's
   `HttpOnly` cookie jar, in TLS traffic and as a hash in the database; it is
   never logged. Anyone who can read the jar inside the window can read the
   live token in the normal case too.
5. *What it does not do.* The server still cannot tell the owner's retry from
   a copied cookie on another device inside the window. Only a device-bound
   proof (§3 D) can, and this proposal does not claim it.

### 4.4 Ordering and the clients

* No client protocol change, no new cookie, no OpenAPI shape change. The SF-28
  coordinator (Web Lock, in-tab coalescing, epochs) stays the only refresh
  manager. No `keepalive` (see §3 C).
* A late `Set-Cookie` for a superseded child that lands after the newer one
  would be presented and treated as reuse: revocation, exactly today's
  behaviour, in a narrower case. Chosen deliberately over also recovering
  superseded siblings, which would let two holders alternate without detection
  up to the limit.
* Mobile (body transport) gets the same recovery for an app killed between
  the server rotation and its Keychain/Keystore write; no client change.

### 4.5 Observability

`[:simple_fit, :auth, :session, :refresh]` gains the outcome `:recovered`
(next to `:rotated`, `:rejected`, `:reuse`). No ids, hashes or tokens. A
recovery is logged at `:info` with the bounded reason only; reuse stays a
warning. No Sentry events for expected outcomes.

### 4.6 Rollout and rollback

* The migration adds nullable/defaulted columns and an index: no rewrite of
  existing rows. Tokens issued before the deploy have no `parent_id`, so the
  first rotation after deploy cannot be recovered (strict, as today).
* Code rollback alone is safe: old code ignores the columns and sees
  superseded tokens as consumed (reuse). The down migration drops the columns.
* The OpenAPI description of `refreshSession` ("presenting a consumed token
  again revokes its session") changes wording only; web and mobile
  snapshots are re-synced, generated types do not change.

## 5. Decision

ADR 0010 said "There is no grace window" and "the server never relaxes this".
This proposal relaxes it in the bounded, structural way above. Approved on
2026-10-19 with a 60 s window and 10 recoveries per token; ADR 0010 is
amended ("Reuse" and "Lost-response recovery (SF-75)").
