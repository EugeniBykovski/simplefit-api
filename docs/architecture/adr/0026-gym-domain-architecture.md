# ADR 0026 — Gym domain architecture

* Status: **Accepted** (SF-82, final approval 2026-10-23). Epic SF-81 Gym &
  Club Management. Nothing is implemented; SF-83 needs its own start
  authorization.
  * **Approved:** `D-G01`–`D-G08`, `D-G12`–`D-G16`, `D-G18`, `D-G20`–`D-G24`
    and `D-G26`.
  * **Deferred product decisions** (not engineering facts): `D-G09`
    (pricing, gym SaaS subscriptions, trials, billing, commercial ownership
    limits), `D-G10` (payment provider and architecture) and `D-G11`
    (business verification and publishing).
  * **Open:** `D-G17` (no Gym local-development bypass), `D-G19` (non-commercial
    member pass) and `D-G25` (anti-abuse rate limits; the three-gym cap was
    rejected).
* Context: ADR 0009 (one global user), 0016 (account registration), 0017
  (entry resolution), 0018 (first run), 0021 (Coach–Fighter relationships),
  0023 (training sessions), 0024 (email identity linking), 0025 (local
  development coaching mode, SF-105), SF-49 §9 (Gym boundary), SF-80
  (invitation app links), the platform route architecture and registry.
* Detail: [`proposals/SF-82-gym/`](../proposals/SF-82-gym/README.md).

## Problem

Claude Design contains about 116 Gym-related screens (owner setup, staff
onboarding, web console, mobile cockpit, member side, commerce) and the route
registry has 53 Gym placeholders, but the backend has no Gym domain. Without
one model, tickets SF-83–SF-104 would invent tenancy, roles and data access
screen by screen, and the design's commercial screens (plans, trials,
payments, payouts) would invite fabricated data.

## Decision

1. **Tenant.** A new context `SimpleFit.Gyms` owns `gyms` (the tenant root)
   and separate address-only `gym_locations`. No `gym_id`, role or type on
   `users`, and no generic workspaces table (`D-G01`, `D-G02`).
2. **Staff.** `gym_staff_memberships` with fixed MVP roles `owner`,
   `manager`, `coach`, `front_desk`. Exactly one active owner, and ownership
   moves only by a transactional transfer. Authorization is one
   `Gyms.Policy` matrix in code (`D-G03`, `D-G04`). Staff invitations are
   their own domain, separate from Coach–Fighter invitations: `sfs_` tokens,
   7-day expiry, bound to a verified email (`D-G12`, `D-G16`).
3. **Members.** `gym_members` need only a completed account, not a
   FighterProfile (`D-G07`). Enrollment is request-based. Auto-approval
   applies only when the gym explicitly enables it, and never bypasses
   identity verification. Invitations are bound to a verified email; there
   is no CSV import (`D-G08`).
4. **Boundary with coaching.** No gym fact creates, implies or widens a
   Coach–Fighter relationship, and no gym permission grants access to a
   fighter's private training data (`D-G06`).
5. **Scheduling.** Group classes are `gym_classes` + materialized
   `gym_class_occurrences` + `gym_bookings` + `gym_check_ins`, not ADR 0023
   training sessions. ADR 0023's time rules move into a shared
   `SimpleFit.Scheduling` module (`D-G14`).
6. **Navigation and authorization.**
   * Gym APIs are path-scoped (`/api/v1/gyms/{gym_id}/…`, `D-G15`).
   * Gym UI routes are ID-based (`/app/gyms/:gymId/…`, `/gyms/:gymId/…`;
     member views `/me/gyms/:gymId/…`). This replaces
     `D-WORKSPACE-NOT-IN-URL` for Gym (`D-G23`).
   * The id is only a lookup key: every request is authorized by the backend.
     The server remembers only the last chosen gym, for landing.
7. **Errors.** Outsiders, other gyms, revoked and unknown ids get 404, so a
   private gym's existence is never revealed. Active staff whose role lacks
   the permission get 403 `forbidden` and a role-restriction state (`D-G24`).
8. **Creation.** Any registered user may create a gym and becomes its owner.
   The gym is persisted as a draft at the first valid submission, with
   `client_request_id` idempotency and resume (`D-G05`). Creation requires
   only name, type and one location. Optional setup and a truthful first-run
   checklist follow, and the 14 designed steps remain a product journey with
   unavailable steps marked "coming later" (`D-G21`). Drafts are never
   deleted automatically until a retention policy is approved (`D-G20`).
   Anti-abuse is by rate limits, not an ownership cap (`D-G25`, open).
9. **Invitations on mobile.** A token-free inbox matched by verified email.
   Tokens live only in the web fragment and in request bodies, never in app
   routes (`D-G22`, SF-80 rule).
10. **Lifecycle.** The sole owner's account cannot be deleted before a
    successful ownership transfer (`D-G26`). Audit events are recorded from
    the first Gym domain ticket (`D-G18`).
11. **Commerce.** Enrollment, bookings and attendance carry no money. Plans,
    trials, payments, payouts, verification, publishing and commercial
    ownership limits are **deferred product decisions** (`D-G09`–`D-G11`).
    No mock payment grants an entitlement.

## Consequences

* SF-83 (tenant foundation) depends on no deferred decision. Only `D-G25`
  remains open for it.
* The route registry and `route-architecture.md` change in SF-85 (id-based
  console, the rule-9 exception), SF-87 (token-free invitation entries) and
  SF-91 (account-level member routes). The SF-57/SF-80 `/invite/coach` link
  and its security are unchanged.
* Two dependencies are missing from SF-83–SF-104:
  * account deletion, which the `D-G26` guard needs;
  * a native build for the `/invite/staff` and `/invite/gym` app links
    (`proposals/SF-82-gym/09-dependency-matrix.md` §3).
* Claude Design needs the corrections R1–R11 / C1–C17. They are not
  published until separately approved.
* The OpenAPI artifact and the registry are unchanged by this ADR. Proposed
  endpoints are in the package's contract matrix.

## Alternatives considered

The rejected alternatives are listed per decision in the package's
[decision register](../proposals/SF-82-gym/10-decision-register.md). They
include:

* a polymorphic workspace table;
* the active gym stored in the backend session, or id-free console URLs;
* classes built as training sessions;
* custom roles;
* a hard cap on owned gyms;
* co-owners;
* FighterProfile-gated membership.

## Amendment — SF-83 (2026-10-26): tenant foundation, ownership and RBAC

SF-83 implements the tenant root, staff (workspace) memberships, the fixed
permission matrix, creation with ownership bootstrap, and the domain
operations for ownership transfer and staff revocation.

### Data (migration `20261026090000_create_gyms`)

* **`gyms`**:
  * columns: `name` (1–80, trimmed), `gym_type` (the six D-G13 values),
    `setup_status` (`draft` | `completed`), `created_by_user_id` (audit and
    idempotency only, `ON DELETE SET NULL`), `client_request_id`;
  * unique `(created_by_user_id, client_request_id)`;
  * partial unique "one open draft per creator";
  * a trigger keeps the key and creator immutable, and makes `completed`
    final.
* **`gym_locations`**:
  * address-only (D-G02), with a partial unique "one non-archived primary per
    gym";
  * defined and read only. Creating and editing locations belongs to the setup
    API (SF-85).
* **`gym_staff_memberships`**:
  * `role` (`owner`, `manager`, `coach`, `front_desk`) and `status` (`active`
    | `ended`, with `ended_at` and `ended_reason`);
  * partial unique "one active membership per user and gym" and partial
    unique "one active owner per gym";
  * a deferred constraint trigger checks **exactly one active owner per gym**
    at every commit;
  * a guard trigger keeps `gym_id` and `user_id` immutable, and ended rows
    final;
  * `user_id` is `ON DELETE SET NULL` with `CHECK (status = 'ended' OR
    user_id IS NOT NULL)`. The database therefore refuses to delete a user who
    still has an active membership, and keeps the history of ended ones.
* **`gym_audit_events`**:
  * append-only (an update trigger rejects changes), no foreign keys, no
    retention job;
  * stores `event_type` (`gym_created`, `staff_membership_created`,
    `ownership_transferred`, `staff_membership_ended`), actor id, membership
    id, roles and reason.

### Ownership

The single source of truth is the gym's one active `owner` membership. There
is no `gyms.owner_user_id`.

* **Creation** inserts the gym, the owner membership and the two audit events
  in one transaction.
* **Transfer** (`Gyms.transfer_ownership/4`):
  * locks the gym row first, then the memberships involved;
  * ends the old owner row (`transferred`) before promoting the target, then
    optionally creates a manager row for the previous owner.
* **Revocation** (`Gyms.revoke_staff_membership/3`) takes the same lock
  order, so a transfer and a revocation at one gym serialize.

### Authorization

`SimpleFit.Gyms.Policy` encodes the SF-82 matrix:

* **Grants:** `:all` or a named scope (`:coach_and_front_desk`,
  `:own_classes`, `:own_occurrences`, `:at_check_in`, `:today`) that the
  operation enforces.
* **No training-data permission:** no permission reads private training data
  (D-G06).
* **Per-request access:** `Gyms.Access` re-reads the actor's active membership
  for the path's gym on every call. The results are:
  * 404 for an unknown gym, a malformed id, or no active membership;
  * 403 for an active membership without the permission.

### API

| Operation | Behaviour |
| --- | --- |
| `createGym` (`POST /api/v1/gyms`) | Idempotent create. A new key while a draft is open resumes the draft. Rate limited at 5 per user and 20 per client per 24-hour window |
| `listMyGyms` (`GET /api/v1/me/gyms`) | Paginated |
| `getGym` (`GET /api/v1/gyms/{gym_id}`) | The gym, its locations and the viewer's role and read-only permission list |

All three answer `no-store`. `SECRET_KEY_BASE` also derives the
rate-limit key, with its own salt; no new environment variable is needed.

### Rate limiting (D-G25, as approved)

* **Rolling windows.** Gym creation allows at most 5 creations per user and
  20 per client in **any rolling 24 hours**. `SimpleFit.RateLimit.hit_rolling/2`
  is an exact sliding log:
  * one `rate_limit_events` row (bucket, HMAC key digest, time) per counted
    event;
  * migration `20261026100000_create_rate_limit_events`;
  * the window is `(now - 24 h, now]`.
* **Locking.** A transaction-scoped advisory lock per bucket and key runs as
  its own statement before the count, so concurrent hits are counted
  exactly. A count inside the same statement would use a snapshot taken
  before the lock wait.
* **What is recorded.** A refused hit is not recorded. The rules of one
  call commit only with the caller's transaction, so replays, resumed drafts,
  invalid requests and rolled-back creations are never counted.
* **Retention.** Rows are deleted by the existing hourly cleanup after two
  days. Rolling periods are capped at 24 hours.
* **Client attribution.** Production refuses to boot without an explicit
  `TRUSTED_PROXY_HOPS` (`ClientIP.parse_required_hops!/1`; `0` is valid but
  must be stated). An undeclared proxy can therefore never make every client
  share one IP limit. Development keeps the default of 0. This applies to
  every IP-based limit.

### Ownership, lifecycle and authorization audit

* **Ownership.**
  * `gym_staff_memberships` is the only ownership source.
  * Exactly one active owner on every committed gym: a partial unique index
    plus the deferred commit-time trigger. Real-commit tests show an
    ownerless commit is rejected and a second owner is refused.
  * Transfer and revocation lock the gym row first. The race tests show
    concurrent transfers leave one owner, and a transfer racing a revocation
    always ends consistent.
  * A user with any active membership cannot be deleted; the database
    refuses. Ended memberships keep their history.
  * No transfer HTTP operation exists.
* **Lifecycle.**
  * `setup_status` (`draft` / `completed`) is only the setup state. There is
    no publication, plan, payment or verification column. Publication will be
    a separate state that requires a completed setup and D-G11.
  * No endpoint shows a gym to anyone but its active staff.
  * SF-85 must refuse `complete-setup` until the gym has a non-archived
    primary location (with name and type).
* **Authorization.**
  * 401 for no, invalid or revoked session.
  * 404 for unknown or malformed gym ids, and for gyms where the caller has
    no active membership.
  * 403 `forbidden` for active staff whose role lacks the permission.
  * The three SF-83 operations allow every staff role, so none returns 403
    yet. Every future role-specific operation must call
    `Gyms.authorize/3` (reads) or the locking variant (writes) with its
    specific permission.
  * No permission reads private training data, and a test asserts that the
    Gyms context references no Coaching, Training, Fighters or Coaches module
    or table. A CoachProfile, a FighterProfile or a Coach–Fighter relationship
    grants nothing at a gym.

### Ticket ownership (actual Jira)

| Jira | Scope | What it takes over from SF-83 |
| --- | --- | --- |
| SF-84 | Gym Registration Intent & Workspace Entry Resolution | `GYM_WORKSPACE` and the gym workspaces in `/me/entry`; the remembered last gym |
| SF-85 | Gym Owner Registration & Gym Setup API | Locations, setup fields, `complete-setup` (requires a primary location), discarding a draft |
| SF-92 | Gym Staff Roles, Coach Affiliation & Invitations API | Staff invitations; role change and the revocation HTTP operation (on top of `Gyms.revoke_staff_membership/3`) |
| SF-100 | Gym Member Booking & Attendance UI | Nothing from SF-83. An earlier SF-83 report wrongly gave it ownership transfer |

**Ownership transfer (recommendation): a dedicated backend Jira task,
sequenced after SF-92.** It reuses SF-92's invitation and acceptance machinery
(7-day expiry, verified identity). It is kept separate for these reasons:

* it changes who controls the tenant, and later payouts and closure;
* it needs its own threat review: pending-transfer state, cancellation, a
  concurrent revocation of the target, and the account-deletion guard;
* SF-92 is already large.

It depends on SF-92, because only SF-92 creates non-owner staff. The commit
step (`Gyms.transfer_ownership/4`) is ready for it.

The ticket numbers in this ADR's Consequences section come from the SF-82
proposal. Where they differ, this table wins.

### Remaining deviations from the SF-82 package

1. **Lifecycle names.** The SF-83 brief said "draft and active". The approved
   vocabulary `draft` / `completed` is used.
2. **Naming.** The brief's "GymWorkspaceMembership" is
   `gym_staff_memberships` / `SimpleFit.Gyms.StaffMembership`, as in ADR 0026.
3. **First location.** Creation inserts no location; location writes are
   SF-85's. A draft may have none, and "at least one primary location" is
   SF-85's completion check.
4. **Transfer and revocation are domain functions only.** They have no HTTP
   operations yet (see the ownership table above).
5. **Drafts cannot be transferred.** A draft answers `conflict`,
   `setup_status: draft`. This is a new rule: a draft has no other staff
   (D-G20) and holds the creator's single draft slot.
6. **Deferred columns.** `phone`, `website`, `handle`, `home_location_id`,
   `display_title` and `completed_at` arrive with the tickets that use them.
7. **Account deletion.** It has a read-only guard
   (`Gyms.check_account_deletion/1`) plus the database refusal. The release
   step (delete drafts, end other memberships with `account_deleted`) comes
   with the account-deletion feature.

The fixed-window deviation of the first SF-83 report is withdrawn: rolling
windows are implemented as approved.

## Amendment — SF-84 (2026-10-27): gym entry resolution

* **Where it lives:** gym intent, `GYM_WORKSPACE`, the gym chooser and the
  remembered gym are part of the SF-45 resolver (ADR 0017, SF-84
  amendment). There is no Gym-only resolver.
* **Public reads in `Gyms`:** `workspace_overview/2`, `workspace/2` and
  `lock_workspace/2`, the last of which takes the gym row first, then the
  membership.
* **D-G23:** gym UI routes are still the id-free registry placeholders. The
  entry answer carries `gym_id`, and the id-based gym routes come with the
  gym UI tickets.


## Amendment — SF-85 (2026-10-28): gym owner registration and setup API

Claude Design source: canvas version `1792675284-1046` (unchanged since
SF-82). The SF-82 reconciliation register (`12-design-reconciliation-plan.md`)
is authoritative for its discrepancies.

### Field matrix

| Field | Artboard | Stored in | Draft | Completion | After completion |
| --- | --- | --- | --- | --- | --- |
| `name` | OG1 | `gyms.name` | required at create | required | editable (owner, manager) |
| `gym_type` | OG1 | `gyms.gym_type` (six D-G13 values) | required at create | required | editable |
| `phone` | OG1 | `gyms.phone` | optional | — | editable |
| `website` | OG1 | `gyms.website` (`http(s)` only) | optional | — | editable |
| public handle / URL | OG1, OG3 | not stored | — | — | future: publishing (D-G11, C2/C4) |
| primary location: `country_code`, `city`, `address_line` | OG2 | `gym_locations` (one active primary) | optional | required | replaceable in place, never removable |
| `entrance_note`, location `name` | OG2 | `gym_locations` | optional (`name` defaults to the city) | — | replaceable |
| additional locations | OG2 | — | — | — | future (WG23) |
| `tagline` | OG3 | `gyms.tagline` | optional | — | editable |
| `accent_color` | OG3 | `gyms.accent_color` (the six OG3 swatches, lowercase hex) | optional | — | editable |
| logo, cover | OG3 | not stored | — | — | deferred: storage attachment (below) |
| gym size | OG4 | not stored | — | — | future: plan suggestion (D-G09, C1/R2) |
| features | OG5 | not stored | — | — | future: plan entitlements (D-G09, C1/R2) |

### Lifecycle and API

The existing `createGym` is the only create. Setup then uses five
operations:

| Operation | Behaviour | Permission |
| --- | --- | --- |
| `getGymSetup` (`GET /api/v1/gyms/{gym_id}/setup`) | The setup, `revision` and `missing_requirements` | any active staff |
| `updateGymSetup` (`PATCH …/setup`) | Partial update: omitted means unchanged; `null` or blank clears an optional field; `name` and `gym_type` cannot be cleared; read-only and unknown fields are rejected; nothing is truncated | `edit_gym`: owner, manager |
| `setGymPrimaryLocation` (`PUT …/setup/primary-location`) | Full replacement of the one primary location, created on first use and replaced in place afterwards | `manage_locations`: owner, manager |
| `completeGymSetup` (`POST …/complete-setup`) | Re-validates the persisted state (name, type, a complete primary address, exactly one active owner) and completes once; a repeat is a no-op without a second audit event; missing requirements are a `422 validation_error` with each requirement as `required` | `complete_setup`: owner |
| `discardGymDraft` (`DELETE /api/v1/gyms/{gym_id}`) | Hard-deletes a draft and its membership, locations and entry choices (cascades), keeping a `draft_discarded` audit event; a completed gym answers `409`, and a repeat answers `404` | `discard_draft`, new in the matrix: owner |

* **Errors:** 401 / 403 / 404 / 409 / 422 follow ADR 0003 and D-G24.
* **No capability gate:** a draft's owner needs no `GYM_WORKSPACE` (SF-84).
* **Conditional writes (final contract):** `gyms.revision` increases with
  every setup change, including the primary location.
  * `updateGymSetup` and `setGymPrimaryLocation` **require**
    `expected_revision`. It is compared under the gym-row lock: missing gets
    `422` (`required`), stale gets `409` (`details: {revision: "stale"}`,
    nothing more) and changes nothing.
  * A stale device therefore never overwrites another device's change, and
    of two writers on one revision exactly one applies; the other rereads and
    retries.
  * A body with only `expected_revision`, or with identical values, is a
    no-op after the same check, and the revision does not move.
  * `completeGymSetup` and `discardGymDraft` take no revision. Completion
    changes no setup field, re-validates the persisted state and is
    idempotent. Discard is the owner's explicit removal of their own draft.
    Both serialize with every write on the gym-row lock.
* **Locks:** every write locks the gym row, then the membership, then the
  primary location. This is the SF-83/SF-84 order, so completion, discard,
  transfer, revocation and entry choice serialize.
* **Database invariants** (migration `20261028090000`, explicit up/down):
  * completion requires an active primary location
    (`gyms_completion_requirements`);
  * a completed gym can never archive, demote or delete its last active
    primary location (`gym_locations_keep_primary`);
  * the existing triggers keep `completed` final and exactly one active
    owner;
  * format checks on `phone`, `website`, `tagline` and `accent_color`.
* **Audit** (in the same transaction, no address or personal data):
  `primary_location_set`, `setup_completed`, `draft_discarded`.
* **Entry (SF-84, unchanged):**
  * a draft resolves to `gym_onboarding` with its `gym_id`;
  * completion adds `GYM_WORKSPACE` and `gym_home`;
  * a discarded draft disappears, and its choices cascade away.
* **Durable creation keys:** `gym_creation_requests` (migration
  `20261028100000`, backfilled from existing gyms) records every
  `client_request_id` with the gym it created or resumed.
  * Discarding the gym only sets `gym_id` to NULL, so the key stays spent: a
    replay, however late and even racing the discard, answers `409`
    (`client_request_id: discarded`) and never creates a gym.
  * A lost-response retry before the discard returns the same gym, and a new
    key still creates normally.
  * Rows go with their user and carry no personal data; no retention period
    is invented.
* **Entry snapshot fix (SF-84 defect found here):**
  `Gyms.workspace_overview/2` now reads its counts, the single completed gym
  and the owned draft in one statement. Separate statements could straddle a
  concurrent completion and answer `gym_onboarding` without `gym_id`.

### Logo and cover: the storage blocker

`SimpleFit.Storage` (SF-15) can only presign uploads and downloads. A safe
attachment also needs three things it lacks:

* **Ownership:** a record binding an upload to its gym and purpose.
* **Existence:** a way to verify the uploaded object exists before
  attaching it.
* **Orphans:** cleanup of uploads that are never attached ("avoid orphaned
  uploads").

The smallest extension, proposed and not built:

1. A `gym_branding_uploads` table: gym, purpose (`logo` / `cover`), a
   server-generated key under `gyms/{gym_id}/branding/{uuid}`, content type,
   size and expiry.
2. A presign endpoint for owners and managers. Allowed types are
   `image/png`, `image/jpeg` and `image/webp`, within size limits. SVG is
   deferred: it is active content.
3. An attach step that verifies the object with a presigned `HEAD` through
   `SimpleFit.HTTP`.
4. An Oban job that deletes unattached uploads with a presigned `DELETE`.

This adds new adapter capabilities (HEAD and DELETE), so it needs its own
ticket. Branding never blocks completion.

### Deliberate deferrals (none blocks completion)

| Item | Status | Exact future dependency |
| --- | --- | --- |
| OG4 gym size | FUTURE (SF-82 D-G21, C1/R2) | It exists only to suggest a SimpleFit plan; it waits for the deferred product decision D-G09. No plan, price or payment is implied before then |
| OG5 features | FUTURE (SF-82 D-G21, C1/R2) | It maps plan entitlements; same dependency on D-G09 |
| Logo and cover | BLOCKED | A controlled media-asset lifecycle in `SimpleFit.Storage`: an upload record per gym and purpose, a server-side existence check (presigned `HEAD`) on attach, orphan cleanup (presigned `DELETE` via Oban), and an image type allowlist (SVG excluded). This is its own ticket |
| Tagline, accent colour | DONE, optional | — |

### Deviations

* OG4/OG5 and logo/cover are not built, as in the table above. The SF-82
  register outranks the SF-85 brief for OG4/OG5.
* The location `name` defaults to the city, because OG2 has no name field
  and the column is required.

## Amendment — SF-90 (2026-10-28): gym first run and setup checklist API

Claude Design source: canvas version `1792675284-1046` (unchanged). Artboards:
GRW1 `FirstRunWebG`, GRW2 `FirstRunWebGTour(Steps)` (9 steps + complete),
GR1 `FirstRunGPulse`, GR2 `FirstRunGCheckinTip(Steps)` (8 steps + complete)
and OS4 `OnbSTour` (staff, out of scope). The approved checklist is SF-82 C7
(`12-design-reconciliation-plan.md`); the boards still show the unapproved
published / invites / payout / store / challenge rows (R5).

### Three things, kept apart

| Concept | Source of truth | Changed by |
| --- | --- | --- |
| Gym setup | `gyms.setup_status` (SF-85) | `completeGymSetup` only; SF-90 never writes it |
| Introduction (first run) | `gym_first_runs`, one row per gym and owner | explicit start / complete / dismiss |
| Setup checklist | derived on every read from the gym's own records | nothing: no stored flag, no client input |

Tour steps, highlights, arrows, scroll, replays and overlays are client-only
and stored nowhere. A finished or skipped introduction marks no checklist
item and changes nothing about the gym.

### Lifecycle

* `unavailable` (the gym is a draft), `not_started` (no row), `in_progress`
  (`started_at`), then `completed` (`completed_at`) or `dismissed`
  (`dismissed_at`, the design's Skip / End tour; ADR 0018 vocabulary).
* **Final outcomes.** A repeat of the same outcome returns the same state
  with the first timestamp; the other outcome, or a start after an outcome,
  is `409 conflict` (`details.first_run: completed | dismissed`) and changes
  nothing. A dismissed introduction cannot be resumed: replaying the tour
  ("Replay the tour any time") is client-only. There is no reset, and new
  features never reopen it.
* `complete` without a recorded start sets `started_at = completed_at`; a
  dismissal without a start keeps `started_at` null.
* A draft's transitions are `409` (`details.setup_status: draft`); a draft
  never has a row.

### Data (migration `20261029090000`, explicit up/down)

* `gym_first_runs`: `gym_id` (`ON DELETE CASCADE`), `user_id`
  (`ON DELETE CASCADE`, personal presentation state like
  `first_run_outcomes`), `started_at`, `completed_at`, `dismissed_at`,
  timestamps.
* Unique `(gym_id, user_id)`; index on `user_id`.
* Checks: at most one outcome; a row records something; completion after a
  start; dismissal not before a start.
* Trigger `gym_first_runs_guard`: keys and a set start are immutable, and an
  outcome is final.
* Audit types `first_run_completed`, `first_run_dismissed` (gym, actor,
  type, time; nothing else). Starting is not audited.

### Checklist (SF-82 C7)

| Key | Status today | Derived from |
| --- | --- | --- |
| `create_gym` | `completed` when setup is completed; `available` for a draft | `gyms.setup_status` |
| `add_class` | `coming_later` | classes (SF-93) |
| `invite_staff` | `coming_later` | an accepted staff invitation (SF-92) |
| `invite_members` | `coming_later` | an active gym member (member domain) |
| `first_check_in` | `coming_later` | a recorded check-in (check-in domain) |

Item statuses are `completed`, `available` and `coming_later`. Each future
item derives from its own domain when that ships, with no change to the
first-run model. No item is ever blocked today, so no `blocked` status exists.

### API (tag "Gyms", all `no-store`)

| Operation | Path |
| --- | --- |
| `getGymFirstRun` | `GET /api/v1/gyms/{gym_id}/first-run` |
| `startGymFirstRun` | `POST /api/v1/gyms/{gym_id}/first-run/start` |
| `completeGymFirstRun` | `POST /api/v1/gyms/{gym_id}/first-run/complete` |
| `dismissGymFirstRun` | `POST /api/v1/gyms/{gym_id}/first-run/dismiss` |

* Every response is `GymFirstRunResponse`: `gym_id`, `status`, the three
  timestamps and `checklist`.
* Transitions take an empty body. Any field, such as a forged `user_id`,
  `gym_id` or checklist flag, is a `422 validation_error`.
* Errors:
  * 401: no, invalid or revoked session.
  * 404: unknown, foreign, malformed or revoked gym.
  * 403: active staff who are not the owner.
  * 409: a conflicting transition.
  * 422: a body field.

### Authorization and locks

* New permission `manage_first_run` (owner only). GRW1/GR1 are the owner's
  opening week. Managers, coaches and front desk get `403`; their tour is OS4
  (`gym_staff_tour`, later). The saved entry context is never authorization.
* `Access.authorize_shared/3`: gym row `FOR SHARE`, then the membership
  `FOR SHARE` (the SF-84 order), then the first-run row `FOR UPDATE`.
* Ownership transfer, revocation and discard lock the gym row `FOR UPDATE`,
  so they commit entirely before or after a first-run call. Two transitions
  of one owner serialize on the row, and a first insert is
  `ON CONFLICT DO NOTHING` then re-read under the lock.
* Real-commit race tests cover:
  * concurrent starts;
  * double completion;
  * completion vs. dismissal;
  * a mixed burst;
  * transfer vs. completion;
  * read vs. transfer;
  * revocation + setup write + transition;
  * draft completion or discard vs. start;
  * one owner on two gyms.

  The suite is repeated without failure.

### Ownership and lifecycle

* The state belongs to the gym and the user together. Gym A and Gym B are
  independent, and a later owner after a transfer starts fresh. The previous
  owner's row stays as history but is unreachable without the permission.
* Discarding a draft never meets a row. Deleting a user removes their rows;
  the database still refuses to delete an active member (SF-83). Deleting a
  gym (closure is future) removes its rows. No retention period is invented.
* Entry resolution (ADR 0017, SF-84) is unchanged: the first run never
  changes `resolveMyEntry`, and the gym shells work without it.

### Deviations from SF-82 §7

* **One cross-platform introduction per gym and owner.** SF-82 §7 proposed
  two per-user keys (`gym_web_tour`, `gym_mobile_first_run`) "after their
  first gym". The SF-90 brief requires per-gym independence and cross-device
  start/resume/complete, so one gym-scoped lifecycle replaces both.
  * Alternative: keep the two ADR 0018 keys in `first_run_outcomes`. Rejected:
    they are account-wide (gym B would inherit gym A) and have no
    `in_progress`.
  * Alternative: a per-platform pair per gym. Not chosen: web and mobile would
    show different states for one owner.
* **`in_progress` is stored.** ADR 0018 deliberately recorded only outcomes.
  The brief requires start on one device and resume on another, so the
  start is stored here, and only here.
* **Owner only.** SF-82 does not say whether managers see the checklist.
  Recommendation, as built: owner only until a design shows it to managers.
  Exposing a read-only checklist to managers later is additive.

## Amendment — SF-93 (2026-10-29): staff roles, coach affiliation and invitations

Jira SF-93 is the ticket the tables above call "SF-92" (staff invitations,
role change and the revocation HTTP operation). Its brief's older role
vocabulary (`admin`, `frontdesk`) is not used: the roles stay `owner`,
`manager`, `coach`, `front_desk`.

### Data (migration `20261030090000`, explicit up/down)

* **`gym_staff_invitations`**:
  * columns: `gym_id` (`ON DELETE CASCADE`), `invited_by_staff_membership_id`,
    `token_hash` (SHA-256 of the `sfs_` token, unique), `recipient_digest`
    (HMAC of the canonical address), `recipient_sealed` (encrypted address),
    `role` (`manager` | `coach` | `front_desk`, never `owner`), `status`
    (`pending` → `accepted` | `declined` | `cancelled` | `expired`),
    `expires_at`, `send_count`, `last_sent_at`, `responded_at`,
    `staff_membership_id`;
  * composite foreign keys `(gym_id, invited_by_staff_membership_id)` and
    `(gym_id, staff_membership_id)` to `gym_staff_memberships (gym_id, id)`
    (new unique index): neither the inviter nor the accepted membership can
    belong to another gym;
  * partial unique "one pending invitation per gym and recipient digest",
    unique "one invitation per accepted membership";
  * checks on roles, statuses, digest sizes and the outcome shape (only an
    acceptance names a membership; only a response has a time);
  * insert trigger: a completed gym only, and `pending` only;
  * update trigger: a resolved invitation is immutable; a pending one keeps
    its gym, recipient, role, inviter and creation; an acceptance must name
    an active membership of the gym with the invited role.
* **`gym_audit_events`**: nullable `staff_invitation_id`, and the types
  `staff_invited`, `staff_invitation_cancelled`, `staff_invitation_accepted`,
  `staff_invitation_declined`, `staff_role_changed`.
* `gym_staff_memberships` is unchanged: acceptance inserts an `active` row;
  ended rows stay final, so rejoining is a new row from a new invitation.

### Lifecycle and rules

* **Who invites whom:** the owner invites managers, coaches and front desk;
  a manager coaches and front desk; nobody invites an owner, and only a
  completed gym invites. Cancel and resend need the same permission.
* **Duplicates:** the same address and role while pending returns the
  pending invitation (`200`, no new token or email); another role is `409`
  (`staff_invitation: pending_other_role`); an address of an active member
  of this gym is `409` (`staff_membership: already_active`); gyms are
  independent. The gym row lock serializes invitation writes of one gym and
  the partial unique index is the final authority.
* **Expiry (D-G12):** 7 days from the last sending, server time. A pending
  invitation past `expires_at` is reported `expired` and the stored status
  catches up when it is next touched.
* **Resend** rotates the token (the old link stops at once) and restarts the
  7 days; at most 3 resends, 60 seconds apart.
* **Recipient binding (D-G16, D-G22):** only a signed-in user with an email
  identity for the invited address (proved by a code: ADR 0012, or ADR 0024
  linking for Google/Apple-only users) can accept or decline. Provider email
  claims never count; nothing is linked, merged or created. Inviting an
  unregistered address creates no account.
* **Two ways to answer, one transaction:** the mobile inbox
  (`/me/staff-invitations`, token-free, matched by the session user's
  verified addresses; unknown or foreign ids `404`) and the web page of the
  E06 link (token in the body: any unusable token `410
  invitation_unavailable`, a current token held by another account `403
  invitation_recipient_mismatch`).
* **Acceptance** (completed account registration only; no Coach or Fighter
  profile) locks the session (`FOR SHARE`, after the user row `FOR KEY
  SHARE`), the gym row (`FOR UPDATE`), then the invitation (`FOR UPDATE`),
  re-checks the recipient, the inviter's membership and role, and inserts the
  membership (`ON CONFLICT DO NOTHING` on the active-membership index),
  consumes the invitation and records `staff_invitation_accepted` and
  `staff_membership_created`: all or nothing. A repeat by the same person
  returns the same membership (`already_accepted`). A session revoked during
  the request answers `401`.
* **Role changes** (`change_staff_role`): owner any non-owner to `manager`,
  `coach`, `front_desk`; manager only between `coach` and `front_desk`; never
  one's own role, never to or from `owner` (`409 owner_requires_transfer`).
* **End of a membership:** removal (`removed`, as SF-83) or leaving (`left`,
  `leave_gym`: managers, coaches, front desk; never the owner). Access ends
  on the next request; the user's session and other gyms are untouched.
* **Inviter changes:** ending a membership (removal, leaving, ownership
  transfer) cancels the pending invitations it issued, and a role change
  cancels those its new role can no longer issue, in the same transaction.
  Acceptance also re-checks the inviter, as defence in depth.
* **New permission** `view_staff_records` (owner, manager): the gym's
  invitation list (masked addresses) and ended memberships. The active
  roster stays `view_staff` (every role).

### Lock order

Every staff write takes the gym row `FOR UPDATE` first, then memberships,
then invitations (SF-83 order). Acceptance takes the user and session first
(the account-deletion order of ADR 0024), then the same gym → invitation
order. Entry choice, first-run calls and setup writes are unchanged. Real
commit race tests: 12 concurrent acceptances, two accounts on one token,
accept vs cancel, accept vs decline, accept vs inviter removal, concurrent
invitations by two administrators and to different roles, role change vs
removal, attacks on the owner, removal vs entry choice, logout vs
acceptance, and one coach accepting two gyms at once.

### Coach affiliation (D-G06)

A gym coach is a `coach` staff membership. It needs no CoachProfile and
creates or changes none; an existing CoachProfile is untouched and not shown
to the gym. No Coach–Fighter relationship is created, and no gym role reads a
fighter's training data (tests: a gym coach with a CoachProfile and a
fighter working the front desk at the same gym see no relationship or
session of each other). One user may hold memberships at several gyms with
independent roles; ending one leaves the others.

### API (tag "Gym staff", all `no-store`)

| Operation | Path | Who |
| --- | --- | --- |
| `listGymStaff` | `GET /api/v1/gyms/{gym_id}/staff` | any staff (`status=ended`: owner, manager) |
| `changeGymStaffRole` | `PATCH /api/v1/gyms/{gym_id}/staff/{staff_membership_id}` | owner, manager (scoped) |
| `endGymStaffMembership` | `DELETE /api/v1/gyms/{gym_id}/staff/{staff_membership_id}` | removal per matrix; self (not owner) |
| `listGymStaffInvitations` | `GET /api/v1/gyms/{gym_id}/staff-invitations` | owner, manager |
| `createGymStaffInvitation` | `POST /api/v1/gyms/{gym_id}/staff-invitations` | owner, manager (scoped) |
| `resendGymStaffInvitation` | `POST …/staff-invitations/{invitation_id}/resend` | as inviting that role |
| `cancelGymStaffInvitation` | `POST …/staff-invitations/{invitation_id}/cancel` | as inviting that role |
| `listMyStaffInvitations` | `GET /api/v1/me/staff-invitations` | signed in |
| `getMyStaffInvitation` | `GET /api/v1/me/staff-invitations/{invitation_id}` | the recipient |
| `acceptMyStaffInvitation`, `declineMyStaffInvitation` | `POST /api/v1/me/staff-invitations/{invitation_id}/accept`, `/decline` | the recipient |
| `acceptStaffInvitation`, `declineStaffInvitation` | `POST /api/v1/me/staff-invitations/accept`, `/decline` (token in body) | the recipient |
| `previewStaffInvitation` | `POST /api/v1/staff-invitations/preview` (token in body) | anyone |

Errors: `401`; `404` (unknown, foreign, malformed or revoked gym, foreign
membership or invitation id); `403 forbidden` (active staff without the
permission); `403 invitation_recipient_mismatch` (token of another
address); `409 conflict` with the details above; `410
invitation_unavailable` (unusable token or a resolved inbox invitation);
`422 validation_error`; `429 rate_limited`.

### Rate limits (D-G25 open: mirrors SF-57)

Creation (rolling, counted only when an invitation is created): 10 per hour
and 30 per day per user, 100 per day per gym, 3 per day per recipient
address across gyms, 20 per 10 minutes per client. Previews and answers: 30
per 10 minutes per client. Resend, cancel, role change and removal: 60 per
10 minutes per user. Product may tune these when D-G25 closes.

### Email (E06)

The existing E06 template (SF-35) is sent in the invitation's transaction
through the encrypted Oban outbox, with `<web app>/invite/staff#token=sfs_…`
(fragment only). The template's invitee name and location became optional:
an invitation is addressed to an email, and no location is assigned. The
abilities listed are only those that exist today (manager: edit details and
location, invite coaches and front desk, see the team; coach and front desk:
open the workspace, see the team). The reconciled E06 copy (C15/R10) is not
yet published in Claude Design.

### Entry and checklist

Acceptance adds the gym to `resolveMyEntry`/`listMyGyms` (`GYM_WORKSPACE`)
and selects nothing. The SF-90 `invite_staff` item is `available` at a
completed gym and `completed` once any staff invitation of the gym was
accepted (SF-82 03 §3); sending one is not enough and a later removal does
not undo it. A draft keeps `coming_later`.

### Deviations and gaps

1. Inviter display: first name to recipients (T9), "First L." in the gym's
   roster and invitation list, both from the account name. Using the account
   name for staff display needs product confirmation.
2. The web page `/invite/staff` and the mobile inbox `/me/gym-invitations`
   are not in the route registry yet (the frontend ticket). Until then an E06
   link has no page; the API is complete.
3. Claude Design 112 still shows unreconciled E06, OS2, OG11, WG16 and WG17
   copy (drop-ins, incidents, fighter notes, payouts, shifts, a per-invite
   location, an invitee name); the SF-82 corrections R4, R7, R10, R11 and
   C10–C16 apply.
4. Ownership transfer stays a domain function without an HTTP operation.

## Amendment — SF-95 (2026-10-30): gym members, enrollment, member invitations and the member-list foundation

SF-82 calls this backend scope "SF-89" (09 dependency matrix). It adds gym
**members** (participants) as a domain of their own; no member UI is built
(SF-91 owns `/me/gyms`, `/invite/gym` and `/join/:code`).

### Domain

A gym membership (`gym_members`) is a user's participation in one gym. It is
independent of staff memberships (a staff member may also be a member, in
another row and table), of Fighter and Coach profiles and of Coach–Fighter
relationships: no column refers to them, none is required, created or
changed, and no gym permission or `GYM_WORKSPACE` derives from it (Policy
and entry read staff memberships only). Joining needs a completed account
and nothing else (D-G07).

### Data (migration `20261031090000`, explicit up/down)

* **`gym_members`**: `gym_id`, `user_id` (`ON DELETE SET NULL`), `status`,
  `joined_via` (`join_code` | `invitation`), `auto_approved`,
  `requested_at`, `activated_at`, `responded_at`, `ended_at`,
  `ended_reason` (`left` | `removed` | `account_deleted` | `gym_closed`).
  * partial unique "one `requested`-or-`active` row per gym and user"; any
    number of final rows (re-enrollment keeps the history);
  * checks: vocabularies, a user on every non-final row (so a current
    membership blocks account deletion and a final one keeps its history
    with `user_id` NULL), auto-approval only on join-code rows, and the
    exact timestamps of each status;
  * insert trigger: completed gym only; born `requested`, or `active` only
    from an invitation or an auto-approval;
  * update trigger: transitions `requested` → `active` | `rejected` |
    `cancelled` and `active` → `ended` only; gym, user, origin, request and
    creation immutable; final rows immutable (except the user removed by an
    account deletion);
  * delete trigger: **no physical deletion**, unless a maintenance session
    sets `simple_fit.allow_gym_member_purge` (real-commit test cleanup; a
    future approved retention job).
* **`gym_member_invitations`**: as `gym_staff_invitations` without a role,
  with `gym_member_id` (composite foreign key to `gym_members (gym_id,
  id)`); the same pending-uniqueness, outcome-shape and guard triggers; an
  acceptance must name an active membership of the gym.
* **`gym_enrollment_settings`** (one row per gym, created by its first
  change): `join_code_digest` (HMAC, unique), `join_code_sealed`
  (encrypted, for staff display), `join_code_rotated_at`, `auto_approve`
  (default `false`), `auto_approve_changed_at`; completed gyms only. No row:
  no code, no auto-approval.
* **`gym_audit_events`**: nullable `gym_member_id`, `member_invitation_id`
  and `enabled`; types `member_join_requested`, `member_join_approved`,
  `member_join_auto_approved`, `member_join_rejected`,
  `member_join_cancelled`, `member_ended`, `member_invited`,
  `member_invitation_cancelled`, `member_invitation_accepted`,
  `member_invitation_declined`, `join_code_rotated`, `join_code_disabled`,
  `member_auto_approval_changed`.

### Enrollment (D-G08, T10)

* **Join code:** 8 symbols of the Crockford base32 alphabet (40 bits), shown
  `ABCD-EFGH`, typed forgivingly; stored only as a digest and an encrypted
  copy. Joining creates a `requested` membership; owner, managers and front
  desk approve or reject (`manage_member_enrollment`). Rotation stops the
  old code at once; disabling removes it. A pending request joined again is
  returned (`200`); an active member joining is `409 gym_member:
  already_active`.
* **Auto-approval:** off by default; an owner or manager switches it
  (new permission `manage_enrollment_settings`: owner, manager), each change
  audited with `enabled`. When on, a joiner starts `active` only with a
  completed account **and** a verified sign-in identity
  (`Accounts.verified_identity?/1`: an identity exists only after an email
  code or a verified Google/Apple token); otherwise a request.
* **Member invitation (E07):** owner, managers and front desk invite an
  address (`sgm_` token, separate salts: never matches a staff or coach
  secret). Recipient binding, inbox, token page, preview, decline, resend
  and cancel exactly as staff invitations (D-G16/D-G22 rules). Accepting
  inserts an `active` membership (`joined_via: invitation`) or approves the
  recipient's pending join request. The invitation is the gym's: it stays
  valid when the inviting staff member leaves.
* **Expiry decision (SF-95):** a member invitation expires **7 days after it
  was last sent** (server time), the D-G12 staff rule: no separate member
  value was approved, and one rule for every gym invitation keeps E06 and E07
  predictable. Resend restarts the 7 days (at most 3 resends, 60 s apart).

### Lifecycle

`requested` → `active` (approve, auto-approve, invitation) | `rejected`
(staff) | `cancelled` (requester); `active` → `ended` (`left` by the member,
`removed` by owner/manager: `change_member_status`). Each transition is
idempotent for its own result and `409 gym_member: <status>` otherwise.
Leaving as a member leaves a staff membership at the same gym untouched.
Suspension (proposal 01's `suspended`) is deferred: no product need yet.

### Roster and permissions

The roster (`view_members`) shows a short name ("Marta K."), status, origin
and dates: never an email, user id, profile or training data. Owner,
managers and front desk see it; a coach's grant is `own_classes` and no
class domain exists, so coaches are refused (`403`) rather than shown an
empty list. Member contact data (`view_member_contact`) is not exposed by
any SF-95 operation.

### Lock order

Staff decisions: gym row `FOR UPDATE` → staff membership → member row
(SF-83 order). A member's own changes: user/session `FOR SHARE` → gym row
`FOR SHARE` → enrollment settings `FOR SHARE` (joins) → member rows /
invitation `FOR UPDATE`. Setting changes: gym `FOR UPDATE` → settings `FOR
UPDATE`. The partial unique index settles simultaneous joins and
acceptances (`ON CONFLICT DO NOTHING`, the loser answers with the winner's
row). Real-commit race tests: 12 joins by one user, approve/reject/cancel on
one request, 12 acceptances (inbox and token), join vs acceptance,
joins vs the auto-approval switch, joins vs code rotation, leave vs removal.

### API (tag "Gym members", all `no-store`)

| Operation | Path | Who |
| --- | --- | --- |
| `listGymMembers`, `getGymMember` | `GET /api/v1/gyms/{gym_id}/members[/{gym_member_id}]` | owner, manager, front desk |
| `removeGymMember` | `POST …/members/{gym_member_id}/remove` | owner, manager |
| `listGymJoinRequests` | `GET /api/v1/gyms/{gym_id}/join-requests` | owner, manager, front desk |
| `approveGymJoinRequest`, `rejectGymJoinRequest` | `POST …/join-requests/{gym_member_id}/approve`, `/reject` | owner, manager, front desk |
| `getGymEnrollmentSettings` | `GET /api/v1/gyms/{gym_id}/enrollment` | owner, manager, front desk |
| `updateGymEnrollmentSettings` | `PATCH /api/v1/gyms/{gym_id}/enrollment` | owner, manager |
| `rotateGymJoinCode`, `disableGymJoinCode` | `POST /api/v1/gyms/{gym_id}/join-code/rotate`, `/disable` | owner, manager |
| `previewGymMemberImport` | `POST /api/v1/gyms/{gym_id}/member-imports/preview` | owner, manager, front desk |
| `createGymMemberInvitation`, `listGymMemberInvitations` | `POST`/`GET /api/v1/gyms/{gym_id}/member-invitations` | owner, manager, front desk |
| `resendGymMemberInvitation`, `cancelGymMemberInvitation` | `POST …/member-invitations/{invitation_id}/resend`, `/cancel` | owner, manager, front desk |
| `listMyGymMemberships`, `getMyGymMembership` | `GET /api/v1/me/gym-memberships[/{gym_member_id}]` | signed in (own) |
| `joinGym` | `POST /api/v1/me/gym-memberships/join` | registered user |
| `cancelMyGymJoinRequest`, `leaveGymMembership` | `POST /api/v1/me/gym-memberships/{gym_member_id}/cancel`, `/leave` | the member |
| `listMyGymInvitations`, `getMyGymInvitation` | `GET /api/v1/me/gym-invitations[/{invitation_id}]` | signed in |
| `acceptMyGymInvitation`, `declineMyGymInvitation` | `POST /api/v1/me/gym-invitations/{invitation_id}/accept`, `/decline` | the recipient |
| `acceptGymInvitation`, `declineGymInvitation` | `POST /api/v1/me/gym-invitations/accept`, `/decline` (token in body) | the recipient |
| `previewGymInvitation` | `POST /api/v1/gym-invitations/preview` (token in body) | anyone |
| `previewGymJoin` | `POST /api/v1/gym-join/preview` (code in body) | anyone |

### Rate limits (D-G25 open)

Code previews and joins: 20 per 10 minutes per client, 10 per user, every
attempt counted. Member invitation creation (rolling, counted when created):
30 per hour and 100 per day per user, 300 per day per gym, 3 per day per
address across gyms, 60 per 10 minutes per client. Invitation previews and
answers: 30 per 10 minutes per client. Member administration (decisions,
removal, settings, resend, cancel): 120 per 10 minutes per user. List
previews: 30 per 10 minutes per user.

### Member-list import (OG12): foundation only

`previewGymMemberImport` parses a CSV (own strict RFC 4180 reader: UTF-8,
`,`/`;`/tab, quotes; 1 MB, 1,000 rows, 30 columns, 500 bytes per field),
suggests or takes a mapping (`email` required, `name` checked for presence
only, every other column `not_imported`), validates and deduplicates by
canonical email, and classifies rows against **this gym's own facts only**
(`ready`, `missing_email`, `invalid_email`, `duplicate`, `already_member`,
`request_pending`, `already_invited`). It is a dry run: nothing is stored,
queued, audited or logged; addresses come back masked; no user is created
or verified, nothing is linked, merged or matched by name. The `csv`
parameter is filtered from request logs and redacted from crash reports.

**Blocked** until an approved legal basis and retention rule exist (SF-82
D-G08 "CSV import is future", T15, OG12): the commit and its idempotency,
"unclaimed contacts" (storing people without an account), storing names,
phones, plans or start dates, and bulk E07 sending from a list. The
response says so (`commit: {available: false, blocked_by:
"legal_basis_pending"}`). No GDPR or marketing-consent policy was created.

### Email (E07)

The E07 template now carries the approved C15/R10 copy: "{gym} invited you
to join on SimpleFit", no membership plan, payment method or "shared your
name, email and plan"; the privacy line "the gym used your email address to
invite you"; the link `<web app>/invite/gym#token=sgm_…` (fragment only).
Interim: C15's "book classes and check in" waits for those domains, and
there is no opt-out link (no opt-out flow; ignoring the email lets it
expire). Sent through the encrypted Oban outbox in the invitation's
transaction. Production delivery settings are unchanged.

### Entry and checklist

Members get no `GYM_WORKSPACE` (tested). The SF-90 `invite_members` item is
`available` at a completed gym and `completed` once any membership of the
gym became active (03 §3 "done when ≥ 1 member is active"); a later end does
not undo it; a draft keeps `coming_later`.

### Deviations and gaps

1. Statuses follow the SF-95 brief (`rejected`, `cancelled`) rather than
   proposal 01's `declined`; `suspended` is deferred.
2. The join-code settings are read by the front desk (to show the code at
   the desk, 02 §4) but changed only by owner and managers (11: "owner,
   manager").
3. No E09 "join approved" email is sent: E09's copy (plan, billing, QR)
   needs its own reconciliation.
4. Member UI, `/invite/gym`, `/join/:code` and the mobile inbox entries are
   SF-91's; until then an E07 link has no page.
5. Coach-scoped roster (`own_classes`) waits for the class domain.
