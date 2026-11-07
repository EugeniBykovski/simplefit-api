# Sponsor & Admin — design gap register (SF-107)

**Status: specification for later design tasks. Claude Design wasn't changed.**

**Checked against** all 494 boards of Claude Design version `1794038955-2ed3` (2026-11-07), searching
markup and script text, case-insensitively. "None" below means nothing was found for that journey. A generic
system board that could serve is named. No Sponsor or Admin board has a state switch, other than
`step` on SRW2, so each board shows one state.

**Also recorded:**

* All Sponsor and Admin boards are 1440 wide (AdRules 1600). **No phone or tablet variant exists.**
* No Sponsor or Admin board is marked MVP, FUTURE or "no backend", unlike sections 18, 26 and 4.
* Three buttons have no target: AS2 "Reject…", AS2 "Pause", AD12 "Suspend tenant…".
* Canvas capacity is an open question ([D-SA30](sponsor-admin-decision-register.md)).

Priorities: **P0** blocks the MVP journey. **P1** needed for release. **P2** quality.
Device: **D** desktop, **M** phone-width web. Admin is desktop first.

## Sponsor

| Id | Required artboard | Journey | Found today | Device | UI states | Data | Permission | Priority | Task |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| G-S01 | Sign in before application; SPX2 and rail copy without "No account needed" | Start | SP8 asks for an account last | D, M | Signed out, signed in, registration needed | Session, registration | Session | P0 | D2 |
| G-S02 | Resume draft | Return | None. Only "Saved in this browser" | D, M | Resume, discard confirm, stale | Draft | Applicant | P0 | D2 |
| G-S03 | Field validation on SP1–SP6 | Fill | None | D, M | Required, invalid, too long, save failed, saving | Draft | Applicant | P0 | D2 |
| G-S04 | Upload states on SP7 | Fill | Uploaded rows only. Depends on D-SA09 | D, M | Uploading, too large, wrong type, scanning, rejected, failed, removed | Files | Applicant | P1 | D2 |
| G-S05 | Review and submit | Submit | None. SP7 goes directly to SP8; the side rail isn't a review | D, M | Complete, missing fields, declaration | Draft | Applicant | P0 | D2 |
| G-S06 | Submission failure | Submit | None. Generic: `AuthStatesWeb` for code errors only | D, M | Failed, stale revision, offline, already submitted | Draft | Applicant | P0 | D2 |
| G-S07 | Status: submitted, under review | Wait | SP9 is the confirmation. SPX5 has only `needs-info`. **Remove "Go to Sponsor Dashboard"** | D, M | Submitted, in review, loading, error | Application | Applicant | P0 | D2 |
| G-S08 | Status: changes requested | Respond | **SPX5 exists.** Needs a minimal shell instead of portal nav, no "Sarah" | D, M | Message, editing, resubmitted | Application | Applicant | P0 | D2 |
| G-S09 | Status: rejected | Outcome | **None for the applicant.** Only "Rejected → email with reason" on RouteSponsor | D, M | Reason, reapply, cooldown if any | Application | Applicant | P0 | D2 |
| G-S10 | Withdraw, and withdrawn state | Stop | None | D, M | Confirm, done, restart | Application | Applicant | P1 | D2 |
| G-S11 | Approved: open your workspace | Outcome | None as a step. SPX3 → SRW1 only | D, M | Approved, entering, failed | Application, `sponsor_id` | Owner | P0 | D2 |
| G-S12 | Data agreement signing | Commercial | None. Only "Signed Sep 9" text on SPX9, AS4, AS5 | D | **FUTURE, blocked on counsel** | Legal text | Owner | P2 | Future |
| G-S13 | Organizations in context switcher, WCX1, WA2; mobile A04 handoff row | Switch | **None.** No sponsor in `ContextSwitcher`, WCX1 or A04. SponsorNav has one fixed tile | D, M | One, several, suspended | Memberships | Member | P1 | D2 |
| G-S14 | Members and roles | Team | SPX9 has a list and an unlinked "Invite teammate" | D, M | Invite dialog, role change, remove confirm, transfer, pending, errors | Members | Per matrix | P1 | D2 |
| G-S15 | Invitation recipient page and email | Join | **None.** `EmailStaffInvite` is gym only | D, M | Valid, invalid, wrong account, accepted, declined, expired | Invitation | Recipient | P1 | D2 |
| G-S16 | Dashboard, MVP | Home | SPX4 is full of campaign data and metrics | D, M | **Empty first**, loading, error, suspended, no fake figures | Organization | Member | P0 | D2 |
| G-S17 | First run and tour, MVP | First use | SRW1, SRW2 with completion ("TOUR COMPLETE") assume campaigns; 9 steps cover FUTURE features | D, M | Reduced steps, skip, resume, loading, error | First-run | Member | P1 | D2 |
| G-S18 | Portal states | Any | None. Generic: ER2 404, LD3 launch. `StatesSheet` is scoped to social, board and gym console | D, M | Permission denied, suspended, closed, not found, session expired | — | Member | P0 | D2 |
| G-S19 | Emails: received, changes requested, approved, rejected | Notify | **None.** 0 sponsor hits in 17 Email boards and AD15, AD16 | Email | Four locales or as decided | Application | System | P0 | D2 |
| G-S20 | Phone-width variants of SPX2, SP1–SP7, status | All | None | M | Same as above | — | — | P1 | D2 |

## Admin

| Id | Required artboard | Journey | Found today | Device | UI states | Data | Permission | Priority | Task |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| G-A01 | Sign-in, then key check, no Okta or VPN claims | Enter | AD0 assumes both | D | Waiting, success, failed, wrong key, no key, timeout | Operator | Operator | P0 | D1 |
| G-A02 | Enroll two keys | First entry | **None** | D | Instructions, first key, second key, failed, expired | Operator | Pending | P0 | D1 |
| G-A03 | Step-up before a high-risk action | Act | **None.** Text only on AD0b | D | Prompt, success, failed, cancelled | — | Operator | P0 | D1 |
| G-A04 | Non-operator | Enter | **No dedicated board, and none is proposed.** ER2 404 is the answer | D, M | ER2 unchanged | — | — | — | Confirm |
| G-A05 | Permission denied in console | Any | **None.** Nearest: gym "ROLE RESTRICTED · 403" on WebDashboard | D | Inline, page | Permissions | Operator | P0 | D1 |
| G-A06 | Key check or session expired | Any | None. AD0 text only | D | Re-verify, keep form input | — | Operator | P1 | D1 |
| G-A07 | First run, MVP | First use | ARW1 at 2/5 only; no completion. Lists runbooks, shadowing and Support L2, none of which exist | D | Pending, done, dismissed | First-run, permissions | Operator | P1 | D1 |
| G-A08 | Overview, MVP | Home | AD1 full of invented figures, no empty state | D | Zero data, loading, error, partial permission | Counts | `platform.dashboard.read` | P0 | D1 |
| G-A09 | Nav by permission | Any | AdminNav shows all | D | Hidden sections, MVP set | Permissions | Operator | P0 | D1 |
| G-A10 | Sponsor queue states | Review | AS1 has one populated state; budget bands differ | D | Empty, loading, error, filtered none | Applications | `.read` | P0 | D1 |
| G-A11 | Application detail, read-only answers | Review | AS2 has edit controls, CRM fields, "Pause", and combined Approve and Convert | D | Unclaimed, claimed by me, by another, conflict, revision history, terminal | Revision, events | `.read`, `.claim` | P0 | D1 |
| G-A12 | Request changes dialog | Review | **None.** AS2's link goes straight to SPX5, the applicant's page | D | Compose, sending, stale, failed | Application | `.decide` | P0 | D1 |
| G-A13 | Reject dialog | Review | **None.** Button has no target. Inline pattern on AC2 | D | Reason, message, confirm, stale, failed | Application | `.decide` | P0 | D1 |
| G-A14 | Approve confirmation and result | Review | **None.** Goes directly to AS4 | D | What this does and doesn't do, stale, conflict, failed, done | Application | `.decide` | P0 | D1 |
| G-A15 | Sponsor organization list, detail, suspend confirm | Manage | AS4 only, CRM-shaped. "Pause" has no target | D | Empty, active, suspended, closed, confirm, failed | Organization | `sponsors.read`, `.restrict` | P1 | D1 |
| G-A16 | Gym verification queue | Review | **None.** Only a card on AD12; "KYC PENDING" on AD3 is another subject | D | Empty, loading, error, filters | Verification | `.read_queue` | P0 | D1 |
| G-A17 | Gym verification detail and decisions | Review | **None** | D | Details, evidence download, approve, changes, reject, revoke, conflict, stale | Verification | `gyms.verification.*` | P0 | D1 |
| G-A18 | Publication review | Review | **None.** Specified by SF-139 as PO1–PO4 | D | SF-139 | Publication | `gyms.publication.*` | When approved | SF-139 |
| G-A19 | Gym suspend confirmation | Manage | **None.** Button has no target. AD9 is user-only | D | Confirm, reason, failed, done | Gym | `gyms.suspend` | P1 | D1 |
| G-A20 | User search and detail, reduced; suspend, reduced | Manage | AD7 browses all, AD8 has risk score, strikes, devices; AD9 assumes two-person | D | Exact search, none found, masked email, reveal, suspend, lift | User | `users.*` | P1 | D1 |
| G-A21 | Audit entry detail | Investigate | **None.** AD14 rows have no links | D | Detail, not found, filters, empty, export hidden | Audit | `audit.read` | P1 | D1 |
| G-A22 | Operators: add, grant, revoke, enrollment state | Manage | AD20 shows a list, "Add staff", "Access requests", break-glass | D | Add, pending, active, suspended, revoked, last manager refused, self-grant refused | Operators | `operators.*` | P0 | D1 |
| G-A23 | Health failures | Operate | AD17 has one degraded example with unused vendors; AD1 "All systems normal". No job or queue failure board | D | Healthy, degraded, unknown, loading, error | Health | `system.health.read` | P1 | D1 |

## Board corrections, no new artboard

| Board | Change |
| --- | --- |
| SP4 | Remove the reach estimate |
| SP5, AS1, AS2, SPC4 | One budget list (D-SA05) |
| SPX2, SP9, SRW1, SponsorNav | Remove unstaffed names and times (D-SA22) |
| SPX1 | Mock campaigns stay labelled. The artboard's live-looking 48K, 312, 31% aren't in production (SF-43) and shouldn't return |
| AS2, AS3 | Answers read-only (F5). CRM fields separated |
| AD14 | Remove claims not yet true: hash chain, signed export, 7 years |
| AD17 | List real providers only |
| `RouteSponsor`, `FlowSponsor`, `FlowAdmin` | Redraw after approval |
| All FUTURE boards | Mark FUTURE (D-SA30) |
