# Legal documentation

Proposals for legal texts and policies that the product must implement.
Nothing in this folder is legally approved unless a document says so and
references a recorded approval. Coach–Fighter sharing stays disabled until the
activation checklist is complete.

## SF-71 package (Coach–Fighter disclosure, data rules, retention)

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

| Approval | State |
|---|---|
| Product policy L-01 – L-16 | `PRODUCT_APPROVED` 2026-10-19 (product owner) |
| Legal texts, bases, roles, retention periods | `PROPOSED_PENDING_LEGAL_REVIEW` — nothing is `LEGALLY_APPROVED` |
| Engineering foundation (SF-72) | Implemented: registry, evidence, 18+, shared acceptance policy ([ADR 0022](../architecture/adr/0022-legal-documents-coaching-policy.md)); production registry empty |
| Coach–Fighter sharing | Disabled in every environment |

| Document | Content |
|---|---|
| [Decision register](proposals/SF-71-decision-register.md) | L-01 – L-16, approval record, status vocabulary, not-approved list |
| [Fighter Data Sharing Disclosure](proposals/SF-71-fighter-data-sharing-disclosure.md) | Full draft, in-app text, checkbox, summary, version metadata |
| [Coach Data Access & Usage Rules](proposals/SF-71-coach-data-access-rules.md) | Full draft, acknowledgement copy, rollover, SF-72 contract |
| [Consent, versioning, publication, localization](proposals/SF-71-consent-versioning.md) | Lifecycles, evidence, renewal policy, version contract, surfaces, languages |
| [Retention, deletion and rights](proposals/SF-71-retention-policy.md) | Retention matrix (PROPOSED periods), triggers, evidence lifecycle, account deletion, stub |
| [Legal analysis and Privacy/Terms impact](proposals/SF-71-privacy-terms-impact.md) | Sources, per-operation roles, per-purpose bases, minors, impact matrix |
| [Legal review checklist](proposals/SF-71-legal-review-checklist.md) | Counsel questions Q-01 – Q-18, activation checklist, rollback vs revocation |
| [Integration contract](../architecture/proposals/SF-71-coaching-legal-integration-contract.md) | Implemented behaviour, field matrix, findings F-01 – F-15, traceability |
| [SF-72 specification](../architecture/proposals/SF-72-legal-document-integration-spec.md) | Implementation-readiness spec (parts A, B, C) |
| [Follow-up task specifications](../architecture/proposals/SF-71-follow-up-task-specs.md) | T-1 – T-5 and the dependency graph |

Conventions: drafts carry the status line above; legal sources carry the date
checked; retention periods are marked PROPOSED until approved; document
versions are assigned only at approval and never contain `DRAFT` in
production; statuses use `PRODUCT_APPROVED`, `PROPOSED_PENDING_LEGAL_REVIEW`,
`LEGALLY_APPROVED`, `NOT_APPROVED`, `NOT_REQUIRED` as defined in the decision
register.
