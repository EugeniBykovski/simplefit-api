# ADR 0023 — Training sessions: assignment, scheduling and lifecycle

* Status: Accepted (SF-62, 2026-10-20). Amended by SF-63 (2026-10-20):
  completion and read projections, see the amendment at the end.
* Context: SF-49 revision 3 §6.3, §6.4.4, §8, §10, §11 (decisions O-5, O-6,
  O-7, O-8, O-15); ADR 0021 (relationships, the end hook); ADR 0022
  (sharing readiness, withdrawn disclosures). Product decisions of
  2026-10-20 recorded below.

## Decisions of 2026-10-20

| # | Question | Decision |
|---|---|---|
| T-1 | Training types: SF-49 (`pads`) or the SF-62 brief (`conditioning`) | SF-49 §8.2.1 / O-5: `technical`, `sparring`, `pads`, `strength_conditioning`, `roadwork` |
| T-2 | Former coach reading authored sessions after an end (SF-49 §6.4.4 yes vs §8.5 and ADR 0021 no) | **No** (`404`), fail closed; the fighter keeps the full history. A retention ticket may open coach-side history explicitly |
| T-3 | Sessions on account deletion | Cascade with the relationship (as relationships, ADR 0021); revisit with retention |
| T-4 | Coach operations with sharing off / a withdrawn accepted disclosure | All coach session operations need sharing ready; create and update also need the relationship's accepted disclosure to still apply. Fighter reads always; ending stays gate-independent |

## Ownership

`SimpleFit.Training` owns `TrainingSession`: planning, assignment,
scheduling, lifecycle and both sides' reads. It never reads or locks
relationships itself: `SimpleFit.Coaching` authorizes every coach-side
operation (`training_coach/1`, `lock_training_relationship/3`,
`active_relationship_ids/1`, `training_fighters/1`, `training_coaches/1`)
and calls `Training.cancel_for_relationship/2` from its end transaction
(ADR 0021's hook). The two-way call is runtime only (no compile-time cycle).
Coaches, Fighters, controllers and clients hold no training rule.

```
User ─< CoachProfile ─< CoachFighterRelationship >─ FighterProfile >─ User
                              │ (id, coach, fighter)
                              ▼ composite FK, ON DELETE CASCADE
                        TrainingSession (one coach, one fighter, one relationship)
```

## Model

`training_sessions`: `coach_fighter_relationship_id`, `coach_profile_id`,
`fighter_profile_id` (one composite foreign key to the relationship's
`(id, coach_profile_id, fighter_profile_id)`, so the pair can never differ
from the relationship's), `client_request_id` (unique per coach), `title`
(1..80), `training_type` (five values), `starts_at` (UTC), `time_zone`
(IANA), `duration_minutes` (5..600), `notes` (≤ 2000, optional), `status`,
`completed_at`, `cancelled_at`, `cancelled_by` (`coach` | `system`),
`cancel_reason` (`relationship_ended` for system cancellations only).

| Class | Fields |
|---|---|
| Required plan | `title`, `training_type`, `starts_at`, `time_zone`, `duration_minutes` |
| Optional plan | `notes` |
| Backend-owned | ids, owners, `client_request_id` binding, `status`, all lifecycle timestamps and causes |
| Deferred (not in the MVP, A-11) | rounds, round and rest durations, RPE, metrics, outcomes, feedback, media, templates, groups |

One session is one assignment to one fighter (O-15): the same plan for three
fighters is three explicit creates. No gym anywhere; extension points
(nullable coach for self-training, participants for groups, program ids,
execution logs) belong to their own tickets.

## Lifecycle

`planned` → `cancelled` (coach; or system when the relationship ends) or
`completed` (SF-63). Both terminal. The database enforces it: rows are
inserted `planned` under an **active** relationship (trigger, relationship
row locked `FOR SHARE`); the only updates are plan changes while planned
and the two transitions; owners, relationship and request key never change;
a terminal row is immutable; a `CHECK` ties every status to exactly its
lifecycle facts. There is no status PATCH: transitions are operations.

## Authorization

| Operation | Coach, active relationship, sharing ready | Same coach after end | Other coach | Fighter (assignee) | Other user |
|---|---|---|---|---|---|
| Create | ✓ (accepted disclosure still applies) | ✗ | ✗ | ✗ | ✗ |
| Read | ✓ | ✗ (T-2) | ✗ | ✓ always (own history; gate-independent) | ✗ → 404 |
| Update | ✓ while planned (disclosure applies) | ✗ | ✗ | ✗ | ✗ |
| Cancel | ✓ while planned | ✗ | ✗ | ✗ | ✗ |
| Complete (SF-63) | ✗ (O-7) | ✗ | ✗ | ✓ while planned | ✗ |

No endpoint takes a coach, fighter or user id as authority: the coach names a
relationship, the backend derives both parties; foreign, unknown, malformed
and no-longer-authorized ids answer `404 not_found`. A user holding both
profiles acts separately on each side. The coach sees the fighter's
`display_name` / `username` only as the accepted disclosure allows; the
fighter sees the coach's public identity while active and the name at the
end afterwards.

## Relationship end (SF-56 integration)

`Coaching.end_relationship/3` locks the relationship `FOR UPDATE`, ends it,
then cancels its **planned** sessions starting at or after the end
(`cancelled_by: system`, `cancel_reason: relationship_ended`) in the same
transaction. Completed and cancelled sessions stay as they are; planned
sessions that had already started remain planned for the fighter's own
confirmation (SF-63) — no coach can act on them. Creation after an end
commits fails (trigger + domain); a creation that commits first is cancelled
by the end. Sharing switched off temporarily changes no session.

## Scheduling and time zones (SF-49 §8.3)

* `starts_at` is an RFC 3339 instant with an explicit offset (a time without
  one is rejected, `invalid_type`); stored and returned in UTC.
* `time_zone` is an IANA id or `UTC`, validated against PostgreSQL's zone
  data (`pg_timezone_names`, regex for region ids, never abbreviations or
  `posix/`, `right/`, `Etc/`). Legacy aliases are accepted. No Elixir zone
  database is added (ADR 0004).
* A non-UTC offset must equal the zone's offset at that instant: a
  spring-forward gap wall time cannot be expressed (either offset mismatches)
  and a repeated autumn wall time keeps both instants distinct, chosen by
  the client's explicit offset. The API never normalizes a local time.
* When set, `starts_at` lies between one day before and one year after now
  (technical bounds from SF-49, not sports policy).

## Idempotency

`client_request_id` (UUID, unique per coach) makes create retry-safe: the
first create inserts (`201`); any later create with the key returns that
session unchanged (`200`), or `409 conflict {client_request_id: "reused"}`
when it names another relationship. Concurrent creates insert once
(`ON CONFLICT DO NOTHING` on the unique index, then a read-back). No
deduplication by title, date or fighter.

## Locks

Relationship row first (`FOR SHARE` for create / update / cancel,
`FOR UPDATE` for an end), then the session row (`FOR UPDATE`). A
session-only operation (SF-63 completion) locks the session only and never
the relationship afterwards, so no cycle exists. Tested: duplicate keys,
distinct keys, create vs end, update vs cancel, double cancel, cancel vs
end, create vs account deletion, update vs a session-only transition,
several coaches on one fighter.

## API

| Operation | Path |
|---|---|
| `createMyCoachTrainingSession` | `POST /api/v1/me/coach/training-sessions` |
| `listMyCoachTrainingSessions` | `GET /api/v1/me/coach/training-sessions` (`status`, `from`, `to`, `relationship_id`, `limit`, `cursor`) |
| `getMyCoachTrainingSession` | `GET /api/v1/me/coach/training-sessions/{session_id}` |
| `updateMyCoachTrainingSession` | `PATCH …/{session_id}` (plan fields only; strict) |
| `cancelMyCoachTrainingSession` | `POST …/{session_id}/cancel` |
| `listMyTrainingSessions` | `GET /api/v1/me/training-sessions` (`status`, `from`, `to`, `limit`, `cursor`) |
| `getMyTrainingSession` | `GET /api/v1/me/training-sessions/{session_id}` |

Errors: `not_found` (see Authorization), `conflict` (`status` of a terminal
session; `client_request_id: reused`), `validation_error` (unknown fields
`invalid`, ranges `out_of_range`, zone `invalid`, offset `invalid`,
timestamps `invalid_type`), `unauthorized`. No new error code. Lists are
keyset pages by `starts_at` then `id` (ascending), opaque cursors that grant
nothing. Responses are `no-store`.

## SF-63 completion contract

Implemented as specified; see the amendment below.

## Observability

Telemetry `[:simple_fit, :training, :session, :created | :updated |
:cancelled]` with outcomes only (`outcome`, `cancelled_by`). Every query
runs with `log: false`; `title` and `notes` are `redact: true`. The SF-29
canary probe covers the endpoints.

## Consequences

* Coach-side training is unavailable everywhere until Coach–Fighter sharing
  is enabled (ADR 0022); fighters can always read what exists.
* Deleting an account deletes the sessions of its relationships (T-3).
* Web and mobile regenerate their clients; no UI uses the operations yet.

## Amendment — SF-63 (2026-10-20): completion and read projections

### Decisions of 2026-10-20

| # | Question | Decision |
|---|---|---|
| C-1 | Completion before the scheduled start | Not allowed: `409 conflict {starts_at: "not_started"}` |
| C-2 | Completion long after the planned date | Allowed, no deadline (preserved sessions stay completable) |
| C-3 | Upcoming / history | An optional `view=upcoming\|history` on the existing lists, computed with server time; no new endpoints |

### Completion

`completeMyTrainingSession` (`POST /api/v1/me/training-sessions/{session_id}/complete`,
no request body; any field → `422`, `invalid`). Only the fighter the session
is assigned to (identity from the session's user; a dual-role user acts as
fighter) and only for their completed fighter profile. In one transaction the
session row is locked `FOR UPDATE` (scoped to the fighter's profile), its
state checked and `planned → completed` written with `completed_at = now()`
(server clock, UTC, microseconds). The outcome is **status-only**: no
duration, RPE, metrics, notes or ratings (SF-49 A-11); no outcome table.

| Session | Answer |
|---|---|
| planned, started (`starts_at ≤ now`) | `200`, completed now |
| planned, not started | `409 conflict {starts_at: "not_started"}` |
| completed | `200`, unchanged (first `completed_at` kept; nothing else written) |
| cancelled | `409 conflict {status: "cancelled"}` |
| foreign, unknown, malformed id; no completed fighter profile | `404 not_found` |
| no / revoked session | `401 unauthorized` |

Completion is independent of the relationship's status and of the sharing
gate: it never reads or locks the relationship, never reactivates it, and
grants nothing to the coach. `completed_at` may be any time after the planned
start (late is fine); it is never client supplied. The database allows only
`planned → completed` and freezes a completed row (direct SQL could still set
an arbitrary `completed_at` in that one transition; only this operation
writes it).

### Termination and history (T-2 applied to completion)

Planned sessions that had started before an end stay planned and remain
completable by the fighter. The former coach reads nothing after an end, so
a completion recorded afterwards is never visible to them; no projection
widens when a row changes status. Future sessions were cancelled at the end
and stay non-completable.

### Visibility matrix

| Actor | List / detail | Complete | Update / cancel |
|---|---|---|---|
| Assigned fighter | ✓ own, any relationship state, gate-independent | ✓ (planned, started) | ✗ |
| Authoring coach, active relationship, sharing ready | ✓ incl. `status`, `completed_at` | ✗ | ✓ while planned |
| Same coach after the end | ✗ `404` | ✗ | ✗ |
| Another coach of the same fighter | only their own sessions | ✗ | own only |
| Unrelated coach or fighter | ✗ `404` | ✗ | ✗ |
| Dual-role user | each side's own sessions only | as fighter only | as coach only |
| Revoked session / deleted user | `401` / nothing remains (cascade) | — | — |
| Sharing off | fighter ✓, coach `404` | ✓ | ✗ |

### Read projections

`view` on `listMyTrainingSessions` and `listMyCoachTrainingSessions` (both
sides keep their scopes):

* `upcoming`: `status = planned` and `starts_at + duration_minutes > now` —
  still to do or in progress; earliest first (`starts_at`, `id` ascending).
* `history`: completed, cancelled, and planned sessions already over (past
  due, shown as planned, never as completed); newest first (`starts_at`,
  `id` descending).
* no `view`: every session, earliest first (SF-62).

`upcoming` and `history` partition the sessions at the request's server
time. `status`, `from`, `to` (and `relationship_id` for coaches) combine with
a view; "completed" is `status=completed`. Cursors carry their view and are
invalid in another; SF-62 cursors remain valid for the unfiltered list. Each
page is a keyset seek, so a traversal never repeats a session; a session
whose status or time changes between pages may leave its view and is then
skipped, never duplicated. No counters, aggregates or adherence figures.

### Concurrency

Completion locks the session row only; coach update and cancel lock the
relationship then the session; an end locks the relationship then updates
sessions. No cycle. Completion vs cancellation: the first to lock the row
wins, the other gets `409` with the winner's status. Completion vs the end's
automatic cancellation: disjoint sets (completion needs a started session,
the end cancels only those not yet started at the end). Tested on separate
connections: ten simultaneous completions (one `completed_at`), completion vs
coach cancel, vs relationship end, vs coach update, vs account deletion, and
reads during completion (planned or completed, never a half state).

### Observability

Telemetry `[:simple_fit, :training, :session, :completed]` with `outcome:
completed | already_completed` only.
