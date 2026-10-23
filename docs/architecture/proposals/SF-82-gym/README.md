# SF-82 — Gym domain architecture, authorization and Claude Design reconciliation

**Status: ACCEPTED (final SF-82 approval, 2026-10-23); SF-83 not started.**
Epic SF-81 Gym & Club Management. Summary decision:
[ADR 0026](../../adr/0026-gym-domain-architecture.md).

SF-82 is architecture and documentation only:

* no Gym API, migration, OpenAPI change or production UI;
* no route-registry or Claude Design change.

**Decisions:**

* **Approved:** D-G01–D-G08, D-G12–D-G16, D-G18, D-G20–D-G24 and D-G26.
* **Deferred product decisions:** D-G09, D-G10 and D-G11.
* **Open:** D-G17, D-G19 and D-G25 (rate limits; the three-gym cap was
  rejected). See the [register](10-decision-register.md).

| Doc | Content |
| --- | --- |
| [01 Domain model](01-domain-model.md) | Entities, MVP/FUTURE/BLOCKED, ERD, lifecycle and deletion |
| [02 Identity, roles, permissions](02-identity-roles-permissions.md) | Seven separate facts, entry projection, workspace selection, permission matrix, 401/403/404 |
| [03 Registration and workspace lifecycle](03-registration-workspace-lifecycle.md) | Four-phase journey, 14 steps as a product journey, drafts, staff onboarding, lifecycle review |
| [04 Gym vs Coach–Fighter contract](04-gym-vs-coaching-contract.md) | What each relationship authorizes and never authorizes |
| [05 Scheduling and commercial boundaries](05-scheduling-and-commercial-boundaries.md) | Classes vs TrainingSession, five commercial concepts, local development |
| [06 Claude Design inventory](06-claude-design-inventory.md) | 116 boards, classification, routes, truthfulness, design findings R1–R11 |
| [07 Routing](07-routing.md) | Route groups, `gym_id` consistency, member-route capabilities, staff-invite routes |
| [08 Security threat model](08-security-threat-model.md) | Threats T1–T22 and controls |
| [09 Dependency matrix](09-dependency-matrix.md) | SF-83–SF-104 reconciled with the final architecture, missing dependencies (account deletion, native app links), SF-83 independence |
| [10 Decision register](10-decision-register.md) | Approved, deferred and remaining decisions D-G01–D-G26; conflicts with approved documents |
| [11 API contract matrix](11-api-contract-matrix.md) | Proposed `/api/v1` operations (not in OpenAPI) |
| [12 Design reconciliation plan](12-design-reconciliation-plan.md) | R1–R11 with exact artboards, proposed changes C1–C17 and the final per-screen checklist (not applied) |

## Invariants

1. One global user. Never `User.role`, `User.type` or a global `gym_id`.
2. Gym membership never creates or implies a Coach–Fighter relationship, and
   no gym role reads training data.
3. Every gym operation is authorized by the backend against the actor's
   active membership at **that** gym.
4. No fabricated plans, prices, trials, payments, balances or revenue. The
   affected screens stay as placeholders.
5. The ADR 0025 coaching bypass (SF-105) does not apply to Gyms.

## Still needed

* Decisions `D-G25` (needed by SF-83), `D-G19` (SF-96/SF-97) and `D-G17`.
* A separate approval of the Claude Design changes C1–C17
  ([12 §3](12-design-reconciliation-plan.md)).
* The Jira alignment of SF-83–SF-104, plus new tickets for account deletion
  and the native invitation app links ([09 §3](09-dependency-matrix.md)).
* An explicit authorization to start SF-83.
