# SF-72 — Legal document integration: implementation-readiness specification

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

* Policy source: SF-71 decisions L-01 – L-16, **PRODUCT_APPROVED 2026-10-19**;
  legal approval pending for every legal text, basis and period
  ([decision register](../../legal/proposals/SF-71-decision-register.md)).
* Facts audited on `simplefit-api` `01d891e`, `simplefit-platform` `c426249`,
  `simplefit-mobile` `ff7bc7e`
  ([integration contract](SF-71-coaching-legal-integration-contract.md)).
* This is the canonical SF-72 specification. It changes nothing by itself.
  An ADR (proposed: ADR 0022 *Legal document registry and evidence*) is
  written as the first SF-72 step.

## 0. Invariants (must hold after SF-72)

1. Coach access stays exactly `basic_profile` = C1 + C2 (7 fields); no C3/C4
   field (including `weight_class`) enters any coach-facing projection.
   `Fighters.coach_visible_fields/0` and `Disclosure` scopes are unchanged.
2. The coaching gate stays **off** in every committed configuration
   (`access_enabled: false`, no disclosure, no Data Rules version).
3. No legal text, version id, URL or approval date is invented. Draft
   fixtures exist only in development and test and are visibly `draft`.
4. SF-56 termination and stub behaviour and SF-57 acceptance behaviour are
   unchanged except where §5–§7 say so explicitly.
5. Every new API change is additive, except the two request fields listed in
   §8.3, which the SF-72 ticket must authorise explicitly.

## 1. Work split

### A. Can start now (product-approved, no counsel output needed)

| # | Item | Section |
|---|---|---|
| A1 | ADR 0022 | — |
| A2 | Registry schema, loader, validation, fail-closed boot | §2 |
| A3 | Draft-state handling (dev/test fixtures only, prod rejects) | §2.4 |
| A4 | Binding configuration to the registry (`COACHING_DISCLOSURES`, `COACHING_DATA_RULES_VERSION`, account consents) | §3 |
| A5 | Evidence domain: table, writes in the same transaction, immutability | §4 |
| A6 | Server-side 18+ eligibility at acceptance | §5 |
| A7 | Scope-widening guard (L-13 MVP) | §6 |
| A8 | Language availability rule (app language only, §7.1 option (a)) | §7 |
| A9 | API: document references, language fields, errors; OpenAPI + clients | §8 |
| A10 | Web: Data Rules acknowledgement step; legal text rendered from the API (not message catalogs); 18+ and language outcomes | §9 |
| A11 | Mobile: render from the API, full-text link, language outcome | §9 |
| A12 | Product-copy accuracy fix F-09 ("dates only") | §9 |
| A13 | Tests | §10 |

### B. Requires approved legal decisions or documents

| # | Item | Blocked by |
|---|---|---|
| B1 | Registering approved texts (full, in-app summary, checkbox) per language, with version ids, hashes, effective dates, approvers | Counsel approval of L-03, L-04 texts; L-11 per market |
| B2 | Canonical URLs in the registry | T-1 pages live; L-12 assignment |
| B3 | E08 invitation privacy statement and link, operator identity in E08 | Q-06, Q-12, operator facts |
| B4 | Final checkbox wording (consent or alternative) | Q-02 |
| B5 | Retention periods inserted into the texts | Q-07, Q-08 |
| B6 | Enabling user-chosen-language acceptance (§7.1 option (b)) | Q-17 |
| B7 | Migrating `terms-v1` / `privacy-v1` to registry versions | T-1, L-15 |

### C. Production activation prerequisites (not SF-72 work)

Counsel approval recorded; approved versions registered; operator facts in
every text; T-1 (pages, Terms, Privacy), T-2 (retention), T-3 (deletion),
T-4 (gate-off management) live; notification and revocation policy approved
(Q-18); release validation (checklist §2); release decision per market.

## 2. Approved-document registry (L-10)

### 2.1 Storage

* New context `SimpleFit.Legal` (owns registry and evidence).
* Source of truth in the repository, code-reviewed:
  `priv/legal/registry.json` (metadata) and
  `priv/legal/documents/<document-id>/<version>/<language>/<part>.md`
  (text parts). Loaded and validated at boot into a persistent term; no
  database table for document text.
* Parts: `full` (all documents), `summary` and `checkbox` (disclosure and
  Data Rules; the in-app copy is part of the approved text, so it is never
  in a message catalog).

### 2.2 Record

| Field | Rule |
|---|---|
| `document_id` | One of `fighter-coach-disclosure`, `coach-data-rules`, `privacy-notice`, `terms-of-service` |
| `version` | `<document-id>-<YYYY>-<MM>-<seq>`; matches `^[A-Za-z0-9._-]{1,64}$`; unique, never reused |
| `status` | `draft` → `approved` → `published` → `superseded` / `withdrawn` (no way back) |
| `scope` | Disclosure only: a scope name known to `Disclosure` (today `basic_profile`) |
| `languages` | Map language → `{status, content_sha256, approved_by, approved_on, approval_ref}`; a language variant is usable only when `approved` |
| `effective_at`, `published_at` | Required from `approved` / `published` |
| `canonical_url` | Required from `published` (L-12 pattern); `null` before |
| `approved_by`, `approved_on`, `approval_ref` | Required from `approved`; product **and** counsel for legal texts |
| `changelog` | Non-material fixes (same id, new hash), each entry dated with its approval reference |

### 2.3 Validation (boot fails on any violation)

* Every `content_sha256` equals the SHA-256 of its files.
* An `approved`/`published` record has every approval field; an approved
  text never changes except through a `changelog` entry.
* Status transitions only forward; a version id appears once.
* Version id prefix equals `document_id`; production rejects `DRAFT` ids and
  `draft` records.

### 2.4 Draft handling

* `config :simple_fit, SimpleFit.Legal, allow_drafts: false` (default);
  `true` only in `config/dev.exs` and `config/test.exs`. Not an environment
  variable.
* With `allow_drafts: false`, configuration that selects a draft fails boot.
* Drafts carry `status: "draft"` in every API response; web and mobile show a
  visible DRAFT banner and never present the text as approved.
* Test fixtures use obviously fake ids (`fighter-coach-disclosure-DRAFT-1`)
  and placeholder text; they are not the SF-71 draft texts.

## 3. Runtime configuration bound to the registry

| Setting | Today | After SF-72 |
|---|---|---|
| `COACHING_DISCLOSURES` (`version=scope`, first = current) | Format check only | Each version must exist in the registry as `fighter-coach-disclosure` with status `approved`/`published` (or `draft` when allowed) and the **same scope**; the current one must be `published` (or `draft` when allowed) |
| `COACHING_DATA_RULES_VERSION` | Format check only | Must exist as `coach-data-rules`, `published` (or `draft` when allowed) |
| `Consents.current_versions` (`terms-v1`, `privacy-v1`) | Identifiers only | Unchanged in SF-72; migrated in T-1 (B7) |
| `COACHING_ACCESS_ENABLED` | `false` | Unchanged; enabling additionally requires both versions above (already required) |

Configuration only **selects**; it never defines text, scope or URLs.

## 4. Evidence domain (L-08)

### 4.1 Table `legal_evidence` (migration, reversible)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | — |
| `kind` | enum | `fighter_disclosure_acceptance`, `coach_data_rules_acknowledgement` |
| `subject_user_id` | uuid, **no FK** | Fighter (acceptance) or coach (acknowledgement) |
| `counterparty_user_id` | uuid, **no FK**, nullable | Coach user for an acceptance |
| `relationship_id`, `invitation_id` | uuid, **no FK**, nullable | Acceptance only |
| `document_id`, `document_version`, `document_language` | text | From the registry |
| `content_sha256` | bytea | Hash of the accepted language variant |
| `recorded_at` | utc_datetime_usec | Server time |

No names, email, IP, user agent, note or profile data. Indexes on
`subject_user_id` and `recorded_at`.

### 4.2 Rules

* Written inside the existing transaction of
  `Invitations.accept/3` (after activation) and of the Data Rules
  acknowledgement; any failure rolls back the action.
* `already_connected` acceptance writes no new evidence (nothing new was
  accepted); idempotent acknowledgement writes none either.
* Immutable: a database trigger rejects `UPDATE`; `DELETE` only through the
  retention and erasure functions of `SimpleFit.Legal` (T-2, T-3).
* No API endpoint reads it; included in a subject's access/export later.
* Existing columns (`accepted_disclosure_version`, relationship
  `disclosure_version`, `coach_data_rules_acknowledgements`) stay for
  operations and are not removed.
* Retention period: **not implemented in SF-72** (pending counsel, T-2).

## 5. Server-side 18+ eligibility (L-14)

* `SimpleFit.Coaching.Activation.activate/3` (the single activation
  chokepoint) checks the fighter's age on the server date: at least
  **18** (`@minimum_coaching_age 18`, a code constant; changing it is a
  product and legal decision through code review, not configuration).
* Uses the immutable `account_profiles.date_of_birth` and the same age
  computation as registration (`AccountProfile`, ADR 0016), shared rather
  than duplicated.
* Failure: the transaction rolls back; the invitation stays `pending` (so the
  coach sees only "pending" until expiry); the fighter may still decline.
* Error: `validation_error` with field `coaching_age`, field code
  `too_young`, details `minimum_age: 18` (additive field code).
* The coach never receives the reason, the age or the date of birth; the
  outcome is not emitted with personal data (telemetry reason tag only).
* Account registration stays 16+ (unchanged).

## 6. Disclosure version rollover (L-13 MVP)

* Existing relationships keep their accepted version and fields
  (implemented; unchanged).
* **Scope-widening guard:** boot fails if any configured disclosure version
  has a scope with more fields than the scope of an earlier registered
  `published` version, while no renewal operation exists (T-5). Today only
  `basic_profile` exists, so the guard is a no-op until a wider scope is
  added in code.
* No termination-and-reinvitation flow is added as renewal.
* Version withdrawal: the registry status `withdrawn` makes boot fail if the
  version is still configured without an explicit `withdrawal_notice_ref`
  (the approved notification policy, Q-18); this prevents silent removal
  (F-11). Removing a version from configuration still discloses nothing for
  relationships under it (existing behaviour); the runbook requires the
  notice first.
* Data Rules: a new current version requires re-acknowledgement before
  inviting (implemented, `409 data_rules_acknowledgement: required`).

## 7. Language availability (L-11)

* Acceptance and acknowledgement requests carry `document_language`.
* The server accepts only when the configured version has an approved
  variant in that language. The API has no locale header today, so the
  client contract is: web and mobile send their **current app locale** as
  `document_language` and request the preview / Data Rules text with
  `?language=<app locale>` — option (a). Offering another language for
  acceptance (option (b), user-chosen English) stays disabled until Q-17.
* Otherwise: `conflict` with details `document_language: "unavailable"`;
  nothing is shared; the invitation stays pending.
* `previewCoachInvitation` and `getMyCoachDataRules` accept `?language=` and list `available_languages` so the
  client can show the safe outcome before the checkbox.
* Evidence records the language (§4).

## 8. API contract (OpenAPI, additive unless noted)

### 8.1 Document reference object `LegalDocumentRef`

`{document_id, version, status, language, available_languages,
effective_at|null, canonical_url|null, content_sha256, parts: {summary,
checkbox, full_url|null}}` — `parts.summary` and `parts.checkbox` are the
approved texts in `language`, with `{coach}` / `{version}` placeholders filled
by the client.

### 8.2 Changed responses

| Operation | Change |
|---|---|
| `previewCoachInvitation` | `disclosure.document: LegalDocumentRef` (language from `?language=`; `null` parts when unavailable) |
| `getMyCoachDataRules` | `document: LegalDocumentRef` |
| New `getLegalDocument` (`GET /api/v1/legal/documents/{document_id}/versions/{version}?language=`) | Public, no auth, `published` only (drafts in dev/test); full text as Markdown + metadata; used by T-1 pages |

### 8.3 Changed requests (explicit authorisation needed in SF-72)

| Operation | Change | Why safe |
|---|---|---|
| `acceptCoachInvitation` | `document_language` **required** | Gate off in every environment; no deployed client can accept today |
| `acknowledgeMyCoachDataRules` | `document_language` **required** | Same; mobile client updated in the same release |

### 8.4 Errors

| Situation | Code | Details |
|---|---|---|
| Fighter under 18 at acceptance | `validation_error` (422) | `fields: [coaching_age]`, `field_codes: {coaching_age: too_young}`, `minimum_age: 18` |
| No approved variant in the requested language | `conflict` (409) | `document_language: unavailable` |
| Version not current | `conflict` (409) | `disclosure_version: stale` / `document_version: stale` (existing) |
| Data Rules not acknowledged | `conflict` (409) | `data_rules_acknowledgement: required` (existing) |
| Gate off | `not_found` (404) | existing |
| Unknown/unpublished document (public endpoint) | `not_found` (404) | — |

Clients regenerate (`mix openapi.gen`; platform Orval; mobile client).

## 9. Web and mobile

| Surface | Requirement |
|---|---|
| Web `web.invite.coach` (fighter review) | Render `parts.summary` and `parts.checkbox` from the API (never from `messages/*`, whose fallback chain silently falls back to English: F-14); link `full_url` when present; unticked checkbox; echo `version` and `document_language`; show "not available in your language" when `available_languages` lacks the locale; show the 18+ outcome on `coaching_age: too_young`; DRAFT banner for drafts |
| Web `web.app.coach.fighters` (coach invite) | New Data Rules acknowledgement step mirroring mobile (F-07): API text, unticked box, version and language echo, `409` handling |
| Mobile `mobile.coach.fighters` | Render API text instead of bundled copy; full-text link; language outcome; DRAFT banner |
| Mobile `mobile.profile.coaches` | No change beyond F-09 copy |
| Web/mobile ended-relationship copy | F-09: replace "dates only" with "dates and the name at the end" (product copy, normal translation process) |
| E08 | **B3** only (no change in A) |

## 10. Test plan

* **Registry:** valid fixture loads; hash mismatch, unknown status, backwards
  transition, duplicate id, missing approval fields, `DRAFT` id in
  production mode, missing scope, scope mismatch with configuration, current
  version not published → boot raises.
* **Configuration:** each `COACHING_*` variable rejected when absent from the
  registry; defaults keep the gate off (regression).
* **Evidence:** written with acceptance and acknowledgement in one
  transaction; rollback leaves none; `already_connected` writes none;
  deleting coach user, fighter user, invitation or relationship leaves
  evidence intact; `UPDATE` rejected by the trigger; no endpoint exposes it.
* **18+:** one day before the 18th birthday rejected; on the birthday
  accepted; 29 February birthdays follow the registration age computation; invitation stays
  pending; coach list shows pending; no age in any coach response or
  telemetry.
* **Language:** unavailable language → `409` and nothing shared; available →
  evidence language recorded; option (b) not reachable.
* **Scope guard:** a test-only wider scope fails boot.
* **Contract:** `assert_schema` for every changed response; OpenAPI check;
  Redocly lint.
* **Regression:** C1/C2 projection unchanged (7 fields, no `weight_class`);
  SF-56 end and stub; SF-57 binding, single use, `410`, `403`; gate-off `404`s.
* **Web/mobile:** unit tests per state (draft, unavailable language, too
  young, stale); Playwright review and acknowledgement flows against the API
  with draft fixtures (dev only).

## 11. Rollout and gate

* Merge with the gate off; no production configuration change in SF-72.
* Production deploy succeeds with **no** coaching versions configured
  (current state) — verified by a boot test with production config.
* Activation needs every item of checklist §2 and section 1.C; SF-72 does not
  activate anything.
