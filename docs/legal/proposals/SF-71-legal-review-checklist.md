# SF-71 — Legal review checklist, activation gate and rollback

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71 (brief §14). Product policy PRODUCT_APPROVED 2026-10-19; no
item is legally approved. Coach–Fighter sharing stays **disabled**
(`COACHING_ACCESS_ENABLED` unset/false, no disclosure or Data Rules version
configured). SF-71 changes no configuration.

## 1. Questions for counsel

| ID | Question | Blocks activation |
|---|---|---|
| Q-01 | Roles: SimpleFit controller; coach separate or joint controller (invitation, roster, off-platform notes); Art. 26 arrangement needed? | Yes |
| Q-02 | Legal basis for showing C1/C2 to a coach (consent proposed), for stubs and invitations (6(1)(f) proposed), for evidence retention | Yes |
| Q-03 | Can any C1/C2 field be health data in context (Art. 9)? | Yes |
| Q-04 | Safeguarding: may adult coaches connect with 16–17-year-old fighters? Additional measures? | Yes |
| Q-05 | Capacity of 16–17-year-olds to accept Terms / coaching arrangements per market | Yes (per market) |
| Q-06 | E08 to non-users: Art. 14 content; "commercial information" under PL art. 398 and other markets' ePrivacy rules | Yes |
| Q-07 | Retention periods (all PROPOSED values in the retention policy) | Yes |
| Q-08 | Ended stub with name snapshot: basis, period, erasure behaviour | Yes |
| Q-09 | Which claims (if any) justify keeping consent evidence, and for how long | Yes |
| Q-10 | Re-consent and notice rules on document changes (material-change definition) | Yes |
| Q-11 | Languages required per market before activation | Per market |
| Q-12 | Privacy Notice / Terms content, operator identity, transfers, processors | Yes |
| Q-13 | Digital Omnibus (COM(2025) 836) and UK DUAA 2025 status and impact | No (monitor) |
| Q-14 | DSA obligations for coach profiles and notes (notice-and-action) | Counsel to decide |
| Q-15 | Per-operation roles (privacy impact §2.1, R1–R9): joint controllership for invitation creation (R1) and roster display (R4); when the coach becomes a controller | Yes |
| Q-16 | Evidence records after account deletion: keep user ids or replace by a keyed digest; erasure exception (Art. 17(3)(b) or (e)); who may access | Yes |
| Q-17 | Is acceptance of a text in a language other than the app language (user-chosen English) informed acceptance, per market? | Yes (per market) |
| Q-18 | Notification and revocation policy for narrowing or emergency withdrawal of a disclosure version: content, timing, whether relationships end | Yes |

## 2. Activation checklist (all required)

1. ☐ Approved Fighter Data Sharing Disclosure (product + counsel, recorded).
2. ☐ Approved Coach Data Access & Usage Rules.
3. ☐ Approved version ids in the document registry (no `DRAFT`), with an
   approved variant in the official language of every launch market (L-11).
4. ☐ Published, accessible legal pages (current and versioned URL per
   language), linked from preview, acknowledgement and E08 (T-1).
5. ☐ Privacy Notice and Terms published/updated (impact matrix), operator
   identity filled in (T-1, L-15).
6. ☐ Approved retention matrix (L-05 – L-08) and the retention job live (T-2).
7. ☐ Account deletion workflow live, with evidence exceptions and no
   cross-user cascade (T-3, L-09).
8. ☐ Gate-off relationship management live (T-4, L-16).
9. ☐ Approved notification and revocation policy for narrowing and
   emergency withdrawal (Q-18).
10. ☐ SF-72 merged (registry, references, evidence records, web
    acknowledgement step, 18+ acceptance check, language rule, copy fixes
    F-02/F-09/F-10, E08 privacy link).
11. ☐ Acceptance and acknowledgement verified end to end on a production-like
    environment with the approved versions, including the 18+ check and the
    "not available in your language" outcome.
12. ☐ Stale-version handling verified (current version change → `409`;
    scope-widening version rejected at boot).
13. ☐ Multi-account security tests (recipient binding, foreign ids `404`,
    cross-account sessions, gym/sponsor isolation, age not revealed to the
    coach).
14. ☐ Native and web quality checks for every surface (including native QA
    still NOT VERIFIED for SF-61).
15. ☐ Rollback rehearsed: gate off and on (§3.1) and a permanent revocation
    (§3.2).
16. ☐ Authorized release decision recorded (product owner + counsel), per
    market.

## 3. Rollback — temporary shutdown versus permanent revocation

### 3.1 Temporary operational shutdown: gate off (verified behaviour)

Turning `COACHING_ACCESS_ENABLED` off is an **operational pause**. It does
**not** terminate any relationship.

| Effect | Behaviour (ADR 0021) |
|---|---|
| New invitations | Stop: create, resend, preview, accept answer `404` |
| New relationships | Cannot be activated |
| Existing relationships | **Stay `active` in the database**; coaches see nothing (`404`) |
| Re-enabling the gate | **Restores coach access to every relationship still `active`**, without asking the fighter again |
| Termination | Fighters can list and end; coaches can end **only if they know the relationship id** (lists are `404`): F-08, closed by T-4 |
| Exposure | No fighter data reaches coaches while off |
| Evidence | Untouched (no deletion happens on gate change) |
| Decline / cancel | Still work |

Use it for incidents where access must stop at once and may resume
unchanged. Before re-enabling, confirm that the cause is fixed and that no
relationship should have been ended meanwhile.

### 3.2 Permanent revocation

When access must not come back by flipping the gate, one of these is needed
in addition to (or instead of) the gate:

| Action | Effect | Status |
|---|---|---|
| End a relationship | Live access ends for good; stub per retention policy | Implemented (either side, gate-independent) |
| End many relationships (operator action) | Same, in bulk, with notice to both sides | Not implemented; part of the approved revocation policy (Q-18) and T-4 |
| Withdraw a disclosure version | Relationships under it disclose nothing | Only with the approved notification and revocation policy (consent and versioning §4.2); silent removal is not a procedure (F-11) |

### 3.3 Gate-off relationship management (T-4)

A minimal, management-only mechanism lets a coach end relationships while the
gate is off: relationship id and the fighter's display name only, no other
profile data, no invitation actions. Until T-4 ships, a coach asks support or
the fighter ends.
