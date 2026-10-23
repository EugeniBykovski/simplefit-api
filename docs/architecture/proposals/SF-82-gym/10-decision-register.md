# SF-82 · 10 — Decision register

**Review status (2026-10-23):** the architecture is approved in principle;
**SF-83 is not authorized yet**. Statuses:

* **APPROVED**: approved by the product owner in the SF-82 review.
* **OPEN**: engineering proposal awaiting a decision.
* **DEFERRED PRODUCT DECISION**: a business, legal or vendor decision. It is
  not an engineering fact, and nothing that depends on it is designed further
  or built.

## 1. Approved decisions

| ID | Decision approved | Notes for implementation |
| --- | --- | --- |
| D-G04 | One canonical gym owner in MVP; ownership moves only by a safe, transactional transfer | Partial unique index "one active owner per gym"; transfer locks the gym row; the owner cannot leave or be removed ([03 §6](03-registration-workspace-lifecycle.md)) |
| D-G05 | A gym is created as a **draft** at the first valid onboarding submission, with idempotency and resumability | `POST /gyms` with `client_request_id`; `GET /me/gyms` resumes. **Not covered by the approval:** draft retention (`D-G20`), creation limits (`D-G25`) and the step redistribution (`D-G21`) |
| D-G07 | Gym membership does not require a FighterProfile. Gym members and Coach–Fighter relationships stay independent | Member-side routes move to account level ([07 §5](07-routing.md)) |
| D-G14 | Gym classes and occurrences are separate from private, coach-assigned TrainingSessions | Shared `SimpleFit.Scheduling` time rules, extracted without changing ADR 0023's behaviour |
| D-G15 | Explicit path-scoped Gym APIs `/api/v1/gyms/{gym_id}/…`, with backend membership and permission checks on every request | UI URL shape is `D-G23`; UI treatment of 403 is `D-G24` |
| D-G16 | A canonical Gym staff-invitation domain, separate from Coach–Fighter invitations; conflicting token routes are not reused | Entry design is `D-G22`; the SF-57/SF-80 `/invite/coach` link and its security stay untouched |

## 2. Deferred product decisions

| ID | Decision | What is blocked | Engineering position |
| --- | --- | --- | --- |
| D-G09 | Pricing, Gym SaaS subscriptions, trials and SimpleFit billing | OG4–OG6, OG6b trial copy, WG25, PR3, PR6m, L4 prices, plan tiles | No plan, price or trial is stored or shown. Gym creation never depends on a plan |
| D-G10 | Payment provider and payment architecture activation (member commerce, payouts, refunds, dunning) | OG8, OG9, WG6, WG7, GC1–GC12, F16 renewals, credits | No provider is selected or stubbed. No mock payment grants an entitlement |
| D-G11 | Business verification (KYB) and public publishing policy | OG7, OG14, E05, Discover, MK4/MK5, "verified" badges | Gyms stay private. Nothing shows "verified" or "published" |

## 3. Open decisions

| ID | Decision | Proposed choice | Alternatives | Recommendation and trade-off |
| --- | --- | --- | --- | --- |
| D-G01 | What is the tenant? | `gyms` table owned by `SimpleFit.Gyms` | B: generic polymorphic `workspaces` table shared with sponsors | **Proposed choice.** B forces a lowest-common-denominator model; sponsors get their own table later |
| D-G02 | Locations | ≥ 1 address-only `gym_locations`, one in the first UI | B: address columns on `gyms` | **Proposed choice.** One join more; no migration when the second location arrives (WG23 already shows several) |
| D-G03 | Staff roles | Fixed `owner`, `manager`, `coach`, `front_desk` in code; "head coach" is a display title | B: custom roles with permission JSON (WG17 "Add custom role"); C: add a `head_coach` role now | **Proposed choice.** B is speculative and hard to audit; C can be added later without migrating data |
| D-G06 | Gym access to members' training data | Never via the gym; only via ADR 0021 relationships | B: a future gym-scoped consent (WG16/WG17/OS2/INV2 "fighter notes with consent") | **Proposed choice now.** B only as a separate future decision with its own legal text |
| D-G08 | How members join | Email invitation (E07) plus a join code that creates a request; the owner may turn on auto-approve | B: also CSV import (OG12); C: open joining without approval | **Proposed choice.** Import stores third parties' data before they have an account and needs a legal basis |
| D-G12 | Staff invitation lifetime and binding | 7 days; bound to a verified email identity (ADR 0021/SF-73 pattern) | B: 24 h; C: link-only possession | **Proposed choice.** Matches the E06 and OS1 copy; C would let a forwarded email be accepted |
| D-G13 | Gym types | OG1's six values as a code-level enum in a text column | B: free text | **Proposed choice.** New values need a code change only |
| D-G17 | Local development for Gym | No bypass. The Gym MVP needs no legal or vendor gate, and ADR 0025 (SF-105) is not extended | B: extend the ADR 0025 bypass | **Proposed choice.** Future gates use provider sandboxes |
| D-G18 | Audit history | Append-only `gym_audit_events` from SF-83 | B: logs only | **Proposed choice.** Logs cannot keep reliable, PII-free history (ADR 0008) |
| D-G19 | Member pass without commerce | F16 as a non-commercial "member pass" (rotating QR, gym name, status) | B: no pass until commerce exists | **Proposed choice.** Needs the R6 design change |
| D-G20 | Abandoned draft gyms | Keep drafts indefinitely in MVP. Show them only to their owner; the owner can discard a draft explicitly. Account deletion removes the user's drafts. Automatic expiry waits for a retention policy | B: automatic deletion after N days (SF-82's original "30 days", **not approved**); C: reminder e-mails (E04) followed by deletion | **Proposed choice.** No automatic deletion until a retention period is approved. A draft has no members, staff or schedule, so keeping it costs little |
| D-G21 | Onboarding step redistribution | Four phases: account → **create gym** (required: name, type, first location) → **optional setup** (branding and other available items) → **post-registration checklist**. Unavailable steps are shown as "coming later", never required ([03 §3](03-registration-workspace-lifecycle.md)) | B: keep the 14-step wizard and skip unavailable steps; C: create-gym only, with no setup or checklist | **Proposed choice.** It keeps the 14 steps as the product journey without blocking creation |
| D-G22 | Staff-invitation entry on web and mobile | Web `/invite/staff#token=sfs_…` (fragment, like SF-60). On mobile, a **token-free** `/invite/staff` link mapped to a signed-in "staff invitations" inbox matched by verified email (SF-73/SF-80 pattern). Retire the `/invite/staff/:token`, `/invite/staff/:token/confirm` and `/invite/coach/:token` path-token routes | B: token in the mobile path (current placeholders); C: token in the mobile fragment (rejected by SF-80: Expo Router copies it into navigation state) | **Proposed choice.** Same security as SF-80. No live links break, because no staff or INV2 link has ever been sent ([07 §6](07-routing.md)) |
| D-G23 | Console UI URLs | Keep `D-WORKSPACE-NOT-IN-URL`: id-free console paths, a client-held active gym and the last choice remembered on the server | B: gym id in console URLs (`/app/gyms/:gymId/members`) | **Proposed choice now**, with B kept open for deep links from emails and push. Either option is safe because the API always carries the id |
| D-G24 | UI treatment of a 403 in the gym console | The backend keeps 403 for staff who lack a permission. The console shows a "your role can't do this" state instead of route-architecture rule 9's not-found | B: follow rule 9 (403 rendered as not found) | **Proposed choice.** The staff member already knows the gym exists; rule 9 would mislead. Needs a route-architecture amendment |
| D-G25 | Creation limits | At most 1 draft and 3 owned gyms per user, plus a rate limit | B: no limits; C: limits by plan (needs `D-G09`) | **Proposed choice.** Anti-abuse without depending on a plan |
| D-G26 | Owner account deletion and gym retention | Account deletion is refused while the user is an active owner; they must transfer first. Closure and retention periods are a future product/legal decision | B: deleting the owner closes the gym automatically | **Proposed choice.** B would end every member's and staff member's access as a side effect. The account-deletion API itself does not exist yet ([09 §3](09-dependency-matrix.md)) |

## 4. Conflicts with approved documents

These need amendments in the implementing tickets. SF-82 changes none of
them.

| Document | Current text | Required change | Ticket |
| --- | --- | --- | --- |
| `route-architecture.md` §7 | The active workspace is "session context held by the backend session" | Client-held active gym; the last choice is remembered by the backend; every Gym API request carries `gym_id` (`D-G15`, `D-G23`) | SF-85 |
| `route-architecture.md` §8 rule 9 | 403 and 404 both render not found | Gym console exception for 403 (`D-G24`) | SF-85 |
| Route registry | Member gym routes require `FIGHTER` | Account level (`D-G07`) | SF-91 |
| Route registry | `/invite/coach/:token` (INV2), `/invite/staff/:token`, `/invite/staff/:token/confirm` | Token-free entries (`D-G22`) | SF-87 |
| Claude Design | R1–R11 | [12](12-design-reconciliation-plan.md) | per screen |
