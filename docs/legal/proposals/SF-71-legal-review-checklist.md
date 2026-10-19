# SF-71 — Legal review checklist, activation gate and rollback

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71 (brief §14). Coach–Fighter sharing stays **disabled**
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

## 2. Activation checklist (all required)

1. ☐ Approved Fighter Data Sharing Disclosure (product + counsel, recorded).
2. ☐ Approved Coach Data Access & Usage Rules.
3. ☐ Approved version ids in the document registry (no `DRAFT`).
4. ☐ Published, accessible legal pages (canonical URL per version and
   language), linked from preview, acknowledgement and E08.
5. ☐ Approved retention matrix (L-06–L-08) and the retention task scheduled
   or done.
6. ☐ Privacy Notice and Terms published/updated (impact matrix), operator
   identity filled in.
7. ☐ SF-72 backend and web/mobile integration merged (registry, references,
   web acknowledgement step, copy fixes F-02/F-09/F-10, E08 privacy link).
8. ☐ Acceptance and acknowledgement verified end to end on a production-like
   environment with the approved versions.
9. ☐ Stale-version handling verified (current version change → `409`,
   withdrawn version → no disclosure + notice).
10. ☐ Multi-account security tests (recipient binding, foreign ids `404`,
    cross-account sessions, gym/sponsor isolation).
11. ☐ Native and web quality checks for every surface (including native QA
    still NOT VERIFIED for SF-61).
12. ☐ Rollback plan rehearsed (§3).
13. ☐ Authorized release decision recorded (product owner + counsel), per
    market.

## 3. Rollback (gate off after launch) — verified behaviour

| Effect | Behaviour (ADR 0021) |
|---|---|
| New invitations | Stop: create, resend, preview, accept answer `404` |
| New relationships | Cannot be activated |
| Existing relationships | Stay `active` in the database; coaches see nothing (`404`); turning the gate back on revives access only for relationships not ended meanwhile |
| Termination | Fighters can list and end; coaches can end **only if they know the relationship id** (lists are `404`): F-08 |
| Exposure | No fighter data reaches coaches while off |
| Evidence | Untouched (no deletion happens on gate change) |
| Decline / cancel | Still work |

Follow-up proposal (L-16): a minimal coach list available with the gate off,
returning only relationship ids and the fighter's display name, for ending
relationships, approved separately; until then a coach asks support or the
fighter ends.

Removing a disclosure version from configuration (instead of the gate)
discloses nothing for relationships under that version, without telling
users (F-11): use the gate for emergencies, version removal only with notice.
