# ADR 0027 — Sponsor and platform operator architecture

* Status: **Proposed** (SF-107, 2026-11-07). Epic SF-106. **Not approved.** The operator half was
  implemented outside production by SF-110 ([ADR 0028](0028-platform-operator-identity.md)); production
  bootstrap is BLOCKED. The Sponsor half isn't implemented.
* Context: ADR 0009 (one global user), 0010 (sessions), 0016 (registration), 0017 (entry), 0018 (first
  run), 0021 and 0024 (invitations bound to verified email), 0026 (gyms; SF-136 and SF-138 amendments),
  SF-139 (gym publication proposal), the route registry.
* Detail: [overview](../sponsor-admin-overview.md) and the documents it lists.

## Problem

The design has about 80 Sponsor and Admin boards, and the registry has 51 routes for them. No Sponsor
domain or operator identity exists. SF-136 and SF-138 refused privileged actions in production until
one does. Without one model, later tickets would invent authority screen by screen. The boards also
contain things that must not be copied: an application route only an approved sponsor can reach,
approval merged with a CRM stage, operators editing what applicants submitted, and invented figures.

## Decision

1. **One global user.** No `User.role` or `User.type`, no column on `users`, no separate Sponsor or Admin
   user or authentication. Authentication is global, and authorization is contextual.
2. **No context grants another.** Registration intent, a profile, a gym role, a sponsor application or
   membership never gives operator authority, and operator authority gives no membership.
3. **Sponsor domain, `SimpleFit.Sponsors`.** `sponsor_applications` (with immutable revisions),
   `sponsor_organizations`, `sponsor_workspace_memberships` (fixed roles `owner`, `manager`, `member`,
   one active owner), `sponsor_invitations`. No generic workspace table (D-G01).
4. **Application lifecycle.** `draft`, `submitted`, `under_review`, `changes_requested`, `approved`,
   `rejected`, `withdrawn`; PostgreSQL enforces transitions. Only an operator can approve. No automatic
   approval on any input. Answers are immutable once submitted.
5. **Approval is narrow.** One transaction creates an active organization and the applicant's owner
   membership. It gives no contract, verification, plan, entitlement, placement or public listing.
6. **Operator domain, `SimpleFit.Operators`.** `platform_operators`, `operator_credentials`,
   `operator_step_ups`, `operator_permission_assignments`, `operator_audit_events`. Explicit per-action
   permissions in a table, with no JSON blob and no superuser flag. Each request needs a valid session, an active
   operator, a current key check bound to that session, and an active grant, read fresh, with no cache.
7. **Authentication.** WebAuthn hardware keys, two per operator. An identity provider can come later
   behind the same interface. Implements the SF-136 authority contract; `VerificationAuthority` gets a
   real backend only in a separately reviewed change.
8. **Founder bootstrap is a one-time ceremony:** a reviewed public key, an offline-signed statement
   naming a `user_id`, a release command with no identity argument, the person's own key enrollment,
   explicit permission rows, a database limit of one bootstrap row, and removal of the code afterwards.
   Never the first user, an email, an environment variable, a CLI argument or a seed.
9. **Least privilege in data.** No endpoint exists for private coaching, health, message or gym member
   data. Admin search is exact, email masked. Reads of non-public data are audited with a reason.
10. **Separate processes stay separate.** Sponsor review, activation, verification and contract; operator
    authorization; gym verification; gym publication. They may share UI parts and audit storage, and
    must not share an authorization check.
11. **Entry reads real Sponsor state, and never mentions operators.** `ADMIN` isn't in `/me/entry`.
12. **Routing.** Applicants reach status without a workspace. Sponsor workspace paths carry `:sponsorId`.
    Web only, plus a mobile handoff. Non-operators get a 404 on all of `/admin`.
13. **Commercial layer is separate and FUTURE.** Campaigns, invoices, analytics and contracts aren't part
    of approval or workspace access. No invented opportunity, reach or revenue figure.

## Alternatives rejected

| Alternative | Why not |
| --- | --- |
| `users.role` or an admin flag | ADR 0009, and it mixes authority with identity |
| Separate admin accounts | D-ADMIN-IDENTITY; a second identity system to secure |
| Email allowlist | SF-136 removed it: an email proves nothing |
| One shared workspace table | D-G01; hides each domain's rules |
| Shared "review" permission or state machine | A reviewer of one domain would gain another |
| Session-scoped self-elevation (AD0b) | The operator would be choosing their own authority |
| Application approval creating a contract | Legal and commercial steps have different owners |

## Consequences

* Production stays as today until approval and SF-110: review disabled, applications closed.
* A solo founder hits real limits: no self-review, no two-person operations and a weak separation of
  duties. These are stated, not hidden, and a second operator is required before some decisions are possible.
* MVP leaves out much of the design: moderation, bans, deletion tooling, money, campaigns, support sessions.
  Many boards remain as FUTURE references.
* New design work is required, because the canvas lacks applicant outcomes, dialogs, denied states and all
  empty, loading and error states.
* Application code can't stop someone with production database write access; that needs infrastructure
  controls.
* A WebAuthn dependency and a file scanner need their own review.

## Open

All of [D-SA01–D-SA30](../sponsor-admin-decision-register.md). Implementation needs its own authorization.
