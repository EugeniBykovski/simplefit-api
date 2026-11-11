# ADR 0033 — Sponsor application review queue, documents and decisions

* Status: **Accepted for implementation in non-production environments** (SF-116, 2026-11-09). Epic SF-106.
  Extends [ADR 0031](0031-sponsor-applications.md), [ADR 0032](0032-sponsor-application-evidence-review-and-notifications.md),
  [ADR 0029](0029-admin-action-framework.md) (admin actions) and [ADR 0030](0030-sponsor-organizations-and-workspaces.md)
  (provisioning). Builds on the **proposed** D-SA10 (approval semantics), D-SA07 (one owner, the applicant) and the
  lifecycle's "later events" rule; none of them is approved by this. Nobody is named to review (D-SA22, BLOCKED)
  and production has no operator yet (D-SA13, D-SA14), so nothing here runs in production.

## Decision

1. **Queue** `GET /api/v1/admin/sponsor-applications` (projection `sponsor_applications.queue`, permission
   `sponsors.applications.read`, key check, each query audited as `sponsor_applications.queue_read`).
   * It lists submitted applications only, never drafts, oldest submission first, with ties broken by id.
   * Filters: `status` (any but `draft`), `submitted_after` and `submitted_before`.
   * `limit` is 1..100 (default 50). `cursor` is SF-111's signed cursor, bound to the filters (plus a queue
     marker), the reading operator and a TTL.
   * A row carries what the latest submission says about the company (name, country, industry), counts and
     whether a change request is open. It never carries the contact, budget or goals.
2. **Detail** gains `decided_at`, the organization an approval created (`sponsor_id`, `status`) and the status
   history. The history lists events, applicant or operator, codes and times, and never says which person acted.
3. **Documents.** `POST …/{application_id}/documents/{evidence_id}/download` uses projection
   `sponsor_applications.file` with the new `sponsors.applications.read_files` permission and a fresh key check.
   * Only uploaded documents that are part of a submission of that application can be downloaded. The
     operator's own application is refused.
   * The download is a 5-minute presigned `GET` with `response-content-disposition: attachment` and
     `response-content-type: application/octet-stream` signed into it. The Storage boundary gained the
     `:attachment` option.
   * The response is `Cache-Control: no-store`. Each download is audited (`sponsor_application.file_downloaded`,
     with the document as target) before the URL exists. The URL is never stored or logged.
4. **Decisions** are declared SF-111 actions on the application, each with its own permission (least privilege,
   as gym verification has, instead of the matrix's combined `.decide`). Each needs a fresh key check, the
   `expected_revision`, an `operation_id` and a **one-time confirmation** from a preview of exactly that request.
   Reason codes come from per-action lists and are internal, never shown to the applicant.

   | Action | Permission | Change |
   | --- | --- | --- |
   | `sponsor_application.approve` | `sponsors.applications.approve` | `under_review` -> `approved` + organization + owner |
   | `sponsor_application.reject` | `sponsors.applications.reject` | `under_review` -> `rejected` (final) |
   | `sponsor_application.suspend_organization` | `sponsors.restrict` | approved application's organization `active` -> `suspended` |
   | `sponsor_application.reinstate_organization` | `sponsors.restrict` | `suspended` -> `active` |

5. **Approval** runs in the pipeline's single transaction, with the operator and the application locked:
   * The status becomes `approved` and `decided_at` is set.
   * `Provisioning.application_authority/1` is now real. It is given only inside a transaction, for an
     application approved in it with no organization yet.
   * `provision_organization/3` then creates the organization from **the latest submission's snapshot**.
     The company name becomes the legal name, and also the display name, cut to 120 characters. The submitted
     contact becomes the primary contact.
     * The applicant is the only member: the owner. No other contact, email, collaborator or operator becomes
       a member.
     * The application id is the provisioning key, and `source_application_id` is unique, so a repeat can't
       make a second organization.
   * Then come the approval event, the applicant's email intent, the audit row and the operation record.
   * Any failure (provisioning, notification or audit) rolls all of it back. A preview creates nothing.
   * Approval grants no contract, plan, placement, entitlement, payment, campaign or public listing.
6. **Rejection** is final, as ADR 0031 has it: reapplication stays blocked (D-SA03). It creates nothing and
   queues an email without a reason.
7. **Undoing an approval** is how the lifecycle answers a mistaken approval: the organization is **suspended**.
   * A suspended organization is read-only for its members and gives no workspace entry.
   * The application stays approved, as decided at the time. Nothing is deleted, and no other organization or
     membership is touched.
   * Reinstatement reverses it.
   * The authority is the new `platform_operator`, recorded with the operator's user.
   * **Not built:** a `revoked` application state and closing an organization. Neither has an approved policy
     (closing revokes every membership for good).
8. **Conflicts of interest.** These come from domain relationships, never email:
   * An operator is a party to their own application, and to an application whose organization they belong to
     (any non-revoked membership). A party gets `409 target: self`.
   * Sponsor membership grants no operator authority. Accounts without a usable operator get `404` everywhere.
9. **Notifications.** `application_approved` (deduplicated by `approved:<application>`) and `application_rejected`
   go through the ADR 0032 outbox. The placeholder copy states facts only. Sending stays off in production (S7).
   Suspension sends no email: no copy exists.

## Database (migration `20261124090000`)

* The permission catalog gains `sponsors.applications.approve`, `.reject`, `.read_files` and `sponsors.restrict`.
* Organization events accept the authority `platform_operator`.
* Notification kinds gain `application_approved` and `application_rejected`.
* No new tables or columns: `status`, `decided_at` and the trigger allowing `under_review -> approved | rejected`
  came from ADR 0031.
* Rollback refuses once any decision, grant, operator authority or decision notification exists.

## Concurrency

These were proven on real connections outside the sandbox:
* approve against approve, reject, request changes;
* suspend against suspend;
* five identical retries;
* an audit write made to fail;
* an operator revoked mid-decision.

Each ends in exactly one transition, at most one organization and owner, and no approval without its audit row.
Lock order is the operator, the application, then the organization.

## Decisions taken here, and not

| Item | SF-116 |
| --- | --- |
| Approval semantics (D-SA10) | Proposed default built: organization + applicant owner, nothing commercial |
| Reason codes | Proposed defaults: approve `review_complete`; reject `not_a_business`, `outside_supported_categories`, `insufficient_information`, `duplicate_application`, `other`; suspend `approval_mistaken`, `policy_concern`, `under_investigation`, `other`; reinstate `concern_resolved`, `approval_confirmed`, `other` |
| Applicant-facing rejection reason | None (no approved wording) |
| Revocation | Organization suspension only; no `revoked` state, no closing |
| Evidence and contact verification required for approval | No (D-SA09 open; contact verification optional by ADR 0032) |
| Malware scanning | None; documents are never reported scanned and always download as attachments |
| Reviewer staffing (D-SA22), second operator (D-SA14) | **BLOCKED** |

## Verification layers (SF-116 corrections)

These are kept apart, and none stands in for another:

| Layer | What it is | Where |
| --- | --- | --- |
| Domain and in-process HTTP | ExUnit in the SQL sandbox; Phoenix endpoint and router in-process (`ConnTest`) | `test/simple_fit/sponsor_application_decisions_test.exs`, `test/simple_fit_web/controllers/sponsor_application_*_test.exs` |
| Real PostgreSQL races | Concurrent `Task`s on separate pooled connections, real commits, outside the sandbox | `test/simple_fit/sponsor_application_decisions_race_test.exs` |
| Standalone HTTP E2E | A separately running `mix phx.server` on a disposable database, driven over real HTTP | `test/standalone/sponsor_review_http_e2e_test.exs` (skipped unless pointed at a server) |
| WebAuthn | The repository's **software** authenticator (`SimpleFit.OperatorHelpers`) against the production verification code | All of the above |
| Hardware security keys | **Not performed.** An operational check before any production use | — |

### Standalone HTTP E2E

The server needs:
* a disposable database (with `e2e` in its name);
* the development configuration;
* the test-only legal registry, which holds the published declaration fixture;
* the local development ceremony key, created before the server starts so that it trusts it at boot.

Nothing is injected into requests: accounts use the email-code API, and the founder is bootstrapped by the development ceremony. Two keys and the key check go over HTTP.

A database can have only one founder (SF-110), so each run needs a **fresh** disposable database. The test refuses a database that already has an operator. Disposable databases are never dropped by the procedure.

```bash
export E2E_DB=postgres://postgres:postgres@localhost/simple_fit_sf116_e2e
MIX_ENV=dev mix operators.dev_ceremony --user-id 00000000-0000-4000-8000-000000000000 --out /tmp/x.json  # creates .operator-dev/ keys
MIX_ENV=dev DATABASE_URL=$E2E_DB mix ecto.create && MIX_ENV=dev DATABASE_URL=$E2E_DB mix ecto.migrate
env -u RESEND_API_KEY MIX_ENV=dev PORT=4116 DATABASE_URL=$E2E_DB \
  SIMPLEFIT_DEV_LEGAL_REGISTRY=test/support/legal mix phx.server &
E2E_API_URL=http://127.0.0.1:4116 E2E_API_DATABASE_URL=$E2E_DB mix test test/standalone
```

## Amendment (SF-124)

The Control Plane review console (AS1, AS2) uses these endpoints unchanged. One additive read-only field:
`GET /api/v1/admin/sponsor-applications/{id}` returns `viewer_is_party`, whether the reading operator is a party
to the application by the same rule the actions apply (the applicant, or a member of the organization its
approval created, `SimpleFit.Sponsors.ReviewTarget.party?/2`), so the console can say so before any action is
tried. Action results don't carry it (they have no reader). The rule, the refusal (`conflict`,
`details.target: "self"`) and every other contract are unchanged. An unanswered decision is reconciled by
sending the identical request again under the same `operation_id`: the framework's replay check runs before the
revision and confirmation checks, so a committed request answers with the current state and is never applied
twice.
