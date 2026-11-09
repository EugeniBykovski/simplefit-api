# ADR 0031 — Sponsor applications: drafts, validation, submission

* Status: **Accepted for implementation in non-production environments** (SF-113, 2026-11-09). Epic SF-106.
  Implements the applicant half of the **proposed** SF-107 lifecycle (task S1). **Submission is closed in
  production** until counsel publishes the sponsor declaration; review (S6) doesn't exist.
* Context: ADR 0009, 0016 (registration), 0017 (entry), 0022 (legal registry), 0027 (proposed), 0030 (sponsor
  organizations), [sponsor-application-lifecycle.md](../sponsor-application-lifecycle.md), the SF-108 design
  (canvas version `1794214317-c2e0`: SPA1 / SP1–SP9, SPX5).

## Decision

1. **Tables** (`SimpleFit.Sponsors`, module `Sponsors.Applications`):
   * `sponsor_applications`: the applicant's user id (never an email; `ON DELETE RESTRICT`), status
     (`draft`, `submitted`, `under_review`, `changes_requested`, `approved`, `rejected`, `withdrawn`), a
     trigger-raised `revision`, the creating `client_request_id`, and **typed answer columns** with CHECKs.
     At most one current (non-terminal) application per applicant. A trigger allows only the lifecycle's
     transitions, locks answers outside `draft` and `changes_requested`, keeps the applicant immutable and
     forbids deletes.
   * `sponsor_application_submissions`: one append-only row per submission: a **versioned, schema-tagged JSONB
     snapshot** built from an allowlist (`sponsor-application-snapshot.v1`) and its SHA-256, the policy version,
     the declaration accepted (document, version, language, text hash), the idempotency key and request digest.
     JSONB is used here only, because the row is immutable, versioned and schema-checked; drafts are columns.
   * `sponsor_application_events`: append-only history, ids and codes only.
   * `sponsor_organizations.source_application_id` gets its foreign key.
2. **Validation policy** `sponsor-application-2026-11.v1` (`Sponsors.ApplicationPolicy`): the fields, codes,
   bands and requiredness in one versioned module, with an endpoint (`getSponsorApplicationPolicy`). Every
   submission records the version. Not a rule engine.
3. **Drafts.** No application from sign-up, intent or an empty save. The first save with at least one non-blank
   answer and `client_request_id` creates the draft (a retry answers the same). Later saves name
   `expected_revision` (stale: `409 revision_conflict`). Only the sent answers change, each validated now; an
   invalid save changes nothing. Drafts live on the server, so they resume on any session or device.
4. **Submission** is its own operation, in one transaction under the application's row lock: idempotency key
   (same request: same answer; other request: `409 conflict`), editable status, revision, the **published
   declaration** (`sponsor-application-declaration` in the legal registry; none published: `409 conflict
   declaration: unavailable`), completeness (`422` naming each missing answer), snapshot, `submitted`, event.
5. **Nothing is granted.** No status creates an organization, membership, capability, agreement, payment or
   verification. `sponsor_id` appears in the DTO only once an approval has created an organization.
6. **Review states** exist in the schema and the trigger but no applicant or public endpoint sets them. Review
   (claim, request changes, approve, reject, approval provisioning through `Sponsors.Provisioning`) is S6,
   through the SF-111 action framework. Tests use a test-support fixture for them.
7. **Entry** (ADR 0017, amended): `intent=sponsor` without a workspace resolves by the real application: none ->
   `sponsor_application`; draft -> `sponsor_application_draft`; submitted, under review or changes requested ->
   `sponsor_application_status` (with the matching reason); rejected, withdrawn or approved without membership
   -> `sponsor_application_status` (`sponsor_application_closed`). A workspace always wins; a sponsor draft is
   an in-progress journey for rule 5. No new response fields.

## Decisions taken here, and not

| Item | SF-113 |
| --- | --- |
| Account before SP1 (D-SA01) | Followed (recommended option A; design's option B not built) |
| States (D-SA02) | The proposed seven; proposed, not approved |
| Budget (D-SA05, NEEDS DECISION) | SP5's six annual EUR bands as codes with integer bounds; an estimate only |
| Uploads (D-SA09) | Unavailable (`file_scanning_unavailable`); optional, so not a blocker. Logo and SP7 files not stored |
| Declaration | **BLOCKED** until counsel writes and publishes it; submission fails closed. A test-only fixture exists for tests and local E2E |
| Contact email | Never verified, grants nothing, never linked to an account |
| Reapplication (D-SA03) | **Blocked**: a user with a rejected or withdrawn application can't start another |
| Withdrawal (T9) | **Not exposed**: with reapplication blocked it would lock the applicant out for good |
| Discard draft (T2) | Not exposed; retention undecided |
| Emails | None (no templates; S7) |

## Trust boundary

Triggers bind the application's database role, not a superuser (D-SA28). The snapshot hash detects accidental
change; it is not a signature.
