# SF-82 · 02 — Identity, multi-workspace and the Gym permission matrix

**Status: ACCEPTED (ADR 0026); `D-G25` open.** See the [package index](README.md) and the
[decision register](10-decision-register.md).

## 1. Seven separate facts about one user

A single global `User` (ADR 0009) can hold any combination of the following.
None implies another, none is stored on `users`, and each has exactly one
authorizer.

| # | Fact | Stored in | Grants | Authorizer |
| --- | --- | --- | --- | --- |
| 1 | Account identity | `users`, `identities`, `sessions` | being signed in | `Accounts` (ADR 0009/0010) |
| 2 | Fighter capability | `fighter_profiles` (completed) | the user's own Fighter app | `Fighters` (ADR 0015) |
| 3 | Coach capability | `coach_profiles` (completed) | the user's own Coach app; *independent* coaching | `Coaches` (ADR 0020) |
| 4 | Gym workspace membership | `gym_staff_memberships` (active) | entering that gym's console (`GYM_WORKSPACE`) | `Gyms.Staff` |
| 5 | Gym-specific permission | role on (4), fixed matrix in code (§4) | each console action at **that** gym only | `Gyms` (policy module) |
| 6 | Gym membership as a participant | `gym_members` (active) | booking, checking in, the member pass at that gym | `Gyms.Members` |
| 7 | Coach–Fighter relationship | `coach_fighter_relationships` (active) | disclosed fighter fields and assigned training for that pair | `Coaching` (ADR 0021/0023) |

Consequences:

* A user can be the owner of gym A, a coach at gym B, a member of gym C, an
  independent coach with three fighters and a fighter with two coaches — at
  the same time, with no conflict and no "primary role".
* **(4) never implies (3) or (7)**, and (3) never implies (4). A gym coach
  sees gym members' attendance through (5); they see training data only
  through (7) or a future, separate, consent-based gym grant (`D-G06`).
* **(6) never implies (2)**: a member needs only a completed account
  (`D-G07`). Existing registry routes for member-facing gym pages require
  `FIGHTER`; SF-89 must relax them to account-level (`D-G07`, routing
  [07](07-routing.md)).

## 2. Capability projection (entry, ADR 0017)

`GET /api/v1/me/entry` keeps projecting capabilities for routing only. SF-83
adds `GYM_WORKSPACE` when the user has **≥ 1 active staff membership** and a
`gym_workspaces` summary (id, name, role, setup status) — a routing
projection, never an authorization input. The intent `gym` keeps meaning
"start or resume gym owner setup" and still grants nothing (ADR 0017 E6).

Gym membership as a participant (6) is **not** a capability: it does not
change the user's home; member gym pages are reached from the user's own
context (Fighter app today, account area for non-fighters, `D-G07`).

## 3. Selecting and switching the gym (`D-G15`, `D-G23` approved)

The route architecture kept workspace ids out of UI URLs
(`D-WORKSPACE-NOT-IN-URL`) and held the active workspace in the backend
session. For Gym, both rules are **replaced**:

| Option | Description | Assessment |
| --- | --- | --- |
| A. Backend session holds `active_gym_id` | `sessions` gains a column; gym endpoints are implicit (`/api/v1/gym/members`) | Rejected. Two tabs fight over one value, every request depends on hidden state, and IDOR checks become indirect |
| **B. Path-scoped API and ID-based UI navigation (approved)** | Every gym API path carries the id (`/api/v1/gyms/{gym_id}/…`, `D-G15`), and every gym UI route carries it too (`/app/gyms/:gymId/…`, `/gyms/:gymId/…`, `D-G23`). The server remembers only the **last chosen gym** for landing (SF-51 context choice, additive `gym_id`) | Approved. Each request is authorized on its own; tabs are independent; email and push links work; the id grants nothing |
| C. Header `X-Gym-Id` | Implicit tenant header | Rejected. Invisible in logs and traces, easy to forget, no advantage over B |

Landing and switching:

* `/app/gyms` (web) and `/gyms` (mobile) redirect to the only gym, or list
  several with the last chosen one preselected.
* Switching is navigation to another `:gymId` through the in-shell switcher
  or A04.
* A revoked membership answers 404 on the next request. The client then
  returns to the chooser, and the gym disappears from the next entry read.

Routing details are in [07 §3](07-routing.md).

## 4. Roles and the permission matrix (`D-G03`, `D-G04`)

MVP roles are `owner`, `manager`, `coach`, `front_desk`. "Head coach" (WG16,
WG17) is a display title on a `coach` row in MVP; a distinct permission set
for it is FUTURE. Custom roles (WG17 "Add custom role") are FUTURE.
"Gym member" is not a staff role — it is fact (6).

Legend: ✅ allowed · ◐ limited (see note) · ❌ denied · — not applicable.

| Action | Owner | Manager | Coach | Front desk | Member (6) | Other user |
| --- | --- | --- | --- | --- | --- | --- |
| Create a gym (becomes its owner) | — | — | — | — | — | ✅ any registered user (§6) |
| View gym console / staff view | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Edit gym details, branding, locations | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Complete setup / publish (FUTURE) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Invite manager | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Invite coach / front desk | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Change a staff member's role | ✅ (not to owner) | ◐ coach ⇄ front desk only | ❌ | ❌ | ❌ | ❌ |
| Remove staff | ✅ (not self) | ◐ coach / front desk only | ❌ | ❌ | ❌ | ❌ |
| Leave the gym (end own staff row) | ❌ must transfer or close | ✅ | ✅ | ✅ | — | — |
| Transfer ownership (FUTURE, SF-100) | ✅ to an active staff member | ❌ | ❌ | ❌ | ❌ | ❌ |
| Close the gym (FUTURE) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Invite / enroll members, manage join code | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ |
| List members (name, status, plan-less) | ✅ | ✅ | ◐ members of classes they coach | ✅ | ❌ | ❌ |
| See member contact email | ✅ | ✅ | ❌ | ◐ at check-in only | ❌ | ❌ |
| Suspend / resume / remove a member | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Create / edit classes and timetable | ✅ | ✅ | ◐ own classes' coach/notes (FUTURE) | ❌ | ❌ | ❌ |
| Cancel an occurrence | ✅ | ✅ | ◐ own occurrences | ❌ | ❌ | ❌ |
| View rosters | ✅ | ✅ | ◐ own occurrences | ✅ | ❌ | ❌ |
| Book / cancel for a member | ✅ | ✅ | ❌ | ✅ | — | ❌ |
| Book / cancel own place | — | — | — | — | ✅ active member | ❌ |
| Record a check-in | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| View attendance reports | ✅ | ✅ | ◐ own occurrences | ✅ today only | own history | ❌ |
| Billing, plan, payouts, revenue (FUTURE/BLOCKED) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Read members' private training data, messages, RPE, weight, videos, coach notes | ❌ **never, for any role** | ❌ | ❌ via gym (only via ADR 0021 relationship) | ❌ | — | ❌ |

The last row reproduces WG17's "NEVER, FOR ANY ROLE — platform-enforced":
there is no gym permission that reads training data; the only path is fact
(7) with its own consent.

Implementation: one `SimpleFit.Gyms.Policy` module with
`authorize(actor_staff_membership, action, resource)` returning
`:ok | {:error, :forbidden}`, called by each context function. Controllers
never branch on roles (CLAUDE.md rule 5).

## 5. 401 / 403 / 404 semantics

| Situation | Answer | Code | Why |
| --- | --- | --- | --- |
| No or invalid access token | 401 | `unauthorized` | ADR 0010 |
| Gym id unknown, malformed, or the caller has **no active staff membership** there | 404 | `not_found` | Existence of a gym's private resources is never confirmed to outsiders (forged ids, enumeration) |
| Resource id of another gym used with your gym id (`/gyms/A/members/{id of B}`) | 404 | `not_found` | Composite tenancy check; cross-gym IDOR is indistinguishable from "does not exist" |
| Caller is active staff of this gym, role lacks the permission | 403 | `forbidden` (details `{"permission": "<action>"}`) | They already know the gym exists; the console shows a role-restriction state (`D-G24`, approved; an exception to route-architecture rule 9) |
| Ended / suspended staff | 404 (as outsider) | `not_found` | Access ends immediately on revocation |
| Member-facing resources of a gym the user is not a member of | 404 | `not_found` | Same rule for participants |
| State conflict (capacity, already booked, invitation used) | 409 | `conflict` with `details` | ADR 0003 |

## 6. Who creates a gym; no circular authorization

* Any user with **completed account registration** may create a gym; they
  become its owner in the same transaction. No `GYM_WORKSPACE` capability is
  needed beforehand — that capability is the *result* (avoids the circular
  gate the brief warns about).
* `intent=gym` only routes to setup; it never creates or grants anything.
* Anti-abuse instead of gates (`D-G25`, open; recommended): rate limits of 5
  gym creations per user and 20 per IP digest per 24 h, and **one open
  draft** per user (a second create returns the existing draft). There is
  **no cap on owned gyms**: the three-gym cap was not approved, and any
  commercial ownership limit is deferred with `D-G09`. The same
  `client_request_id` returns the same gym (idempotency).

## 7. Revocation

Revoking (staff removed, member suspended/ended) takes effect on the next
request: every gym operation re-reads the actor's membership inside its
transaction (`FOR SHARE` on the staff row for writes), so there is no cached
role. Sessions are not revoked (the user keeps their other contexts); the
client learns from 404 and from the next entry projection.
