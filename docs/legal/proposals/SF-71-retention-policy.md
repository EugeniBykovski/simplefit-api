# SF-71 — Coach–Fighter data retention, deletion and data subject rights

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71 (brief §7, §8). **Every period below is PROPOSED**, with its
rationale; none is a legal requirement unless counsel confirms it. No
deletion job may be implemented before this policy is approved (L-06, L-07,
L-08, L-09).

## 1. Principles

* Storage limitation: identifiable data no longer than necessary for its
  purpose (GDPR Art. 5(1)(e)); data protection by default (Art. 25(2)).
* Separate purposes: active data, historical operational records, consent
  evidence, security records, backups, legal holds.
* A record kept for a legal claim is kept only as long as the claim can be
  made: the Polish general limitation period is six years, three years for
  periodic claims and claims connected with business activity, ending on the
  last day of a calendar year (Civil Code art. 118). Whether any claim
  relevant to coach–fighter connections exists is a counsel question (Q-09).
* Deletion is hard deletion in the primary database; backups expire on their
  own rotation (§5).

## 2. Retention matrix

Legend: **Legal basis** = proposal for counsel (L-02); **Owner** = system
owning the deletion. Periods are PROPOSED.

| # | Data category | Purpose | Proposed legal basis | Retention trigger | Period (PROPOSED) | Deletion method | Owner |
|---|---|---|---|---|---|---|---|
| 1 | Pending invitations | Let the recipient respond | Art. 6(1)(f) (coach's and SimpleFit's interest in delivering a requested invitation) | Creation; status stays pending until expiry (14 days, implemented) | Until resolved or expired | Transition to expired (implemented, derived) | Coaching |
| 2 | Accepted invitations | Consent evidence; idempotent acceptance | Art. 7(1) evidence / 6(1)(c) or (f) | `responded_at` | Keep the evidence fields per row 12; reduce the row (drop `recipient_sealed`, `message`) **30 days** after acceptance | Scheduled job: null sealed address and note | Coaching (retention job) |
| 3 | Declined invitations | Prevent re-invite abuse; show outcome to coach | 6(1)(f) | `responded_at` | **90 days** | Hard delete | Coaching (retention job) |
| 4 | Cancelled invitations | Coach's history | 6(1)(f) | `responded_at`/cancel time | **90 days** | Hard delete | Coaching |
| 5 | Expired invitations | Coach's history, abuse limits | 6(1)(f) | `expires_at` | **90 days** after expiry | Hard delete | Coaching |
| 6 | Token hashes | Single-use verification | 6(1)(f) | Resolution / expiry | Same row as 1–5; for resolved rows null the hash at resolution + 30 days | Null / delete with row | Coaching |
| 7 | Recipient email digests (HMAC) | One pending per coach+recipient; per-recipient rate limit | 6(1)(f) | Row lifetime | With the row (rows 1–5) | Delete with row | Coaching |
| 8 | Encrypted recipient address | Resend; masked display | 6(1)(f) | Resolution | Pending: until resolved/expired; then **≤ 30 days** (rows 2–5) | Null the column, then row deletion | Coaching |
| 9 | Resend counters, `last_sent_at` | Abuse limits | 6(1)(f) | Row lifetime | With the row | Delete with row | Coaching |
| 10 | Delivery metadata | Send email | 6(1)(f) | Job completion | Oban job incl. encrypted payload: **1 day** (implemented); email provider logs: per the processor agreement **[to confirm with provider]** | Oban Pruner; provider retention | Email / Ops |
| 11 | Coach Data Rules acknowledgements | Prove the coach accepted the rules (Art. 5(2) accountability) | 6(1)(c)/(f) | Acknowledgement; account deletion | Account lifetime **+ 3 years** (claims connected with business activity, art. 118 KC), counsel to confirm | Retention job after account deletion (requires detaching from the profile, L-08) | Coaching |
| 12 | Fighter acceptance records | Prove the fighter accepted a specific version (Art. 7(1) if consent) | 6(1)(c)/(f) | Relationship end or account deletion | End of relationship **+ 3 years** (counsel: 6 years?), minimal fields only (no address, no note) | Retention job | Coaching |
| 13 | Active relationships | Provide the connection | per L-02 | Activation | While active | — | Coaching |
| 14 | Ended relationship records | Both sides see their history; disputes | 6(1)(f) | `ended_at` | **12 months** after end (L-05 recommendation), then delete the row (evidence kept per row 12) | Retention job | Coaching |
| 15 | Fighter display-name snapshot | Coach's history | 6(1)(f) | `ended_at` | **12 months** with the stub (row 14); erasure on request earlier (§4) | Null/delete with row | Coaching |
| 16 | Coach display-name snapshot | Fighter's history | 6(1)(f) | `ended_at` | **12 months** with the stub | Null/delete with row | Coaching |
| 17 | Training relationships referenced by future sessions | — | — | — | **Not applicable today** (no Training domain); the Training task must define its own retention and must not extend relationship retention silently | — | Training (future) |
| 18 | Security/audit metadata | Abuse prevention, incident response | 6(1)(f) | Event | Rate-limit windows: removed hourly after expiry (implemented); application logs carry outcomes only, no personal data: **[log retention to confirm with hosting]** | Window cleanup; log retention | Ops |
| 19 | Transactional email jobs (E08) | Delivery | 6(1)(f) | Completion | **1 day** (implemented, Oban Pruner) | Pruner | Email |
| 20 | Deleted-account records and backups | — | — | Account deletion | Primary DB: cascade at deletion (implemented, but see §3); backups: roll off with backup rotation **[period to confirm with hosting, proposal ≤ 35 days]**; restored backups re-apply deletions | Backup rotation + deletion log | Ops |

## 3. Account deletion today (verified)

There is no account-deletion operation in the product (settings screens are
placeholders). If a `users` row is deleted (manually), PostgreSQL cascades:

* the user's account profile, consents, identities, sessions, fighter and
  coach profiles;
* **all relationships on both sides** (`coach_fighter_relationships` FKs
  `ON DELETE CASCADE`): the counterparty loses its ended stub and the
  relationship evidence;
* a coach's invitations and Data Rules acknowledgements (evidence lost);
* a fighter's acceptance evidence on the coach's invitation rows is **kept**,
  with the fighter's encrypted address; `relationship_id` becomes NULL
  (finding F-04).

Implications: erasure works for the deleting user's own profile but deletes
the other party's history and consent evidence, and leaves the fighter's
address on invitation rows. Proposal (L-09): a dedicated account-deletion task
that (a) deletes the user's profile data, (b) keeps only the minimal evidence
rows required by rows 11–12, detached from profiles (no names), (c) removes the
fighter's address from invitations, (d) leaves the counterparty a stub without
the deleted person's name ("Deleted user"), and (e) documents backup handling.

## 4. Data subject rights

| Right | Expected behaviour | Today |
|---|---|---|
| End relationship | Immediate revocation of live access; stub per row 14 | implemented |
| Account deletion / erasure (Art. 17) | §3 proposal; exceptions only for evidence needed for legal claims (Art. 17(3)(e)) | manual only |
| Access (Art. 15) / portability (Art. 20) | Export of profile, relationships (incl. stubs), invitations received, acceptance records | not implemented; manual |
| Rectification (Art. 16) | Profile fields editable by the user; coach sees the change live; snapshots are historical and not rewritten except on erasure | partly (profile edit) |
| Withdrawal of consent (Art. 7(3)) — if consent is the basis | Ending the relationship = withdrawal for that coach, as easy as accepting | implemented (end) |
| Objection (Art. 21) / restriction (Art. 18) — if 6(1)(f) | Objection to stub retention → delete the snapshot unless compelling grounds; restriction → manual | manual |
| Non-users (invited addresses) | Request handled by support; deletion of pending invitation + digest | manual |

## 5. Backups

Backups contain deleted data until they expire. Proposal: no restoration of
individual records into production; if a backup is restored, a deletion log
(ids only) is replayed before the system goes live. Backup period and
location are hosting facts to be supplied ([to confirm]).

## 6. The historical stub (SF-56) — reconciliation

* **Why kept:** both sides can see whom they worked with and when (operational
  history, disputes about who ended what), and the fighter sees which coaches
  saw their data in the past (transparency).
* **Fields:** relationship id, start/end dates, `ended_by`, the other side's
  display name at the end. No profile data.
* **Is the name necessary?** Without it the stub is an unlabeled date range,
  of little use to the coach. A defensible middle ground: keep the name for a
  limited period (12 months, PROPOSED), then drop the row; delete the name
  earlier on an erasure or objection request.
* **Who may access:** only the two parties (implemented: `404` for anyone
  else; coach stubs only with the gate on).
* **After an erasure request:** the requester's name snapshot in the other
  party's stub is removed (replaced by a neutral label) unless counsel
  identifies an overriding ground.
* **Defensibility:** plausible under Art. 6(1)(f) with a short period and the
  disclosure saying so before acceptance (finding F-02 must be fixed).
  Counsel to confirm (Q-08).

Implementing the period, the erasure behaviour or "Deleted user" labels
**changes SF-56 behaviour** and needs its own approved follow-up (proposed:
retention-engineering task after SF-72).
