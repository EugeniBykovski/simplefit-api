# Sponsor & Platform Admin — architecture overview (SF-107)

**Status: PROPOSED, 2026-11-07. Awaiting approval.** Epic SF-106. Nothing here is implemented,
and nothing here authorizes implementation. Summary decision:
[ADR 0027](adr/0027-sponsor-and-platform-operator-architecture.md).

## Package

| Document | Content |
| --- | --- |
| [Identity](sponsor-admin-identity.md) | Contexts, non-grant rules, Sponsor domain boundaries, approval boundaries, entry resolution |
| [ERD](sponsor-admin-erd.md) | Tables, keys, constraints, deletion, retention questions |
| [Permissions](sponsor-admin-permissions.md) | Sponsor roles, operator capability matrix, sensitive data access |
| [Application lifecycle](sponsor-application-lifecycle.md) | States, transitions, revisions, concurrency, audit |
| [Operator trust](platform-operator-trust.md) | PlatformOperator, authentication, founder bootstrap, recovery, SF-110 |
| [API matrix](sponsor-admin-api-matrix.md) | Proposed `/api/v1` operations; none exist |
| [Route matrix](sponsor-admin-route-matrix.md) | Registry reconciliation and client parity |
| [Artboard inventory](sponsor-admin-artboard-inventory.md) | Every Sponsor and Admin board |
| [Design gap register](sponsor-admin-design-gap-register.md) | Screens and states the MVP needs |
| [Threat model](sponsor-admin-threat-model.md) | Threats, enforcement layers, required tests |
| [Decision register](sponsor-admin-decision-register.md) | D-SA01–D-SA30: what needs whose approval |
| [Roadmap](sponsor-admin-implementation-roadmap.md) | Dependency-ordered tasks, MVP and FUTURE |

## Today

| Fact | Evidence |
| --- | --- |
| No Sponsor domain exists | No sponsor table, context or endpoint. The word appears only as an entry intent |
| `sponsor` intent creates nothing | `SimpleFit.Entry`: always `sponsor_application`, reason `sponsor_intent` |
| No operator identity exists | SF-136 and SF-138: production review and privileged billing commands are refused at compile time |
| Applications are closed | `PartnersApplyPage` disables "Start application"; nothing is collected (SF-43) |
| 49 of 51 Sponsor and Admin web routes are placeholders | Only `/partners` and `/partners/apply` have real pages. No data is shown |
| Web route gates check the session only | `session-gate.tsx`: the API exposes no capability data for these yet. A signed-in user can open an `/admin` placeholder. It holds no data, so this is harmless **only while they stay placeholders** |
| No account restriction state | `users` has only an id and timestamps. `web.account.suspended` has nothing behind it |
| No second factor | No WebAuthn, TOTP or step-up in `lib` or `mix.exs` |
| Registry parity | `docs/route-registry.json` is byte-identical in Platform and Mobile at the recorded baselines |

## What the audit found

These are the findings that shape the design. Each is tracked in the linked document.

| # | Finding | Consequence |
| --- | --- | --- |
| F1 | **Circular route.** `web.sponsor.application` (SPX5) requires `SPONSOR_WORKSPACE`, but an applicant has no workspace until the application is approved | Applicants can never see their status. [Fix](sponsor-admin-route-matrix.md#2-circular-prerequisites) |
| F2 | **The entry resolver can't find an application.** `intent=sponsor` always goes to the apply page, so someone who has already applied starts again | Entry reads real Sponsor state, as it does for gyms. [Rules](sponsor-admin-identity.md#6-entry-resolution) |
| F3 | **The design delays account creation; the brief doesn't.** SPX2 says "No account needed to start", SP1–SP7 say "Saved in this browser", and SP8 creates an account at the end and promises files survive. ADR 0016 registration (name, date of birth, consents) appears nowhere in that path | Authenticate first. [D-SA01](sponsor-admin-decision-register.md) |
| F4 | **One button does three jobs.** AS2's "Approve · Convert to sponsor" joins approval, organization creation and a CRM stage (Lead → Former on AS4) | Separate facts. [Boundaries](sponsor-admin-identity.md#5-approval-and-verification-boundaries) |
| F5 | **Operators can rewrite what an applicant submitted.** AS2 and AS3 offer "Edit" on company, contact, markets and budget | Submitted revisions are immutable. CRM fields are separate. [Lifecycle](sponsor-application-lifecycle.md#4-revisions) |
| F6 | **AD0 and AD0b assume infrastructure that doesn't exist:** Okta SSO, VPN, company devices and hardware keys, with staff choosing their own scope per session | Build a smaller real version. [Trust](platform-operator-trust.md#3-authentication-assurance) |
| F7 | **AD20 and AD14 assume an organization that doesn't exist:** T&S leads, DPO, Finance lead, CTO, two-person rules, break-glass | Keep the rule as a target. Exclude what needs it from the MVP. [D-SA17](sponsor-admin-decision-register.md) |
| F8 | **Conflict-of-interest rules can block a solo founder.** SF-136 refuses a reviewer who is staff or a member of the gym. A founder who runs a gym can't approve it | Name a second operator before activation. [Trust](platform-operator-trust.md#6-separation-of-duties) |
| F9 | **Design numbers are illustrative.** 48K members, reach ~41,000, MRR €169,500, "Sarah", 5 business days, 7-year audit retention | None is a fact or a commitment. [Inventory](sponsor-admin-artboard-inventory.md) |
| F10 | **AD17 names providers not in use:** Postmark, Twilio and Fakturownia, while ADR 0005 uses Resend | Health lists what the deployment really uses |
| F11 | **Registry `source.version` is older than the canvas.** Registry says `1791448557-b0b9`; this audit read `1794038955-2ed3` | Recorded, not changed. Reconcile with the first route change |

## Sponsor product boundary

A Sponsor is a **business that has been accepted to work with SimpleFit**. It is not a user type,
a gym, a coach or a paying customer.

| Fact | Holds | Doesn't imply |
| --- | --- | --- |
| `SponsorApplication` | A request, with immutable submitted revisions | An organization, membership, approval or contract |
| `SponsorOrganization` | The approved business record | Verified identity, a contract, a campaign, or public visibility |
| `SponsorWorkspaceMembership` | One user's role in one organization | Any platform authority, or rights in another organization |
| Commercial agreement | **FUTURE.** Master and data agreements | Live placements |
| Campaign | **FUTURE.** A proposal reviewed by SimpleFit | Delivery, reach or invoices |

**Rule:** initial approval and workspace access work with the commercial layer absent.

## Commercial scope

Classification of what the current design shows. A design illustration is not a business contract.

| Feature | Boards | Class | Note |
| --- | --- | --- | --- |
| Sponsor application | SPX2, SP1–SP9, SPX5 | **MVP** | Behind the flow in [identity §6](sponsor-admin-identity.md#6-entry-resolution) |
| Partnership categories | SP3 | **MVP** | An expression of interest. Grants nothing |
| Markets | SP4 | **MVP**, without the reach estimate | "~41,000 active members in 312 gyms" is removed: no such measure exists |
| Budget range | SP5 | **NEEDS PRODUCT DECISION** | Currency and period conflict: SP5 says per year, AS2 per quarter, AS1 has other bands. Non-binding and internal in any case ([D-SA05](sponsor-admin-decision-register.md)) |
| Goals, uploads | SP6, SP7 | **MVP**, with smaller upload limits | No 200 MB creative. See [threat model](sponsor-admin-threat-model.md) |
| Partner overview, public page | SPX1 | **MVP** (exists, truthful) | Mock campaigns are labelled examples. No live metrics (SF-43) |
| Named partner manager | SPX4, SRW1, SponsorNav | **DESIGN ONLY** | Nobody is staffed; no messaging exists |
| Response promises (5 business days, 2 days, 1 day) | SPX2, SP9, SRW1 | **NEEDS PRODUCT DECISION** | No service level until someone is staffed ([D-SA22](sponsor-admin-decision-register.md)) |
| Opportunities, sponsorship discovery | — | **FUTURE** | No board exists. No marketplace of invented opportunities |
| Campaigns and review | SPX6, SPC1–SPC7, AC1–AC5 | **FUTURE** | No challenges, events or placements domain |
| Sponsored placements | AV1, AV2, AV2b, MK11, AdRules | **FUTURE** | AdRules is a useful draft policy; it isn't approved |
| Proposals | — | **FUTURE** | No board |
| Contracts, data agreement | AS4, SPX9 | **BLOCKED** | Legal text and counsel. "Signed Sep 9" is illustrative |
| Invoices | SPX8, AS4 | **BLOCKED** | Separate B2B invoicing doesn't exist; Stripe Live is NO-GO (SF-138) |
| Payments | SPX8 | **BLOCKED** | Same |
| Performance analytics | SPX7, SPX4 cards, AS6 | **BLOCKED** | No tracking exists. Show no reach, engagement or conversions until measured |
| Brand exposure, ROI | SPX1, SPX7 | **DESIGN ONLY** | Never display an invented figure |
| Sponsor CRM stages | AS4, AS3 | **NEEDS PRODUCT DECISION** | Internal sales tracking can be a spreadsheet at first ([D-SA06](sponsor-admin-decision-register.md)) |
| Revenue | AS6, AR1 | **FUTURE** | Needs invoices |
| Enterprise and white label leads | AE1–AE3 | **FUTURE** | Separate from Sponsors. AE3 says "UI only" |

## Admin console scope

| Module | Boards | MVP | Real data available |
| --- | --- | --- | --- |
| Access | AD0, AD0b | Reduced: sign in, then security key | New |
| First run | ARW1 | Reduced: truthful checklist | First-run outcome |
| Overview | AD1 | Counts and queues only, no trend | SQL counts of users, fighter and coach profiles, completed gyms, organizations, pending applications. No growth, GMV or WAU |
| Operators | AD20 | Reduced: list, grant, revoke | New |
| Audit | AD14 | Yes | `operator_audit_events` |
| Sponsor applications | AS1, AS2 | Yes, with fixes | New |
| Sponsor organizations | AS4 (partly) | Reduced: status and members | New |
| Gym verification | AD12 card only | Yes, **needs new boards** | SF-103 domain, unreachable in production until SF-110 |
| Gym publication | none | When SF-139 is approved | Proposed by SF-139 |
| Users | AD7, AD8 | Reduced: search, minimal identity, linked contexts | New restriction state is needed |
| User restriction | AD9 | Reversible suspension only | New domain |
| Gyms | AD2, AD12 | Reduced: list, status | `gyms`, staff count, location, verification status |
| Health | AD17, AD1 strip | Reduced | Database reachability, Oban queues and discarded jobs, last Stripe webhook. No P95 or uptime: nothing measures them |
| Coach and Fighter oversight | AD7, AD8 | Read of account-level facts only | No training, health or messaging data |
| Moderation, reports | AD4, AD11 | **FUTURE** | No reports domain. Only SF-139 proposes one for gyms |
| Ban, delete | AD9, AD10 | **FUTURE** | Needs account deletion policy and a two-person rule |
| DSAR | AD18 | **FUTURE**, but **legal may require a process** | Counsel. A manual runbook is possible at first |
| Support sessions | AD5, AD21 | **FUTURE** | No tickets domain |
| Money | AD3, AD13, AR1–AR6 | **FUTURE** | Stripe Dashboard stays the tool. SF-138: Live NO-GO |
| Flags, emails, markets | AD6, AD15, AD16, AD19 | **FUTURE** | Those are code or config today |
| Campaigns | AC1–AC5 | **FUTURE** | See above |
| Enterprise | AE1–AE3 | **FUTURE** | The forms are disabled |

**No expensive analytics stack or invented telemetry.** A number appears only if a query produces it.

## Entry flows

### Sponsor

```
/partners → /partners/apply (SPX2)
  → sign in or register (no account required to read)
  → account registration, if not done (ADR 0016)
  → /app/onboarding/sponsor: company → contact → interests → markets → budget → goals → uploads → review
  → submit → /sponsor/application (status)
      ├─ changes requested → edit and resubmit
      ├─ rejected → reason, where to go next
      ├─ withdrawn
      └─ approved → organization and owner membership created in one transaction
           → /sponsor/:sponsorId/dashboard (first run) → tour, optional
```

Registering or choosing "Sponsor" grants nothing, and neither does submitting. Only an operator's
approval creates a workspace, and it still grants no commercial right.

### Admin

```
Normal sign-in (the same account as anywhere else)
  → open /admin
  → not an active operator → ordinary 404
  → operator without a current security key check → /admin/verify
  → first time → /admin/welcome (presentation only)
  → /admin, showing only what granted permissions allow
```

There is no public "Sign up as Admin", no admin intent, and `/api/v1/me/entry` never mentions
operators. Onboarding creates no authority: the operator record exists before the first visit.

## Out of scope for SF-107

No code, migration, endpoint, OpenAPI change, generated client, route registry edit, operator grant,
Jira change or Claude Design change.
