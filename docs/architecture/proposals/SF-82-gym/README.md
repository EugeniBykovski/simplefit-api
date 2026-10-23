# SF-82 — Gym domain architecture, authorization and Claude Design reconciliation

**Status: PROPOSED — awaiting approval** (2026-10-23). Epic SF-81 Gym & Club
Management. Summary decision: [ADR 0026](../../adr/0026-gym-domain-architecture.md).

SF-82 is architecture and documentation only:

* no Gym API, migration, OpenAPI change or production UI;
* no route-registry or Claude Design change;
* SF-83 does not start until the decisions are approved.

| Doc | Content |
| --- | --- |
| [01 Domain model](01-domain-model.md) | Entities, MVP/FUTURE/BLOCKED, ERD, lifecycle and deletion |
| [02 Identity, roles, permissions](02-identity-roles-permissions.md) | Seven separate facts, entry projection, workspace selection, permission matrix, 401/403/404 |
| [03 Registration and workspace lifecycle](03-registration-workspace-lifecycle.md) | Owner setup, drafts, resume, staff onboarding, ownership |
| [04 Gym vs Coach–Fighter contract](04-gym-vs-coaching-contract.md) | What each relationship authorizes and never authorizes |
| [05 Scheduling and commercial boundaries](05-scheduling-and-commercial-boundaries.md) | Classes vs TrainingSession, five commercial concepts, local development |
| [06 Claude Design inventory](06-claude-design-inventory.md) | 116 boards, classification, routes, truthfulness, design findings R1–R11 |
| [07 Routing](07-routing.md) | Route groups, workspace switching, gates, future registry changes |
| [08 Security threat model](08-security-threat-model.md) | Threats T1–T22 and controls |
| [09 Dependency matrix](09-dependency-matrix.md) | Proposed SF-83–SF-104 split, entry conditions, critical path |
| [10 Decision register](10-decision-register.md) | D-G01–D-G19, conflicts with approved documents |
| [11 API contract matrix](11-api-contract-matrix.md) | Proposed `/api/v1` operations (not in OpenAPI) |

## Invariants

1. One global user. Never `User.role`, `User.type` or a global `gym_id`.
2. Gym membership never creates or implies a Coach–Fighter relationship, and
   no gym role reads training data.
3. Every gym operation is authorized by the backend against the actor's
   active membership at **that** gym.
4. No fabricated plans, prices, trials, payments, balances or revenue. The
   affected screens stay as placeholders.
5. The ADR 0025 coaching bypass does not apply to Gyms.

## Approval needed

* The register's decisions, especially:
  * `D-G07` (member without FighterProfile);
  * `D-G15` (path-scoped API, which amends the route-architecture wording);
  * `D-G16` (single staff-invite entry).
* Claude Design revisions R1–R11.
* Separate product decisions for the blocked items: `D-G09` (plan/trial),
  `D-G10` (commerce and payment provider), `D-G11` (verification and
  publication).
