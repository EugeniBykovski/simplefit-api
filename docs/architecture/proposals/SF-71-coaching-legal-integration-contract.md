# SF-71 — Coaching legal integration contract (proposal)

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

* Ticket: SF-71 (epic SF-48). Implementation owner: SF-72.
* Date: 2026-10-19. Audited code: `simplefit-api` `main` `01d891e`,
  `simplefit-platform` `main` `c426249`, `simplefit-mobile` `main` `ff7bc7e`.
* Package index: [`docs/legal/README.md`](../../legal/README.md).

This document records what the software does today, field by field, and
what SF-72 must change so the approved legal texts and the product match.
Product policy L-01 – L-16: **PRODUCT_APPROVED** 2026-10-19; legal approval
pending ([decision register](../../legal/proposals/SF-71-decision-register.md)).
It changes nothing: no code, configuration, schema or OpenAPI change is part
of SF-71.

## 1. What is implemented today (audited)

| Area | Implemented behaviour | Source |
|---|---|---|
| Gate | `access_enabled: false`, `disclosures: %{}`, `current_disclosure: nil`, `data_rules_version: nil` by default (`config/config.exs`); per environment `COACHING_ACCESS_ENABLED`, `COACHING_DISCLOSURES` (`version=scope,…`, first = current), `COACHING_DATA_RULES_VERSION`; malformed values fail boot (`config/runtime.exs`) | ADR 0021, `SimpleFit.Coaching.Disclosure` |
| Disclosure scope | Only scope `basic_profile` = C1 + C2 (7 fields); intersected with `Fighters.coach_visible_fields/0`; a version no longer configured discloses nothing; a later version never widens an existing relationship | `Disclosure`, `Fighters.coach_projection/2` |
| Fighter acceptance | Signed-in recipient bound by a verified **email** identity for the invited address; completed account registration and fighter profile; must echo the current disclosure version (stale → `409`); one transaction activates the relationship and consumes the invitation | ADR 0021 SF-57 amendment |
| Acceptance evidence | `coach_invitations.accepted_disclosure_version` + `responded_at` + `relationship_id`; `coach_fighter_relationships.disclosure_version` + `started_at` | migrations `20261015…`, `20261016…` |
| Coach acknowledgement | Append-only `coach_data_rules_acknowledgements` (`coach_profile_id`, `document_version`, `acknowledged_at`), unique per version; required before creating or resending an invitation | ADR 0021 SF-57 amendment |
| Preview | Anonymous, token in body; returns coach `display_name` + `brand_name`, the coach's note, `expires_at`, disclosure `{version, fields, never_shared}`; no recipient or account data | `Invitations.preview/2` |
| Never-shared list | `goals, next_fight, weight, height, account_name, date_of_birth, email, other_coaches` (category codes) | `Invitations.never_shared/0` |
| Termination | Either side, idempotent, gate-independent; name snapshots taken in the same transaction; ended rows immutable | ADR 0021 |
| Ended stub | Coach: `relationship_id`, dates, `ended_by`, `fighter_display_name_at_end`. Fighter: coach name at end. No live profile data | ADR 0021 |
| Invitation lifetime | 14 days; resend rotates token and expiry; ≤ 4 sends; expiry derived at read | `Invitations` |
| Retention | **No deletion job** for invitations, acknowledgements or relationships; Oban jobs (incl. encrypted E08 payload) pruned after 1 day; rate-limit windows removed hourly | `config/config.exs`, ADR 0021 |
| Account deletion | **No product operation exists** (web/mobile deletion screens are placeholders, SF-32/SF-33). Deleting a `users` row cascades: profiles → relationships (both sides) → acknowledgements; consents; a coach's invitations; invitations of a deleted fighter keep `recipient_sealed` and `accepted_disclosure_version` (`relationship_id` → NULL) | migrations |
| Minimum age | 16 by calendar date at registration (`too_young`); no guardian flow; date of birth immutable after completion. **No age check at coach invitation acceptance** (L-14 requires 18+, SF-72 §5) | ADR 0016 |
| Web message fallback | Web message catalogs fall back along `es-MX → es → en`; every missing key renders English silently (`src/shared/i18n/routing.ts`, `messages.ts`) | platform `c426249` |
| Account consents | `terms` + `privacy` versions `terms-v1` / `privacy-v1` (identifiers only, no published texts or URLs exist) | ADR 0016, `config/config.exs` |

## 2. Field-by-field classification (reconciled with the code)

`Coach access` refers to an **active** relationship under a configured
`basic_profile` version, with the gate on. Today the gate is off: a coach
has no access to any field.

| Data field | Source entity | Class | Coach access | Purpose | Retention (PROPOSED, see retention policy) | Legal review |
|---|---|---|---|---|---|---|
| `display_name` | `fighter_profiles` | C1 | Live while active; **snapshot kept after end** (`fighter_display_name_at_end`) | Identify the fighter in the roster | Live: while active. Snapshot: per L-05 | Yes (snapshot) |
| `username` | `fighter_profiles` | C1 | Live while active | Identify the fighter unambiguously | While active | Yes |
| `country_code` | `fighter_profiles` | C1 | Live while active (may be absent) | Coaching context (location, time zone, competition region) | While active | Yes |
| `city` | `fighter_profiles` | C1 | Live while active (may be absent) | Coaching context | While active | Yes |
| `experience_level` | `fighter_profiles` | C2 | Live while active | Plan coaching to level | While active | Yes |
| `stance` | `fighter_profiles` | C2 | Live while active (may be absent) | Technical coaching | While active | Yes |
| `amateur_bout_count` | `fighter_profiles` | C2 | Live while active (may be absent) | Coaching context | While active | Yes |
| `goals` | `fighter_profiles` | C3 | **None** | — | Fighter profile lifetime | — |
| `next_fight_on`, `next_fight_name` | `fighter_profiles` | C3 | **None** | — | Fighter profile lifetime | — |
| `weight_class` | `fighter_profiles` | C4 | **None** (not named separately in `never_shared`, covered by "weight") | — | Fighter profile lifetime | Wording |
| `current_weight_kg`, `height_cm` | `fighter_profiles` | C4 | **None** | — | Fighter profile lifetime | Art. 9 question (L-02) |
| `full_name`, `date_of_birth` | `account_profiles` | C4 | **None** | — | Account lifetime | — |
| email address, identities | `identities` | C4 | **None** (the coach typed the address to invite; it is never returned to the coach unmasked) | — | Account lifetime | — |
| other relationships | `coach_fighter_relationships` | C4 | **None** | — | — | — |
| invited address (non-user possible) | `coach_invitations.recipient_sealed` / `recipient_digest` | invitation data | Coach sees a **masked** form only | Deliver, resend and bind the invitation | Per L-06 | Yes (Art. 14) |
| coach note | `coach_invitations.message` | coach content | Coach-authored; shown to recipient | Personal note | Per L-06 | — |
| coach `display_name`, `brand_name` | `coach_profiles` | coach public | Shown to recipient (preview) and fighter | Identify the coach | Coach profile lifetime; snapshot after end | Yes (snapshot) |

**Verified:** no C3 or C4 field is in the `basic_profile` scope, in
`coach_visible_fields/0` or in any coach-facing projection. C1/C2 must not be
broadened without a separate approved architecture decision.

## 3. Actual access matrix

| Actor → data | Gate off | Gate on, active | After end | After fighter account deletion |
|---|---|---|---|---|
| Coach → C1/C2 (live) | none (`404`) | disclosed fields of the accepted version | none | none (row deleted) |
| Coach → ended stub | none (coach lists `404`) | — | `fighter_display_name_at_end`, dates, `ended_by` | none (cascade) |
| Fighter → own relationships | list + end | list + end | coach name at end, dates | — |
| Coach → own invitations | list/cancel (`404` for create/resend/preview/accept) | full | full | invitation row kept with sealed address |
| Gym, gym staff, sponsor, other coaches | none | none | none | none |

## 4. Findings (security and privacy design review)

| ID | Finding | Severity | Owner |
|---|---|---|---|
| F-01 | No published legal texts, versions or URLs exist (Terms, Privacy, Fighter disclosure, Coach Data Rules). The `terms-v1` / `privacy-v1` identifiers refer to no reviewable document. | **Critical** (activation blocker) | Legal / SF-72 |
| F-02 | The fighter review page (SF-60) does not tell the fighter, **before** accepting, that the coach keeps the fighter's name snapshot after an end; it is said only afterwards on My Coaches (`fighterCoaches.endedNote`). The E08 email says "You can remove access at any time" without the stub exception. | **High** | SF-72 (web copy), E08 (SF-72) |
| F-03 | No retention or deletion exists for invitations (incl. encrypted address of possibly non-registered recipients), acknowledgements, ended relationships; expired/declined/cancelled invitations are kept indefinitely. | **High** | Retention engineering (new task) |
| F-04 | A fighter's acceptance evidence and invited address live on the coach's invitation row: they survive the fighter's account deletion and disappear with the coach's. The relationship row (other evidence) disappears with either side. | **High** | SF-72 / retention task |
| F-05 | Account deletion is not a product operation; erasure requests can only be served manually; cascades remove the counterparty's history and consent evidence. | **High** | Account-deletion task (new) |
| F-06 | E08 is sent to an address supplied by a coach; the recipient may not be a user. Art. 14 information and an invitation-specific privacy statement are not linked from E08; whether E08 is "commercial information" under Polish electronic-communications law needs counsel. | **High** (legal) | Legal / SF-72 |
| F-07 | Web coach invite flow has no Data Rules acknowledgement step (only "blocked"); mobile has one but no link to the full text. No API field carries a document reference (URL/hash) for the disclosure or the Data Rules. | **Medium** | SF-72 |
| F-08 | With the gate off, a coach cannot list relationships, so cannot find a relationship id to end it, although the end endpoint is gate-independent (SF-61 note). Fighters can always end. | **Medium** | Follow-up (minimal-authority list, L-16) |
| F-09 | Copy says ended relationships are listed "with the dates only" (`coachFighters.empty.ended.body`, `fighterCoaches.empty.ended.body`) but the name at the end is listed too. | **Low** | SF-72 (copy) |
| F-10 | `weight_class` (C4) is not named separately in `never_shared`; it is implied by "weight". | **Low** | SF-72 (wording) |
| F-11 | A version removed from `COACHING_DISCLOSURES` silently discloses nothing for relationships accepted under it; fighters and coaches are not told. | **Medium** (product) | L-13 / SF-72 |
| F-12 | Coach Data Rules acknowledgement and Fighter acceptance are separate, version-checked, never inferred from registration, never preselected (web/mobile checkboxes start unticked). | Accepted (correct) | — |
| F-13 | Token secrecy (fragment, hash only, `sfi_` redaction), verified-email binding, single use, one transaction, `no-store` responses, outcome-only telemetry. | Accepted (correct) | — |
| F-14 | Legal copy kept in web message catalogs would silently fall back to English for a missing translation, so a user could accept text in a language they did not choose (conflicts with L-11). | **Medium** | SF-72 (render legal text from the registry, not message catalogs) |
| F-15 | No age check exists at acceptance; 16–17-year-old fighters can be connected with coaches once the gate is on (conflicts with L-14). | **High** (activation blocker) | SF-72 §5 |

### 4.1 Traceability (finding → decision → work)

| Finding | Decision | Resolved by | Launch-blocking |
|---|---|---|---|
| F-01 no legal texts, versions, URLs | L-10, L-12, L-15 | SF-72 A2/B1/B2, T-1, counsel | Yes |
| F-02 stub not disclosed before acceptance; E08 wording | L-03, L-05 | Disclosure draft §7 and Part 2 (done in draft); SF-72 B1 (approved text), B3 (E08) | Yes |
| F-03 no retention | L-05 – L-07 | T-2 | Yes |
| F-04 evidence on counterparty rows | L-08 | SF-72 A5; T-2/T-3 for deletion | Yes |
| F-05 no account deletion; cross-user cascade | L-09 | T-3 | Yes |
| F-06 E08 to non-users | L-15, Q-06 | SF-72 B3, T-1 | Yes |
| F-07 no web acknowledgement step; no document reference | L-04, L-10 | SF-72 A9/A10/A11 (done, ADR 0022) | Yes |
| F-08 coach cannot end while gate off | L-16 | T-4 | Yes |
| F-09 "dates only" copy | L-03 | SF-72 A12 | Yes (accuracy) |
| F-10 `weight_class` not named | L-03 | Disclosure and Data Rules drafts (done); SF-72 B1; never-shared category list kept as is (`weight` covers it), text names it | Yes (text) |
| F-11 silent version withdrawal | L-13 | SF-72 §6 guard; Q-18 policy | Yes |
| F-12 separate acknowledgement and acceptance | — | Accepted; preserved by SF-72 | — |
| F-13 token security | — | Accepted; preserved by SF-72 | — |
| F-14 English message fallback | L-11 | SF-72 A8/A10 (done: legal text only from the API), T-1 | Yes |
| F-15 no 18+ check | L-14 | SF-72 A6 (done: `Activation`, both paths) | Yes |

## 5. Contract for SF-72

Superseded by the canonical
[SF-72 implementation-readiness specification](SF-72-legal-document-integration-spec.md):
registry and fail-closed configuration (L-10), API document references and
language fields, evidence domain (L-08), server-side 18+ at acceptance
(L-14), scope-widening and withdrawal guards (L-13), language rule (L-11),
web acknowledgement step (F-07), copy fix F-09. Retention, deletion,
gate-off management, legal pages and renewal are **not** SF-72 (§6).

## 6. Separate tasks

[Follow-up task specifications](SF-71-follow-up-task-specs.md), with the
dependency graph:

| Task | Content | Launch-blocking |
|---|---|---|
| T-1 | Public legal pages and global Terms / Privacy Notice | Yes |
| T-2 | Retention and deletion enforcement | Yes |
| T-3 | Account deletion and erasure workflow | Yes |
| T-4 | Gate-off coach relationship management | Yes |
| T-5 | Disclosure renewal | Only before any wider sharing scope |

Activation remains forbidden until every item of the activation checklist
(`docs/legal/proposals/SF-71-legal-review-checklist.md` §2) is satisfied.
