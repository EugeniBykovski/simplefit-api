# ADR 0026 — Gym domain architecture

* Status: **Proposed — approved in principle** (SF-82, 2026-10-23). Epic
  SF-81 Gym & Club Management. Nothing is implemented, and SF-83 is not
  authorized yet.
  * **Approved:** `D-G04`, `D-G05` (draft creation, idempotency, resume),
    `D-G07`, `D-G14`, `D-G15` and `D-G16`.
  * **Deferred product decisions** (not engineering facts): `D-G09`
    (pricing, SaaS subscriptions, trials, billing), `D-G10` (payment
    provider and architecture) and `D-G11` (business verification and
    publishing).
  * **Open:** the rest of the register, including draft retention (`D-G20`)
    and the onboarding step redistribution (`D-G21`).
* Context: ADR 0009 (one global user), 0016 (account registration), 0017
  (entry resolution), 0018 (first run), 0021 (Coach–Fighter relationships),
  0023 (training sessions), 0025 (local development coaching mode, SF-105), SF-49 §9
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
   server remembers the last choice (`D-G15`). Console UI URLs stay id-free
   for now (`D-G23`, open).
7. **Errors.** 404 for non-staff, cross-gym and revoked access; 403
   `forbidden` for staff whose role lacks the permission.
8. **Creation.** Any registered user may create a gym and becomes its owner.
   The gym is persisted as a draft at the first valid submission, with
   `client_request_id` idempotency and resume (`D-G05`). The limits
   (`D-G25`) and draft retention (`D-G20`) are open.
9. **Commerce.** Enrollment, bookings and attendance carry no money. Plans,
   trials, payments, payouts, verification and publishing are **deferred
   product decisions** (`D-G09`, `D-G10`, `D-G11`). No mock payment grants an
   entitlement. ADR 0025's bypass is not extended to Gyms (`D-G17`).

## Consequences

* The 14 designed setup steps stay as a product journey. Only OG1 and OG2
  are required to create a gym; unavailable steps are "coming later"
  (`D-G21`, open). Several screens need revised copy (R1–R11, C1–C17). The
  design is not changed without approval.
* The route-architecture wording on the active workspace, the `FIGHTER`
  guard on member routes and the INV2 route need registry/doc changes in
  their tickets (`D-G15`, `D-G07`, `D-G16`/`D-G22`). The SF-57/SF-80
  `/invite/coach` link and its security are unchanged.
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
