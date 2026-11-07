# Sponsor application lifecycle (SF-107)

**Status: PROPOSED.** The states are a recommendation, not approved enum values
([D-SA02](sponsor-admin-decision-register.md)).

## 1. States

```
                 ┌───────────┐ withdraw
   discard       │ submitted ├──────────────┐
  ┌───────┐ submit└─┬───▲──┬─┘              ▼
  │ draft ├────────►│   │  │ claim      withdrawn (terminal)
  └───────┘         │   │  ▼                ▲
                    │   │ under_review ─────┤ withdraw
         resubmit   │   │  │  │  │          │
                    │   │  │  │  └─────► approved (terminal)
                    │   │  │  └────────► rejected (terminal)
                    │   │  ▼
                    │  changes_requested ─┘ withdraw
                    └──────┘
```

| State | Meaning | Applicant sees | Design label |
| --- | --- | --- | --- |
| `draft` | Being written. Only the applicant sees it | Form | Draft |
| `submitted` | Waiting. No operator has it | "Received" | SUBMITTED, NEW on AS1 |
| `under_review` | An operator has claimed it | "In review" | UNDER REVIEW |
| `changes_requested` | Needs applicant input | The operator's message and form | NEEDS INFO |
| `approved` | Accepted. Organization exists | Link to workspace | APPROVED |
| `rejected` | Declined | Reason, next step | REJECTED |
| `withdrawn` | Applicant stopped | Can start again | No board |

**Not states:** `paused` (SPX5 lists it; a pause applies to an organization), CRM stages (AS4), and
assignment (a separate column).

An expired draft has no state: it's deleted under the retention rule, once one is approved.

## 2. What can be saved and when

| Step | Requires | Saved where |
| --- | --- | --- |
| Reading SPX1, SPX2 | Nothing | — |
| SP1–SP7 draft | Session and completed registration | Server |
| Uploads | Same, plus draft exists | Private storage |
| Review and submit | Same, plus all required fields and an accepted applicant declaration | Server, as revision |
| After approval | Membership | Organization |

**Recommended: authenticate before SP1** ([D-SA01](sponsor-admin-decision-register.md)).

| | Authenticate first (recommended) | Browser draft, account at the end (current design) |
| --- | --- | --- |
| Resume on another device | Yes | No |
| Business contact details | Server, authorized | Browser storage on possibly shared computers |
| Anonymous uploads | Not needed | Needs a public upload path, or the promise on SP8 is false |
| ADR 0016 registration | Natural | Must be inserted after step 7, which SP8 doesn't show |
| Abandonment | Possibly higher | Lower |
| Design change | SPX2 copy, SP1–SP7 rail, SP8 becomes a sign-in step | None to the look, new states |

No anonymous server drafts in either option: they invite spam and hold personal data with no owner.

## 3. Transitions

| # | From → To | Actor | Requires | Effect |
| --- | --- | --- | --- | --- |
| T1 | none → `draft` | Applicant | Session, registration, no current application, `client_request_id` | Creates the row. Idempotent |
| T2 | `draft` → deleted | Applicant | Own draft | Deletes row and files |
| T3 | `draft` → `submitted` | Applicant | Required fields, file scan clean, declaration, `expected_revision` | Writes immutable revision, event, confirmation email |
| T4 | `submitted` → `under_review` | Operator: `sponsors.applications.claim` | No conflict | Sets assignee, event. A second claim is refused |
| T5 | `under_review` → `changes_requested` | Assignee: `.decide` | Message; current revision | Event, email. Draft fields reopen for applicant |
| T6 | `changes_requested` → `submitted` | Applicant | As T3 | New revision |
| T7 | `under_review` → `approved` | Assignee: `.decide` | Current revision, no conflict, checklist recorded | **One transaction:** organization, owner membership, event, audit, email job |
| T8 | `under_review` → `rejected` | Assignee: `.decide` | Reason code, message; current revision | Event, audit, email |
| T9 | `submitted`, `under_review` or `changes_requested` → `withdrawn` | Applicant | Own application | Event |
| T10 | Any non-terminal → `withdrawn` | System | Applicant account deleted | Event with actor `system` |
| T11 | `under_review` → `submitted` | Assignee, or operator with `.reassign` | Reason | Releases a claim |

Everything else is refused by a PostgreSQL trigger, as `gym_verification_applications`.

**Reopening.** Terminal states don't reopen. Rejected or withdrawn applicants may start a new
application with a new id, subject to a cooldown if the founder sets one
([D-SA03](sponsor-admin-decision-register.md)). Old ones stay as history.

**Later events:** a mistaken approval is handled by suspending the organization, with the
application left as what was decided at the time.

**Forbidden:**

* Auto-approval on budget, industry, country or anything else. T7 has one actor type: an operator.
* A rule engine or score that changes state. AS1's policy note (no gambling, alcohol or tobacco) is a
  reviewer's checklist item unless the founder approves an automatic rejection.
* Any entitlement, plan, Stripe object, placement or public listing on approval.

## 4. Revisions

* `revision` increases on every applicant edit, as gym verification. Edits and submissions send
  `expected_revision`; a stale one gets 409.
* Each submission writes one immutable row in `sponsor_application_revisions`. Operators review a
  specific revision, and a decision records which one.
* **Operators can't edit answers.** AS2's and AS3's edit controls don't apply to a submitted
  application. To correct something, they request changes. Internal notes and assignee aren't
  applicant data and live apart.
* Files attach to a revision by reference. A file in a submitted revision can't be replaced or
  deleted while that revision is under review.
* The answers an operator sees are exactly what was submitted, including after later edits.

## 5. Decisions and concurrency

| Case | Result |
| --- | --- |
| Two operators claim | Row lock: the first wins; the second gets 409 |
| Two operators decide | One decision; the second gets 409 |
| Applicant withdraws during approval | Serialized on the row. Withdrawn first: approval refused. Approved first: withdrawal refused with 409 and the applicant sees approved |
| Applicant edits during a decision | Refused outside `draft` or `changes_requested`. A decision carries `expected_revision` |
| Operator revoked while deciding | Authority asked before locks and again after. Revoked: refused |
| Applicant becomes a member of an involved party | Conflict re-checked under the lock |
| Duplicate requests | `client_request_id` for applicant writes, `operation_id` for operator writes. Same answer, one event |
| Approval, partial failure | Single transaction, so all or nothing. Email is an Oban job inserted in it |

Lock order: application, then organization. No path takes them the other way.

## 6. Audit events

Written in the same transaction as the change. Ids and codes only, no names, emails or free text.
The applicant's message lives in `sponsor_application_events.message`, not in audit.

| Event | Actor | Audit where |
| --- | --- | --- |
| `sponsor_application.created`, `.discarded` | Applicant | Application events |
| `.submitted`, `.resubmitted`, `.withdrawn` | Applicant | Application events |
| `.claimed`, `.released` | Operator | Application events and operator audit |
| `.changes_requested`, `.approved`, `.rejected` | Operator | Both |
| `.viewed`, `.file_downloaded` | Operator | Operator audit |
| `sponsor_organization.created`, `.suspended`, `.reinstated`, `.closed` | Operator or system | Organization events and operator audit |
| `sponsor_membership.created`, `.ended`, `.role_changed`, ownership transfer | Member or system | Organization events |

## 7. Required fields

From SP1–SP7. Final validation is for the implementing task.

| Step | Required | Optional | Note |
| --- | --- | --- | --- |
| Company | Name, country, industry | Website, logo | AS2 also shows VAT ID, size, "partner before": not collected on SP1. Removed from AS2, or added to SP1 ([D-SA09](sponsor-admin-decision-register.md)) |
| Contact | Name, position, work email | Phone | The contact isn't necessarily the signed-in user; the work email is **unverified** and grants nothing |
| Interests | At least one | "Other" text | Fixed list |
| Markets | Scope; countries when not global | Cities | No reach estimate |
| Budget | Band | | Non-binding, never public |
| Goals | Text, up to 2,000 characters | | Plain text |
| Uploads | None | Up to a set limit | See [threat model](sponsor-admin-threat-model.md) |
| Declaration | Authority to apply for this business; privacy notice | | New; text needs counsel. **BLOCKED until written** |

## 8. Emails

No template exists. The canvas has E01–E16 and none is for sponsors, so all are new work:
received, changes requested, approved, rejected. A message from the operator is plain text.
