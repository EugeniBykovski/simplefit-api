# SF-139 — Gym public publication: policy proposal and design gate

**Status: PROPOSED. Nothing in this package is approved, and nothing here is built.**
Epic SF-81. Publishing half of [`D-G11`](../SF-82-gym/10-decision-register.md).

SF-139 is decision, architecture and design work only:

* no route, endpoint, migration, OpenAPI change, UI or flag;
* no change to the route registry or to Claude Design;
* no Jira ticket created.

**Public Gym Publication is NO-GO** ([release gate](09-release-gate.md)). A gym keeps
operating privately whatever happens to this proposal.

## Summary

Publication should be a **fourth, separate fact** about a gym, next to setup,
business verification and billing. Its own record, an explicit owner request and an
explicit decision by a trusted operator. Verified does not mean published.

What the public sees should be an **approved snapshot** of explicitly allowed fields,
never a projection of the private gym row. Public reads should check eligibility on
the server on every request and fail closed.

The largest dependency is outside this package: **no authority can approve anything in
production until SF-110 exists**, and the legal gates below aren't started.

## Documents

| Doc | Content |
| --- | --- |
| [01 Decision proposal](01-decision-proposal.md) | The 15 publishing decisions (D-G11.1–D-G11.15), with defaults, alternatives, owners and status |
| [02 Lifecycle and permissions](02-lifecycle-and-permissions.md) | Existing domain, three lifecycles, publication states and transitions, owner and operator permissions, withdrawal, suspension, revocation |
| [03 Public field matrix](03-public-field-matrix.md) | Field allowlist, never-public list, coach and staff visibility, badge semantics |
| [04 Design and artboard inventory](04-design-artboard-inventory.md) | Screen inventory, conflicts with policy, missing boards, design handoff |
| [05 Routes, API, search and cache](05-routes-api-search-cache.md) | Route topology, domain and API proposal, search, SEO and cache rules |
| [06 Security and moderation](06-security-and-moderation.md) | Invariants, race and leak cases, moderation, SF-110 dependency |
| [07 Legal and jurisdiction checklist](07-legal-checklist.md) | Questions for counsel; no legal conclusions |
| [08 Implementation roadmap](08-implementation-roadmap.md) | Twelve task proposals in dependency order |
| [09 Release gate](09-release-gate.md) | The independent GO/NO-GO and the decisions needing the founder |

## How to read the status words

| Word | Meaning here |
| --- | --- |
| APPROVED | Already decided, and the evidence is cited |
| PROPOSED | A recommendation from this package. **Not a decision** until the named owner takes it |
| DEFERRED | Deliberately later than the first release |
| BLOCKED | Can't be decided or done until a named dependency exists |

Recommendations here come from engineering analysis. None is founder or legal approval.

## Baseline

Read on 2026-11-06: api `86bfed0`, platform `a4c4b1b`, mobile `d248076` (SF-137 and SF-138
merged), Claude Design version `1793198527-a0fc`.
