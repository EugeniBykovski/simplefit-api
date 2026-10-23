# ADR 0026 — Gym domain architecture

* Status: **Proposed** (SF-82, 2026-10-23). Epic SF-81 Gym & Club
  Management. Awaiting approval; nothing is implemented.
* Context: ADR 0009 (one global user), 0016 (account registration), 0017
  (entry resolution), 0018 (first run), 0021 (Coach–Fighter relationships),
  0023 (training sessions), 0025 (local development coaching mode), SF-49 §9
  (Gym boundary), the platform route architecture and registry.
* Detail: [`proposals/SF-82-gym/`](../proposals/SF-82-gym/README.md).

## Problem

Claude Design contains about 116 Gym-related screens (owner setup, staff
onboarding, web console, mobile cockpit, member side, commerce) and the route
registry has 53 Gym placeholders, but the backend has no Gym domain. Without
one model, tickets SF-83–SF-104 would invent tenancy, roles and data access
screen by screen, and the design's commercial screens (plans, trials,
payments, payouts) would invite fabricated data.

## Decision

1. **Tenant.** A new context `SimpleFit.Gyms` owns `gyms` (the tenant) and
   address-only `gym_locations`. No `gym_id`, role or type on `users`, and no
   generic workspaces table (`D-G01`, `D-G02`).
2. **Staff.** `gym_staff_memberships` with fixed roles `owner`, `manager`,
   `coach`, `front_desk`; exactly one active owner; transfer instead of
   co-ownership. Authorization is one `Gyms.Policy` matrix in code
   (`D-G03`, `D-G04`).
3. **Members.** `gym_members` need only a completed account, no
   FighterProfile. Join by email invitation or join code; no CSV import
   (`D-G07`, `D-G08`).
4. **Boundary with coaching.** No gym fact creates, implies or widens a
   Coach–Fighter relationship. No gym role reads members' training data
   (`D-G06`).
5. **Scheduling.** Group classes are `gym_classes` + materialized
   `gym_class_occurrences` + `gym_bookings` + `gym_check_ins`, not ADR 0023
   training sessions. ADR 0023's time rules move into a shared
   `SimpleFit.Scheduling` module (`D-G14`).
6. **Workspace selection.** Gym APIs are path-scoped
   (`/api/v1/gyms/{gym_id}/…`). The client holds the active gym and the
   server remembers the last choice. UI URLs stay id-free (`D-G15`).
7. **Errors.** 404 for non-staff, cross-gym and revoked access; 403
   `forbidden` for staff whose role lacks the permission.
8. **Creation.** Any registered user may create a gym and becomes its owner.
   The gym is persisted at the first setup step as a draft. Limits are 1 draft
   and 3 owned gyms, with `client_request_id` idempotency (`D-G05`).
9. **Commerce.** Enrollment, bookings and attendance carry no money. Plans,
   trials, payments, payouts and verification are **blocked** on separate
   decisions (`D-G09`, `D-G10`, `D-G11`). No mock payment grants an
   entitlement. ADR 0025's bypass is not extended to Gyms (`D-G17`).

## Consequences

* The Claude Design owner setup shrinks from 14 steps to OG1→OG2→(OG3)→done.
  Several screens need revised copy (R1–R11 in the inventory); the design is
  not changed without approval.
* The route-architecture wording on the active workspace, the `FIGHTER`
  guard on member routes and the INV2 route need registry/doc changes in
  their tickets (`D-G15`, `D-G07`, `D-G16`).
* The OpenAPI artifact and the registry are unchanged by this ADR. Proposed
  endpoints are in the package's contract matrix.

## Alternatives considered

The rejected alternatives are listed per decision in the package's
[decision register](../proposals/SF-82-gym/10-decision-register.md). They
include:

* a polymorphic workspace table;
* the active gym stored in the backend session;
* classes built as training sessions;
* custom roles;
* co-owners;
* FighterProfile-gated membership.
