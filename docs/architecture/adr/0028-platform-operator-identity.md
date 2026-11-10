# ADR 0028 — Platform operator identity, founder bootstrap, RBAC and strong authentication

* Status: **Accepted for implementation in non-production environments** (SF-110, 2026-11-09). Epic SF-106.
  **Amended by [ADR 0029](0029-admin-action-framework.md) (SF-111):** grant, permission revocation,
  suspend, reinstate and revoke now run as declared admin actions with `expected_revision`, catalogued
  reason codes and (except permission revocation) a one-time confirmation from their preview.
  **Production bootstrap is BLOCKED**: no approved signing authority exists (D-SA13), so a production build
  trusts no ceremony key and `mix operators.ceremony` refuses with `unavailable`.
* Context: ADR 0009 (one global user), 0010 (sessions), 0016 (registration), 0026 (gyms; SF-136 operator
  review stays on its own fixture authority), **0027 (proposed Sponsor and operator architecture; this ADR
  implements its operator half only)**, [platform-operator-trust.md](../platform-operator-trust.md),
  [sponsor-admin-permissions.md](../sponsor-admin-permissions.md).

## Problem

SF-136 and SF-138 refused privileged actions in production because there was no operator identity: nothing
could say who may act on the platform, prove it was them, or leave evidence. ADR 0027 proposed the model.
A shell username, an email string or an `ADMIN_EMAIL` superuser are not acceptable stand-ins.

## Decision

1. **`SimpleFit.Operators` context.** A `platform_operators` row is bound to one global `users.id`, never
   to an email. No column on `users`; no role or type on the user. A user has at most one non-revoked
   operator. Lifecycle `pending_enrollment → active ⇄ suspended → revoked` (revoked is final); PostgreSQL
   triggers enforce the transitions, the immutable origin and that operators are never deleted.
2. **Founder bootstrap is an out-of-band signed ceremony.** An Ed25519 statement names the user id, the
   permissions, the environment, a validity window (at most 24 h) and a ceremony id; `mix operators.ceremony`
   verifies it against a trusted key, checks the environment and window, and consumes it under an advisory
   lock: the statement digest is unique (replay-safe), and a bootstrap succeeds only while no operator has
   ever existed. The user must have completed registration. Production trusts keys only from compile-time
   configuration, and none are configured. Development uses a local key written by
   `mix operators.dev_ceremony` (outside Git, `.operator-dev/`), recorded as `local_development_ceremony`,
   never as a signed production ceremony. The test suite uses throwaway keys.
3. **Strong authentication is WebAuthn security keys** (`wax_`, ADR 0004). Attestation `none`, user
   verification required, backup-eligible (syncable passkey) credentials refused, signature counters must
   advance, challenges are server-side, single-use and bound to the session that requested them. An
   operator needs **two** keys before it becomes active (a production build refuses fewer).
4. **Step-up is bound to the session.** A key check creates a step-up for this session only, valid for
   30 minutes; `operators.manage` writes need one less than 5 minutes old. Signing out, revoking the
   session, suspension, revocation and credential revocation end it.
5. **Least-privilege RBAC, default deny.** Three explicit permissions: `operators.read`,
   `operators.manage`, `audit.read`. No wildcard, no role bundles, no implied permissions. No operator can
   grant to or change itself (refused, and a database CHECK). One active grant per permission; grants are
   revoked, never deleted.
6. **Concealment.** A user without a usable operator gets the same `404 not_found` on every
   `/api/v1/admin` path, before parameters are validated. `enrollment_required` and `step_up_required` are
   shown only to an operator.
7. **Writes are serialized and idempotent.** Each write holds the caller's session, locks the operator rows
   it touches in id order, re-authorizes inside the transaction, and records an `operation_id`.
8. **Append-only audit.** Every allowed change and every refusal is recorded with the actor operator and
   user, the authority (`platform_operator`, `signed_ceremony`, `local_development_ceremony`), the reason
   code, request and session. Audit, ceremony and operation rows can't be updated or deleted by the
   application (triggers). The migration's `down` refuses once any history exists.
9. **Recovery foundation.** A signed `recovery` ceremony may reset the last remaining manager to
   `pending_enrollment`, revoking its keys and step-ups. It never creates a second operator.
10. **API.** `/api/v1/admin` (tag "Platform operators"): self-service (`me`, credentials, step-up) and
    administration (operators, permissions, suspend, reinstate, revoke, credential revocation, audit
    events). New error codes `step_up_required`, `enrollment_required`, `security_key_rejected`. Additive;
    clients regenerated in platform and mobile. No UI.

## Not done here

* SF-136 gym verification keeps its own local fixture authority and stays disabled in production. Moving
  it onto operators needs its own approved ticket.
* No Sponsor domain, no admin UI, no TOTP or IdP, no two-person rule (D-SA17), no user restriction
  (D-SA29), no audit export or retention job (D-SA18).

## Decisions still open (ADR 0027, decision register)

Implemented **as proposed, not approved**: D-SA13 (ceremony), D-SA15 (WebAuthn keys first), D-SA16
(permission names; only the three above exist). They remain PROPOSED until the founder and a security
reviewer approve them.

Still open and **not decided by this ticket**: D-SA13's production signing authority (who holds the key,
where it's stored, the witness), **BLOCKED**; D-SA14 second operator (no one named), **BLOCKED**; D-SA17
two-person rule; D-SA18 audit retention (NEEDS DECISION, counsel); D-SA20 sensitive record access; D-SA25
admin first-run; D-SA28 production database roles and shell access (NEEDS DECISION); D-SA29 user
restriction (NEEDS DECISION).

## Trust boundary

The application can't stop someone with direct database superuser access or the release shell: they could
insert rows or disable triggers. The triggers stop application bugs and ordinary roles, not a superuser.
D-SA28 covers that. Simulated authenticators in tests and the local E2E run are software ES256 keys and are
**not** evidence of hardware-key behaviour; no real hardware key was exercised in SF-110.

## Consequences

* Production has no operator until the D-SA13 authority exists and its public key is compiled in.
* The two-key minimum means a founder must own two security keys before any administration.
* New permissions need a migration (catalog CHECK) and an ADR update.

## Amendment (SF-120)

* The web Control Plane entry (simplefit-platform SF-120) reads `GET /api/v1/admin/me` and runs the registration and
  step-up ceremonies; it adds no endpoint and changes no rule. Its first visit (ARW1) is the ADR 0018 experience
  `control_plane_web_tour`, offered to active operators only; it grants nothing.
* **Development only:** `config/dev.exs` reads `SIMPLEFIT_DEV_WEBAUTHN_ORIGIN` (default `http://localhost:3000`) so a
  browser E2E on another port can run the real ceremonies; `rp_id` stays `localhost`. Production configuration is
  unchanged (`WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN` in `runtime.exs`), and production bootstrap stays BLOCKED (D-SA13).

## Amendment (SF-121)

* Two permissions join the catalog (migration `20261128090000_add_overview_permissions`), as SF-107 proposed them
  (D-SA16, proposed naming): `platform.dashboard.read` (overview counts, no names) and `system.health.read` (health
  check results and job counts, no payloads), both at a current key check (`:key`). Nothing is granted by the
  migration; rollback refuses once either was granted.
* `GET /api/v1/admin/overview` (`getAdminOverview`) is the overview read. Its sections each follow their own
  permission and are `restricted` without it; at least one of the overview's permissions is needed. Counts only, so a
  successful read isn't audited per load (SF-107); refusals are. The metric definitions are in
  [admin-overview-metrics.md](../admin-overview-metrics.md).
