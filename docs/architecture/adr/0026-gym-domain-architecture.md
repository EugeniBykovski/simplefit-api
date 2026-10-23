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
