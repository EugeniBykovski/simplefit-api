# SF-71 — Decision register (L-01 – L-16)

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

All decisions are **open**. "Counsel" = external legal approval mandatory.
Findings F-xx: [integration contract](../../architecture/proposals/SF-71-coaching-legal-integration-contract.md) §4.
Questions Q-xx: [checklist](SF-71-legal-review-checklist.md) §1.

## Summary

| ID | Question | Recommendation | Risk if wrong | Owner | Counsel | Status |
|---|---|---|---|---|---|---|
| **A. Roles and basis** | | | | | | |
| L-01 | Controller/processor roles | SimpleFit controller for platform processing; coach separate controller for off-platform use; joint-controllership question to counsel | High | Legal | **Yes** | Open |
| L-02 | Legal basis for sharing | Consent for C1/C2 display; legitimate interests for stub, invitations, abuse limits | High | Legal | **Yes** | Open |
| **B. Texts** | | | | | | |
| L-03 | C1/C2 disclosure wording | Draft as written (7 fields, never-shared list incl. weight class, stub disclosed before accepting) | High | Product + Legal | **Yes** | Open |
| L-04 | Coach Data Rules | Draft as written; web acknowledgement step | Medium | Product + Legal | **Yes** | Open |
| **C. Retention** | | | | | | |
| L-05 | Termination stub and name snapshots | Keep stub 12 months, then delete; drop name on erasure/objection | Medium | Product + Legal | **Yes** | Open |
| L-06 | Invitation retention | Pending ≤ 14 days; resolved rows 90 days; address/token removed 30 days after resolution | Medium | Product + Legal | **Yes** | Open |
| L-07 | Relationship retention | Active: while active; ended: 12 months | Medium | Product + Legal | **Yes** | Open |
| L-08 | Evidence retention | Minimal, detached evidence; end/deletion + 3 years (counsel: 3 vs 6) | Medium | Legal | **Yes** | Open |
| L-09 | Account deletion and erasure | Dedicated deletion task; neutral "Deleted user" stub; evidence kept detached | High | Product + Legal | **Yes** | Open |
| **D. Versions and publication** | | | | | | |
| L-10 | Document versioning | Registry + `<doc>-<YYYY>-<MM>-<seq>`; one id for all languages; fail closed | Low | Product + Eng | No (counsel informed) | Open |
| L-11 | Locales and translations | English canonical; Polish counsel-reviewed before PL launch; no unapproved translations | Medium | Product + Legal | **Yes** | Open |
| L-12 | Publication URLs and ownership | Public web pages `/<locale>/legal/<doc>[/<version>]`, product-owned | Low | Product | No | Open |
| L-13 | Re-consent on changes | Material change = new id + re-acknowledge/re-accept; narrowing at once; notice always | Medium | Product + Legal | **Yes** | Open |
| **E. Scope and global documents** | | | | | | |
| L-14 | Minimum age and safeguarding | Keep 16+; launch decision on 16–17 fighters per counsel (option b recommended) | High | Product + Legal + Safeguarding | **Yes** | Open |
| L-15 | Global Privacy/Terms changes | Publish both; changes per impact matrix | High | Legal | **Yes** | Open |
| **F. Release** | | | | | | |
| L-16 | Gate activation and rollback | Checklist §2; gate-off minimal coach list for ending (follow-up) | High | Product | **Yes** (activation) | Open |

---

## A. Roles and legal basis

### L-01 — Controller/processor responsibilities
1. **Today:** no role allocation documented; no published Privacy Notice.
2. **Problem:** fighter data is disclosed to an independent professional who
   may use it off-platform; the platform decides fields and conditions.
3. **Alternatives:** (a) SimpleFit sole controller, coach a mere recipient;
   (b) SimpleFit controller + coach separate controller for own use;
   (c) joint controllers (Art. 26) for invitation and display.
4. **Recommendation:** (b), with counsel testing (c) for the invitation step.
5. **Engineering:** none for (a)/(b); (c) needs an Art. 26 arrangement summary
   in the Privacy Notice and a contact point for rights.
6. **Counsel:** mandatory (Q-01).

### L-02 — Legal basis
1. **Today:** product collects explicit, version-specific, unticked,
   per-coach acceptance; relationship ends at any time.
2. **Problem:** the basis decides checkbox wording, rights (withdrawal vs.
   objection) and retention.
3. **Alternatives:** consent; contract; legitimate interests; a mix.
4. **Recommendation:** consent (Art. 6(1)(a)) for C1/C2 display; legitimate
   interests (Art. 6(1)(f)) for stubs, invitations and abuse limits;
   evidence under Art. 5(2)/7(1) accountability.
5. **Engineering:** none now; wording per disclosure Part 3.
6. **Counsel:** mandatory (Q-02, Q-03).

## B. Texts

### L-03 — Exact disclosure wording
1. **Today:** SF-60 review lists fields + never-shared; stub mentioned only
   after acceptance (F-02); E08 says "remove access at any time" (F-02).
2. **Problem:** the fighter must know before accepting that a name snapshot
   survives the end.
3. **Alternatives:** (a) draft as written; (b) shorter text without the stub
   (not acceptable); (c) remove the stub instead (needs L-05).
4. **Recommendation:** (a).
5. **Engineering:** SF-72 copy in 7 locales after approved translations;
   E08 copy; link to full text.
6. **Counsel:** mandatory.

### L-04 — Coach Data Rules
1. **Today:** acknowledgement exists in API and mobile; web lacks the step
   (F-07); no text exists.
2. **Alternatives:** (a) draft as written; (b) fold into Terms (loses
   version-specific acknowledgement); (c) stricter rules with audits.
3. **Recommendation:** (a).
4. **Engineering:** web step; document reference in API.
5. **Counsel:** mandatory.

## C. Retention

### L-05 — Termination and historical snapshots
1. **Today:** stub with name snapshot kept indefinitely (no job).
2. **Problem:** storage limitation; erasure requests; disclosure accuracy.
3. **Alternatives:** (a) keep indefinitely (not defensible); (b) 12 months
   then delete; (c) no name at all (stub = dates only); (d) 6 months.
4. **Recommendation:** (b), name removed earlier on erasure/objection.
5. **Engineering:** retention job; erasure handling; changes SF-56 behaviour
   (explicit follow-up).
6. **Counsel:** mandatory (Q-08).

### L-06 — Invitation retention
1. **Today:** all invitations kept indefinitely with the encrypted address,
   also of non-users (F-03).
2. **Alternatives:** (a) delete at resolution; (b) 90 days resolved, address
   removed after 30 days; (c) 12 months.
3. **Recommendation:** (b): enough for abuse limits and the coach's history.
4. **Engineering:** Oban cron job, counts-only telemetry.
5. **Counsel:** mandatory (Q-07).

### L-07 — Relationship retention
1. **Today:** kept indefinitely; deleted with either profile.
2. **Recommendation:** active while active; ended 12 months (same as L-05).
3. **Counsel:** mandatory.

### L-08 — Consent/acknowledgement evidence retention
1. **Today:** evidence lives on rows deleted with the counterparty (F-04);
   acknowledgements deleted with the coach profile.
2. **Alternatives:** (a) keep as is; (b) separate minimal evidence records
   (ids, version, timestamp, no names) retained end/deletion + 3 years;
   (c) + 6 years.
3. **Recommendation:** (b), period decided by counsel (Q-09).
4. **Engineering:** evidence table(s) not cascading with the counterparty;
   migration in SF-72 or the retention task.
5. **Counsel:** mandatory.

### L-09 — Account deletion and erasure
1. **Today:** no deletion feature; manual deletion cascades to the
   counterparty's history and leaves addresses on invitations (F-04/F-05).
2. **Alternatives:** (a) keep cascade; (b) deletion service with detached
   evidence, neutral stubs, invitation address removal.
3. **Recommendation:** (b) as a dedicated task before or with activation.
4. **Counsel:** mandatory.

## D. Versions and publication

### L-10 — Document versioning
Recommendation: registry + naming convention (consent and versioning §5); no
version assigned until approval; production rejects `DRAFT`. Engineering:
SF-72 registry and boot check.

### L-11 — Locale and translation policy
Recommendation: English canonical; one version id across languages, per
language hash and approval; English fallback with notice; no activation in a
market without its approved official-language text (counsel per market).

### L-12 — Publication URLs and ownership
Recommendation: public web pages `/<locale>/legal/<document-id>` and
`/<locale>/legal/<document-id>/<version>`; product owns, counsel approves,
engineering publishes approved files only. URLs to be assigned in SF-72; none
exist now.

### L-13 — Re-consent on version changes
Recommendation: material change → new id; coaches re-acknowledge before
inviting; disclosure widening → new acceptance per relationship; narrowing
applies immediately; every material change is notified; version withdrawal
only with notice (F-11).

## E. Scope and global documents

### L-14 — Minimum age and safeguarding
1. **Today:** 16+ at registration, no guardian flow, no youth coaching.
2. **Problem:** 16–17-year-olds are minors; adult coaches can connect; UK
   Children's code applies to under-18s.
3. **Alternatives:** (a) launch as is (16+); (b) coaching connections only for
   fighters aged 18+ at launch, 16–17 later with safeguarding measures;
   (c) raise account minimum to 18.
4. **Recommendation:** (b), pending counsel/safeguarding review; it needs a
   server-side age check at acceptance (date of birth exists, never shown to
   coaches).
5. **Engineering:** acceptance prerequisite (SF-72), copy for under-18s.
6. **Counsel:** mandatory (Q-04, Q-05).

### L-15 — Global Privacy/Terms
Recommendation: publish both documents with the changes in the impact matrix;
supply operator identity, processors, transfers. Counsel mandatory.

## F. Release

### L-16 — Feature-gate activation and rollback
1. **Today:** gate off by default; rollback stops new data flows; coaches
   cannot list to end while off (F-08).
2. **Recommendation:** activation only after the checklist §2; add a minimal
   gate-off coach list (ids + display name) as a separate approved follow-up,
   or document support-assisted ending.
3. **Counsel:** mandatory for activation; the follow-up is a product decision.
