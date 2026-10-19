# SF-71 — Consent, acknowledgement lifecycle, versioning, publication and localization

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71. Covers brief §6, §10 and §11. Policy PRODUCT_APPROVED
2026-10-19 (L-10 – L-13); legal statements PROPOSED_PENDING_LEGAL_REVIEW.
Implementation: [SF-72](../../architecture/proposals/SF-72-legal-document-integration-spec.md).
Today's facts:
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

## 2. Lifecycles (as implemented; gate on; SF-72 additions marked)

**Coach.** CoachProfile completed → reads current Data Rules → ticks the
unticked box → `POST /me/coach/data-rules/acknowledge {document_version}` →
server checks the version equals the configured one (old → `409 stale`) and
appends the record → invitation creation becomes eligible.

**Fighter.** Invitation link (token in fragment) → anonymous preview (coach,
note, expiry, current disclosure) → sign-in with a verified email identity of
the invited address → account registration (Terms, Privacy, age ≥ 16) →
fighter onboarding → review of the current disclosure (*SF-72: approved
variant in the app language, else "not available in your language"*) →
ticks the unticked box → accept with the echoed version (*SF-72: and
language*) → server verifies binding, version, prerequisites (*SF-72: age
18+, language*); activates, consumes (*SF-72: writes evidence*) in one
transaction.

**Termination / withdrawal.** Active → coach or fighter ends (gate
independent) → live access revoked in the same transaction (withdrawal of
consent if consent is the basis, L-02) → stub with name snapshots (SF-56) →
retention policy applies (not implemented yet, F-03, T-2). Turning the gate
off is **not** termination (checklist §3.1).

## 3. Audit evidence (minimum)

| Evidence | Fields | Not collected |
|---|---|---|
| Coach acknowledgement | coach profile id, document version, server timestamp | IP, device, user agent, text copy |
| Fighter acceptance | fighter (via relationship / invitation binding), coach profile, document version, server timestamp, invitation id, relationship id | IP, device, user agent |
| Termination | relationship id, side, timestamp | reason |
| Document | id, version, language, content hash, effective date, approval record | — |

Proposal: keep the current minimal evidence (no IP or fingerprint: not needed
to prove a version-specific action by an authenticated account). Because the
evidence lives on rows deleted with the counterparty (F-04), L-08 proposes
separate, append-only evidence records with their own lifecycle
([retention policy](SF-71-retention-policy.md) §7), including the language of
the accepted text.

## 4. Version rollover and disclosure renewal (L-13)

### 4.1 Data Rules (coach)

| Question | Proposal |
|---|---|
| Material change | Any change that widens what coaches may do, adds obligations or sanctions in substance, or changes the controller. Decided by product and counsel, never by engineering |
| Old acknowledgements | Remain valid evidence for their version; a coach acknowledges the new version before inviting or resending again (implemented: `409 data_rules_acknowledgement: required`) |
| Existing relationships | Continue; coaches are informed of the change |

### 4.2 Fighter disclosure — MVP policy

1. **Fixed authorized scope.** Every relationship stays limited to the fields
   authorized by the disclosure version its fighter accepted (implemented:
   `disclosure_version` per relationship; a later version never widens it).
2. **No expansion without new explicit fighter authorization.** Neither a
   configuration change nor a new version may add fields to an existing
   relationship.
3. **Wider scopes stay disabled.** A disclosure version whose scope is wider
   than `basic_profile` must not be configured as current until an approved
   renewal operation exists (T-5). SF-72 enforces this at boot through the
   registry (a scope-widening version is rejected while no renewal operation
   is registered).
4. **Not the re-consent mechanism:** ending a relationship and sending a new
   invitation. It loses relationship identity and history and is not offered
   as the way to authorize more data.
5. **Future renewal operation (T-5, design only).** In-product request to the
   fighter for a specific new version on the **same relationship**: same
   relationship id, history and start date; new acceptance evidence (§3,
   L-08); the old scope stays in force until the fighter accepts; declining
   or ignoring changes nothing; the coach cannot force or pre-tick it.
6. **Narrowing** (fewer fields) applies at once to all relationships under
   the affected version, **with** the approved user notice (fighter and
   coach) issued at the same time.
7. **Emergency withdrawal** of a version (e.g. a defect in the text): only
   under an approved notification and revocation policy that states what
   stops, who is told, and whether the relationships end or continue under a
   narrower version. Silent removal from `COACHING_DISCLOSURES` (F-11) is
   not permitted as a procedure.
8. **Temporary shutdown** uses the gate, not version removal (checklist §3).

### 4.3 Availability

| Question | Proposal |
|---|---|
| Documents unavailable | Fail closed: no current version → preview, create, accept answer `404` (implemented); boot fails if a configured version is not in the registry (SF-72) |
| Old version silently treated as current | Prevented: current = configured; acceptance must echo it; SF-72 registry check; changing the current version is a configuration change reviewed like code |

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
* **Missing translation:** the canonical English text may be shown **for
  reading**, with a notice in the user's language that the document is
  available in English only; never machine translation presented as
  approved. Counsel decides whether a market may launch without its language
  (proposal: no activation in a market without an approved variant in its
  official language).
* **Ownership:** product owns drafting; counsel approves; professional
  translation with legal review; engineering only publishes approved files.
### 7.1 Acceptance only with an understood approved text

English fallback for reading never authorises acceptance by itself.

* Acceptance (fighter) or acknowledgement (coach) is offered only when an
  approved variant of the current version exists in (a) the user's app
  language, or (b) a language the user explicitly chose for legal documents
  from the approved variants (for example English), after a plain statement
  in the app language that the document is available only in that language.
* Otherwise the flow ends in a safe **"not available in your language"**
  outcome: nothing is shared, the invitation stays pending until it expires,
  the coach sees only "pending", and the fighter is told why.
* The acceptance evidence records the language of the text accepted (§3,
  L-08).
* Whether option (b) yields informed acceptance in a given market is a
  counsel question (Q-17); until answered, only (a) is enabled.

* Accessibility: the text is HTML (not images or PDF only), readable by
  screen readers, plain language (GDPR Art. 12(1)).
