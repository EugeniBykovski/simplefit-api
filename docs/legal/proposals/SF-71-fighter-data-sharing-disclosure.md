# SimpleFit Boxing — Fighter Data Sharing Disclosure

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

* Ticket: SF-71. Proposed document id: `fighter-coach-disclosure`.
  Proposed version: `fighter-coach-disclosure-DRAFT-1` (not approved; never
  configure a `DRAFT` identifier in production, see
  [consent and versioning](SF-71-consent-versioning.md)).
* Canonical language: English (L-11). Translations: none approved.
* Describes the implementation audited on 2026-10-19
  ([integration contract](../../architecture/proposals/SF-71-coaching-legal-integration-contract.md)).
  Coach–Fighter sharing is **not active** on SimpleFit Boxing today.
* Bracketed items `[…]` are facts SimpleFit must supply (operator identity,
  contact details); they are not invented here.

---

## Part 1 — Full text for legal review

### 1. What this document is

You are reading this because a coach invited you to connect with them on
SimpleFit Boxing. It explains what happens to your information if you accept
that invitation, and what does not happen. Accepting is optional. Nothing is
shared with the coach unless you accept.

SimpleFit Boxing is operated by [legal name of the operator], [registered
address], [registration number] ("SimpleFit", "we"). Our Privacy Notice
[link to be assigned] explains how we process your information in general.
This document covers only connections between a fighter and a coach.

### 2. Who receives your information

If you accept, you connect with the coach named in the invitation, as they
appear on SimpleFit Boxing (their display name and, if they gave one, their
coaching or brand name).

The coach is an independent user of SimpleFit Boxing. SimpleFit does not
employ the coach and has not verified the coach's identity, qualifications,
licences or insurance. Please decide yourself whether you want to work with
this coach.

The connection is with this coach only. It does not give access to any gym,
gym owner or staff, sponsor, or other coach, even if the coach works with or
for them.

### 3. What the coach will see

While you are connected, the coach can see the following information from
your fighter profile, as it is at the time they look at it (if you change it,
they see the change):

* **Identity:** your display name, your username, your country and your city;
* **Boxing basics:** your experience level, your stance and your number of
  amateur bouts.

Some of these may be empty if you have not filled them in. The coach sees
only what is filled in.

This list is the whole of what this version of the disclosure shares. If
SimpleFit ever wants to share more with coaches, it will ask you again; a
new version never widens what an existing connection shares.

### 4. What the coach will not see

Through this connection the coach does **not** see:

* your goals, your next fight and its date;
* your weight, weight class, height or other body measurements;
* your account name (full name), date of birth or email address, or how you
  sign in;
* which other coaches you are connected with, or anything you share with
  them.

This describes this connection only. Information you choose to make public
elsewhere on SimpleFit Boxing or outside it is not covered by this document.

### 5. Why the coach receives it

The information is shared so that:

* the coach can recognise you in their list of fighters; and
* you and the coach can start, keep and end your coaching connection on
  SimpleFit Boxing.

Today SimpleFit Boxing offers only this connection. If more coaching features
become available later (for example training plans or sessions), they will be
explained to you before they apply to you.

The coach agreed to SimpleFit's Coach Data Access & Usage Rules before they
could invite you. Those rules limit the coach to using your information for
coaching you and forbid, among other things, selling or publishing it.

### 6. When access starts and ends

* Access starts when you accept the invitation, not when you open it, sign
  in or create an account.
* Access continues until you or the coach end the connection, or until one of
  you deletes their account.
* You can end the connection at any time in Coaches. You do not need to give
  a reason. The coach can end it too.

### 7. What happens when the connection ends

* The coach immediately stops seeing your profile information listed in
  section 3.
* The coach keeps a short record that the connection existed: the dates it
  started and ended, who ended it, and **your display name as it was when the
  connection ended**. You keep the same kind of record about the coach.
  [Retention period to be inserted after approval of L-05; until then: "We
  keep this record for [period] and then delete it."]
* An ended connection cannot be restarted. To work together again, the coach
  must send a new invitation and you must accept it again.
* Anything the coach wrote down or saved outside SimpleFit Boxing while you
  were connected is outside SimpleFit's control; the Coach Data Rules require
  the coach to handle it responsibly. [Counsel: confirm wording and the
  coach's role as a separate controller, L-01.]

### 8. Your rights

[Counsel to confirm the legal basis (L-02) before finalising this section;
the rights below depend on it.]

You can ask SimpleFit for access to your information, correction, deletion,
restriction of processing, or a copy in a portable format, and you can
object to processing based on our legitimate interests. Where processing is
based on your consent, you can withdraw it at any time; ending the connection
withdraws it for that coach. You can complain to a data protection
supervisory authority, in Poland the President of the Personal Data
Protection Office (UODO), or the authority where you live or work. Contact:
[privacy contact to be supplied].

### 9. Your decision

You choose whether to accept or decline. Opening the invitation, signing in,
creating an account or reading this document does not accept it. If you
decline, nothing is shared and the invitation link stops working.

### 10. Version

This is version [approved version id], effective [date]. We record which
version you accepted and when. If a later version shares more, we will ask
you again before it applies to you.

---

## Part 2 — Short in-app disclosure (review screen)

> **If you accept, {coach} sees:** display name · username · country · city ·
> experience level · stance · amateur bouts (only what you filled in).
>
> **Never shared with coaches:** goals and next fight · weight, weight class
> and height · account name, date of birth and email · other coaches.
>
> {coach} is an independent coach, not checked by SimpleFit. You can end the
> connection any time in Coaches; {coach} then stops seeing your profile but
> keeps the dates and your name at the end. [Full disclosure (link)]

## Part 3 — Confirmation checkbox (unticked by default)

> ☐ I agree that {coach} sees the information listed above while we are
> connected. I have read the Fighter Data Sharing Disclosure (version {version}).

Button: **Accept invitation** (disabled until the box is ticked).
Secondary: **Decline**.

[Counsel: if the legal basis is not consent (L-02), replace "I agree" with
"I want to connect with {coach} and share the information listed above".]

## Part 4 — Plain-language summary

* Nothing is shared unless you accept.
* If you accept, the coach sees seven basic profile items, nothing more.
* The coach never sees your weight, goals, real name, date of birth or email.
* You can end the connection whenever you like; the coach then loses access
  but keeps a short record with your name at the end.
* The coach is independent: SimpleFit does not check coaches.

## Part 5 — Versioning and publication metadata

| Field | Value |
|---|---|
| Document id | `fighter-coach-disclosure` |
| Version id | assigned at approval only, format `<document-id>-<YYYY>-<MM>-<seq>` per [consent and versioning](SF-71-consent-versioning.md) §5; one id covers all approved language variants; **none is assigned** |
| Scope binding | `basic_profile` (code-defined field list; the text must list exactly these fields) |
| Status | DRAFT |
| Canonical language | `en` |
| Effective / published dates | to be set at approval |
| Approvers | Product owner; external counsel |
| Content hash | SHA-256 of the canonical text at approval |
| Canonical URL | to be assigned (L-12); none exists |
| Runtime configuration | `COACHING_DISCLOSURES=<version>=basic_profile` (SF-72 only, after approval) |

The UI and the API must refer to the same immutable version: the preview
returns `disclosure.version`, the client renders the text of exactly that
version and echoes it on accept (already enforced: stale → `409`).
