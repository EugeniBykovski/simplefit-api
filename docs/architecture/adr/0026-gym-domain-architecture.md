# ADR 0026 — Gym domain architecture

* Status: **Accepted** (SF-82, final approval 2026-10-23). Epic SF-81 Gym &
  Club Management. Nothing is implemented; SF-83 needs its own start
  authorization.
  * **Approved:** `D-G01`–`D-G08`, `D-G12`–`D-G16`, `D-G18`, `D-G20`–`D-G24`
    and `D-G26`.
  * **Deferred product decisions** (not engineering facts): `D-G09`
    (pricing, gym SaaS subscriptions, trials, billing, commercial ownership
    limits), `D-G10` (payment provider and architecture) and `D-G11`
    (business verification and publishing). Later tickets decided parts of
    them: SF-101 (D-G09 drafts), SF-102 (D-G10: Stripe for SaaS billing) and
    SF-103 (D-G11: business verification only; publishing still deferred).
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
**members** (participants) as a domain of their own; no member UI is built.
The member screens (`/me/gyms`, `/invite/gym`, `/join/:code`, the mobile
inbox entries and the members console) have **no Jira task yet**: SF-91 is
the Gym Web First Run and SF-100 the member booking and attendance UI; the
SF-82 numbers (SF-90/SF-91) for these screens were a superseded proposal.

### D-G08 reconciliation

`D-G08` keeps its approved meaning: request-based enrollment by join code,
staff approval, auto-approval only when a gym explicitly enables it and
never without a verified identity, and E07 acceptance only with a verified
identity for the invited address. SF-95 implements exactly that. The
register row's trailing note ("CSV import is future") is a scope note, not
the decision that blocks importing: the member-list import commit, contact
retention and lawful processing are the separate, **proposed** decision
`D-G27` (10 §3), which is not approved. Earlier SF-95 text that cited
`D-G08` as the import blocker is corrected here.

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

**Blocked** until the proposed decision `D-G27` (lawful basis, retention,
erasure, opt-out) is approved (threat model T15; OG12): the commit and its idempotency,
"unclaimed contacts" (storing people without an account), storing names,
phones, plans or start dates, and bulk E07 sending from a list. The
response says so (`commit: {available: false, blocked_by:
"legal_basis_pending"}`). No GDPR or marketing-consent policy was created.

**Follow-up (Jira-ready): "Gym Member Import Commit & Contact Data
Retention".** Entry condition: `D-G27` approved (lawful basis, retention
period for unaccepted invitations, erasure path, E07 opt-out wording,
controller/processor roles). Scope, if option B is approved: a commit of a
previewed list that creates only member invitations (sealed address and
digest; never names, phones, plans or dates), idempotent by a
client-supplied key and a stored digest of the normalized list, re-validated
at commit against the same classification; per-gym daily caps and the
existing per-address limit; scheduled, throttled E07 sending; automatic
expiry and purge of unaccepted invitations after the approved period; a
public opt-out link and a suppression list that blocks future invitations to
an address; audit events with counts only; real-commit race tests (double
commit, commit vs manual invite, commit vs acceptance); real E2E. Out of
scope: unclaimed contact records (option C), contact export, marketing
consent. Depends on the recipient flow (`/invite/gym` and the in-app inbox),
which must ship first.

### Email (E07)

The E07 template now carries the approved C15/R10 copy: "{gym} invited you
to join on SimpleFit", no membership plan, payment method or "shared your
name, email and plan"; the privacy line "the gym used your email address to
invite you"; the link `<web app>/invite/gym#token=sgm_…` (fragment only).
Interim: C15's "book classes and check in" waits for those domains, and
there is no opt-out link (no opt-out flow; ignoring the email lets it
expire). Sent through the encrypted Oban outbox in the invitation's
transaction. Production delivery settings are unchanged.

**Launch gate.** The E07 link opens `/invite/gym`, which does not exist yet
(web has only `/invite/coach`; mobile `/join/:code` and `/invite/staff/:token`
are placeholders, and there is no in-app member inbox). So creating and
resending member invitations are **off in production**: they answer `409
member_invitation: recipient_flow_unavailable` after the usual access
checks, unless `GYM_MEMBER_INVITATIONS=enabled` is set (fail closed; dev and
test enable them in config). The backend capability (answering, preview,
inbox API) is complete and tested; the recipient UI is a separate
dependency. Joining by code has the same UI gap but sends no email, so it
needs no gate: without a screen, nobody is directed to it.

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
4. Member UI, `/invite/gym`, `/join/:code` and the mobile inbox entries
   have no Jira task yet; until they ship, E07 stays gated off in
   production (see "Launch gate").
5. Coach-scoped roster (`own_classes`) waits for the class domain.
6. Pre-existing, outside SF-95: E06 staff invitation links also point at a
   web page (`/invite/staff`) that does not exist yet, and production sends
   E06 today (SF-93). A recipient-flow ticket or the same gate for E06 is
   recommended. Done in SF-133 (below).

## Amendment — SF-97 (2026-11-02): gym classes, venues and the timetable API

### Scope

Gym venues, class templates, bounded weekly series and class occurrences
under `/api/v1/gyms/{gym_id}/…` (`D-G15`), separate from ADR 0023 training
sessions (`D-G14`). No bookings, waitlists, attendance, check-ins,
payments, notifications or timetable UI.

### Decisions taken by this ticket

1. **Venues exist now.** D-G02 kept rooms FUTURE; SF-97 is the ticket that
   introduces them (`gym_venues`): a training area at one of the gym's own
   non-archived locations, with an IANA zone (fixed) and an optional
   capacity. Every class takes place in exactly one venue, and **every venue
   is exclusive** (one scheduled class at a time). Non-exclusive areas are
   future.
2. **Zone.** The venue carries the zone (the place decides the wall clock);
   a series and each occurrence copy it when created and never change it. A
   one-time class is an RFC 3339 instant whose explicit offset must be the
   zone's at that instant (ADR 0023's rule): a spring-gap time cannot be
   sent, the two instants of an autumn repeated hour are chosen by offset.
3. **Weekly series are bounded and fully materialized** (deviation from
   SF-82 05's rolling 8-week window and Oban job): `starts_on` today or
   later, `ends_on` at most 365 days after it and 366 days from today; every
   class is written when the series is created or changed, so each one has
   passed the venue and instructor constraints (no projected, unchecked
   classes; no job; no gaps between windows). A longer schedule is extended
   by changing `ends_on`. `POST …/generate` is an idempotent repair (normally
   0 classes).
4. **DST policy for series.** Local times are resolved date by date in the
   zone (`scheduling_resolve_local/2`). A date whose local start time does
   not exist (spring gap) **or exists twice** (autumn repeated hour) is
   skipped and reported in `skipped_dates` (`nonexistent_local_time`,
   `ambiguous_local_time`), never shifted or guessed; SF-82 05 approved
   skipping the gap, and the ambiguous case gets the same treatment rather
   than a silent choice. Such a class is scheduled as a one-time class with
   an explicit offset. Duration is elapsed time.
5. **Series change policy.** Only classes still to come that follow the
   rule are rewritten: kept dates updated, lost dates cancelled
   (`series_changed`, which a later rule may restore), new dates created.
   Started classes, classes changed on their own (`rescheduled_at`) and
   classes cancelled by staff stay. Series cancellation cancels every class
   still to come (`series_cancelled`) and is final. Template edits change
   only defaults; scheduled classes keep their title, duration, capacity,
   venue and instructor.
6. **Instructors.** An active owner, manager or coach membership of the gym
   (front desk never; a CoachProfile alone never). One instructor per class.
   A person instructs one scheduled class at a time **across all gyms**
   (exclusion on `instructor_user_id`); the conflict answer is a bare
   `instructor_unavailable` with no details, so no gym learns another's
   schedule. Coach–Fighter training sessions are not part of the conflict
   scope. When a membership ends (removal, leaving, transfer) or becomes
   front desk, `Timetable.release_instructor!/4` clears it from the gym's
   classes still to come (`needs_instructor`), its series and its template
   defaults in the same transaction (audited `class_instructor_released`);
   past classes keep it.
7. **Permissions.** Read: every active staff role (`view_workspace`).
   Create, change, regenerate, cancel series, venues and templates:
   `manage_timetable` (owner, manager). Cancel one class:
   `cancel_occurrence` (owner and manager any; coach `own_occurrences`, a
   class they instruct). No new permission was added.
8. **`add_class`** is completed once the gym has any class occurrence (one-time
   or from a series); a template alone does not complete it, and a later
   cancellation does not undo it.
9. **Capacity** is the limit a future Booking domain enforces
   (`active_bookings <= capacity`, counted from real booking rows in the same
   transaction that locks the occurrence). A venue capacity caps its classes;
   it may not drop below a class still to come. Nothing is reserved or
   counted here.

### Model and invariants

`gym_venues`, `gym_class_templates`, `gym_class_series`,
`gym_class_occurrences` (migration `20261102090000`). Every cross-reference
is a composite foreign key including `gym_id`. Occurrences have one row per
`(series_id, series_local_date)`; `ends_at - starts_at = duration`;
`scheduled | cancelled` (`series_changed` the only revivable reason);
exclusion constraints `gym_class_occurrences_venue_overlap` and
`…_instructor_overlap` on `tsrange(starts_at, ends_at, '[)')` of scheduled
rows (deferrable; series writes check them at the end of their own work).
Triggers: completed gym, active venue at an active location, capacity within
the venue's, an eligible instructor (the person derived by the database),
fixed identity fields, cancelled final, no deletes (the SF-95 purge switch
only). Extension `btree_gist`.

### Writes and concurrency

Every write holds the session (`FOR SHARE`), then the gym row and the
actor's membership (`Access.authorize_locked/3`): one gym's timetable writes,
staff revocations and role changes serialize. Two gyms inserting overlapping
classes for one person can deadlock in the exclusion check; the losing
transaction is retried (at most 3 times) and then meets the committed row as
a conflict. Creates are idempotent by `client_request_id` per gym; changes
take `expected_revision` (`422` missing, `409 revision: stale`). Rate limit:
120 timetable writes per 10 minutes per user.

### API

Tag "Gym timetable": `listGymVenues`, `createGymVenue`, `getGymVenue`,
`updateGymVenue`, `deactivateGymVenue`, `listGymClassTemplates`,
`createGymClassTemplate`, `getGymClassTemplate`, `updateGymClassTemplate`,
`archiveGymClassTemplate`, `listGymClassSeries`, `createGymClassSeries`,
`getGymClassSeries`, `updateGymClassSeries`, `cancelGymClassSeries`,
`generateGymClassSeries`, `listGymClassOccurrences` (`from`/`to`, at most 31
days; filters venue, instructor, template, series, status; cursor pages),
`createGymClassOccurrence`, `getGymClassOccurrence`,
`updateGymClassOccurrence`, `cancelGymClassOccurrence`. Occurrences return
UTC instants, the zone, wall-clock start and end, the offset and no booking
or attendance figures.

### Audit and telemetry

Audit events (ids and counts only): `venue_created|updated|deactivated`,
`class_template_created|updated|archived`,
`class_series_created|updated|cancelled`,
`class_occurrence_created|rescheduled|cancelled`, `class_instructor_changed`,
`class_capacity_changed`, `class_instructor_released`. Telemetry
`[:simple_fit, :gyms, :timetable, event]` with the outcome only.

## Amendment — SF-99 (2026-11-02): class bookings, attendance and the participant roster API

### Scope

Bookings of SF-97 class occurrences by active SF-95 gym members, staff
booking on a member's behalf, the privacy-safe class roster and manual staff
check-in, under `/api/v1/me/…` and `/api/v1/gyms/{gym_id}/…`. Separate from
ADR 0023 training sessions (`D-G14`); no FighterProfile or CoachProfile is
needed or created. No waitlist, payments, entitlements, credits, QR or
self check-in, notifications, no-show penalties or UI (SF-100).

### Decisions taken by this ticket

1. **Booking window.** A class is bookable while it is `scheduled` and has
   not started (`409 class_occurrence: cancelled | started`). No opening
   time or cutoff before the start.
2. **Cancellation window.** A confirmed booking is cancelled, by the member
   or by staff, until the class starts (`409 class_occurrence: started`).
   A checked-in booking is never cancelled (`409 class_booking: checked_in`).
   A cancelled booking is final and keeps its row (`cancel_reason`
   `member_cancelled | staff_cancelled | occurrence_cancelled |
   membership_ended`, `cancelled_at`, `cancelled_by_user_id`); booking the
   class again is a new booking.
3. **One current booking per member and class**, partial unique index on
   `(occurrence_id, gym_member_id) WHERE status = 'confirmed'`; a second
   attempt is `409 class_booking: already_booked`.
4. **Idempotency.** `client_request_id` is unique per gym and names one
   logical booking for ever: the same key again returns that booking
   (`200`), even after it was cancelled, and takes no new seat; the same key
   for another member or class is `409 client_request_id: reused`.
5. **Capacity.** `confirmed bookings <= capacity`, counted under the
   occurrence row lock (`FOR UPDATE`) and checked again by the
   `gym_class_bookings_guard` trigger. Full is `409 class_occurrence: full`
   with the capacity. No overbooking or staff override.
6. **SF-97 lifecycle.** Cancelling a class or a series releases its
   confirmed bookings (`occurrence_cancelled`, one `class_bookings_released`
   audit event per class with the count) in the same transaction, before
   the status changes; the database refuses to cancel a class that still
   holds confirmed bookings. A capacity below the confirmed bookings is
   refused (`409 class_occurrence: capacity_below_bookings` with
   `confirmed_bookings`; for a series, `class_series:
   capacity_below_bookings` with the affected `local_dates`), by the app
   and by a trigger. Rescheduling keeps the bookings.
7. **SF-95 lifecycle.** A membership that ends (removal, leaving, account
   deletion) releases, in the same transaction, the member's confirmed
   bookings of classes still to come with no check-in
   (`membership_ended`); history stays. A requested, rejected, cancelled or
   ended membership books nothing (`409 gym_member`).
8. **Check-in** is manual, by staff only, on a confirmed booking of a
   scheduled class, on the class's own local day in its venue's zone (`409
   class_occurrence: not_today`; also after the class has ended that day).
   One per booking (unique `booking_id`): a repeat returns the same event
   (`200`) and writes nothing. No correction or undo.
9. **Permissions** (existing `Gyms.Policy`, nothing added): roster
   `view_rosters` (owner, manager, front desk any class; coach only a class
   they instruct, else `403`); book and cancel for a member
   `book_for_member` (owner, manager, front desk); check-in
   `record_check_in` (every active staff role). A member reaches only their
   own bookings (anyone else's is `404`).
10. **`first_check_in`** is completed once the gym has a real check-in; a
    booking alone does not complete it.

**Proposed, not implemented (FUTURE):** waitlist and promotion, booking
opening times and cancellation cutoffs, late-cancel and no-show policies,
check-in correction, self or QR check-in, capacity overrides, paid or
entitlement-gated booking, notifications.

### Model and invariants

`gym_class_bookings` and `gym_class_check_ins` (migration
`20261104090000`, explicit up/down). Every cross-reference is a composite
foreign key including `gym_id`; a check-in references
`(booking_id, occurrence_id, gym_member_id)` of its booking. Triggers:
insert only for a scheduled class, an active member and a free seat (the
trigger locks the occurrence row); `confirmed → cancelled` the only
transition, identity fields fixed; check-ins immutable (only the recorder's
user reference is nulled on account deletion) and only for a confirmed
booking of a scheduled class; occurrence capacity and cancellation guarded
against confirmed bookings; no deletes (the SF-95 purge switch only).

### Writes and concurrency

Lock order: session (`FOR SHARE`) → gym → staff membership → member →
occurrence (`FOR UPDATE`) → booking. A member's booking or cancellation
holds the gym `FOR SHARE`; staff writes and every SF-97 timetable write hold
it `FOR UPDATE` (`Schedule.write/5`), so a class change, cancellation,
member removal or staff revocation commits entirely before or after a
booking, and bookings of one class serialize on its row. Verified by real
PostgreSQL race tests (committed transactions): 20 members for the last
seat, 30 for 5 seats, one key 20 times, booking against cancellation,
class and series cancellation, capacity reduction, member removal and
session revocation, two gyms, 20 concurrent check-ins, check-in against
cancellation and against class cancellation with staff revocation. Rate
limit: 60 bookings and cancellations per 10 minutes per user
(`gym_booking_user`; a replayed key answers before it counts); staff writes
also take the 120 per 10 minutes timetable limit.

### API

Tag "Gym bookings", all `no-store`. Member: `listMyGymClasses` (`GET
/me/gym-memberships/{gym_member_id}/classes`, window as the timetable, seats
left and the caller's own booking), `bookMyGymClass` (`POST
…/class-bookings`), `listMyGymClassBookings`, `getMyGymClassBooking`,
`cancelMyGymClassBooking` (`/me/class-bookings…`). Staff:
`getGymClassRoster` (`GET /gyms/{gym_id}/class-occurrences/{occurrence_id}/bookings`,
summary `capacity`, `confirmed_count`, `remaining_capacity`,
`checked_in_count`; entries carry the member's short name, booking status,
times and check-in time, never an email, user id, profile or training
data), `bookGymClassForMember`, `cancelGymClassBooking`,
`checkInGymClassBooking` (`/gyms/{gym_id}/class-bookings/{booking_id}/…`).
Errors `401`, `403`, `404` (another gym, a booking that is not the
caller's), `409` (details above), `422` (unknown or invalid fields), `429`.

### Audit and telemetry

Audit events (ids and counts only, new columns `class_booking_id`,
`booking_count`): `class_booking_created`, `class_booking_cancelled`,
`class_bookings_released`, `class_check_in_recorded`. Telemetry
`[:simple_fit, :gyms, :booking, event]` with the outcome only.

## Amendment — SF-101 (2026-11-03): SimpleFit plans, gym member products and entitlements

### Scope

A provider-independent commercial domain: SimpleFit's SaaS plans sold to
gyms (`SimpleFit.Billing`), a gym's own products sold to its members
(`SimpleFit.Gyms.Commerce`, internal to `SimpleFit.Gyms`), and
backend-owned entitlements (`SimpleFit.Entitlements`). Two separate domains
with no shared table, state or entitlement. No payment provider, payment,
invoice, tax, refund, payout, credit redemption, renewal charge, checkout UI
or feature gating.

### D-G09 reconciliation and price sources

The SF-82 register (D-G09 SaaS pricing, D-G10 payments and member commerce,
D-G11 KYB) said no plan or price is stored. SF-101 is the product decision
that amends **D-G09 only so far as storing drafts**: plans and prices exist
as versioned data, and nothing is offered until an operator publishes a
version under an approval reference. D-G10 and D-G11 stay open: no provider,
no payment and no KYB; activation is impossible outside tests.

Price source priority: approved design → ADR/Jira decision → the SF-101
provisional catalog. Design v112 (`1793198527-a0fc`) shows illustrative EUR
tiers (Free €0, Starter €39, Pro €89 with a 14-day trial, Business €179,
Club+ €299, Multi-location from €499; "VAT added at checkout") on boards
labelled FUTURE / D-G09, and inconsistent złoty member prices on OG8, WG6,
GC2 and GC6: not approved. So the provisional catalog is stored, **as drafts
only** (`price_source: provisional`): Starter 149 / 1490 PLN, Growth 349 /
3490, Pro 699 / 6990 (month / year), Enterprise `quote_required` (no amount,
never zero), no Free plan, a 14-day trial **proposal** (`proposed_trial_days`,
never granted), no entitlements. The provisional member examples (Single
Class 49, 4-Class Pack 169, 8-Class Pack 299, Unlimited Monthly 399 PLN) are
not seeded at all. **Unresolved:** EUR tiers in design and on the public site
(SF-43) versus the PLN provisional catalog; feature mapping per plan;
commercial caps; trial policy; VAT presentation; grandfathering.

### Decisions taken by this ticket

1. **Money.** Integer minor units (`bigint`, `>= 0`, at most 10^12) with an
   ISO 4217 code from a supported list (PLN EUR USD GBP CHF CZK SEK NOK DKK
   HUF UAH JPY; JPY has no minor unit). Input is a decimal string (or a
   `Decimal`), never a JSON number: floats, integers, negatives, exponents
   and excess precision are `422`. Output is the decimal string, the currency
   and `amount_minor`. No conversion, VAT or discount. Zero is a price
   (free); a missing price is not.
2. **Plan catalog (operator workflow).** `saas_plans` (stable key) →
   `saas_plan_versions` (`draft | archived | published | superseded |
   retired`, one draft and one published per plan, approval reference and
   operator name required to publish, a provisional draft also needs an
   explicit confirmation) → `saas_price_versions` (month / year × currency,
   `fixed` or `quote_required`) and `saas_plan_entitlements` (registry keys).
   Written only by `mix billing.catalog` (no HTTP write), audited in
   `billing_audit_events` with the operator's name. Publishing supersedes the
   previous published version, which stays immutable with its subscriptions.
3. **Gym SaaS subscription.** The gym is the subscriber; its owner acts for
   it (existing `manage_billing`, owner only; an ownership transfer moves the
   authority, not the subscription). An intent (`pending_activation`) names a
   published version's `fixed` price and grants nothing; one current
   (`pending_activation | active | cancellation_scheduled`) subscription per
   gym. Cancellation `immediate` or `period_end` (an intent is always
   cancelled at once), idempotent. Period end: an active subscription
   expires (no renewal source exists), a scheduled cancellation takes effect.
4. **Member products.** A gym's `gym_member_products` (key, type
   `single_visit | class_pack | unlimited_period`, `active | retired`) →
   immutable versions (name, admissions, validity; one draft, one published)
   → append-only prices per currency (`sequence`; the highest is current, an
   earlier subscription keeps its own). Owner and managers manage
   (`manage_member_products`), front desk reads (`view_member_products`,
   `view_member_product_subscriptions`), coaches hold no commercial
   permission. An active member asks for the published version at its
   current price (`pending_activation`, nothing granted, a superseded price
   is `409`); cancelling is immediate and idempotent; a membership that ends
   cancels its product subscriptions (`membership_ended`) in the same
   transaction. A staff membership is not a member product, and a gym
   membership is not a paid subscription. No FighterProfile is needed.
5. **Payment verification boundary.** The only way to `active` is
   `SimpleFit.Billing.Activation.record/4`: a provider module listed in
   `config :simple_fit, SimpleFit.Billing, trusted_providers:` verifies a
   payload into a reference and a paid period; the evidence row
   (`billing_activation_evidence`, unique provider reference, append-only)
   and the period (`gym_saas_subscription_periods`) are written with the
   transition. The list is empty in every environment except test
   (`SimpleFit.BillingTestProvider`, in `test/support`). No HTTP endpoint
   activates; a `status`, `receipt` or payment field is `422`; a replayed
   reference is refused. A future provider adds a module and webhook
   verification without replacing the subscription domain.
6. **Entitlements.** `Entitlements.gym_feature/3` fails closed: entitled
   only through an `active` (or `cancellation_scheduled`) subscription with
   evidence, inside its paid period, whose plan version includes the key;
   otherwise `no_subscription | pending_activation | not_in_force |
   not_in_plan | unknown_feature`. **No endpoint gates on an entitlement**
   (`enforced: false`): every SF-83–SF-100 feature stays available to every
   gym until a rollout and grandfathering policy are approved. Booking needs
   no product (`class_admission/3` is `:not_required`); no admission is
   issued or debited.

### Model and invariants

Migration `20261106090000` (explicit up/down; 12 tables, 5 audit columns).
Composite foreign keys keep a price with its version and a subscription with
its gym, member, version and price. Triggers: published version content
immutable and transitions `draft → archived | published`, `archived →
draft`, `published → superseded | retired`, `superseded → retired`; plan
prices and entitlements written only on drafts, member prices only on draft
or published versions, never updated; a subscription is created only for a
published offer (SaaS: a `fixed` price; member: an active product and an
active member); identity fields fixed, `cancelled | expired` final, legal
transitions only; `active` and `cancellation_scheduled` require evidence and
a period; evidence and periods append-only; deletes only through the SF-95
purge switch, and a published plan version is never deleted.

### Writes and concurrency

Staff and owner writes use `Gyms.Guarded.write/6`: session `FOR SHARE` →
gym → staff membership (`Access.authorize_locked/3`) → product or
subscription `FOR UPDATE`; catalog publication locks the plan row; a member
intent holds the session, the gym `FOR SHARE` and the member row. Real
PostgreSQL race tests (committed transactions): 20 intents for one gym, one
key 20 times, publication of one draft and drafts of one plan, publication
while gyms subscribe, mixed concurrent cancellations, one evidence reference
for ten subscriptions, concurrent activation, untrusted activation replays,
entitlement reads against cancellation, ownership transfer against an
intent, 20 concurrent prices on one version, intents against retirement and
against leaving the gym. Rate limits per user: 30 billing changes, 60
catalog changes and 30 member intents per 10 minutes.

### API

Tag "SimpleFit plans": `listSaasPlans` (`GET /saas-plans`, published only),
`listGymSaasSubscriptions`, `requestGymSaasSubscription`,
`cancelGymSaasSubscription` (`/gyms/{gym_id}/saas-subscriptions…`),
`getGymEntitlements` (`GET /gyms/{gym_id}/entitlements`, any staff). Tag
"Gym member products": `listGymMemberProducts`, `createGymMemberProduct`,
`getGymMemberProduct`, `createGymMemberProductVersion`,
`publishGymMemberProductVersion`, `addGymMemberProductPrice`,
`retireGymMemberProduct`, `listGymMemberProductSubscriptions`;
`listMyGymProducts`, `requestMyGymProduct`, `listMyProductSubscriptions`,
`cancelMyProductSubscription`. All `no-store`. Errors `401`, `403`, `404`
(another gym's resource, never disclosed), `409`, `422`, `429`. No approval
reference, operator name, provider, evidence or payment field is rendered.

### Audit and telemetry

Gym audit events (ids only): `saas_subscription_requested | activated |
cancellation_scheduled | cancelled | expired`, `member_product_created |
version_created | version_published | price_created | retired`,
`member_product_subscription_requested | activated | cancellation_scheduled |
cancelled | expired`. Catalog events in `billing_audit_events`. Telemetry
`[:simple_fit, :billing, :catalog | :subscription]`,
`[:simple_fit, :gyms, :commerce]` and `[:simple_fit, :entitlements,
:evaluated]` carry the event, the outcome and (for entitlements) the
registered key only. Request logs filter `card`, `cvc`, `cvv`, `iban`,
`payment` and `receipt` parameters.

**Proposed, not implemented (FUTURE, D-G10/D-G11):** a payment provider and
its webhooks, checkout, invoices and tax, refunds and proration, renewals,
trials, class admission debit, entitlement enforcement and grandfathering,
member product purchase UI.

## Amendment — SF-102 (2026-11-03): Stripe payments for SimpleFit SaaS billing

### Decision and scope

Stripe is the payment provider (product decision in the SF-102 ticket): Stripe
Checkout (hosted) to collect, Stripe Billing for the gym's SaaS subscription,
the Stripe Customer Portal for payment methods and invoices, signed webhooks
for lifecycle, Stripe invoices as the billing history, and a Stripe Connect
**foundation** for future gym member payments. The SF-101 domain stays
provider-neutral and authoritative for gyms, plans, prices, lifecycle and
entitlements; Stripe is authoritative only for its own objects. No microservice,
broker or second database; no Stripe SDK (ADR 0004).

**Test mode only until a release approval.** Live mode is refused outside a
production build, needs `STRIPE_LIVE_APPROVAL`, and never sells a draft or
`provisional` price. Disabled or misconfigured means no checkout and no paid
state (never a substituted success). Commercial enforcement stays off
(`enforced: false`): no gym workspace is locked out.

### Two financial flows

* **SaaS billing** (payer: the gym; seller: SimpleFit): implemented.
* **Gym member payments** (payer: a member; seller: the gym, Direct Charges on
  its connected account as the candidate model): **disabled.** Only an
  operator-linked, test-mode connected account mapping and its synced
  capability summary exist (`stripe_connected_accounts`, `SimpleFit.Billing.Connect`).
  Nothing creates an account, onboarding link, charge, transfer or payout.
  Open decisions: merchant of record, account type and capabilities, country
  availability, legal seller, KYB/KYC, platform fees and currency,
  refund/dispute and negative-balance liability, tax responsibility, payouts,
  offboarding.

### Configuration (`SimpleFit.Billing.Stripe.Config`)

`STRIPE_BILLING_ENABLED`, `STRIPE_MODE` (`test`|`live`), `STRIPE_SECRET_KEY`
(`sk_`/`rk_` of the mode; a key of the other mode fails boot),
`STRIPE_WEBHOOK_SECRET` (`whsec_`), `STRIPE_ACCOUNT_ID`, `STRIPE_API_VERSION`
(default pinned **`2026-10-28.endive`**; preview versions refused),
`STRIPE_PORTAL_CONFIGURATION_ID`, `STRIPE_CONNECT_ENABLED`,
`STRIPE_LIVE_APPROVAL`. No publishable key is read; no secret reaches a
client. `SimpleFit.Billing.Stripe.Provider` is a trusted activation provider
only where the integration is configured.

API version notes (`2026-10-28.endive`): billing periods live on subscription
items (`items.data[].current_period_*`), an invoice names its subscription
under `parent.subscription_details.subscription`, invoice payments are
`invoice_payment` objects, Checkout's `payment_method_types` is gone and
`ui_mode` defaults to `hosted_page`.

### Model (migration `20261108090000`, explicit up/down)

`stripe_customers` (gym ↔ customer per mode, immutable), `stripe_prices`
(price version ↔ Stripe Price per mode with the amount, currency and interval
Stripe confirmed; immutable), `stripe_checkouts` (`creating | open |
completed | expired | failed`, idempotency key, one `creating`/`open` per
subscription), `stripe_subscriptions` (link, provider status, period,
`discrepancy` code), `stripe_invoices` (status, payment status, minor-unit
amounts, refunded amount, dispute flag, Stripe-hosted URLs), `stripe_refunds`
(operator or provider origin; one operator refund in flight per invoice),
`stripe_disputes`, `stripe_webhook_events` (inbox: ids and type, **never the
payload**), `stripe_connected_accounts`. Every row names its mode; provider ids
are unique per mode; mappings keep their mode and gym; financial rows are never
deleted (SF-95 purge switch excepted). Audit: gym events
`saas_checkout_started | saas_subscription_renewed |
saas_subscription_reactivated | saas_payment_failed | saas_refund_recorded |
saas_dispute_recorded` (ids only, `billing_record_id`); operator events
`stripe_price_mapped | stripe_refund_requested |
stripe_connected_account_linked`.

SF-101 amendments (explicit): the subscription guard allows
`cancellation_scheduled → active` (a cancellation withdrawn at the provider,
applied only from reconciled state); cancel reason `provider_initiated` (the
provider ended or scheduled the end outside SimpleFit); `advance/1` leaves a
subscription with a live Stripe link to reconciliation (entitlements still
lapse at the period end). Down migration restores both.

### Flows

* **Price mapping** (operator, `mix billing.stripe map-price`): Product + Price
  created idempotently per price version and mode, checked against Stripe's
  answer. Clients select internal plan/price versions; the backend resolves the
  Stripe Price and refuses `not_mapped`/`mismatch`.
* **Checkout** (`createGymSaasCheckoutSession`, owner only): gym write
  transaction (session held, gym and staff membership locked, subscription
  `FOR UPDATE`) validates the pending intent and its mapping, reuses an
  `open`/`creating` row or writes one with a fresh idempotency key; outside it
  the customer is created once (key per gym and mode) and the session with the
  row's key, so a lost answer retried returns the same session. A `creating`
  row past its window is `failed` (nobody holds its URL).
* **Return** (`reconcileGymSaasSubscription`): reads Stripe; a redirect is
  never proof of payment.
* **Webhooks** (`POST /api/webhooks/stripe`): signature over the exact raw
  body (`SimpleFitWeb.RawBody`, only this route keeps it), 300 s tolerance in
  both directions, configured mode, no Connect `account`; inbox row and Oban
  job in one transaction; duplicates change nothing; `2xx` only after commit,
  `503` when disabled or the inbox is unavailable. Handled types:
  `mix billing.stripe webhook-events`.
* **Reconciliation** (`SimpleFit.Billing.Reconciliation`): the only path from
  Stripe to SF-101. Every decision re-reads the object from the Stripe API, so
  event order and content never matter. Lock order gym `FOR SHARE` →
  subscription `FOR UPDATE` (as every gym write; locking the subscription first
  deadlocked against a cancellation in the race tests), Stripe fetched inside
  the lock. A link is created only from SimpleFit's own checkout row whose
  session (read from Stripe) is complete, names the subscription and the gym's
  customer; metadata never creates identity. Activation and renewal only from
  a `paid` invoice of the linked Stripe Subscription and customer, in the price
  version's currency and exact amount, with a current subscription-line period
  (`VerifiedInvoice` → evidence `<mode>:<invoice id>`, unique). Anything else
  records a `discrepancy` and grants nothing. SCA and failed payments stay
  pending (payment status read from the PaymentIntent); failed renewals are
  `past_due` with the paid period kept; Stripe's own retries are the recovery
  engine. Stripe ending it: `expired` (payment failed) or `cancelled`.
* **Sweep** (`SweepWorker`, hourly): live links not synced for 6 h, past their
  period or pending, and pending checkouts.
* **Cancellation** (`cancelGymSaasSubscription`): Stripe first (`immediate`:
  delete, no proration, no refund; `period_end`: `cancel_at_period_end`; a
  pending intent's checkout is expired; a completed one is `409 checkout:
  completed`), then SF-101. Stripe unreachable: nothing changes (`503`).
* **Portal** (`createGymBillingPortalSession`): short-lived, never stored; the
  configuration (`mix billing.stripe setup-portal`) enables payment method
  update, invoice history and billing details, **not** plan change or
  cancellation (SimpleFit owns both).
* **Refunds** (operator, `mix billing.stripe refund`, approval reference):
  full refunds only (partial: not approved), one per invoice under the invoice
  lock, idempotent at Stripe (a lost answer is retried with its key),
  reconciled from Stripe; refunds made at Stripe are recorded with their real
  amount. No gym staff can refund. **Disputes** are recorded as disputes, never
  as refunds. Neither revokes an entitlement by itself (no approved rule).
* **Invoices** (`listGymBillingInvoices`): Stripe's invoices as reconciled;
  SimpleFit renders no PDF and computes no tax; a draft or open invoice is never
  shown as paid.

### Tax and invoicing boundary

Stripe Tax is **not** enabled and no VAT rate is configured. Open questions
before any legally presented invoice: SimpleFit's seller entity and VAT
registration, B2B/B2C treatment and reverse charge, the gym's billing address
and tax id collection, Polish invoicing obligations (KSeF e-invoicing,
invoice numbering, correction invoices/credit notes), retention, and the
accounting export. The integration boundary for accounting is
`stripe_invoices` (ids, amounts, periods, statuses) and Stripe's own records.

### Security and observability

Secrets only in env and the `authorization` header; Stripe ids validated
before entering a URL; every answered object must carry the configured mode's
`livemode`; no card, bank, email, address or tax data is stored or rendered;
logs carry the provider, a status and a reason code only. Telemetry:
`[:simple_fit, :billing, :webhook]` (stage, outcome),
`[:simple_fit, :billing, :stripe_request]` (method, result) and the SF-101
subscription events.

### Verification

ExUnit against `SimpleFit.StripeFake` (a deterministic Req.Test fake of the
documented endpoints with idempotency semantics and fault injection) and real
PostgreSQL race tests (20 concurrent checkouts → one session, 20 concurrent
deliveries → one inbox row, 10 concurrent reconciliations → one activation,
10 concurrent refunds → one Stripe refund, cancellation racing renewal and
checkout completion). **Real Stripe test-mode journeys need test credentials
and were not verified in SF-102.**


## Amendment — SF-103 (2026-11-04): business verification, community defaults and go-live

### Scope and D-G11 reconciliation

D-G11 (business verification and public publishing) was deferred. The SF-103
ticket is the product decision for **its verification half only**: a gym's
owner submits a business-verification application with documents, and an
independently authorized SimpleFit operator decides it, with an immutable
history. **Publishing stays deferred:** SimpleFit has no approved public gym
surface (Discover, MarketGyms, a public gym page, E05) or publishing policy,
so nothing is published, no publication state is stored and no endpoint
requests or grants publication. Go-live readiness is derived and reported;
`publication.status` is always `unavailable`.

Five facts stay apart: gym setup (SF-85, unchanged), business verification
(SF-103), Stripe account capabilities (SF-102, unchanged), operational
readiness (derived by SF-103) and publication (not available). None implies
another: a completed setup, a paid SimpleFit plan, a Stripe `charges_enabled`
or `payouts_enabled` account and a ready checklist are each not a
verification, and a verification grants no Stripe capability, plan,
entitlement, staff right or publication.

### Operator authority (gap reported)

SimpleFit has **no platform operator identity or admin authorization domain**:
the designed admin console (AD0–AD20, scoped time-boxed access, second
approvers) has no backend, and no `User.role` exists or is added. Review
therefore follows the accepted operator pattern of SF-101/SF-102
(`mix billing.catalog`, `mix billing.stripe`): `mix gyms.verification`
(`SimpleFit.Gyms.VerificationReview`), with no HTTP route. Production shell
access is the authorization boundary until an admin domain exists. Guards
that hold whatever the shell user types: the operator is named by an email
address and must not match a verified email identity of the application's
creator, its submitter or an active staff member of the gym
(`operator: not_independent`); a decision names the revision reviewed; only
reviewed transitions exist; concurrent decisions serialize on the
application row. A mandatory two-person approval is **not** introduced (no
policy).

### Verification lifecycle (migration `20261110090000`, explicit up/down)

`gym_verification_applications`: the owner's business details (legal name,
registration country, optional registration number, registered address and
website), `status` and a `revision` bumped by every owner change, under a
versioned requirement policy. One current application per gym (partial
unique index on `draft | submitted | changes_requested | approved`).

    draft --submit--> submitted --operator--> approved --operator--> revoked
                        |    \--operator--> rejected
                        \--operator--> changes_requested --submit--> submitted

A trigger allows only these transitions, keeps the identity, never lets the
revision go back and freezes the content from submission on (only `draft`
and `changes_requested` are edited, only by the owner). Rejected and revoked
are final for that application; the owner starts a new one from nothing.
`gym_verification_events` is the append-only history (`submitted` by the
owner; `approved`, `rejected`, `changes_requested`, `revoked` and
`evidence_downloaded` by an operator), each with the application revision,
the documents it covered, a reason code where needed and a total order
(`seq`). Gym audit events gain `business_verification_*` types with
`verification_application_id` (no actor for operator decisions; the operator
is in the history). Nothing is deleted (the SF-95 purge switch of test
cleanup excepted).

**Requirement policy `sf103-generic-1`** (`SimpleFit.Gyms.VerificationPolicy`):
legal name, registration country and at least one confirmed document; the
rest optional. **No jurisdiction-specific requirement is approved** (KRS,
NIP, REGON, EU KYB, any other): a country gains required fields only by
reviewed configuration (`country_requirements`, none set). Reason codes are
the operator's vocabulary; the owner sees the code, never the operator or
free text.

**Owner** (`manage_business_verification`: owner only; managers are not
assumed to declare for the owner) reads, drafts, uploads, removes unsubmitted
documents and submits. **Go-live** (`view_go_live`: owner and managers) shows
only the verification status. No role holds an approval permission.

### Documents and storage

The SF-85 storage blocker is resolved for this use: `SimpleFit.Storage` gains
`stat/2` (a server-sent presigned `HEAD`: size and content type) and
`delete/2` (presigned `DELETE`), through `SimpleFit.HTTP`. A document is
announced (kind, base file name, `application/pdf | image/jpeg | image/png`,
exact size up to 10 MiB, at most 10 per application) and the server answers
with a 15-minute presigned upload to a key it built
(`gyms/<gym>/business-verification/<application>/<evidence>`); after the
client's direct upload, the server reads the object's size and type itself
and attaches it only if they match. No client key, URL or path is ever
accepted; the composite foreign key makes another gym's application
impossible; another application's document is `not_found`. Submitted
documents are frozen. Operators download through 5-minute links recorded in
the history; there is no public or owner download and no key leaves the
server. `SimpleFit.Gyms.VerificationCleanupWorker` (Oban cron, 30 min)
deletes the objects of uploads abandoned for a day and of documents removed
before submission. **Retention of submitted documents is not approved:**
nothing submitted is deleted. Logo and cover (SF-85) can reuse these
capabilities in their own ticket.

### Community defaults (OG13)

Every OG13/WG10 setting (community feed, challenges, coaches on a public
page, member visibility, discoverability, open sparring, shared sessions,
public leaderboard, member discovery) needs a domain that does not exist:
none has an enforcing consumer, so **nothing is persisted** and no endpoint
is added. The web page states the platform guarantees that hold regardless
(no gym role reads private training data, messages, coach notes or health
data; D-G06) and shows the settings as coming later. The one real enrollment
setting (auto-approval, SF-95) stays where it is.

### Go-live readiness (OG14)

`getGymGoLive` derives on every read, under policy `sf103-golive-1`:

| Check | Requiredness | Source |
| --- | --- | --- |
| `setup_completed` | required | gym setup |
| `primary_location` | required | gym setup |
| `business_verification` (`passed` only when approved; `pending` in review) | required | verification |
| `upcoming_class` (a scheduled future occurrence) | recommended | timetable |
| `staff` (an active non-owner staff membership; an invitation is not staff) | optional | staff |
| `members` (an active member; a request is not a member) | optional | members |
| `member_products` (a published product version) | optional | member products |
| `member_payments` (`blocked`: SF-102 decisions not approved; not required) | optional | payments |
| `public_profile`, `community_settings` (`unavailable`) | future | — |

`prerequisites_met` is true only when every required check passes, re-derived
each read (a revocation makes it false at once). Stripe test-mode or Connect
state, and SaaS subscription status, are not readiness facts.

### Revocation

`approved -> revoked` with a reason code. It changes nothing else: staff,
members, classes, bookings, attendance, subscriptions, Stripe mappings and
audit history stay; no refund; no Coach–Fighter relationship. Go-live reads
fail closed from the commit on.

### Unresolved (product and legal)

Jurisdiction-specific KYB requirements and legal grounds; retention of
verification documents; whether managers may submit for the owner;
two-person review; an operator identity and admin authorization domain (and
the admin review UI); the publishing policy and public gym surface (D-G11
public half, E05); community features and their privacy model; the
relationship between business verification and Stripe Connect KYB for
member payments (D-G10).

## Amendment — SF-104 (2026-11-04): release-acceptance hardening

* **Verification review is fail-closed.** SF-103's `mix gyms.verification`
  accepted any email address as the operator (only a conflict-of-interest
  check applied), so anyone with shell access could act as any operator.
  Every review call (list and show included) now needs an address on
  `GYM_VERIFICATION_OPERATORS`; without the list, review is disabled
  (`:review_disabled`), and an unlisted address is `{:forbidden, :operator}`.
  The list is an approval in deployment configuration, not an identity: a
  shell user can still claim another listed address. Production review stays
  disabled until a platform operator identity exists or that risk is accepted.
* See `docs/release/sf-104-gym-release-acceptance.md` for the release
  acceptance evidence and verdicts.

## Amendment — SF-133 (2026-11-04): the staff invitation recipient flow

SF-104 found (F-01, P1) that E06 links to a page that did not exist while
production sent E06. SF-133 builds the web page on the SF-93 domain and gates
sending. It adds no table, migration, role or `User.role`.

* **Delivery gate.** `config :simple_fit, SimpleFit.Gyms, staff_invitations:`
  is read at the point of sending. While it is off, creating or resending
  answers `409 staff_invitation: recipient_flow_unavailable`, after the policy
  check, with nothing created and no email queued. Production is off unless
  `GYM_STAFF_INVITATIONS=enabled`; dev and test are on. Answering invitations
  stays open while it is off, so links already issued keep working. E05, E07
  and coach invitations are not affected.
* **Activation order.** Backend compatibility, then the recipient page
  deployed, then a production smoke test, then sending enabled under explicit
  release approval.
* **`resolveStaffInvitation`** (`POST /api/v1/me/staff-invitations/resolve`,
  token in the body). `previewStaffInvitation` deliberately answers 410 for
  every non-pending invitation, so a page could not tell its own recipient
  what happened. This operation answers the recipient view in any status when
  the token's recipient digest is one of the viewer's verified email
  addresses. Otherwise it answers 403 while the invitation is pending and 410
  once it isn't, which is what accepting would answer, and an unknown token is
  410. It reads and changes nothing, so it adds no new oracle for anyone but the
  recipient.
* **Token transport is unchanged.** The fragment contract stays, and issued
  links keep working.

### Deviations and gaps

1. No web recipient artboard exists (`D-WEB-STAFF-INVITATION`, in the route
   registry, needs a product decision): an interim composition of WFI1 with the
   OS1 and OS1b content.
2. The web keeps the token in the tab's `sessionStorage`, as the SF-60 coach
   flow does, so it survives sign-up. The client's rules are in
   `simplefit-platform/docs/gym-console-web.md`.
3. Google and Apple continuation were not exercised with real providers: no
   credentials exist here.

## Amendment — SF-134 (2026-11-05): the member join and invitation recipient flow

SF-104 found (F-02, P1) that no client lets a person join a gym by code or accept
a member invitation. SF-134 builds the web pages on the SF-95 domain. It adds no
table, migration, status or role, and closes deviation 4 of SF-95 for the web.

* **`resolveGymInvitation`** (`POST /api/v1/me/gym-invitations/resolve`, token in
  the body), the same gap and answer as `resolveStaffInvitation` (SF-133):
  `previewGymInvitation` deliberately answers 410 for every non-pending
  invitation, so the page could not tell its recipient what happened. It answers
  the recipient view in any status when the token's recipient digest is one of the
  viewer's verified addresses; otherwise 403 while pending and 410 afterwards, as
  accepting would. It reads and changes nothing.
* **Delivery gate unchanged.** `GYM_MEMBER_INVITATIONS` stays off in production
  and SF-134 does not touch it. Activation order: compatible backend, then the
  recipient page deployed, then the production URL and token transport verified,
  then a production-safe smoke test, then sending enabled under explicit release
  approval. The staff gate of SF-133 is separate.
* **Token transport unchanged.** The fragment contract stays.
* **Race tests added.** Acceptance vs the gym's cancellation, acceptance vs the
  recipient's decline, and joining again vs the approval of the same request.

### Deviations and gaps

1. No web artboard exists for join by code, the E07 page or the member inbox, and
   A03's QR, six letters, role and group have no contract
   (`D-WEB-GYM-MEMBER-JOIN`, needs a product decision).
2. E07's approved copy comes from the template; Claude Design's E07 board still
   shows the older "claim your membership" content.
3. Mobile screens are SF-135. The mobile `/join/:code` route stays a placeholder.
4. Google and Apple continuation were not exercised with real providers.

## Amendment — SF-136 (2026-11-06): trusted review authority, fail-closed in production

SF-104 F-03 found that `mix gyms.verification` took the operator from an argument.
The allowlist it added narrowed that but didn't fix it: anyone able to run the task
could type another listed address and be recorded as that person.

### Trust boundary before SF-136

| Step | What happened |
| --- | --- |
| Who invokes | Anyone able to run `mix` with the deployment's configuration |
| How they are authenticated | Not at all |
| How the actor is bound | The `--operator` argument |
| How it is authorized | That argument is on `GYM_VERIFICATION_OPERATORS` |
| What changes | An application's status, under the row lock and database guards |
| What is audited | The typed address, as if it identified someone |

The privileged paths were all the public functions of `VerificationReview`:
`list_submitted`, `show`, `evidence_download` (a working link to a business document),
`decide` (approve, request changes, reject) and `revoke`. Each is reachable only from
that task; no HTTP route, job or other module calls them.

### Decision: no authority exists, so production has none

SimpleFit has no operator table, grant model, workload identity or signing authority,
and building one is SF-110. A `Session` proves a user, not an operator. So production
review is **disabled**, which SF-136 allows and prefers to a weaker substitute.

* `SimpleFit.Gyms.VerificationAuthority` is the only door. Its backend is chosen at
  **compile time**: the default is `Disabled`, a production build refuses any other at
  compile time, and `Local`, the fixture for tests and development, isn't compiled into
  a production build. No environment variable or runtime setting can enable review.
  `GYM_VERIFICATION_OPERATORS` is gone; if still set it does nothing.
* `VerificationReview` takes a **credential**, never an operator. Every public function,
  reads included, asks the authority for that action's own permission (`read_queue`,
  `read_application`, `read_evidence`, `approve`, `request_changes`, `reject`, `revoke`).
  An address, an actor id or a hand-built `OperatorPrincipal` is not a credential.
* `mix gyms.verification` has no operator flag, and any unknown option is refused. In a
  production build it refuses before starting the application.
* Owners keep drafting and submitting. **In production, a submitted application waits:**
  no one can decide it until SF-110, so go-live stays unmet.

### Attribution

Migration `20261112090000` adds `operator_actor_id`, `operator_authority` and
`operation_id` to `gym_verification_events`.

* A new operator row must carry all three and no address. The constraint
  `gym_verification_events_trusted_actor` is deliberately `NOT VALID`: it binds new rows
  and leaves history alone, and **must never be validated**.
* Existing rows are not rewritten. An `operator` address with no authority is legacy,
  unverified attribution: `VerificationEvent.attribution/1` and the task say so.
* `operator_authority` allows only `local_fixture` today, which is not a trusted operator.
  A real authority needs a new value in a reviewed migration.
* The decision, its history row and its audit event are in one transaction.
* Rollback of this migration is refused once a row has new attribution: those rows can't
  be expressed in the old shape, and history isn't rewritten to allow it.

### Conflict of interest and revocation

* An operator may not read or decide an application if their user is its creator or
  submitter, the gym's creator, active staff, or a current member (or requester). This is
  checked by **user id**, with the gym row locked, so a staff change commits either before
  the check or after the decision. Staff and member rights never grant operator rights.
* The authority is asked on every call and again once the locks are held, with no cache,
  so a call that waited on a lock can't act on an old answer. A decision that passed that
  second check before the revocation took effect stands and stays in the history.

### Limits of this control

* Anyone with production shell or database credentials can change rows directly. No check
  inside the application stops that; it needs infrastructure access control and database
  roles, which don't exist here yet.
* `mix billing.catalog` and `mix billing.stripe` still take `--operator NAME`, the same
  pattern. They aren't in SF-136's scope and should be reviewed.

### Enabling production review (SF-110)

SF-110 must first provide an authority that verifies a credential cryptographically or
through an independent identity provider, enrolls and revokes operators independently of
the reviewer, answers for current grants on every call under a documented lock, and
returns an immutable actor id and user id. Then, in a reviewed change: implement the
`VerificationAuthority` behaviour; add its `operator_authority` value; replace the
production compile guard to allow exactly that backend; delete `Local` from any path a
production build could reach; and run the security suite against it. **There is no
interim switch, and none should be added.** Decisions that need making before then have
no supported path.

### Audit and incident notes

Refusals emit `[:simple_fit, :gyms, :verification, :review_refused]` with the reason only.
Any production `gym_verification_events` row with `operator` set dates from before this
change and proves nothing about who acted: treat such approvals as unverified in an
incident. Check for them before relying on an `approved` status from that period.

