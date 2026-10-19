# SimpleFit Boxing — Coach Data Access & Usage Rules

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

* Ticket: SF-71. Proposed document id: `coach-data-rules`. Proposed version:
  `coach-data-rules-DRAFT-1` (not approved; never configured in production).
* Canonical language: English. Translations: none approved.
* Applies to the implementation audited on 2026-10-19; inviting is not
  available on SimpleFit Boxing today.
* `[…]` = facts SimpleFit must supply or counsel must confirm.
* Approval: separate, versioned rules with explicit acknowledgement
  **PRODUCT_APPROVED** 2026-10-19 (L-04); the text is
  **PROPOSED_PENDING_LEGAL_REVIEW**; nothing here is legally approved.

---

## Part 1 — Full text for legal review

### 1. Purpose and scope

These rules apply to you when you use SimpleFit Boxing as a coach and invite
fighters to connect with you. They explain what fighter information you may
see, what you may do with it, and what you must not do. You must accept the
current version before you can invite fighters. They add to the SimpleFit
Terms of Service [link to be assigned]; if they conflict, these rules apply
to fighter information.

### 2. What you can see

You see a fighter's information only while you have an active connection
that the fighter accepted, and only the information that fighter agreed to
share. Under the current disclosure this is: display name, username,
country, city, experience level, stance and number of amateur bouts (some may
be empty). You never see a fighter's goals, next fight, weight, weight
class, height or other body measurements, account name, date of birth, email
address, or other coaches. Only fighters aged 18 or older can connect with
coaches.

The fighter can end the connection at any time. When a connection ends, you
immediately stop seeing the fighter's information. SimpleFit keeps, and shows
you, only a short record: the dates, who ended it and the fighter's display
name at the end.

### 3. Using fighter information

You may use fighter information only to coach that fighter and to manage your
coaching relationship with them ("coaching purposes"). [Counsel: confirm the
coach's role for each operation (invitation, viewing, use outside the
platform) and what that requires of the coach, L-01, Q-15.]

### 4. Keeping it confidential

You must keep fighter information confidential and take reasonable care to
protect it, including on any device you use to access SimpleFit Boxing. Do not
share your account. Tell SimpleFit at [security contact] if you believe
fighter information was accessed or disclosed without permission.

### 5. What you must not do

You must not:

1. sell, rent, publish or otherwise distribute fighter information;
2. use fighter information for marketing, including marketing your other
   services, unless the fighter separately agreed to it outside this
   connection in a lawful way;
3. share fighter information with anyone else (including a gym, its owner or
   staff, sponsors, or other coaches) without a lawful basis and, where
   required, the fighter's permission;
4. try to get information beyond what the fighter agreed to share, or get
   around SimpleFit's access controls (for example by creating accounts,
   guessing links or using automated tools);
5. collect or build lists of fighter profiles outside your accepted
   connections;
6. keep or use fighter information contrary to the law that applies to you;
7. invite someone without a genuine coaching reason, or invite the same
   person repeatedly after they declined.

SimpleFit limits what its platform shows you, but it cannot technically
prevent everything you do with information once you have seen it. You are
responsible for complying with these rules and the law.

### 6. When a connection ends

* SimpleFit removes your access to the fighter's profile information
  immediately.
* You keep seeing the short record described in section 2 for [period:
  12 months is the product-approved proposal, PROPOSED_PENDING_LEGAL_REVIEW
  (L-05)]. The fighter's name may be removed from it earlier if the fighter
  deletes their account or objects.
* Information you copied, noted or stored outside SimpleFit Boxing while
  connected: you must delete it or stop using it once you no longer need it
  for coaching purposes, unless the law requires you to keep it. [Counsel:
  confirm, L-01.]

### 7. Several coaches, gyms and other workspaces

A fighter may connect with several coaches. Each connection is separate: your
connection gives you nothing from the fighter's other connections. Your
connection is personal to you: it does not extend to any gym, gym owner,
gym staff, sponsor workspace or other coach, and you must not let them use
it.

### 8. Invitations

When you invite someone, you provide their email address. Use only an address
you are entitled to use for this purpose, for a person you genuinely intend to
coach. SimpleFit sends one invitation email on your behalf [counsel: "on your
behalf" vs. SimpleFit's own message, F-06] and lets you resend it a limited
number of times. Your note must not contain marketing, offensive content or
other people's personal information.

### 9. Enforcement

If you break these rules, SimpleFit may remove your access to fighter
information, end your connections, suspend inviting or your account, and
inform affected fighters or authorities where the law requires. [Counsel:
align with the Terms of Service and the notice-and-action rules that apply to
SimpleFit, including the Digital Services Act if applicable.]

### 10. Changes and versions

SimpleFit may update these rules. If a change is material (section 4 of the
versioning policy), you must accept the new version before you can invite
again; your existing connections continue. You can always read the version
you accepted.

### 11. Acknowledgement

By ticking the box and selecting "Acknowledge", you confirm that you have
read and will follow version [version] of these rules.

---

## Part 2 — Concise acknowledgement copy (web and mobile)

> **Before inviting fighters**
> You see only what each fighter agrees to share (name, username, place,
> level, stance, bouts), only while connected, and you may use it only to
> coach them. Never sell, publish, market with or pass it on, including to a
> gym. When a fighter ends the connection, your access ends at once.
> [Read the Coach Data Access & Usage Rules (link)]

## Part 3 — Checkbox text (unticked by default)

> ☐ I have read and will follow the Coach Data Access & Usage Rules (version
> {version}).

Button: **Acknowledge** (disabled until ticked). Secondary: **Not now**.

## Part 4 — Version rollover policy

* An acknowledgement is valid only for the exact version it names.
* **Material change** (L-13): a new version id; inviting and resending stop
  until the coach acknowledges it (the API already returns `409
  data_rules_acknowledgement: required` for a stale version). Existing
  relationships continue; coaches are informed of the change.
* **Non-material change** (typo, formatting, translation of an unchanged
  meaning): the same version id, a new content hash and a changelog entry; no
  new acknowledgement. Whether a change is material is decided by product and
  counsel, never by engineering.
* Older versions stay archived and readable.

## Part 5 — Backend contract requirements for SF-72

Canonical specification: [SF-72](../../architecture/proposals/SF-72-legal-document-integration-spec.md).

1. `COACHING_DATA_RULES_VERSION` may only name a version present in the
   approved document registry; boot fails otherwise (fail closed).
2. `GET /me/coach/data-rules` additionally returns the document reference
   (`url`, `effective_at`), additive change.
3. Acknowledgement stays append-only, per coach profile and version, server
   timestamped, never inferred from registration, never preselected.
4. Web gains the acknowledgement step (mobile has it, SF-61).
5. Evidence per L-08: a separate acknowledgement evidence record written in
   the same transaction (acknowledgements currently disappear with the coach
   profile); retention period pending counsel.
6. Acknowledgement only with an approved variant in the coach's app
   language (L-11).
