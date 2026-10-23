# ADR 0022 — Legal documents, acceptance evidence and the Coach–Fighter policy

* **Status:** accepted as engineering architecture (SF-72, 2026-10-20).
  **Engineering acceptance is not legal approval:** no legal text is
  approved; the production registry is empty; Coach–Fighter sharing stays
  off everywhere.
* **Context:** SF-71 (product policy approved, legal approval pending),
  ADR 0016 (account consents), ADR 0021 and its SF-57, SF-73 and SF-74
  amendments.

## Decision

### Ownership and source of truth

Legal texts are owned by product (drafting) and counsel (approval);
engineering only publishes approved files. The backend's code-reviewed
**registry** (`SimpleFit.Legal.Registry`) is the single source of every
version a user can read or accept:

```
priv/legal/registry.json
priv/legal/documents/<document_id>/<version>/<language>/{title,summary,checkbox,full}.md
```

No database table, upload, CMS or environment variable can add or change a
text; there is no run-time substitution. Configuration
(`COACHING_DISCLOSURES`, `COACHING_DATA_RULES_VERSION`) only *selects*
registered versions. Documents: `fighter-coach-disclosure`,
`coach-data-rules`. Terms and Privacy keep their ADR 0016 identifiers
(`terms-v1`, `privacy-v1`) until a separate task (SF-71 T-1) moves them into
the registry; SF-72 does not touch the registration consent contract.

### Versions, immutability and hashes

* A version id is `<document_id>-<YYYY>-<MM>-<seq>`, assigned at approval;
  it covers every language variant of the same approved meaning.
* Each variant records the SHA-256 of its four parts (name, size and bytes
  of `title`, `summary`, `checkbox`, `full`, in that order;
  `Registry.content_sha256/1`, `mix legal.hash`). At load every text is
  re-hashed: any mismatch invalidates the registry.
* Status: `draft` → `approved` → `published` → `superseded` / `withdrawn`.
  Only `published` is acceptable (one per document); `superseded` remains
  readable and keeps existing relationships' scope; `withdrawn` discloses
  nothing and needs a `withdrawal_notice_ref` (the approved notification
  policy, SF-71 Q-18). Every status but `draft` needs `approval_ref`,
  `approved_by` and `effective_at`; published ones `published_at`.
* An approved text never changes under its id: a changed text is a new
  version (or, for a fix approved as non-material, a new hash recorded with
  its approval).
* Test fixtures (`test_only`, `<document_id>-test-<n>`,
  `TEST-FIXTURE-NOT-APPROVED`) are accepted only where
  `allow_test_fixtures` is configured (tests; local E2E) and live outside
  `priv/`, so no release contains them.

### Boot and run time

The registry is read and validated once at boot into a persistent term. An
invalid registry is logged (reason code only) and never stops the
application: sign-in, profiles, the fighter's own relationships and
everything else keep working; only Coach–Fighter sharing is unavailable.
The empty production registry is valid.

### Localization

Four languages are kept apart: the UI language, the language a client
requests (`language`), the language of the text actually presented
(`document.language`: only an approved variant, **never a fallback**), and
the language recorded in the evidence (the presented one, echoed by the
client as `document_language`). A request for a language without an
approved variant returns the metadata and `available_languages` with null
text; accepting or acknowledging in it answers `409 document_language:
unavailable`. English is the reference language (required from `approved`);
other variants need their own approval. Clients render legal text from the
API, never from message catalogs (whose English fallback is silent, F-14).

### Readiness (one predicate)

`SimpleFit.Coaching.sharing_ready?/0` = gate flag on **and** registry valid
**and** the configured current disclosure `published` with the configured
scope **and** the configured data rules `published`. Every coach read,
invitation creation, preview and acceptance requires it; the flag alone
enables nothing.

| Check | Applies |
|---|---|
| Gate, registry, published disclosure and data rules | Globally (`sharing_ready?/0`) |
| Pending, not expired, verified recipient, exact disclosure version, approved language, explicit acceptance | Per invitation |
| Completed account and fighter profiles, 18+, coach's data-rules acknowledgement (at issuance) | Per user |

### Age (18+)

`SimpleFit.Coaching.Activation` refuses a fighter under 18
(`fighter_too_young` → `422 validation_error`, `coaching_age: too_young`),
from the account profile's date of birth only (immutable once registration
is complete; no date: not eligible), in whole calendar years
(`AccountProfile.age/2`, 29 February reached on 1 March in common years),
on the date in UTC−12 so nobody is treated as 18 before their birthday in
any time zone. Activation is the only way a relationship becomes active, so
token and id acceptance (and any future path) enforce it. The coach is never
told; the invitation stays pending. Account registration stays 16+.

### Shared acceptance transaction

Token (`acceptCoachInvitation`) and id (`acceptMyIncomingCoachInvitation`)
acceptance run the same locked transaction: lock the invitation (by token
hash or by id within the caller's recipient digests), check status and
expiry, bind the recipient, require account registration and fighter
profile, check the exact current version and the approved language, call
`Activation.activate/3` (readiness, offered version, profiles, 18+, coach,
no self-coaching), consume the invitation, record the evidence. All or
nothing. The SF-73 `id_acceptance_enabled` switch is removed: no path has a
separate bypass.

### Evidence

`legal_evidence` (`SimpleFit.Legal.Evidence`): kind
(`fighter_disclosure_acceptance`, `coach_data_rules_acknowledgement`),
subject and counterparty user ids, invitation and relationship ids,
document id, version, language and content hash, server time. No names,
addresses, notes, IP or device data. No foreign keys: it survives the
deletion of the invitation, relationship, profiles and accounts. Append-only
(a trigger rejects updates); one row per accepted invitation and per coach
and acknowledged version (unique indexes). An acceptance of an already
connected pair is still recorded for its invitation (the fighter accepted
that text). No endpoint reads it. **Retention is not implemented**: periods
are pending counsel (SF-71 L-08, Q-09); deletion belongs to SF-71 T-2/T-3.

### Disclosure scope and rollover

The only scope is `basic_profile` (C1 + C2, seven fields); C3/C4 —
including `weight_class`, weight, height, goals, next fight, legal name,
date of birth, email and identities — never reach a coach. A relationship
keeps the version it was accepted under; its fields require that version to
be configured and `published`/`superseded` in the registry. Publishing a
successor never widens an existing relationship; renewal for a wider scope
is SF-71 T-5 and not built.

### Gate off, withdrawal, revocation

* **Gate off** (temporary): no invitation, acceptance or coach read; the
  fighter's own list, detail and ending keep working; relationships stay
  `active` and return unchanged when the gate is on again; ended ones never
  reactivate.
* **Withdrawal** (registry status `withdrawn`, with its notice): the
  version discloses nothing and cannot be accepted; if it was current,
  sharing is not ready until a successor is published.
* **Permanent revocation:** ending relationships (existing operations).

### Public documents

`getLegalDocument` (`GET /api/v1/legal-documents/{document_id}`) and
`getLegalDocumentVersion` (`…/versions/{version}`), no sign-in: only
`published` and `superseded`; anything else `404`. The web pages
`/[locale]/legal/[documentId]` and `/[locale]/legal/[documentId]/[version]`
render them as text (a Markdown subset), never as HTML.

### API evolution

`document_language` is required in the acceptance and acknowledgement
requests and the responses carry `LegalDocumentRef`. Requiring the field on
established operations is safe because no deployed client can accept or
acknowledge today (sharing is off in every environment) and the web and
mobile clients are updated in the same release; public activation follows
only after those clients ship (SF-71 activation checklist).

## Consequences

* LOCAL DEVELOPMENT coaching mode (ADR 0025) is the only regime without
  these documents. `SimpleFit.Coaching.LegalPolicy` decides which regime
  applies; a production build cannot enter that mode.

* Publishing (Part B) and activation (Part C) are reviewed code and
  configuration changes after counsel's approval; this ADR does not perform
  them.
* The evidence table grows until the retention task exists.
* A registry change needs a deploy; that is intended.
