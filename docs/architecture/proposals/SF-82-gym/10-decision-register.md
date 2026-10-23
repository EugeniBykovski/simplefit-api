# SF-82 · 10 — Decision register

**Status:** every row is **PROPOSED — awaiting approval**. Nothing here is
implemented. "Blocked" rows cannot be decided by engineering alone.

| ID | Decision | Options | Recommendation | Trade-off | Status |
| --- | --- | --- | --- | --- | --- |
| D-G01 | What is the tenant? | A `gyms` table; B generic polymorphic `workspaces` (gym + sponsor) | **A** | B anticipates sponsors but forces a lowest-common-denominator model; sponsors get their own table later | Proposed |
| D-G02 | Locations | A ≥ 1 `gym_locations`, address only; B address on `gyms` | **A** (one in first UI) | A costs one join; avoids a migration when the 2nd location arrives (WG23 already shows several) | Proposed |
| D-G03 | Staff roles | A fixed `owner/manager/coach/front_desk` in code; B custom roles with permission JSON | **A**; "head coach" is a title; custom roles FUTURE | A cannot model WG17 "Add custom role" yet; B is speculative and hard to audit | Proposed |
| D-G04 | Ownership | A exactly one owner, transfer; B co-owners | **A** | Co-owned clubs must pick one account owner; simpler invariants (T4) | Proposed |
| D-G05 | Who creates gyms; draft persistence | A any registered user, persisted at OG1, ≤ 1 draft, ≤ 3 owned; B approval/verification first | **A** | Spam gyms possible but private and invisible until publication (which needs `D-G11`) | Proposed |
| D-G06 | Gym access to members' training data | A never (only ADR 0021 relationships); B future gym-scoped consent | **A now**, B as separate future decision with legal text | WG16/WG17/OS2 "fighter notes (with consent)" stays unbuilt | Proposed |
| D-G07 | Does a gym member need a FighterProfile? | A account only; B FighterProfile required | **A**; member routes move from `FIGHTER` to account-level | Contradicts current registry guards (registry PR in SF-91); non-boxers (fitness boxing) can join | Proposed — conflicts with registry |
| D-G08 | How members join | A invitation (E07) + join code → request (auto-approve opt-in); B also CSV import | **A**; import FUTURE | Owners must invite manually; avoids storing third parties' data without basis | Proposed |
| D-G09 | SimpleFit plan, trial, pricing for gyms | — | **Product/business decision required** | OG6, WG25, PR3, PR6m cannot be built | **BLOCKED** |
| D-G10 | Gym commerce and payment provider | — | **Separate approved decision** (provider, merchant-of-record, SCA, refunds, consumer law) | OG8/OG9, WG6/WG7, GC* cannot be built; no mock payments | **BLOCKED** |
| D-G11 | Business verification (KYB) and publication | — | **Separate decision** (provider, legal requirements) | OG7, OG14, Discover, MK4/MK5 cannot be built | **BLOCKED** |
| D-G12 | Staff invitation lifetime and binding | A 7 days, verified-email binding (ADR 0021 pattern); B 24 h; C link-only | **A** | Matches WG26 7-day accept and E06 copy | Proposed |
| D-G13 | Gym types | A OG1's six values as enum; B free text | **A** | New types need a migration-free code change only (enum in code, text column) | Proposed |
| D-G14 | Classes vs TrainingSession | A separate class/occurrence/booking tables, shared `SimpleFit.Scheduling` rules; B classes as batches of TrainingSessions | **A** | Some duplication of time logic, removed by extraction | Proposed |
| D-G15 | Active gym selection | A backend session column; B path-scoped API + client-held selection + remembered last choice; C header | **B** | Requires amending route-architecture §7 wording | Proposed — conflicts with current doc wording |
| D-G16 | Staff invitation entry | A single `/invite/staff#token=` for all roles; B keep INV2 `/invite/coach/:token` for coach role | **A** | Registry change; avoids collision with SF-57/SF-80 coach invitations | Proposed |
| D-G17 | Local development for Gym | A no bypass (none needed for MVP); B extend ADR 0025 bypass | **A** | Future gates use provider sandboxes | Proposed |
| D-G18 | Audit history | A `gym_audit_events` append-only from SF-83; B logs only | **A** | One small table; logs cannot hold PII-free history reliably (ADR 0008) | Proposed |
| D-G19 | Member pass without commerce | A F16 as non-commercial "member pass" (QR + status); B wait for commerce | **A** | Requires design copy change (R6) | Proposed |

## Conflicts with existing approved documents

1. `route-architecture.md` §7 — "active workspace … held by the backend
   session" vs `D-G15` B.
2. Route registry — member gym routes require `FIGHTER` vs `D-G07` A.
3. Route registry — `mobile.invite.coach._token` (INV2) vs `D-G16` A.
4. Claude Design — R1–R11 in [06](06-claude-design-inventory.md).

None of these is changed by SF-82.
