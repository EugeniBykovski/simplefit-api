# ADR 0021 — Coach–Fighter relationships and relationship-scoped authorization

* Status: Accepted (relationship domain). The invitation, data-rules
  acknowledgement and training parts of SF-49 remain PROPOSED.
* Date: 2026-10-15
* Ticket: SF-56 (epic SF-48; architecture: SF-49 revision 3,
  `docs/architecture/proposals/SF-49-coach-training-architecture.md` §6,
  §7.4, §10, §11; builds on ADR 0009 one global user, ADR 0015 fighter
  profile, ADR 0016 account registration, ADR 0019 identity security,
  ADR 0020 coach profile)

## Context

A coach may only ever see a fighter's data because that fighter explicitly
agreed to it. SF-49 chose the model (§6.1 option B: several coaches per
fighter, no primary), the four data classes (§6.4.1), a versioned
disclosure contract (§6.4.2), the access matrix before and after
termination (§6.4.4) and a fail-closed legal gate (§7.4). Two inputs do not
exist yet: the approved legal texts (and so any disclosure version), and
the retention period of ended-relationship history (SF-49 B-1, B-2). The
invitation flow that will carry a fighter's acceptance is a later task.

For SF-56 the product owner decided (2026-10-15):

1. **Gate scope.** While the gate is off, no relationship can be activated
   and every coach read answers `404`; ending a relationship (either side)
   and the fighter's own list stay available. (SF-49 §7.4 had every
   endpoint answer `404`, which would stop a fighter from revoking.)
2. **Disclosure versions come from configuration** (identifiers of approved
   legal texts), none by default; no version is written in code.
3. **History** follows SF-49 O-6: a stub with each side's display name as
   it was at the end; rows are kept until the retention ticket decides.
4. This ADR is **Accepted** for the relationship domain.

## Decision

### Domain and ownership

`SimpleFit.Coaching` owns `coach_fighter_relationships`. It reads the two
profiles only through their contexts: `SimpleFit.Fighters.coach_projection/2`
(never wider than `coach_visible_fields/0`, the C1 + C2 fields) and
`SimpleFit.Coaches.public_projection/1` / `get_profile_by_id/1`. Fighters and
Coaches never call Coaching. Nothing refers to a gym, a workspace or a role
on `users`.

### Model

| Column | Notes |
|---|---|
| `id` | UUID; the only handle either side uses |
| `coach_profile_id`, `fighter_profile_id` | FKs, `ON DELETE CASCADE` (as every profile FK: deleting a user removes their grants) |
| `status` | `active` → `ended` (terminal) |
| `disclosure_version` | the version the fighter accepted, 1..64 chars |
| `started_at` | the acceptance time |
| `ended_at`, `ended_by` | set once; `ended_by` ∈ `coach`, `fighter` |
| `fighter_display_name_at_end`, `coach_display_name_at_end` | name snapshots taken at the end, never refreshed |

There is no pending state (pending belongs to the future invitation) and no
`invitation_id` yet (added with the invitations table).

Database invariants (not only domain checks):

* partial unique index `(coach_profile_id, fighter_profile_id) WHERE status
  = 'active'`: one active relationship per pair; ended history unrestricted,
  so a reconnection is a new row;
* `lifecycle` check: an active row has no end facts; an ended row has all
  of them and `ended_at >= started_at`;
* insert trigger: created `active` only, both profiles completed, the two
  profiles belong to different users (no self-coaching, also for a user
  holding both profiles);
* update trigger: the only allowed change is active → ended; the parties,
  disclosure version and start never change; an ended row is immutable (no
  reactivation).

### Activation: the trusted boundary

`SimpleFit.Coaching.Activation.activate(coach_profile_id, fighter_user,
disclosure_version)` is the only code that creates a relationship. It
requires the gate on, a configured disclosure version, the accepting user's
completed fighter profile, a completed coach profile and two different
users, then inserts (`ON CONFLICT … DO NOTHING` on the partial index) or
returns the pair's existing active relationship. No endpoint, controller or
other context calls it (a test asserts no web module references it). There
is no public create, patch, reactivate or ownership-changing operation.

**Contract for the Invitation Acceptance task.** Inside one transaction the
acceptance must: lock and verify the invitation by token hash (unknown /
used / expired / revoked / rotated → `invitation_unavailable`), bind it to
the signed-in user (never by email match), require that the fighter echoed
the exact disclosure version shown in the preview (stale → `409`), refuse
the coach's own invitation, call `Activation.activate/3` with the
invitation's coach profile and the echoed version, then mark the invitation
accepted (one-time). The one-time token, not `activate/3`, makes a retried
acceptance after an end harmless: `activate/3` alone always ensures an
active relationship.

### Disclosure

`SimpleFit.Coaching.Disclosure`: configuration maps approved version ids to
a code-defined scope; the only scope is `basic_profile` = C1
(`display_name`, `username`, `country_code`, `city`) + C2
(`experience_level`, `stance`, `amateur_bout_count`). A relationship keeps
its accepted version; the coach sees `fields(version) ∩
Fighters.coach_visible_fields()`. A version no longer configured discloses
nothing (narrowing applies at once); a new version never widens an existing
relationship. C3 (goals, next fight) and C4 (body data, account name, date
of birth, email, identities, sessions, other relationships) are never
disclosed: they are not in any scope nor in the allow-list, and projections
select only allowed columns (a new FighterProfile field is invisible to
coaches until added here deliberately).

### Gate and configuration

`config :simple_fit, SimpleFit.Coaching, access_enabled: false,
disclosures: %{}` (fail-closed default). `COACHING_ACCESS_ENABLED` and
`COACHING_DISCLOSURES` (`version=scope,…`, malformed fails boot) set them
per environment in `config/runtime.exs`. Both are read on every call. With
the gate off: no activation, every coach read `404`; ending and the
fighter's list work. Turning it on revives nothing (ended rows are
immutable).

### Authorization and API

Every operation takes the session's user; relationships are addressed only
by id, checked against the caller's own completed profile (coach side also
needs the gate). Foreign, unknown, malformed and (for coach detail) ended
ids all answer the same `404 not_found` — no existence oracle, never `403`.

| Operation | Path | Notes |
|---|---|---|
| `listMyCoachFighters` | `GET /api/v1/me/coach/fighters?status=active\|ended&limit&cursor` | completed coach + gate; active = disclosed fields, ended = stubs |
| `getMyCoachFighter` | `GET /api/v1/me/coach/fighters/{relationship_id}` | active only |
| `endMyCoachFighterRelationship` | `POST /api/v1/me/coach/fighters/{relationship_id}/end` | `204`, idempotent, gate-independent |
| `listMyCoaches` | `GET /api/v1/me/coaches?status=active\|ended&limit&cursor` | completed fighter; gate-independent |
| `endMyCoachRelationship` | `POST /api/v1/me/coaches/{relationship_id}/end` | `204`, idempotent, gate-independent |

SF-49 §11 listed ended coach stubs at `/me/coach/relationships?status=ended`;
they are the `status=ended` page of `listMyCoachFighters` instead (one list
per side). Lists are keyset-paged (newest first by start, or by end for
ended pages); the cursor is opaque, scoped to the status and grants nothing.
Responses are `no-store`. Errors: `not_found`, `validation_error` (`status`,
`limit`, `cursor`), `unauthorized`; no new code.

### Termination

Either side ends; the row is locked (`FOR UPDATE`), the first end wins and
is kept (its time and side), repeats return `204`, concurrent coach and
fighter ends both succeed with one end recorded. The name snapshots are
taken in the same transaction. Every check reads committed state, so any
operation that starts after an end is confirmed sees it ended; a read
already running when the end commits may finish with the data it was
authorized for (no stronger guarantee is claimed).

**Contract for the TrainingSession task.** SF-49 requires planned future
sessions to be cancelled (`cancelled_by = system`, `cancel_reason =
relationship_ended`) in the same transaction as the end. The hook point is
`SimpleFit.Coaching.end_relationship/3`'s transaction, after the row is set
to `ended`: Training exposes `cancel_for_relationship/2` and Coaching calls
it there (or enqueues an Oban job in the same transaction if the direct
call is rejected, SF-49 §3). No training data exists yet; nothing is
cancelled today.

### History and retention

After an end the coach sees only the stub (`relationship_id`, dates,
`ended_by`, `fighter_display_name_at_end`); the fighter sees the coach's
name at the end. No current profile data is read for ended rows. Rows are
kept: there is no deletion job, and **the retention period is not decided**
(SF-49 B-2, legal). Deleting a user deletes their profiles and, by cascade,
their relationships on both sides.

### Observability

Telemetry `[:simple_fit, :coaching, :relationship, :activated]` (metadata
`outcome: :created | :existing`) and `[…, :ended]` (`ended_by`): outcomes
only. Queries touching relationships and projections run with `log: false`;
schema fields holding names are `redact: true`. The SF-29 canary probe
covers the new endpoints.

## Consequences

* Coach–Fighter sharing is technically implemented but **not enabled**
  anywhere until legal provides the texts and their versions (SF-49 B-1,
  B-2); the coach-side data-rules acknowledgement (SF-49 §7.4) belongs to
  the Invitation task and is not a precondition of this domain.
* Web and mobile regenerate their clients; no UI uses these operations yet.
* Rejected: a `pending` relationship state (two sources of truth), creating
  relationships by email match (ADR 0009), gym membership as coaching
  authorization, a public create endpoint, a hard-coded disclosure version,
  serializing FighterProfile for coaches.

## Amendment — SF-57 (2026-10-15): coach invitations and the fighter's acceptance

Status: Accepted. Product decisions for SF-57 (2026-10-15): recipient
binding by a verified email identity; interim truthful E08 copy; the abuse
limits below; an anonymous, minimal token preview.

### Model

`coach_invitations` (owned by `SimpleFit.Coaching`, module
`SimpleFit.Coaching.Invitations`): `coach_profile_id`, `token_hash`
(SHA-256 of a one-time `sfi_` token, unique), `recipient_digest` (HMAC of
the canonical address) and `recipient_sealed` (the address encrypted with
`Plug.Crypto`, for resends and the masked display), optional `message`
(≤ 500, one plain paragraph), `status` (`pending` → `accepted` | `declined`
| `cancelled` | `expired`), `expires_at` (14 days), `send_count` /
`last_sent_at`, and for an outcome `responded_at`,
`accepted_disclosure_version` (the consent evidence) and `relationship_id`
(`ON DELETE SET NULL`). A partial unique index allows one pending
invitation per coach and recipient; a check constraint ties each status to
its outcome fields; a trigger makes a resolved invitation immutable (it
never becomes pending again) and keeps a pending one's coach, recipient
and message. Expiry is derived from `expires_at` at every read and
acceptance; the stored status catches up when the invitation is touched.

`coach_data_rules_acknowledgements`: append-only (`coach_profile_id`,
`document_version`, `acknowledged_at`), unique per version; separate from
account consents and the coach profile (SF-49 §7.4).

### Configuration (fail-closed)

`current_disclosure` (the first `COACHING_DISCLOSURES` entry: the version
a preview shows and an acceptance must echo) and `data_rules_version`
(`COACHING_DATA_RULES_VERSION`) join `access_enabled` and `disclosures`.
None has a default. Without the gate, a current disclosure and a data-rules
version, creating, resending, previewing and accepting answer `404`.

### Issuing

A completed coach who acknowledged the configured data-rules version
invites an address (`createMyCoachInvitation`): one transaction inserts the
invitation and enqueues E08 (an outbox: the encrypted job exists exactly
when the invitation commits). No user, identity, profile or relationship
is created, and the response is the same whether the address has an
account. A pending invitation of the same coach to the same address is
returned unchanged (`200`, no email). A coach cannot invite an address they
hold. Resend (`resendMyCoachInvitation`) rotates the token and the expiry
on the same invitation; the previous token stops matching at once.

### Accepting

The recipient must be signed in with an email identity for the invited
address (an address proved with a code, ADR 0012; Google and Apple
identities store no email and do not count), with completed account
registration and fighter profile, and must echo the current disclosure
version. In one transaction the invitation row is locked by token hash,
checked (pending, not expired, bound recipient, prerequisites, version),
`SimpleFit.Coaching.Activation.activate/3` runs, and the invitation is
consumed with the accepted version and the relationship id. Any failure
rolls everything back. A pair already connected resolves to its existing
relationship (`outcome: already_connected`): the invitation records the
version accepted now, the relationship keeps the version it was accepted
under (never widened). A consumed token answers `410 invitation_unavailable`
(retries recover the relationship from `listMyCoaches`). Self-coaching is
refused again at activation (`410`).

Declining (`declineCoachInvitation`) has the same binding and fighter
prerequisite and creates nothing; cancelling (`cancelMyCoachInvitation`)
is the coach's, idempotent for cancelled or expired invitations, `409` once
answered. Both work while the gate is off.

### Errors

New codes: `invitation_unavailable` (410) for every token that is not a
current pending one (unknown, malformed, rotated, used, declined,
cancelled, expired: no state oracle) and `invitation_recipient_mismatch`
(403). `409 conflict` carries details (`disclosure_version: stale`,
`data_rules_acknowledgement: required`, `pending_invitations:
limit_reached`, `resends: limit_reached`); `429 rate_limited` carries
`retry-after`.

### Abuse limits (PostgreSQL windows, ADR 0019)

Create: 10/hour and 30/day per coach, 3/day per recipient digest (any
coach), 20 per 10 minutes per client. Resend: 60 s apart, at most 3 per
invitation (and the coach's hourly limit). At most 50 pending invitations
per coach. Preview, accept and decline: 30 per 10 minutes per client.
Keys are HMACs; nothing personal is stored.

### Token transport and secrecy

E08 links to `<WEB_APP_URL>/invite/coach#token=sfi_…`: the token is in the
fragment, which browsers never send, so it never reaches server logs,
access logs or `Referer`. Clients send it only in request bodies (preview,
accept, decline). The web client keeps it tab-scoped (`sessionStorage`)
across sign-in, account registration and fighter onboarding and clears it
on accept, decline, unavailable or sign-out (SF-49 §7.3); mobile acceptance
happens on the web until universal links exist. The `sfi_` prefix is
redacted from every log and Sentry event (`Redaction`); telemetry
(`[:simple_fit, :coaching, :invitation, …]`) carries outcomes only.

### SF-56 change found by SF-57

`Activation` could raise when an acceptance's insert conflicted with the
pair's active relationship and an end committed before the follow-up read.
It now locks the existing active row (`FOR SHARE`, so a concurrent end
waits) and retries the insert when that row was ended in between (bounded).
The relationship model is unchanged.

### Not decided (legal)

The legal ticket, the fighter disclosure text and version, the coach data
rules text and version, and the retention of invitations and ended
relationships (rows are kept; no deletion job) are still open (SF-49 B-1,
B-2). E08's copy is interim until design CR-12 and the legal texts.
