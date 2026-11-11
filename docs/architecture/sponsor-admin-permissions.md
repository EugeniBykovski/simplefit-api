# Sponsor & Admin — permissions and data access (SF-107)

**Status: PROPOSED.** Nothing is granted by this document. Exact names are for approval
([D-SA16](sponsor-admin-decision-register.md)).

## 1. Sponsor roles

A fixed matrix in code, as `Gyms.Policy`, applied to an **active** membership in an **active**
organization. No other context grants any of it. An operator isn't given these by being an operator.

| Permission | Owner | Manager | Member |
| --- | --- | --- | --- |
| View workspace, application history | ✓ | ✓ | ✓ |
| Edit brand details | ✓ | ✓ | — |
| View members | ✓ | ✓ | ✓ |
| Invite and remove `member` | ✓ | ✓ | — |
| Invite and remove `manager`, change roles | ✓ | — | — |
| Transfer ownership, close organization | ✓ | — | — |
| Invoices (FUTURE) | ✓ | ✓ | — |
| Campaigns (FUTURE) | Later | Later | Later |
| Leave | After transfer | ✓ | ✓ |

SPX9's "Admin" maps to owner or manager; "Campaign manager · can't see invoices" maps to member.
A **suspended** organization is read-only; a **closed** one is gone from the workspace.
An applicant before approval holds none of these: they own only their application.

## 2. Operator capability matrix

**Actor type is always an active operator, reached through the [authority](platform-operator-trust.md#4-the-authority).**
**Default denial: no row, no action.** Scope is global in MVP.

Naming: the existing code uses local verb atoms (`:read_queue`, `:approve`). Stored operator
permissions are dotted `domain.area.verb` and map one-to-one to those atoms, so nothing broad like
`gyms.verification.review` can hide several actions. SF-136 requires per-action checks.

Assurance A1 means a current key check and A2 a very recent one ([definition](platform-operator-trust.md#3-authentication-assurance)).

### Platform and people

| Permission | Tier | Allows | Sees | Assurance | Audit | MVP |
| --- | --- | --- | --- | --- | --- | --- |
| `platform.dashboard.read` | Routine | AD1 | Counts only, no names | A1 | View not logged per load | Yes |
| `users.read` | Routine | Search by exact email or id; read one user | Masked email, identity providers, linked context **types** and gym or organization ids. Not profile content | A1 | Each view, with `ticket_ref` | Yes |
| `users.reveal_email` | Elevated | Show one full address | One email | A2 | Each reveal, with reason | Yes |
| `users.restrict` | High | Suspend or lift | State only | A2 | Write, reason, before and after | Yes |
| `gyms.read` | Routine | AD2, AD12 reduced | Name, status, location, staff count, verification status. **No member list** | A1 | Each detail view | Yes. **Built in SF-123**: also counts by role and the owner's short name; each list query audited too |
| `coaches.read` | Routine | AD7 Coaches tab | Exact lookup; shared profile fields, account state, relationship counts, gym ids. **No relationships, bio or training** | A1 | Each search and view | Yes (SF-123) |
| `fighters.read` | Routine | AD7 Fighters tab | Exact lookup; shared profile fields, account state, relationship and gym membership counts. **No body, health, goals or training** | A1 | Each search and view | Yes (SF-123) |
| `gyms.suspend` | High | Suspend or reinstate | State | A2 | Write | Yes |
| `audit.read` | Elevated | AD14 | Audit rows | A1 | Each query | Yes |
| `system.health.read` | Routine | Reduced AD17 | Queue and job counts. No args, no payloads | A1 | None | Yes |
| `operators.read` | Elevated | AD20 list | Operators and grants | A1 | Each view | Yes |
| `operators.manage` | **Critical** | Add, suspend, revoke, grant | Same | A2 | Write | Yes |

### Gym verification

These map one-to-one to `VerificationAuthority.permission`.

| Permission | Tier | Allows | Sees | Assurance | Audit |
| --- | --- | --- | --- | --- | --- |
| `gyms.verification.read_queue` | Routine | Queue | Gym name, status, dates | A1 | Query |
| `gyms.verification.read_application` | Elevated | Detail | Declared business details | A1 | Each view |
| `gyms.verification.read_evidence` | High | Download a document | One document by short presigned link | A2 | Each download |
| `gyms.verification.approve` | High | Approve | | A2 | Write |
| `gyms.verification.request_changes` | Routine write | Ask for changes | | A1 | Write |
| `gyms.verification.reject` | High | Reject | | A2 | Write |
| `gyms.verification.revoke` | High | Revoke | | A2 | Write |

### Gym publication

SF-139's eleven permissions, renamed only for the prefix, and available **only if SF-139 is approved**:
`gyms.publication.read_queue`, `.read`, `.approve`, `.request_changes`, `.reject`, `.suspend`,
`.reinstate`, `.revoke`, `.reopen`, `.read_audit`, `.process_reports`.

### Sponsors

| Permission | Tier | Allows | Sees | Assurance | Audit | MVP |
| --- | --- | --- | --- | --- | --- | --- |
| `sponsors.applications.read` | Routine | AS1, AS2 | Submitted revisions. **Not drafts** | A1 | Each detail view | Yes |
| `sponsors.applications.read_files` | Elevated | Download a file | One file | A2 | Each download | Yes |
| `sponsors.applications.claim` | Routine write | Claim, release own | | A1 | Write | Yes |
| `sponsors.applications.reassign` | Routine write | Move another's claim | | A1 | Write | Yes |
| `sponsors.applications.decide` | High | Approve, reject, request changes | | A2 | Write | Yes |
| `sponsors.read` | Routine | Organizations, members' roles | Masked member emails | A1 | Each detail view | Yes |
| `sponsors.restrict` | High | Suspend, reinstate, close | | A2 | Write | Yes |

### FUTURE

`moderation.read`, `moderation.action`, `users.delete`, `users.ban`, `users.export`, `support.session`,
`payments.*`, `flags.*`, `markets.*`, `campaigns.*`. Not in the catalog until their task. The CHECK
constraint refuses them meanwhile.

### Rules for every permission

| Rule | Detail |
| --- | --- |
| Revocation | Effective on the next call. A decision that passed its second check before revocation stands in history (SF-136) |
| Conflict | Reviewing permissions also pass the domain's conflict check. No permission overrides it |
| Founder | Gets explicit rows, not a superuser flag, and each can be revoked |
| Bundles | Suggested sets below are a UI convenience. They store nothing: only rows count |
| Reads of non-public data | Need a recorded reason, or a `ticket_ref` once tickets exist |

**Suggested sets, not roles:** *Reviewer* (sponsor application read, claim, decide), *Gym reviewer*
(verification), *Auditor* (`audit.read`, `operators.read`), *Operator manager* (`operators.*`,
which holds no reviewing permission). AD0b's choose-your-scope isn't proposed: an operator can't
elect a higher scope for themselves.

## 3. Sensitive data classes

| Class | Examples | Routine operator | Redacted | Audited | Step-up |
| --- | --- | --- | --- | --- | --- |
| Public | Public website content, future published gym | Yes | No | No | No |
| Account identity | Email, identity provider | `users.read`, masked | **Yes**; full address via `users.reveal_email` | Yes | A2 to reveal |
| Internal operational | Status, counts, queues | By permission | No | Detail views | A1 |
| Business documents | Gym evidence, sponsor uploads | By permission | No, but one at a time, short link | Every download | A2 |
| Sponsor application data | Contact, budget, goals | `sponsors.applications.read` | No | Each view | A1 |
| Payment | Card details, Stripe ids, payouts | **None in MVP.** Card data is never held | N/A | N/A | N/A |
| Private coaching | Training sessions, notes, relationships | **Never.** No permission exists | N/A | Attempt refused | N/A |
| Health-related | Weight, RPE, pain, recovery, date-of-birth-derived age | **Never.** No permission exists | N/A | N/A | N/A |
| Private messages | DMs, when they exist | **Never** | N/A | N/A | N/A |
| Gym member lists | Names, attendance | **Never in MVP.** Support sessions are FUTURE | N/A | N/A | N/A |
| Security and audit | Audit rows, session metadata, IP digests | `audit.read` | Digest, not IP | Each query | A1 |
| Secrets | Tokens, keys, verifiers | **Never via any screen.** AD17's key rotation dates are FUTURE | N/A | N/A | N/A |

## 4. Sensitive data access

* **An admin console isn't permission to browse.** Search is exact, not list-all. AD7's filtered list
  of every account is replaced in the MVP by search ([D-SA20](sponsor-admin-decision-register.md)).
* **No endpoint exists for private data.** Absence is the control, stronger than a check. Admin
  views use explicit JSON views over explicit queries, and a canary test proves private fields never
  appear in them.
* **AD8 states the right rule:** "Messages, training logs, weight and RPE are not visible to admins
  unless a participant reports that exact item." The exception is FUTURE, with moderation.
* **No superuser database connection in the app.** Admin endpoints use the same connection and the
  same context functions, with authorization in the context. Direct production database access is an
  infrastructure control and doesn't exist yet (see ADR 0026, "Limits of this control").
* **Exports:** none in MVP. AD7's and AD14's export is FUTURE, with the two-person rule.
* **Sponsors see no athlete data.** No individual or small-group data is ever shared, in any task.
