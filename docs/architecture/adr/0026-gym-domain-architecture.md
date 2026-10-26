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

### Deviations from the SF-82 package

1. **Lifecycle names.** The SF-83 brief says "draft and active". The approved
   vocabulary `draft` / `completed` is used.
2. **Naming.** The brief's "GymWorkspaceMembership" is
   `gym_staff_memberships` / `SimpleFit.Gyms.StaffMembership`, as in ADR 0026.
3. **First location.** SF-82 (`01` §4.1, `11`) had creation insert the
   first location. The SF-83 brief gives the location API to SF-85, so
   creation takes only `name` and `gym_type`. A draft may have no location;
   the "at least one location" rule becomes a completion check for SF-85.
4. **Ticket mapping.** The SF-83 brief gives entry resolution to SF-84, setup
   and location APIs to SF-85, participant memberships to SF-95 and classes to
   SF-97. That supersedes the proposed mapping in
   `proposals/SF-82-gym/09-dependency-matrix.md`.
5. **Fixed windows.** The brief asked for rolling 24 hours. The existing
   `SimpleFit.RateLimit` uses fixed windows aligned to UTC, and the brief said
   to reuse it rather than build a new subsystem.
6. **What counts toward the limit.** Only requests that pass validation and
   are neither replays nor resumed drafts count, and a count commits only with
   the gym it allowed. Invalid requests create nothing and consume no
   allowance.
7. **Client key behind proxies.** With unconfigured proxies
   (`TRUSTED_PROXY_HOPS` = 0 behind a proxy), all clients share one key.
   The 20-per-client limit then becomes global, as it already is for
   coach invitations. The per-user limit is unaffected.
8. **Transfer is a domain function only.** There is no HTTP operation and no
   request/acceptance step (D-G04's 7-day acceptance is SF-100's).
9. **Drafts cannot be transferred.** Transfer is limited to completed gyms;
   a draft answers `conflict`, `setup_status: draft`. This is a new rule: a
   draft has no other staff (D-G20) and holds the creator's single draft slot.
10. **Revocation is a domain function only.** Its HTTP operation comes with
    staff management.
11. **No HTTP 403 yet.** Every SF-83 HTTP operation is allowed to every staff
    role, so 403 is exercised at the domain level; the error contract already
    exists.
12. **Deferred columns.** `phone`, `website`, `handle`, `home_location_id`,
    `display_title` and `completed_at` arrive with the tickets that use them.
13. **Entry projection.** `GYM_WORKSPACE` and the remembered last gym are
    SF-84's.
14. **Account deletion.** It has a read-only guard
    (`Gyms.check_account_deletion/1`) plus the database refusal. The release
    step (delete the user's drafts, end other memberships with
    `account_deleted`) waits for the account-deletion feature.
