# SF-71 — Decision register (L-01 – L-16)

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**
(product policy approved; legal approval pending — see below)

## Approval record

| Approval | Scope | Date | By | Evidence |
|---|---|---|---|---|
| Product | L-01 – L-16 as stated in the "Product-approved position" column, including the corrections of the reconciliation review | 2026-10-19 | Product owner | Explicit product-owner instruction recorded in the SF-71 task conversation |
| Legal | — | — | — | **None.** No text, legal basis, role classification or retention period is legally approved |

## Status vocabulary

| Status | Meaning |
|---|---|
| `PRODUCT_APPROVED` | The product owner approved the product policy or design. Not a legal opinion |
| `PROPOSED_PENDING_LEGAL_REVIEW` | A legal text, interpretation, legal basis, role classification or retention period proposed for counsel; not valid as a legal position |
| `LEGALLY_APPROVED` | Approved by external counsel with a recorded approval reference. **No item has this status** |
| `NOT_APPROVED` | Explicitly rejected or not authorised; must not be implemented or relied on |
| `NOT_REQUIRED` | Counsel approval not needed (counsel informed) |

"Counsel" = external legal approval mandatory. Retention periods are
PROPOSED values, never legal requirements. Findings F-xx:
[integration contract](../../architecture/proposals/SF-71-coaching-legal-integration-contract.md) §4.
Questions Q-xx: [checklist](SF-71-legal-review-checklist.md) §1. SF-72:
[specification](../../architecture/proposals/SF-72-legal-document-integration-spec.md).
Tickets T-1 – T-5 and the dependency graph:
[follow-up task specifications](../../architecture/proposals/SF-71-follow-up-task-specs.md).

## Decision matrix

| ID | Subject | Product-approved position | Product | Legal | Blocks |
|---|---|---|---|---|---|
| **A. Roles and basis** | | | | | |
| L-01 | Controller/processor roles | Operating model as a **product hypothesis**: SimpleFit defines fields, conditions, versions, retention; roles assessed per operation R1–R9 (privacy impact §2.1), incl. in-platform processing. No final classification | `PRODUCT_APPROVED` (hypothesis) | `PROPOSED_PENDING_LEGAL_REVIEW` (Q-01, Q-15) | Launch |
| L-02 | Legal basis for sharing | Consent for live C1/C2 display as the **proposed** approach; separate bases evaluated for invitations, evidence, historical records, security; withdrawal (ending) stops live access at once; no record kept merely because consent existed | `PRODUCT_APPROVED` (approach) | `PROPOSED_PENDING_LEGAL_REVIEW` (Q-02, Q-03) | Launch; SF-72 B4 |
| **B. Texts** | | | | | |
| L-03 | C1/C2 disclosure wording | Scope exactly 7 fields (`display_name`, `username`, `country_code`, `city`, `experience_level`, `stance`, `amateur_bout_count`); C3/C4 excluded, `weight_class` named; name snapshot described before acceptance | `PRODUCT_APPROVED` (scope) | Text `PROPOSED_PENDING_LEGAL_REVIEW` | SF-72 B1; launch |
| L-04 | Coach Data Rules | Separate, versioned rules; explicit, unticked, version-specific acknowledgement on web and mobile | `PRODUCT_APPROVED` | Text `PROPOSED_PENDING_LEGAL_REVIEW` (Q-14) | SF-72 B1; launch |
| **C. Retention** | | | | | |
| L-05 | Termination stub and name snapshots | 12 months after end, then delete; name removed earlier on erasure or upheld objection | `PRODUCT_APPROVED` (proposed period) | `PROPOSED_PENDING_LEGAL_REVIEW` (Q-08) | Launch (T-2) |
| L-06 | Invitation retention | Pending ≤ 14 days (implemented); resolved rows 90 days; sealed address, note, token hash 30 days; triggers per retention policy §2.1 | `PRODUCT_APPROVED` (proposed periods) | `PROPOSED_PENDING_LEGAL_REVIEW` (Q-07) | Launch (T-2) |
| L-07 | Relationship retention | Active: lifetime of the relationship; ended: 12 months | `PRODUCT_APPROVED` (proposed period) | `PROPOSED_PENDING_LEGAL_REVIEW` (Q-07) | Launch (T-2) |
| L-08 | Evidence retention | Separate, minimal, tamper-resistant evidence domain (retention policy §7; SF-72 §4) | `PRODUCT_APPROVED` (domain) | Period and erasure exceptions `PROPOSED_PENDING_LEGAL_REVIEW` (Q-09, Q-16) | SF-72 A5; launch |
| L-09 | Account deletion and erasure | Dedicated workflow; counterparties keep a neutral stub; legally justified evidence kept under a documented exception; no cross-user cascade (T-3) | `PRODUCT_APPROVED` | Exceptions `PROPOSED_PENDING_LEGAL_REVIEW` | Launch (T-3) |
| **D. Versions and publication** | | | | | |
| L-10 | Document versioning | Immutable registry; version ids; content hashes; approved language variants; fail-closed validation | `PRODUCT_APPROVED` | `NOT_REQUIRED` (counsel informed) | SF-72 A2 |
| L-11 | Locales and translations | English reference language; Polish legal review for the initial Polish market; unapproved translations never establish acceptance; acceptance only with an approved variant in the app language (option (a)) | `PRODUCT_APPROVED` | Per-market requirements `PROPOSED_PENDING_LEGAL_REVIEW` (Q-11, Q-17) | SF-72 A8; launch per market |
| L-12 | Publication URLs and ownership | Public current `/[locale]/legal/[documentId]` and immutable `/[locale]/legal/[documentId]/[version]` in the existing localized web routing | `PRODUCT_APPROVED` | `NOT_REQUIRED` | SF-72 B2; launch (T-1) |
| L-13 | Re-consent on changes | Corrected renewal policy (consent and versioning §4.2): relationships keep identity and authorised scope; no new field without renewed explicit authorisation; termination + reinvitation is not the renewal mechanism; wider scopes disabled until T-5 | `PRODUCT_APPROVED` | Material-change definition and notices `PROPOSED_PENDING_LEGAL_REVIEW` (Q-10, Q-18) | SF-72 A7; launch |
| **E. Scope and global documents** | | | | | |
| L-14 | Minimum age and safeguarding | Coach–fighter connections 18+ at initial launch, enforced by the backend at acceptance; account registration stays 16+ | `PRODUCT_APPROVED` | Opening to 16–17 `NOT_APPROVED` (needs Q-04, Q-05) | SF-72 A6; launch |
| L-15 | Global Privacy/Terms changes | Publish updated Terms and Privacy Notice with the coaching amendments | `PRODUCT_APPROVED` (requirement) | Documents `PROPOSED_PENDING_LEGAL_REVIEW` (Q-12) | Launch (T-1) |
| **F. Release** | | | | | |
| L-16 | Gate activation and rollback | Activation checklist; gate off = temporary shutdown, not termination; permanent revocation separate; minimal management-only gate-off ending (T-4) | `PRODUCT_APPROVED` | Activation sign-off by counsel required | Launch (T-4) |

## Explicitly not approved (`NOT_APPROVED`)

* Any coach access beyond the 7 C1/C2 fields; any C3/C4 field, including
  `weight_class`.
* Coach–fighter connections for fighters aged 16–17.
* Ending a relationship and re-inviting as the renewal mechanism.
* Acceptance on the basis of an unapproved translation, or of English text
  the user did not choose (option (b)) before Q-17.
* Silent withdrawal of a disclosure version.
* Treating any retention period in this package as a legal requirement.
* Activating Coach–Fighter sharing in any environment.

---

## A. Roles and legal basis

### L-01 — Controller/processor responsibilities
1. **Today:** no role allocation documented; no published Privacy Notice.
2. **Problem:** a coach chooses whom to invite and uses what they see in a
   professional activity; SimpleFit defines fields, conditions, versions and
   retention. A single label for "the coach" does not fit every operation.
3. **Proposal:** classify **per operation** (privacy impact §2.1): invitation
   creation and delivery, preview, acceptance, roster access, ended stubs,
   in-platform processing, off-platform processing by the coach, retention
   and evidence. Product approves this as an operating **hypothesis**
   only; future in-platform coaching features (R5) each need their own row
   before release. For each: candidate roles (SimpleFit controller; coach
   separate controller; joint controllers, Art. 26), indicators and the open
   question.
4. **Not concluded:** the coach is **not** classified as a separate controller
   only for off-platform activity; joint controllership for invitation
   creation and roster display remains a live option.
5. **Engineering:** none for SF-72. Joint controllership would add an Art. 26
   summary and contact point to the Privacy Notice (T-1) and possibly to the
   Coach Data Rules.
6. **Counsel:** mandatory (Q-01, Q-15). **Final classification: pending
   counsel.**

### L-02 — Legal basis
1. **Today:** explicit, version-specific, unticked, per-coach acceptance;
   ending is possible at any time and immediately stops live access.
2. **Proposal:** a separate basis per purpose (privacy impact §2.2). Consent
   (Art. 6(1)(a)) for live C1/C2 display is **proposed, not established**;
   alternatives (Art. 6(1)(b), 6(1)(f)) stay on the table for counsel.
3. **Withdrawal:** if consent is the basis, ending the relationship withdraws
   it and ends live access at once (implemented). Withdrawal does **not**
   authorise keeping anything else by default: the ended stub, evidence and
   invitation rows each need their own basis and period, and erasure or
   objection may require earlier deletion.
4. **Engineering:** none now; checkbox wording follows the basis
   (disclosure Part 3).
5. **Counsel:** mandatory (Q-02, Q-03). **Pending counsel.**

## B. Texts

### L-03 — Exact disclosure wording
1. **Today:** SF-60 review lists the 7 fields and the never-shared list; the
   stub is mentioned only after acceptance (F-02); E08 says "remove access at
   any time" (F-02); "dates only" copy (F-09); `weight_class` not named
   (F-10).
2. **Proposal:** disclosure as drafted: exactly `display_name`, `username`,
   `country_code`, `city`, `experience_level`, `stance`,
   `amateur_bout_count`; C3/C4 excluded and named, including weight class;
   the name snapshot kept after an end is described **before** acceptance,
   together with its limited period and earlier deletion on request.
3. **Engineering:** SF-72 copy (approved languages only), E08, full-text link.
4. **Counsel:** mandatory.

### L-04 — Coach Data Rules
1. **Today:** acknowledgement exists in API and mobile; web lacks the step
   (F-07); no text exists.
2. **Proposal:** separate, versioned rules with explicit, unticked,
   version-specific acknowledgement on web and mobile; incorporated by
   reference into the Terms for enforceability (L-15).
3. **Engineering:** SF-72 web step and document reference. Enforcement
   tooling (suspend inviting, end a coach's connections) is not in SF-72;
   confirm whether support tooling exists.
4. **Counsel:** mandatory (Q-14).

## C. Retention

### L-05 — Termination and historical snapshots
1. **Today:** stub with name snapshot kept indefinitely (no job).
2. **Alternatives:** (a) indefinitely (not defensible); (b) 12 months then
   delete; (c) no name; (d) 6 months.
3. **Proposal:** (b), PROPOSED period; name removed earlier on erasure or
   upheld objection.
4. **Engineering:** T-2 (changes SF-56 behaviour; explicit follow-up).
5. **Counsel:** mandatory (Q-08).

### L-06 — Invitation retention
1. **Today:** all invitations kept indefinitely with the sealed address, also
   of non-users (F-03).
2. **Proposal:** pending ≤ 14 days (implemented expiry); resolved rows deleted
   90 days after the resolution trigger; sealed address, note and token hash
   removed 30 days after it. Triggers per status in retention policy §2.1.
   All periods PROPOSED.
3. **Engineering:** T-2 (Oban cron, idempotent, counts-only telemetry), only
   after approval.
4. **Counsel:** mandatory (Q-07).

### L-07 — Relationship retention
1. **Today:** kept indefinitely; deleted with either profile.
2. **Proposal:** active while active; ended 12 months (PROPOSED), same as
   L-05. Evidence follows L-08, not the relationship row.
3. **Counsel:** mandatory.

### L-08 — Consent/acknowledgement evidence lifecycle
1. **Today:** fighter evidence lives on the coach's invitation row and on the
   relationship row (F-04); acknowledgements are deleted with the coach
   profile.
2. **Proposal (retention policy §7):** append-only evidence records written in
   the same transaction as the action; no foreign key that cascades from
   invitations or relationships; pseudonymous identity references (no names,
   email, IP or notes); a document version and content hash; restricted
   access (no user-facing API); deletion only by the retention job after the
   approved period, or by an approved erasure decision.
3. **Period:** pending counsel (Q-09); 3 years after end or account deletion
   is a reference point only.
4. **Engineering:** SF-72 (schema and writes); deletion by T-2/T-3.
5. **Counsel:** mandatory (Q-09, Q-16).

### L-09 — Account deletion and erasure
1. **Today:** no deletion feature; manual deletion cascades into the
   counterparty's history and leaves addresses on invitations (F-04/F-05).
2. **Proposal:** dedicated workflow (T-3): deletes the user's own data;
   keeps only L-08 evidence under an explicit, documented exception; removes
   the fighter's address from invitations; replaces the deleted person's name
   in the counterparty's stub with a neutral label; never deletes another
   user's records through a cascade; documents backup handling.
3. **Counsel:** mandatory (Art. 17(3) exceptions).

## D. Versions and publication

### L-10 — Document versioning
Proposal: immutable registry of approved documents (id, version, language,
content SHA-256, effective date, canonical URL, approvers); configuration may
only select registered versions; production boot fails on an unknown,
unapproved or `DRAFT` version; an approved text never changes under the same
id except non-material fixes recorded with a new hash. Engineering: SF-72.

### L-11 — Locale and translation policy
Proposal: English canonical; Polish reviewed by Polish-qualified counsel for
the initial Polish market; one version id across languages with a per-language
hash and approval; no unapproved translation presented as approved. **English
fallback is for reading only:** acceptance or acknowledgement is offered only
when an approved variant exists in a language the user selected or confirmed
understanding (consent and versioning §7.1); otherwise the flow ends in a safe
"not available in your language" outcome with nothing shared. Counsel per
market (Q-11, Q-17).

### L-12 — Publication URLs and ownership
Proposal: public, unauthenticated pages; current
`/<locale>/legal/<document-id>`; immutable archive
`/<locale>/legal/<document-id>/<version>`; product owns, counsel approves,
engineering publishes approved files only (T-1). URLs are assigned when T-1
lands; none exist now.

### L-13 — Disclosure renewal and re-consent
Proposal for MVP (consent and versioning §4):
* existing relationships stay limited to the fields authorized by their
  accepted version;
* no expansion without new explicit fighter authorization;
* a disclosure version with a wider scope cannot be configured as current
  until an approved renewal operation exists (T-5); ending a relationship and
  sending a new invitation is **not** the re-consent mechanism;
* the future renewal operation keeps the relationship id and history and
  records evidence per L-08;
* narrowing and emergency withdrawal follow an approved notification and
  revocation policy, never silent removal (F-11);
* Data Rules: a material change requires re-acknowledgement before inviting
  (implemented).
Counsel: material-change definition and notices (Q-10).

## E. Scope and global documents

### L-14 — Minimum age and safeguarding
1. **Today:** 16+ at registration, no guardian flow.
2. **Proposal:** account registration stays 16+; coach–fighter relationships
   are 18+ at the initial launch, enforced by the backend at invitation
   acceptance from the immutable date of birth; the coach learns nothing
   about the age. 16–17 only after a separate safeguarding and legal review.
3. **Engineering:** SF-72 (acceptance prerequisite, error code, fighter copy).
4. **Counsel:** mandatory to ever open 16–17 (Q-04, Q-05).

### L-15 — Global Privacy/Terms
Proposal: publish both with the impact-matrix amendments; operator identity,
processors and transfers supplied by SimpleFit (T-1). Counsel mandatory.

## F. Release

### L-16 — Feature-gate activation and rollback
1. **Gate off = temporary operational shutdown.** It stops every coach-facing
   data flow but does **not** terminate relationships: they stay `active` in
   the database, and re-enabling the gate restores access to every
   relationship not ended meanwhile.
2. **Permanent revocation** is a different action: ending relationships (per
   relationship or in bulk, with notice) or withdrawing a disclosure version
   under the L-13 notification policy.
3. **Gate-off ending:** a minimal, management-only mechanism lets coaches end
   relationships while sharing is disabled (relationship id and the fighter's
   display name only, no profile data) (T-4).
4. **Activation:** only after the checklist §2; release decision recorded per
   market.
5. **Counsel:** mandatory for activation.

---

## Revision log

| Date | Change | Source |
|---|---|---|
| 2026-10-19 | Initial register (L-01 – L-16, all open) | SF-71 package |
| 2026-10-19 | Product owner review: L-03 – L-07, L-09, L-10, L-12, L-14, L-15 retained as proposed; L-01, L-02 reopened as pending counsel; L-08, L-11, L-13, L-16 revised; tickets T-1 – T-5 separated from SF-72 | Product owner review |
| 2026-10-19 | Product policy for L-01 – L-16 recorded as `PRODUCT_APPROVED`; legal statuses recorded as `PROPOSED_PENDING_LEGAL_REVIEW` / `NOT_REQUIRED`; nothing `LEGALLY_APPROVED` | Product owner approval |
