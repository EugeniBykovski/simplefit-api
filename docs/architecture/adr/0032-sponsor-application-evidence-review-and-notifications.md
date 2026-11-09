# ADR 0032 — Sponsor application evidence, contact verification, review requests and notifications

* Status: **Accepted for implementation in non-production environments** (SF-114, 2026-11-09). Epic SF-106.
  Extends [ADR 0031](0031-sponsor-applications.md) (applications) and
  [ADR 0029](0029-admin-action-framework.md) (admin actions). **Uploads and sponsor emails are off in
  production** until D-SA09 (scanner) and the S7 email copy are decided; the declaration stays BLOCKED (ADR 0031).
* Context: ADR 0005 (providers), 0006 (Oban), 0008 (observability), 0011 (email), 0012 (codes),
  [SF-103's gym evidence](0026-gym-domain-architecture.md), the
  [decision register](../sponsor-admin-decision-register.md) (D-SA03, D-SA09, D-SA18, D-SA22).

## Problem

SF-113 left applications without documents, without a verified contact, without a way for an operator to ask
for changes and without any email. Each needs the same guarantees as the rest of the platform: private storage
the server verifies, secrets stored only as keyed digests, operator writes through the declared action
framework, and emails that exist exactly when the change that caused them commits. None of it may grant access,
and none of it may decide retention, legal copy or approval.

## Decision

1. **Evidence** (`Sponsors.Evidence`, table `sponsor_application_evidence`), on the SF-103 pattern:
   * The applicant announces `kind` (`logo`, `brand_deck`, `campaign_brief`, `other`), `file_name`,
     `content_type` (PDF, JPEG, PNG) and `byte_size` (at most 10 MiB) at the application's `expected_revision`.
     At most five live documents. The server builds the key
     (`sponsors/applications/<application>/evidence/<evidence>`), records `pending_upload` and returns a
     presigned `PUT` for 15 minutes, signed for exactly that type and length. No client key, bucket or URL is
     accepted, and the key never appears in a response, log or snapshot.
   * **Confirm** reads the object with a server-signed `HEAD` **before** taking any lock, then, under the
     application's lock, attaches it only if size and media type match and the upload is within its window plus
     one hour of grace. Repeats answer the same. Missing: `409 upload: not_found`; different: `mismatch`; late:
     `expired`; storage failing: `503`.
   * **Remove** (idempotent) works until the document is part of a submission. Submission freezes the uploaded
     documents into it (`submission_id`); the snapshot lists them by id, kind, type and size, never key or name.
   * A trigger forbids deletes, freezes identity fields and submitted rows, and allows only
     `pending_upload -> uploaded | removed`, `uploaded -> removed`.
   * `EvidenceCleanupWorker` (Oban cron, every 30 minutes) marks uploads unconfirmed 24 hours after their window
     `removed` (`abandoned`) and deletes the **objects** of removed, never-submitted documents (100 per run).
     **Submitted evidence is never deleted**: its retention is D-SA18 (counsel).
   * Every document is reported `scanned: false`. A `HEAD` is not a malware scan. Uploads exist only with
     `evidence_uploads: true` (`SPONSOR_EVIDENCE_UPLOADS=enabled` in production, default off: D-SA09).
     Otherwise the policy says `available: false, reason: "file_scanning_unavailable"` and the endpoints answer
     `503`.
2. **Contact email verification** (`Sponsors.ContactVerification`, table `sponsor_application_contact_codes`):
   a 6-digit code is sent to the application's current contact email; only an HMAC verifier of the code and an
   HMAC digest of the address are stored (keys derived from `secret_key_base`, ADR 0012's pattern). 15 minutes,
   five attempts, one live code per application (a new request supersedes). Success stores the address digest
   on the application: the contact counts as verified only while the contact email is still that address, and
   submissions record `contact_email_verified`. Changing the address after the code was sent voids the code.
   Throttled per user (5 sends, 20 confirms per hour) and per application (3 sends per hour). **Verification
   grants nothing**: no account, identity, membership, workspace or permission, and is never linked to an account
   by email (ADR 0009). It needs email sending (below); without it, `503`.
3. **Operator review** through the SF-111 framework, generalised by an `ActionTarget` behaviour
   (`fetch`, `lock!`, `party?`, `status`, `project`) with `OperatorTarget` and `Sponsors.ReviewTarget`. Lock
   order is session, actor operator, then the application. New permissions (catalogue CHECK widened):
   * `sponsors.applications.read` (key check): audited projection `sponsor_applications.detail`
     (`sponsor_application.viewed`); drafts are invisible.
   * `sponsors.applications.claim` (fresh key check): `submitted -> under_review`, reason `review_started`.
   * `sponsors.applications.request_changes` (fresh key check): `under_review -> changes_requested`, with the
     answers to revisit (1–14 policy answer names) and a 1–2000 character plain-text message, stored in
     `sponsor_application_change_requests` (one open request per application; trigger-guarded; only resolution,
     once). The message isn't audited.
   * An operator is a party to their own application and can't act on it (`409 target: self`). Neither action
     needs a preview confirmation (both are undone by the applicant's next submission); both take
     `expected_revision` and an idempotent `operation_id`. **No approval, rejection or provisioning exists.**
4. **After a change request** the applicant may change only the named answers (others: `422`, field code
   `not_requested`, a new additive reason code); answers sent again unchanged are fine. The next submission
   resolves the request and returns the application to `submitted`.
5. **Notifications** (`Sponsors.ApplicationNotifications`, table `sponsor_application_notifications`): a
   transactional outbox. Inside the transaction that holds the application's lock, one append-only row per
   dedupe key (`submitted:<submission>`, `changes_requested:<request>`, `contact_code:<code>`) records the
   intent and, when sending is enabled and an address exists, inserts the email's Oban job (encrypted payload,
   ADR 0011) in the same transaction. A rolled-back change sends nothing; delivery is at least once, five attempts,
   a provider idempotency key per job. Kinds: application received or resubmitted (to the applicant's oldest
   email identity), changes requested (applicant), contact code (contact address). **No approval or rejection
   email.** Rows hold ids and codes only. Suppressed (recorded, not sent): `delivery_disabled`,
   `no_recipient_address`, `render_failed`; a suppressed notification never fails the change. Telemetry
   `[:simple_fit, :sponsor_application, :notification]` carries kind and status only.
6. **Templates** (`Email.Templates.SponsorApplication`) are factual placeholders: there is no designed or
   approved sponsor email copy (S7), so they are outside the designed inventory (E01–E17) and sending is off in
   production (`application_emails`, `SPONSOR_APPLICATION_EMAILS=enabled`).
7. **Consent.** The legal declaration stays a submission acknowledgement (ADR 0031). Marketing consent is the
   account's existing `product_news` (SF-44), never set, asked for or implied by an application.

## Decisions taken here, and not

| Item | SF-114 |
| --- | --- |
| Uploads (D-SA09, NEEDS DECISION) | Built, **off in production** until a scanner or an accepted risk; never reported scanned |
| Evidence retention (D-SA18) | Not decided: submitted evidence and all rows kept; only never-submitted objects deleted |
| Sponsor email copy (S7) | Not designed: placeholder templates, sending **off in production**, so contact verification is unavailable there |
| Change reasons | `missing_information`, `unclear_answers`, `contact_details`, `company_details`, `other`: proposed defaults |
| Review staffing (D-SA22) | **BLOCKED**: no one named; nothing promises a review time |
| Approval, rejection, reapplication (D-SA03, D-SA10) | Not built |

## Trust boundary

As ADR 0029: the triggers bind the application's database role, not a superuser (D-SA28). Storage presigning
binds type and length, but the object's content is not inspected. A verified contact email proves only that
someone read that mailbox once.

## Consequences

* Production needs `SECRET_KEY_BASE` (already required) and, to turn features on, the two variables above.
* Rollback of the migration refuses once evidence, change requests, notifications, contact verifications or
  sponsor grants exist.
* A later approval task adds its actions to `ReviewActions` and its email to the outbox; retention work
  (D-SA18) adds deletion of submitted evidence.

## Amendment (SF-116)

[ADR 0033](0033-sponsor-application-decisions.md) adds approval, rejection and suspension or reinstatement of an approved organization; a `revoked` state and closing remain unbuilt.
