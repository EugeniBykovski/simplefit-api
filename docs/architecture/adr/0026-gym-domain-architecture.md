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
