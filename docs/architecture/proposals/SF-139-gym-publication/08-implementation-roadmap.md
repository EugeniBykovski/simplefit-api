# 08 — Implementation roadmap

**Proposals only. No Jira ticket has been created, and none is authorized by this document.**
Sizes are rough. Each task keeps the guardrails in [06](06-security-and-moderation.md).

## Order

```
T1 policy ─┬─ T2 field contract ─┬─ T3 lifecycle ─┬─ T4 operator review (needs SF-110)
           │                     │                ├─ T5 public read API ─┬─ T9 web page
           │                     │                │                      ├─ T10 mobile page
           │                     │                │                      └─ T6 discovery API
           │                     │                ├─ T7 owner controls
           │                     │                └─ T8 operator UI (needs SF-110)
           └─ legal checklist                     T11 SEO and cache ── T12 acceptance
```

T1 and SF-110 are the true blockers. T3 can be built and tested with the existing test-only
authority pattern, and stays unreachable in production.

## Tasks

### T1 Public publication policy approval

* **Scope:** founder and counsel decide D-G11.1–15; register updated. **Repository:** api (docs).
* **Depends on:** this package. **Boards:** —.
* **Acceptance:** each decision APPROVED or rejected, with who and when; mandatory legal items signed off.
* **Guardrail:** nothing proceeds to production on PROPOSED decisions. **Blocks release:** yes.

### T2 Public field and privacy contract

* **Scope:** final allowlist, never-public list, exact DTO, attestation text. **Repository:** api (docs, OpenAPI draft).
* **Depends on:** T1. **Boards:** PG1, MK5, WG8.
* **Acceptance:** counsel-reviewed field matrix; DTO keys fixed.
* **Guardrail:** no field without a basis. **Blocks release:** yes.

### T3 Backend publication lifecycle and audit

* **Scope:** tables, triggers, context, permissions, events, owner API; closure state or its explicit handling. **Repository:** api.
* **Depends on:** T1, T2. **Boards:** —.
* **Acceptance:** every transition and race in [06 §2](06-security-and-moderation.md) has a real-commit test; `mix quality`; OpenAPI regenerated; rollback documented.
* **Guardrail:** no public read; no production approver. **Blocks release:** yes.

### T4 Trusted operator review integration

* **Scope:** publication permissions in the authority; review functions; independence checks; attribution. **Repository:** api.
* **Depends on:** **SF-110**, T3. **Boards:** PO1–PO3.
* **Acceptance:** production compile guard holds for non-trusted backends; impersonation cases fail.
* **Guardrail:** no interim authority. **Blocks release:** yes.

### T5 Public gym read API

* **Scope:** `getPublicGym`, eligibility predicate, rate limits, reports endpoint. **Repository:** api.
* **Depends on:** T3, T2. **Boards:** PG1, PG2.
* **Acceptance:** exact-keys and canary tests; uniform 404; compile-time or config gate defaults off.
* **Guardrail:** off by default; country allowlist empty. **Blocks release:** yes.

### T6 Gym discovery and search API

* **Scope:** `listPublicGyms`; filters; cursors. **Repository:** api.
* **Depends on:** T5, D-G11.7. **Boards:** MK4, L5.
* **Acceptance:** same predicate as detail; no enumeration signal.
* **Guardrail:** no ads, no paid ordering. **Blocks release:** not the first release.

### T7 Owner publication controls

* **Scope:** profile editor, status panel, request, withdraw, republish, notices. **Repository:** platform.
* **Depends on:** T3, new boards PP1–PP6. **Boards:** WG8, OG14.
* **Acceptance:** all states; keyboard and screen reader flows; truthful copy; E05 replaced.
* **Guardrail:** no "published" unless the backend says so. **Blocks release:** yes.

### T8 Operator moderation controls

* **Scope:** queue, review, suspend, reinstate, revoke, reports. **Repository:** platform, api.
* **Depends on:** T4, boards PO1–PO4, AD4. **Boards:** PO1–PO4.
* **Acceptance:** permission on every action; history visible; stale revision handled.
* **Guardrail:** the admin shell alone isn't authority. **Blocks release:** yes.

### T9 Web public gym page

* **Scope:** `/g/:gymSlug`; registry entry; not-found; report action. **Repository:** platform.
* **Depends on:** T5, boards PG1–PG3. **Boards:** PG1–PG3.
* **Acceptance:** server-rendered from the DTO only; `noindex`; geometry and a11y suites; suspended page gone on next load.
* **Guardrail:** no client-side hiding. **Blocks release:** yes.

### T10 Mobile public gym page

* **Scope:** shared route, links, retire `/marketplace/gym/:gymId`. **Repository:** mobile.
* **Depends on:** T5, PG1m, PG2m. **Boards:** MK5, PG1m.
* **Acceptance:** native evidence on iOS and Android, if Android is in scope.
* **Guardrail:** no FighterProfile required. **Blocks release:** founder's call.

### T11 SEO, indexing and cache invalidation

* **Scope:** robots, sitemap, metadata, canonical, removal runbook; cache only if justified. **Repository:** platform, api.
* **Depends on:** T9, D-G11.8. **Boards:** —.
* **Acceptance:** canary test on the HTML head; sitemap equals the eligibility query; measured removal time.
* **Guardrail:** `noindex` until decided. **Blocks release:** the indexing step only.

### T12 End-to-end publication security and release acceptance

* **Scope:** full journey and negatives on real infrastructure; release document. **Repository:** all.
* **Depends on:** all of the above. **Boards:** all.
* **Acceptance:** [release gate](09-release-gate.md) evidence complete.
* **Guardrail:** no fixture authority counted as evidence. **Blocks release:** yes.

Also needed, outside the twelve: a **gym closure state**, and a **legal document** set for
publication. Both are prerequisites, and neither has a ticket.
