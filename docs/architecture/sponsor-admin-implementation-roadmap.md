# Sponsor & Admin — implementation roadmap (SF-107)

**Proposals only. No Jira ticket has been created or read for this document, and none is authorized.**
SF-110 is the only number used, because the repository already names it. Task ids here are labels, to
be mapped to the epic's real tickets. Each task keeps the guardrails in the [threat model](sponsor-admin-threat-model.md).

## Order

```
Decisions (register: First decisions)
   │
   ├── D1 Admin design reconciliation ─┐       ┌── D2 Sponsor design reconciliation
   │                                   │       │
A1 Operator domain, ceremony (SF-110)  │       S1 Application backend
   │                                   │       │
A2 Admin gate, step-up, /admin/me ◄────┘       S2 Organization, membership, approval transaction
   │                                           │
   ├── A3 Shell, nav, first run                S3 Entry and registry ◄── D2
   │     ├── A4 Operators                      │
   │     ├── A5 Audit                          ├── S4 Application UI
   │     ├── A7 Overview and health            ├── S5 Status UI
   │     └── A8 User and gym reads ── A9 Restriction
   │                                           │
   ├── A6 Gym verification review              S7 Emails
   ├── A10 Gym publication (only if SF-139 approved)
   │                                           │
   └────────────► S6 Sponsor review ◄──────────┘
                     │
                     ├── A11 Sponsor organizations admin
                     ├── S8 Workspace, dashboard, first run
                     └── S9 Members and invitations
                                │
                             R1 Security and release acceptance
```

**True blockers:** approval of this architecture; A1. S1, S3 and S4 can be built and tested while the
production gate stays closed, since nothing can be approved until S6.

## Admin

| Task | Scope | Repo | Depends on | Boards | Acceptance | Guardrail |
| --- | --- | --- | --- | --- | --- | --- |
| **A1 (SF-110)** Operator domain | Tables, `SimpleFit.Operators`, authority, WebAuthn, ceremony and recovery, compile guard, `VerificationAuthority` backend not yet enabled | api | D-SA13, D-SA15, D-SA16; dependency review | — | [All SF-136 requirements](platform-operator-trust.md#9-what-sf-110-must-deliver); threat tests; `mix quality`; ADR amended | **No production grant in this task.** No interim path |
| **A2** Gate and step-up | `/admin` HTTP gate, `/admin/me`, enrollment, step-up API; web guard; 404 for non-operators on all 39 placeholders | api, platform | A1, D1 | AD0, new | Router-generated permission matrix test; identical 404 | Fails closed |
| **A3** Shell | `AdminNav` filtered by permission, first run, permission state | platform | A2 | ARW1, AdminNav | All states; keyboard, screen reader | Shell isn't authority |
| **A4** Operators | List, add, grant, revoke, suspend | api, platform | A3 | AD20 reduced | No self-grant, last manager; audit | No bulk grants |
| **A5** Audit | List, filter, detail | api, platform | A3 | AD14, new | Append-only verified; no PII in rows | Read only |
| **A6** Gym verification review | Enable the real backend in a **reviewed change**; HTTP operations; queue and detail UI | api, platform | A2, D1; SF-136 steps | New | Security suite on real authority; SF-104 verdict re-run | No fixture as evidence |
| **A7** Overview, health | Real counts; queues, jobs, last webhook | api, platform | A3 | AD1, AD17 reduced | Each number from a query; zero states | No trend, GMV or P95 |
| **A8** User and gym reads | Exact search, masked, linked context types | api, platform | A3, D-SA20 | AD7, AD8, AD2, AD12 reduced | Canary tests | No private data |
| **A9** Restriction | `user_restrictions`; session enforcement; gym suspended state; closure state | api, platform, mobile | A8, D-SA29, counsel | AD9 reduced, new; WS4, E13 | Suspended user blocked everywhere; lifts cleanly | Reversible only |
| **A10** Gym publication | SF-139 T4, T8 | api, platform | A2, SF-139 T1–T3 | SF-139 PO1–PO3 | SF-139 gate | **Only if approved** |
| **A11** Sponsor organizations | List, detail, suspend, close | api, platform | S6 | AS4 reduced, new | Suspended org is read-only | No CRM |

## Sponsor

| Task | Scope | Repo | Depends on | Boards | Acceptance | Guardrail |
| --- | --- | --- | --- | --- | --- | --- |
| **S1** Application backend | Tables, states, revisions, applicant API; files if D-SA09 allows | api | D-SA01, 02, 05, 09 | — | Transition, race and DTO tests; OpenAPI | No approval path |
| **S2** Organization, membership | Tables, policy, approval transaction, no-commercial test | api | S1, D-SA10, D-SA07 | — | All-or-nothing approval test; one-owner constraint | Reachable only from tests until S6 |
| **S3** Entry and registry | Entry rules; registry per [parity list](sponsor-admin-route-matrix.md#5-client-parity-requirements) | api, platform, mobile | S1, D-SA26 | — | Registry byte-identical; all entry cases; mobile handoff | Writes nothing on read |
| **S4** Application UI | SPX2 copy, SP1–SP7, review, submit, resume | platform | S3, D2 | SPX2, SP1–SP7, new | All states; responsive; keyboard | Applications stay closed until the release gate |
| **S5** Status UI | Submitted, review, changes, rejected, withdrawn, approved | platform | S3, D2 | SP9, SPX5, new | Each state from the API | No invented times or names |
| **S6** Sponsor review | Operator API; AS1, AS2 rework; dialogs | api, platform | A2, S2, D1 | AS1, AS2, new | Conflict, stale and concurrent cases | Authority per call |
| **S7** Emails | Received, changes requested, approved, rejected | api | S1, D2 | New | Templates, plain text, four locales or as decided | No campaign promises |
| **S8** Workspace | Shell, reduced dashboard, first run, tour | platform, api | S6, D2 | SPX4, SRW1, SRW2, SponsorNav | No metric appears without data; first-run rules | Campaign nav hidden |
| **S9** Members | Settings, invitations, transfer, recipient page, invite email | api, platform | S8, D-SA12 | SPX9, new | Invitation tests as SF-133 | `owner` not invitable |

## Design

| Task | Scope | Acceptance |
| --- | --- | --- |
| **D1** Admin | [G-A items](sponsor-admin-design-gap-register.md), marking FUTURE boards | Approved artboards, separately authorized, on a canvas that has room |
| **D2** Sponsor | [G-S items](sponsor-admin-design-gap-register.md) | Same |

## Release

| Task | Scope | Acceptance |
| --- | --- | --- |
| **R1** | Full journeys and negatives on real infrastructure; a release document | Below |

**Gate to open applications (all needed):** approved decisions; bootstrap done with evidence; second
operator named; reviewer named; counsel's sign-off on the declaration, privacy notice and retention;
security suite passing on the real authority; emails working; `web.partners.apply` enabled in a
reviewed change.

## FUTURE, each its own approved task

| Area | Boards | Blocked by |
| --- | --- | --- |
| Campaigns and review | SPX6, SPC1–SPC7, AC1–AC5 | Challenges, events and placement domains; AdRules approval |
| Placements | AV1, AV2, AV2b, MK11 | Same; labelling law |
| Contracts, data agreement | SPX9, AS4, AS5 | Counsel |
| Invoices, B2B payments, revenue | SPX8, AS6, AR1 | Finance; SF-138 Live |
| Analytics | SPX7 | Tracking; privacy review |
| CRM | AS3, AS4, AS5 | D-SA06 |
| Sponsor verification | New | D-SA04 |
| Moderation, reports, appeals | AD4, AD11, Appeal | Reports domain, staffing, counsel |
| Ban, delete, DSAR tooling | AD9, AD10, AD18 | Two-person rule, deletion policy |
| Support sessions | AD5, AD21 | Tickets; owner notification |
| Money operations | AD3, AD13, AR2–AR6 | Live payments |
| Flags, emails, markets | AD6, AD15, AD16, AD19 | Need |
| Enterprise, white label | AE1–AE3 | Sales |
| IdP, device trust, hash chain, external audit copy, break-glass | AD0, AD14, AD20 | Scale |
