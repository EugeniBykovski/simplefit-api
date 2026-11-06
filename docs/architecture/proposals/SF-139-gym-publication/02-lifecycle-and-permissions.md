# 02 — Lifecycles and permissions

**Status: PROPOSED** for publication. The first two sections describe code as it is.

## 1. What exists today

| Area | Fact | Source |
| --- | --- | --- |
| Gym row | `name`, `gym_type`, `setup_status`, `phone`, `website`, `tagline`, `accent_color`, `revision`, `created_by_user_id`, `client_request_id` | `lib/simple_fit/gyms/gym.ex` |
| Ownership | No owner column: the one active `owner` row in `gym_staff_memberships` | `create_gyms` migration |
| Location | `name`, `country_code`, `city`, `address_line`, `entrance_note`, `is_primary`, `archived_at`. No geocoding | `gym_location.ex` |
| Roles | `owner`, `manager`, `coach`, `front_desk`, fixed matrix | `lib/simple_fit/gyms/policy.ex` |
| Verification | Application, evidence and event tables; owner submits, authority decides | `verification*.ex` |
| Go-live | Derived, writes nothing; `publication.status` always `unavailable` | `go_live.ex` |
| Community settings | Not stored | ADR 0026, SF-103 |
| Audit | Append-only `gym_audit_events`; ids, no names or free text | `audit_event.ex` |

**Don't exist:** slug, publication state, logo, cover, description, contact email, social
links, disciplines, amenities, coordinates, a closure state, any public gym endpoint, any
search or geo capability, any HTTP cache layer, any `manage_publication` permission.

One trap: `lib/simple_fit/email/templates/gym_live.ex` (E05) already renders "PUBLISHED" and
"You're in Discover". Nothing triggers it, and it must stay untriggered until its copy
matches the approved policy.

## 2. Three independent lifecycles

### A. Workspace (exists)

`setup_status`: `draft` → `completed`. Final; a database trigger refuses a return to draft.
Means the gym can operate. Says nothing about the public. There is **no closed or suspended
workspace state** today; D-G11.6 needs one before "not closed" can be checked.

### B. Business verification (exists)

`draft` → `submitted`; `submitted` → `approved`, `rejected` or `changes_requested`;
`changes_requested` → `submitted`; `approved` → `revoked`. Enforced by a trigger. Rejected and
revoked are terminal, and the owner starts again. The owner can never self-approve. No expiry.

In production, a submitted application **waits**: the only authority is `Disabled` (SF-136).

### C. Publication (proposed)

A new record, owned by the gym, changed only by the transitions below. No other domain
changes it, except the one automatic link: verification revocation suspends it (§4).

| Fact | Does it imply publication? |
| --- | --- |
| Setup completed | No |
| Verification approved | No |
| Go-live prerequisites met | No |
| SaaS subscription active | No |
| Stripe account enabled | No |
| Publication `published` | Doesn't imply the others; they're checked separately on every read |

## 3. Publication states

The candidate list had eight states. Recommended: **seven stored**, and no row for "not requested".

| State | Meaning | Publicly visible |
| --- | --- | --- |
| *(no row)* | Never requested (`not_requested` in API responses) | No |
| `pending_review` | Owner requested; operator to decide | No |
| `changes_requested` | Operator asks for edits | No |
| `rejected` | Operator refused this request; can ask again after changes | No |
| `published` | Approved and on | **Yes**, if every eligibility check also passes |
| `withdrawn` | Owner turned it off | No |
| `suspended` | Operator or an automatic link turned it off, temporarily | No |
| `revoked` | Operator ended eligibility | No |

**Dropped:** `approved_unpublished`. The owner has already asked to publish when the operator
decides, so approval publishes that snapshot. A withdrawn gym with a still-valid approved
snapshot covers "approved but off". If the founder wants a separate launch moment, add it back.

**Added:** `rejected`, because a first request refused for cause isn't `revoked` (nothing was
public) and isn't `changes_requested` (edits may not help). The founder can merge it into
`changes_requested` if preferred.

## 4. Transitions

| From | To | Who | Needs | Reason |
| --- | --- | --- | --- | --- |
| none, `rejected`, `withdrawn` (snapshot changed) | `pending_review` | Owner | Eligible verification, allowed country, attestation, revision | — |
| `pending_review` | `published` | Operator `approve_publication` | Reviewed revision matches; independent of the gym; eligibility still holds | — |
| `pending_review` | `changes_requested` | Operator `request_publication_changes` | Reviewed revision matches | Required code |
| `pending_review` | `rejected` | Operator `reject_publication` | Reviewed revision matches | Required code |
| `changes_requested` | `pending_review` | Owner | New revision | — |
| `pending_review`, `changes_requested` | `withdrawn` | Owner | — | — |
| `published` | `withdrawn` | Owner | Takes effect immediately | Optional code |
| `withdrawn` (snapshot unchanged, approval current) | `published` | Owner | Eligibility still holds | — |
| `published` | `suspended` | Operator `suspend_publication` | — | Required code |
| `published`, `withdrawn` | `suspended` | System, same transaction as verification revocation or failed reverification | — | `verification_revoked`, `verification_expired` |
| `suspended` | `published` | Operator `reinstate_publication` | Eligibility holds; independent | Required code |
| `suspended` | `revoked` | Operator `revoke_publication` | — | Required code |
| `published`, `withdrawn` | `revoked` | Operator `revoke_publication` | — | Required code |
| `revoked` | `pending_review` | Owner, only after an operator reopens | Reopen permission and reason | Required code |

Rules:

* Anything else is refused by a database trigger, as verification does.
* While `suspended` or `revoked`, the owner can't republish. Withdrawing a suspended gym is
  refused, so a suspension can't be erased by toggling.
* An owner edit during `published` creates a new draft revision. The approved snapshot stays
  live until a new request is approved.
* Reason codes for operators (proposed): `inaccurate_information`, `impersonation`,
  `prohibited_content`, `unauthorized_image`, `verification_invalid`, `legal_request`,
  `safety_concern`, `abuse_report`, `business_closed`, `owner_request`, `other`.

## 5. Permission matrix

New gym permissions in `Gyms.Policy` (proposed) and operator permissions in the SF-110 authority.

| Action | Owner | Manager | Coach | Front desk | Member, stranger | Trusted operator |
| --- | --- | --- | --- | --- | --- | --- |
| Read publication state | Yes | Yes | No | No | No | With `read_publication` |
| Edit public profile draft | Yes | Yes (proposed) | No | No | No | No |
| Request publication | **Yes** | No | No | No | No | No |
| Withdraw, republish | **Yes** | No (proposed) | No | No | No | No |
| Claim a public coach listing | — | — | Own only | — | — | — |
| Approve, request changes, reject | **Never** | **Never** | **Never** | **Never** | **Never** | With that permission, if independent |
| Suspend, reinstate, revoke | Never | Never | Never | Never | Never | With that permission |
| Read audit and reports | Own outcome only | No | No | No | Own report | With that permission |

Independence follows SF-136, by user id with the gym row locked: an operator who created or
submitted the application, created the gym, is active staff, or is a current member can't act.

A session, a `User.role`, a shell user, an email address and a frontend state are **not** authority.

**Ownership transfer** doesn't change publication state, but it should require the new owner
to re-attest within a set period, and it triggers reverification (D-G11.14). The transfer
has no HTTP route today.

## 6. The three removal operations

| | Owner withdrawal | Operator suspension | Operator revocation |
| --- | --- | --- | --- |
| Purpose | The gym no longer wants to be public | Temporary, moderation or compliance | Permanent end of eligibility |
| Permission | Owner only | `suspend_publication` | `revoke_publication` |
| Concurrency | Expected revision; idempotent if already withdrawn | Doesn't need the owner's revision; idempotent | Idempotent |
| Effect on reads | Immediately not found | Same | Same |
| Public response | 404 | 404 | 404 |
| Reason | Optional | Required | Required |
| Way back | Owner republishes | Operator reinstates | New application after an operator reopens |
| Notice to the owner | Confirmation | Reason and how to respond | Reason and how to appeal |
| Appeal | — | Yes, proposed | Yes, proposed; second reviewer |

None of these touches memberships, bookings, classes, staff, billing or verification
evidence. All are appended to history with actor, authority, reason and revision.

Revoking verification suspends publication. Revoking publication doesn't revoke verification.
