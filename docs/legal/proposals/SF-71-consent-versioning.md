# SF-71 — Consent, acknowledgement lifecycle, versioning, publication and localization

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71. Covers brief §6, §10 and §11. Today's facts:
[integration contract](../../architecture/proposals/SF-71-coaching-legal-integration-contract.md).

## 1. Separate decisions, never one flag

| Decision | Who | Where recorded today | Version-checked | Inferred from anything else? |
|---|---|---|---|---|
| Terms of Service acceptance | every user | `account_consents` (`terms`, version) | yes (`terms-v1`) | no |
| Privacy Notice acknowledgement | every user | `account_consents` (`privacy`, version) | yes (`privacy-v1`) | no |
| Product news | every user, optional | `account_consents` (`product_news`) | no | no |
| Coach Data Rules acknowledgement | coach | `coach_data_rules_acknowledgements` | yes | no (not from registration, coach profile or Terms) |
| Fighter data-sharing acceptance | fighter, per coach | `coach_invitations.accepted_disclosure_version` + `coach_fighter_relationships.disclosure_version` | yes (stale → `409`) | no (not from preview, sign-in, registration) |
| Relationship termination | either side | `coach_fighter_relationships.ended_at/ended_by` | n/a | — |
| Withdrawal / objection | fighter | ending the relationship (per coach); account-level requests manual today | — | — |

A coach acknowledgement is never fighter consent; a fighter acceptance never
implies account-level consent and vice versa.

## 2. Lifecycles (as implemented; gate on)

**Coach.** CoachProfile completed → reads current Data Rules → ticks the
unticked box → `POST /me/coach/data-rules/acknowledge {document_version}` →
server checks the version equals the configured one (old → `409 stale`) and
appends the record → invitation creation becomes eligible.

**Fighter.** Invitation link (token in fragment) → anonymous preview (coach,
note, expiry, current disclosure) → sign-in with a verified email identity of
the invited address → account registration (Terms, Privacy, age ≥ 16) →
fighter onboarding → review of the current disclosure → ticks the unticked
box → accept with the echoed version → server verifies binding, version,
prerequisites; activates and consumes in one transaction.

**Termination.** Active → coach or fighter ends → live access revoked in the
same transaction → stub with name snapshots → retention policy applies
(retention not implemented yet, F-03).

## 3. Audit evidence (minimum)

| Evidence | Fields | Not collected |
|---|---|---|
| Coach acknowledgement | coach profile id, document version, server timestamp | IP, device, user agent, text copy |
| Fighter acceptance | fighter (via relationship / invitation binding), coach profile, document version, server timestamp, invitation id, relationship id | IP, device, user agent |
| Termination | relationship id, side, timestamp | reason |
| Document | id, version, language, content hash, effective date, approval record | — |

Proposal: keep the current minimal evidence (no IP or fingerprint: not needed
to prove a version-specific action by an authenticated account). Because the
evidence lives on rows deleted with the counterparty (F-04), L-08 proposes a
fighter-owned acceptance record with its own retention.

## 4. Version rollover (product/legal decisions, L-13)

| Question | Proposal |
|---|---|
| Material change | Any change that widens shared data, adds a recipient category or purpose, changes retention to the detriment of the user, changes the controller, or changes rights or obligations of coaches in substance. |
| Old acknowledgements | Remain valid evidence for their version; a coach must acknowledge the new Data Rules version before inviting again. |
| Existing relationships after a disclosure change | Keep their accepted version (already enforced). A narrowing change applies at once; a widening change needs a new acceptance per relationship (new invitation or an in-product re-accept flow, SF-72 decision). Users get a notice of any material change. |
| Documents unavailable | Fail closed: no current version → preview, create, accept answer `404` (implemented); boot fails if a configured version is not in the registry (SF-72). |
| Old version silently treated as current | Prevented: current = configured; acceptance must echo it; SF-72 registry check; changing the current version is a configuration change reviewed like code. |
| Withdrawing a version | Only together with a notice to affected users, since withdrawn versions disclose nothing (F-11). |

## 5. Document version contract (L-10)

* **Document id:** stable kebab-case: `fighter-coach-disclosure`,
  `coach-data-rules`, `privacy-notice`, `terms-of-service`.
* **Version id:** `<document-id>-<YYYY>-<MM>-<seq>`, assigned **only at
  approval**; a version id is never reused and its approved text never
  changes (non-material fixes: new content hash + changelog, same id, L-13).
  Draft states use `<document-id>-DRAFT-<n>` and are rejected by the
  production registry.
* **Business version ≠ software release:** the version id never contains an
  app or API version; documents change on their own approval cycle.
* **Registry record:** id, version, status (`draft` / `approved` / `published`
  / `superseded`), languages, effective date, publication date, canonical
  source (repository path of the approved text), canonical URL, content
  SHA-256 per language, approvers and approval date.
* **Runtime mapping:** `COACHING_DISCLOSURES` → approved
  `fighter-coach-disclosure` versions (first = current);
  `COACHING_DATA_RULES_VERSION` → approved `coach-data-rules` version;
  `SimpleFit.Accounts.Consents.current_versions` → approved `terms-of-service` /
  `privacy-notice` versions. All fail closed when absent.

The 64-character `[A-Za-z0-9._-]` constraint of today's configuration fits
this convention. No version is assigned by SF-71.

## 6. Publication surfaces (verified routes)

| Surface | Route (registry) | Status today |
|---|---|---|
| Fighter web invitation review | `web.invite.coach` `/invite/coach` | implemented (SF-60); disclosure list, no link to full text |
| Fighter web coaches | `web.app.coaches` `/app/coaches` | implemented (SF-60) |
| Coach web roster + invite | `web.app.coach.fighters` `/app/coach/fighters` (SF-58) | invite blocked; no acknowledgement step (F-07) |
| Coach mobile invite | `mobile.coach.fighters` (SF-61) | acknowledgement step, no link to full text |
| Fighter mobile coaches | `mobile.profile.coaches` `/profile/coaches` (SF-59) | implemented; mobile acceptance happens on web |
| Email E08 | template `coach_invite` | interim copy; no privacy link (F-06) |
| Public legal pages | **none exist** (no `/terms`, `/privacy`, `/legal/*` route) | to be created (L-12) |
| Settings privacy / data / deletion | `mobile.settings.privacy`, `mobile.settings.data`, `mobile.settings.delete`, `web.app.settings.data` | placeholders |

Proposal (L-12): public, unauthenticated, versioned pages on the web app,
`/<locale>/legal/<document-id>` (current) and
`/<locale>/legal/<document-id>/<version>` (archive), owned by product
with counsel approval; apps link to them. URLs are **to be assigned**; none
are created by SF-71.

## 7. Localization (L-11)

Product locales: `en` (default), `pl`, `ru`, `uk`, `de`, `es` (+ `es-MX`
product copy variant), `fr`.

* **Canonical legal language:** English (proposal), with **Polish** reviewed
  by Polish-qualified counsel before any activation in Poland.
* **One version id covers all language variants** of the same approved
  meaning; each language has its own content hash and approval record. A
  language variant without approval is not published.
* **Missing translation:** show the canonical English text with a notice in
  the user's language that the document is available in English only; never
  machine translation presented as approved. Counsel decides whether a
  market may launch without its language (proposal: no activation in a
  market without an approved variant in its official language).
* **Ownership:** product owns drafting; counsel approves; professional
  translation with legal review; engineering only publishes approved files.
* Accessibility: the text is HTML (not images or PDF only), readable by
  screen readers, plain language (GDPR Art. 12(1)).
