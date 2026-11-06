# 01 — D-G11 publishing: decision proposal

**Status: PROPOSED.** The defaults below are recommendations. Only the rows marked
APPROVED cite an existing decision.

Already decided, and not reopened here:

* The **verification half** of D-G11 is decided by SF-103 (ADR 0026, amendment SF-103).
* Setup, verification, Stripe capabilities, readiness and publication are separate facts,
  none implying another (same amendment).
* Production review is fail-closed until a real authority exists (ADR 0026, amendment SF-136).

## Decisions

### D-G11.1 Is business verification required?

* **Problem:** an unverified listing lets anyone claim to be a real gym.
* **Default:** yes. An `approved` application with **trusted attribution** is required to
  request publication and to stay published. A row attributed only by a legacy `operator`
  address or `local_fixture` doesn't count (SF-136 says such rows prove nothing).
* **Alternatives:** (a) publish unverified with no badge: faster, weaker against
  impersonation. (b) Verification required only for the badge: same weakness.
* **Trade-off:** the default blocks publication until SF-110, which is already blocking review.
* **Owner:** founder. **Depends on:** SF-110. **Status:** PROPOSED.

### D-G11.2 Must a trusted operator approve publication?

* **Problem:** owner self-publication would make the public surface unreviewed.
* **Default:** yes, by a trusted operator with `approve_publication`, separate from verification.
* **Alternatives:** (a) automatic once verified, with reactive moderation: cheap, but
  unreviewed text and images reach the public. (b) Automatic after a pilot: a sensible later change.
* **Trade-off:** review is a staffing cost; pilot volume should be small.
* **Owner:** founder. **Depends on:** SF-110. **Status:** PROPOSED for the requirement;
  APPROVED that no shell string or email may authorize it (SF-136).

### D-G11.3 Who asks for publication?

* **Problem:** publication must be the gym's own choice.
* **Default:** the owner alone requests, explicitly, after an attestation that they may
  publish the content. Nothing requests it on the owner's behalf.
* **Alternatives:** managers may also request: convenient, but verification is owner-only today.
* **Owner:** founder. **Depends on:** the owner controls task. **Status:** PROPOSED.

### D-G11.4 What is disclosed publicly?

* **Problem:** the gym row mixes private and business data.
* **Default:** an explicit allowlist ([03](03-public-field-matrix.md)). The first release:
  name, slug, gym type, tagline, city, country; optional business address, phone and website
  only by owner opt-in. No schedule, coaches, images or counts.
* **Alternatives:** the design's fuller profile (WG8, MK5): richer, but each extra field adds
  a privacy and moderation dependency.
* **Owner:** founder and legal. **Depends on:** the legal checklist. **Status:** PROPOSED.

### D-G11.5 Which jurisdictions?

* **Problem:** business identity, consumer and privacy duties vary by country. Policy
  `sf103-generic-1` has no per-country requirement.
* **Default:** an explicit country allowlist, **empty by default** (nothing is eligible until
  a country is added by an approved change). Candidate first market: Poland, for counsel to confirm.
* **Alternatives:** the EU at once: more legal work first.
* **Owner:** founder and legal. **Depends on:** counsel. **Status:** BLOCKED on legal review.

### D-G11.6 Which gyms may have a public page?

* **Default:** setup `completed`, active primary location in an allowed country, eligible
  verification, an approved snapshot, status `published`, and not closed. All checked on
  the server at read time. A paid plan is **not** a condition.
* **Alternatives:** require a paid plan: mixes commerce with trust, and D-G09 is unapproved.
* **Open gap:** no gym closure state exists today (only a `close_gym` permission and a
  `gym_closed` reason), so "not closed" has nothing to read yet.
* **Owner:** founder. **Depends on:** a closure state. **Status:** PROPOSED.

### D-G11.7 Which gyms appear in discovery?

* **Default:** a separate, later step. The first release is a direct-link public page with no
  listing. When added: the same eligibility, plus at least the `discoverable` opt-in.
* **Alternatives:** launch page and listing together: a listing raises the stakes of every
  gap, and needs search work that doesn't exist.
* **Note:** the design's Sponsored labels and promoted ordering (MK4) are out of scope.
* **Owner:** founder. **Status:** DEFERRED, default PROPOSED.

### D-G11.8 Search engine indexing?

* **Default:** `noindex` for the first release, turned on per decision once takedown handling
  has been exercised. Then only eligible gyms, with explicit owner consent to indexing.
* **Alternatives:** indexable from day one: better reach, slower to undo.
* **Owner:** founder. **Status:** PROPOSED.

### D-G11.9 Owner withdrawal

* **Default:** available at any time, immediate, no review, doesn't touch operations. The
  owner may republish an unchanged approved snapshot without review if still eligible.
* **Alternatives:** review on every republish: safer against flip-flopping, more operator work.
* **Owner:** founder. **Status:** PROPOSED.

### D-G11.10 Platform suspension

* **Default:** a trusted operator can suspend at once for a stated reason. Temporary and
  reversible by an operator. Also automatic in the same transaction if verification is revoked.
* **Alternatives:** two-person suspension: slower in an emergency. Prefer one person to
  suspend and two to revoke, if a two-person rule is adopted at all.
* **Owner:** founder and trust and safety. **Depends on:** SF-110. **Status:** BLOCKED on SF-110.

### D-G11.11 Operator revocation

* **Default:** a permanent end to the current eligibility, with a reason; a new application
  only after a defined review. Separate permission from suspension.
* **Alternatives:** no revocation, only suspension: leaves permanent cases looking temporary.
* **Owner:** founder and legal. **Depends on:** SF-110. **Status:** BLOCKED on SF-110.

### D-G11.12 Moderation and complaints

* **Default:** a report path open to anyone, reviewed by operators, with an audited outcome
  and notice to the gym ([06](06-security-and-moderation.md)). It must exist before the first
  public page, not after.
* **Alternatives:** an email inbox for the pilot: acceptable only if counsel agrees it meets
  notice-and-action duties and it's still audited.
* **Owner:** founder and legal. **Status:** PROPOSED; legal shape BLOCKED.

### D-G11.13 Legal and privacy prerequisites

* **Default:** the mandatory items in [07](07-legal-checklist.md) are signed off by counsel
  before activation. No legal document covers public gym profiles today, and the production
  legal registry is empty.
* **Owner:** legal and founder. **Status:** BLOCKED.

### D-G11.14 Reverification

* **Problem:** verification has **no expiry** today; an approval lasts until revoked.
* **Default:** reverification every 12 months while published, and on a legal name change,
  country change or ownership transfer. Failing it suspends publication.
* **Alternatives:** no expiry, with reports as the only signal: cheaper, and a closed business can look current.
* **Owner:** founder and legal. **Depends on:** a change to the verification policy. **Status:** PROPOSED.

### D-G11.15 Reactivation

* **Default:** withdrawn: owner republishes (D-G11.9). Suspended: operator lifts, with a
  reason. Revoked: a new application after review. Rejected: a new request after changes.
* **Alternatives:** a cooling-off period after revocation: a policy choice for trust and safety.
* **Owner:** founder and trust and safety. **Status:** PROPOSED.

## Summary

| Id | Topic | Status | Owner |
| --- | --- | --- | --- |
| D-G11.1 | Verification required | PROPOSED | Founder |
| D-G11.2 | Trusted operator approval | PROPOSED; no-shell-authority APPROVED | Founder |
| D-G11.3 | Owner request | PROPOSED | Founder |
| D-G11.4 | Public disclosure | PROPOSED | Founder, legal |
| D-G11.5 | Jurisdictions | BLOCKED | Founder, legal |
| D-G11.6 | Page eligibility | PROPOSED | Founder |
| D-G11.7 | Discovery | DEFERRED | Founder |
| D-G11.8 | Indexing | PROPOSED | Founder |
| D-G11.9 | Withdrawal | PROPOSED | Founder |
| D-G11.10 | Suspension | BLOCKED | Founder, trust and safety |
| D-G11.11 | Revocation | BLOCKED | Founder, legal |
| D-G11.12 | Moderation | PROPOSED; legal shape BLOCKED | Founder, legal |
| D-G11.13 | Legal prerequisites | BLOCKED | Legal, founder |
| D-G11.14 | Reverification | PROPOSED | Founder, legal |
| D-G11.15 | Reactivation | PROPOSED | Founder, trust and safety |
