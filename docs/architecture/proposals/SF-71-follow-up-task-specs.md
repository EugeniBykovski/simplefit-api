# SF-71 — Follow-up task specifications (T-1 – T-5)

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Separate Jira tasks proposed by SF-71 (policy PRODUCT_APPROVED 2026-10-19,
legal approval pending). No Jira issue was created or changed; ticket numbers
are assigned when the product owner files them. Before filing, check for
existing issues: ADR 0004 and ADR 0014 already refer to an unnumbered
"account deletion ticket" (Apple token revocation), and web/mobile deletion
routes exist as placeholders (`web.account.pending-deletion`,
`mobile.settings.delete`, SF-32/SF-33). T-3 extends that work if it exists.

SF-72: [implementation-readiness specification](SF-72-legal-document-integration-spec.md).

## Dependency graph

```text
                   ┌──────────────────────────── counsel approval (Q-01–Q-18)
                   │                              operator facts
                   ▼
SF-72 part A ──► SF-72 part B ──┐
   │   ▲                        │
   │   └── T-1 pages (URLs) ◄───┤ (B2/B7 need T-1; T-1 needs SF-72 A2 + getLegalDocument)
   │                            │
   ├──► T-2 retention ──────────┤ (needs SF-72 A5 evidence table)
   ├──► T-3 account deletion ───┤ (needs SF-72 A5; reuses T-2 deletion functions)
   │                            │
T-4 gate-off management ────────┤ (independent; can start now)
                                ▼
                     PUBLIC ACTIVATION (checklist §2)

T-5 disclosure renewal ──► only before any scope wider than basic_profile
```

Launch-blocking: SF-72 (A+B), T-1, T-2, T-3, T-4, counsel approval,
operator facts. Not launch-blocking: T-5 (until scope expansion).

---

## T-1 — Public legal pages and global Terms / Privacy Notice

| | |
|---|---|
| Decisions | L-12, L-15, L-11, L-10 |
| Repos | platform (pages), api (`getLegalDocument` from SF-72, consent versions) , mobile (links) |
| Can start | Engineering now with draft fixtures (dev only); publication blocked on counsel and operator facts |

**Scope**

1. Web routes in the existing localized architecture (`localePrefix:
   "always"`), `(site)` group, public, no auth:
   `web.legal.document` `/[locale]/legal/[documentId]` (current) and
   `web.legal.document-version` `/[locale]/legal/[documentId]/[version]`
   (immutable archive). Registered in `src/shared/routes/web-routes.ts` and
   `docs/route-registry.json`.
2. Content from `getLegalDocument` (server-rendered HTML from the approved
   Markdown); never from `messages/*` (F-14). `hreflang` only for approved
   variants.
3. Missing variant: canonical English shown **for reading** with a notice in
   the page locale; no machine translation.
4. Draft documents: never served outside dev; a DRAFT banner in dev.
5. Footer and settings links (`web.app.settings.data`,
   `mobile.settings.privacy`) point to the pages.
6. Terms and Privacy Notice: register approved versions, switch
   `Consents.current_versions` from `terms-v1` / `privacy-v1` to registry
   versions (SF-72 B7), using the existing re-acceptance behaviour of
   ADR 0016.
7. Canonical URLs written into the registry when pages are live (SF-72 B2).

**Tests:** route registry checks, SSR snapshot per state (current, archive,
English-only notice, 404 for unknown/unpublished), accessibility (headings,
contrast, screen-reader text), no auth required, cache headers immutable for
archive URLs.

**Blocked for publication by:** counsel approval of texts (L-15, Q-12),
operator facts, L-11 per market.

---

## T-2 — Retention and deletion enforcement

| | |
|---|---|
| Decisions | L-05, L-06, L-07, L-08 |
| Repos | api |
| Can start | Engineering now with the product-approved PROPOSED values, **disabled by default**; enabling in production requires counsel confirmation (Q-07 – Q-09) |

**Scope**

1. Oban cron worker `SimpleFit.Coaching.RetentionWorker` (daily),
   idempotent, batch-limited, telemetry with counts only.
2. Invitations (retention policy §2.1 triggers): resolved + 30 days → null
   `recipient_sealed`, `message`, `token_hash`; resolved + 90 days → delete
   row. Pending rows untouched.
3. Ended relationships: `ended_at` + 12 months → delete row (stub and both
   name snapshots). Changes SF-56 behaviour: ADR 0021 amendment and copy
   ("kept for 12 months") in the same task, only after counsel confirms the
   period.
4. Evidence (`legal_evidence`): delete after the counsel-approved period from
   relationship end or account deletion; **no default period** — the worker
   skips evidence until a period is configured.
5. Periods are code constants changed by reviewed commits (not env), each
   annotated "PROPOSED — pending legal review" until approved.
6. Config `retention_enabled: false` by default; on only after approval.
7. Erasure helpers (name snapshot replacement, invitation address removal)
   exposed for T-3 and for support-handled objections.

**Tests:** each trigger boundary (day 29/30, 89/90, 12 months), pending
untouched, idempotency, evidence untouched without a period, telemetry
without personal data, disabled flag = no deletes.

---

## T-3 — Account deletion and erasure workflow

| | |
|---|---|
| Decisions | L-09, L-08, L-05 |
| Repos | api, platform, mobile |
| Can start | Design and engineering now; evidence exception wording and periods pending counsel; grace-period length is an **open product question** (the `pending-deletion` route implies one) |

**Scope (api)**

1. Request deletion (authenticated, recent re-authentication); state
   `pending_deletion` for the grace period, then a deletion job.
2. Deletion job, in this order, one transaction per step, idempotent:
   * end every active coach–fighter relationship (both roles) through the
     SF-56 end path, so access stops at once;
   * replace the deleted person's name snapshot in every counterparty stub
     with a neutral label ("Deleted user");
   * remove the deleted fighter's address from invitations addressed to any
     of their verified emails (`recipient_sealed` → null), delete their
     pending invitations;
   * delete the coach's own invitations;
   * delete profiles, identities, sessions, consents; revoke Apple tokens
     (ADR 0014);
   * keep `legal_evidence` rows (no FK) under the documented exception;
   * delete the `users` row last.
3. **No cross-user cascade:** a migration changes
   `coach_fighter_relationships` foreign keys to the coach and fighter
   profiles from `ON DELETE CASCADE` to `ON DELETE SET NULL` (nullable
   columns) so the counterparty's stub survives; ended rows then follow T-2.
4. Backups: deletion log (ids only) replayed after any restore.
5. Support procedure for non-users (invited addresses) and objections.

**Scope (web/mobile):** wire the existing placeholder screens (settings
delete, confirm, `account/pending-deletion`), explain what is deleted, what
is kept and for how long (text from the approved Privacy Notice).

**Tests:** both roles, counterparty stub survives with the neutral label,
evidence survives, addresses removed, no orphan access, re-run safety,
OpenAPI.

---

## T-4 — Gate-off coach relationship management

| | |
|---|---|
| Decisions | L-16, F-08 |
| Repos | api, platform, mobile |
| Can start | Now (product decision only) |

**Scope**

1. New `listMyCoachManageableRelationships`
   (`GET /api/v1/me/coach/relationships/manageable`), available whatever the
   gate says, returning only active relationships:
   `{relationship_id, started_at, fighter_label}`.
2. `fighter_label` = the fighter's display name **only if** the relationship's
   disclosure version is still configured (the fighter authorised it);
   otherwise a neutral label ("Fighter") — no new field, no profile data, no
   other C1/C2 field, no invitation data.
3. Ending uses the existing gate-independent
   `endMyCoachFighterRelationship`.
4. Web and mobile: a minimal "Manage connections" list shown when the roster
   answers `404`, with an End action and confirmation.
5. Operator bulk revocation (checklist §3.2) is a separate runbook item,
   designed with the Q-18 policy.

**Tests:** gate off and on, ended relationships excluded, foreign coach
`404`, no fields beyond the three, withdrawn version → neutral label.

---

## T-5 — Disclosure renewal (only when sharing scope expands)

| | |
|---|---|
| Decisions | L-13 |
| Repos | api, platform, mobile |
| Can start | Not before a wider scope is proposed, analysed (Art. 9 if C3/C4) and approved |

**Scope**

1. Coach (or system) requests renewal to a specific approved disclosure
   version for an existing relationship; one open request per relationship.
2. Fighter sees the new version's text (approved language rule), accepts
   with an unticked checkbox and version/language echo, or declines.
3. Acceptance updates the relationship's authorised version **in place**
   (same `relationship_id`, `started_at`, history), appends a history row
   (`relationship_disclosures`: version, accepted_at) and writes
   `legal_evidence`.
4. Until accepted, the old scope stays; declining or ignoring changes
   nothing; the coach cannot force it; ending remains available.
5. Lifts the SF-72 scope-widening guard only for versions reachable through
   renewal.

**Tests:** identity and history preserved, old scope until acceptance,
evidence written, decline no-op, multi-account isolation.
