# 09 — Public Gym Publication release gate

**Verdict on 2026-11-06: NO-GO (BLOCKED).** Independent of the Operational Gym MVP and
Commercial Payments verdicts in [SF-104](../../../release/sf-104-gym-release-acceptance.md).

A successful onboarding, a Stripe payment or a business verification doesn't satisfy any row.

| Requirement | Evidence today | Status |
| --- | --- | --- |
| Approved publication policy | This proposal only | **BLOCKED**: founder |
| Legal and privacy prerequisites | [Checklist](07-legal-checklist.md) not started | **BLOCKED**: counsel |
| Trusted operator authority | Production authority is `Disabled` | **BLOCKED**: SF-110 |
| Verified gyms can exist in production | No one can decide an application | **BLOCKED**: SF-110 |
| Approved public fields | [Proposal](03-public-field-matrix.md) | Not approved |
| Owner controls | None built | Not built |
| Moderation and revocation | None built; no staff named | Not built |
| Production public API | None; OpenAPI has no public gym path | Not built |
| Production public UI | Placeholders and tagged examples | Not built |
| Cache and search safety | No cache or search exists; rules proposed | Not built |
| End-to-end security | Cases defined only | Not run |
| Reconciled design | 14 conflicts, new boards needed; canvas not changed | Not done |

**Today's state, confirmed:** `publication.status` is always `unavailable`; no public gym route
or endpoint exists; E05 isn't triggered; nothing shows a gym as published or verified to the
public. The tagged examples on L5 are marketing, not gyms.

## Decisions needing the founder

Ordered so that each unblocks the next.

| # | Decision | Recommendation |
| --- | --- | --- |
| 1 | Should public gym pages be built at all, and when? | Not before the operational pilot has run |
| 2 | Is verification required to publish? (D-G11.1) | Yes |
| 3 | Is operator approval required for each publication? (D-G11.2) | Yes, at least during the pilot |
| 4 | First release scope (D-G11.4, .7, .8) | A direct-link page with minimal fields, `noindex`, no listing |
| 5 | Which market first, and who is the legal entity? (D-G11.5) | Poland as a candidate, for counsel to confirm |
| 6 | Engage counsel on [the checklist](07-legal-checklist.md) | Before any further build |
| 7 | When does SF-110 get scheduled? | It blocks verification and billing commands too |
| 8 | Who staffs review and reports? | Name a person before activation |
| 9 | Reverification period (D-G11.14) | 12 months |
| 10 | Keep `approved_unpublished` or `rejected`? ([02 §3](02-lifecycle-and-permissions.md)) | Drop the first, keep the second |
| 11 | Canvas capacity: the design is at its file limit | Decide where new boards live before design work starts |

## What would change the verdict

GO needs every row above evidenced by T12 in the [roadmap](08-implementation-roadmap.md), plus
explicit approval. A conditional GO for a small invited pilot could be considered once the
blocked rows clear; it can't be granted while any BLOCKED row remains.
