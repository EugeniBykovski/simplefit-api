# ADR 0030 — Sponsor organizations, workspace memberships and entry resolution

* Status: **Accepted for implementation in non-production environments** (SF-112, 2026-11-09). Epic SF-106.
  Implements the organization and membership part of the **proposed** [ADR 0027](0027-sponsor-and-platform-operator-architecture.md)
  (task S2's foundation and S3's API rules). **No production path creates an organization**: approval (S1/S6)
  doesn't exist, and the only working authority is a local fixture that a production build refuses.
* Context: ADR 0009 (one global user), 0016 (registration), 0017 (entry), 0026 (gyms, D-G01, D-G23),
  0027 and the SF-107 package ([identity](../sponsor-admin-identity.md), [ERD](../sponsor-admin-erd.md),
  [permissions](../sponsor-admin-permissions.md), [API matrix](../sponsor-admin-api-matrix.md),
  [decision register](../sponsor-admin-decision-register.md)), 0028 and 0029 (operators).

## Decision

1. **`SimpleFit.Sponsors` context**, its own tables (no generic workspace table, D-G01):
   * `sponsor_organizations`: legal and display name, country, optional https website, status `active` /
     `suspended` / `closed` (terminal), `provisioning_source` (`sponsor_application` with a unique
     `source_application_id`, or `local_fixture` without one), a unique `provisioning_key`, a trigger-raised
     `revision`. Never deleted. No verification, plan, contract or other commercial column.
   * `sponsor_workspace_memberships`: user × organization, role `owner` / `manager` / `member`, status
     `active` / `suspended` / `revoked` (terminal; the ERD's `ended` is `revoked` with a reason code). One
     non-revoked membership per user and organization; at most one non-revoked owner; **exactly one active
     owner** in every organization that isn't closed, checked by a deferred constraint trigger at commit.
     Organization, user and role immutable; never deleted.
   * `sponsor_contacts`: business contacts (one `primary`, optional `additional`): name, optional job title,
     normalized email, optional E.164 phone. **No user id**: a contact isn't an account or a member, its email
     matches nothing and grants nothing.
   * `sponsor_organization_events`: append-only business history (provisioning, membership and status changes,
     with authority, actor, subject, role, from/to state, reason code). Separate from `operator_audit_events`:
     this is the organization's own record, which a later task may show its owner; operator audit stays
     platform-internal with its own access policy.
2. **No public creation.** `SimpleFit.Sponsors.Provisioning` is the only writer, and no endpoint calls it.
   Every function takes an `Authority` only that module constructs:
   * `application_authority(application_id)` returns `{:error, :unavailable}` until the Sponsor Application
     domain exists. **Interface for S1/S6:** inside the approval transaction, call
     `provision_organization(authority, %{provisioning_key, legal_name, display_name, country_code, website,
     owner_user_id: applicant, contacts: [...]})`; the organization, its owner membership, contacts and history
     commit with the approval or not at all, and `source_application_id` is unique (one organization per
     application). The application table's foreign key and the deferred "approved has exactly one
     organization" check arrive with that task.
   * `local_fixture_authority()` exists only where `config :simple_fit, SimpleFit.Sponsors.Provisioning,
     local_fixture: true` (dev and test); `Mix.env() == :prod` with it set refuses to compile. Its rows say
     `local_fixture`, which is never trust (SF-136). `mix sponsors.fixture` drives it in `dev` only.
   * Provisioning is idempotent by `provisioning_key` (same request: same organization; other request:
     `conflict`). Owners need completed account registration. Members are added only by explicit user id
     (`manager` or `member`, never `owner`), never from an email, contact or link.
3. **Authorization.** Every organization route names `{sponsor_id}` and is authorized against the viewer's
   **active** membership of that organization, read on every call, while the organization isn't closed (a
   suspended one is read-only). Anyone else, including revoked or suspended members, other organizations'
   members, gym owners, applicants and operators, gets `404 not_found`; a member whose role lacks the
   permission gets `403 forbidden`. Roles follow the SF-107 matrix as a fixed `Sponsors.Policy`: SF-112
   implements only reads (`view_organization`, `view_members` for all roles; `view_contacts` for owner and
   manager). Member lists show the short account name only.
4. **Entry (SF-45 / ADR 0017, amended).** Additive: destination `sponsor_home` with `sponsor_id`, reasons
   `sponsor_workspace_active` and `sponsor_choice_required`, capability `SPONSOR_WORKSPACE`, context `sponsor`
   with `sponsor_id` (resolve and `chooseMyEntryContext`), `sponsor_workspaces` (≤25) and
   `sponsor_workspace_count`. A sponsor workspace is an active membership of an **active** organization.
   * Account registration stays first (rule 1).
   * `intent=sponsor`: none → `sponsor_application` (begin; nothing created, **no application state inferred**:
     `sponsor_application_draft` / `_status` wait for S1); one → `sponsor_home`; several → the remembered one
     while valid, else `context_selection`. No circular gate: the application route needs no sponsor capability.
   * `context=sponsor&sponsor_id=` opens that home only for a valid workspace; anything else is ignored.
   * Without intent, sponsor workspaces count among completed contexts (one → its home; several → last choice
     or `context_selection`).
   * The remembered choice is written under a `FOR SHARE` lock of organization and membership, and re-validated
     on every read. `ADMIN` is never projected.
5. **Route registry unchanged.** `sponsor_home` has no client route until D-SA26 (id-based sponsor URLs) is
   decided; clients treat an unknown destination as a controlled failure, never a guess. No production user
   can reach it, since no production organization can exist.

## Decisions taken here, and not

| Decision | SF-112 |
| --- | --- |
| No role/type on users; no context grants another; intent grants nothing | Implemented (ADR 0009, 0027 invariants) |
| Approval creates organization + owner (D-SA10) | Interface only; no approval path |
| One owner, transfer needs acceptance (D-SA07) | One-owner invariant enforced; **no transfer, owner can't be suspended or revoked** |
| Brand/legal edits (D-SA08) | **Not exposed** |
| Invitations, multi-organization (D-SA12) | Multi-organization supported; **invitations not built** (no recipient page, template or approved policy; no links can exist) |
| Member removal, role change, leave | **Not exposed**; internal provisioning only |
| Reapplication (D-SA03) | N/A until S1 |
| Workspace URLs (D-SA26) | Registry untouched |
| Retention, deletion of a member's or owner's account | Open; users are `ON DELETE RESTRICT` from memberships |

## Trust boundary

Triggers and constraints bind the application's database role, not a superuser or the release shell (D-SA28).
`local_fixture` rows can exist only in development and test databases.

## Consequences

* S1/S6 call `provision_organization/3` with the application authority in the approval transaction, and add the
  foreign key and the approved-has-one-organization check.
* S9 (members, invitations) builds on memberships and history without schema changes to them, except a
  role-change/transfer path that the role-immutability trigger will need relaxed by a reviewed migration.
* Operator administration of organizations (A11) runs through the SF-111 action framework, not this boundary.
