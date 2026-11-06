# 06 — Security, concurrency, moderation and SF-110

**Status: PROPOSED.** These are acceptance cases for later tasks. No code exists.

## 1. Invariants PostgreSQL should enforce

Rules in application code alone are not enough, as with verification and bookings.

| Invariant | Mechanism |
| --- | --- |
| One publication per gym | Unique index on `gym_id` |
| Only legal transitions | Trigger, as `gym_verification_applications` |
| `published` has a live snapshot | Check constraint |
| An approved or suspended row names its authority | Check on `gym_publication_events`: `operator_actor_id`, `operator_authority` and `operation_id` together, as SF-136's constraint |
| `operator_authority` excludes fixtures in production | No production value exists until SF-110 adds one by reviewed migration |
| Snapshots and history are immutable | Append-only triggers |
| One gym per slug, past slugs reserved | Unique index on the lower-cased slug |
| Decision, history and audit commit together | One transaction |
| Lock order | Gym `FOR SHARE`, then publication `FOR UPDATE`, as every gym write |

A failed eligibility read returns not found. There is no fallback path that shows a gym.

## 2. Security and race cases

| # | Case | Required result |
| --- | --- | --- |
| 1 | Owner withdraws while an operator approves | Serialized on the row. Withdraw first: approval refused. Approve first: withdrawal wins and it's off |
| 2 | Operator suspends while a publication commits | Ends `suspended`, whichever order; never `published` after a suspend |
| 3 | Revoke racing an owner's republish | Ends `revoked`; the republish gets 409 |
| 4 | Operator reinstates while verification is revoked | Reinstate refused, eligibility checked under the lock |
| 5 | Duplicate requests (same `client_request_id`) | One request, one event, same answer |
| 6 | Two operators decide the same request | One decision; the second is refused as stale |
| 7 | Decision on a stale revision, after the owner edited | Refused; the operator reviews the new one |
| 8 | Owner edits while published | Live snapshot unchanged; no unreviewed text reaches the public |
| 9 | Ownership transfer racing a request | Authority by commit order; a former owner gets 403 or 404 |
| 10 | Manager or staff removed mid-edit | Refused at the write |
| 11 | Verification revoked while published | Suspended in the same transaction; the next read is 404 |
| 12 | Verification not approved, or attributed to a fixture or legacy address | Not eligible |
| 13 | Another gym's id in the path; another gym's slug | 404; no status disclosed |
| 14 | Coach ended while listed | Listing gone in the same transaction |
| 15 | Stale cached page after suspension | Gone within the stated bound; test it if a cache is added |
| 16 | Search or sitemap disagreeing with detail | Impossible by construction: one predicate; test it |
| 17 | Public DTO leak | Exact-keys test and canary values in all never-public fields |
| 18 | Metadata leak | Same canaries checked in the rendered HTML head |
| 19 | Slug enumeration | Rate limited; a suspended gym is indistinguishable from an unknown slug, by status and body |
| 20 | Timing or error differences on the report endpoint | Same answer whether or not the gym exists |
| 21 | Impersonating an operator: `--operator`, an email, a hand-built principal | No such path exists. Production build refuses at compile time |
| 22 | Owner approves their own gym through an operator account | Refused by independence check on user id, gym row locked |
| 23 | Owner's frontend state says "published" | Irrelevant; the backend decides |
| 24 | Slug squatting on another gym's name | Reserved list, review before going live, no slug goes live unreviewed |
| 25 | Free text carrying links or contact details of others | Reviewed in the snapshot; plain text rendered; no HTML |
| 26 | Gym closes or the owner's account is deleted | Not eligible at once; defined once closure exists |

## 3. Moderation

Minimum for the first public page. Every action needs a trusted operator and leaves history.

| Topic | Minimum |
| --- | --- |
| Pre-publication review | Every first request and every changed snapshot. Checklist: is this the verified business, are the claims plausible, is the text clean |
| Inaccurate claims | Report, review, changes requested or suspended. The operator can't edit an owner's text |
| Impersonation | Name compared with the verified legal name at review; conflicting report leads to suspension |
| Prohibited imagery | Not applicable in release 1, which has no images. Required before images ship |
| Fraudulent verification | Verification revoked for `suspected_fraud`, which automatically suspends |
| Unauthorized staff photos | Not applicable in release 1. Then: image rights attestation, report, immediate removal |
| Abuse reports | Public form with category and text. Rate limited. No account needed. Doesn't reveal the reporter to the gym |
| Emergency suspension | One operator, immediately, reason required |
| Audit | Append-only; viewable only with a permission |
| Review and reinstatement | The gym gets the reason and can respond; a second reviewer on appeal, if staffing allows |
| Repeat offenders | Tracked by gym in history. Thresholds are a trust and safety decision; none is invented here |
| Service levels | None are promised until staffed. Publish none until they can be met |

Staffing is a real dependency: someone must watch the queue, or reports do nothing.

## 4. SF-110 dependency

**Without SF-110, public approval is BLOCKED.** No interim mechanism should be built:
SF-136 already rejected that, and it applies here.

| Concern | Required of SF-110 |
| --- | --- |
| Authentication | A credential tied to an operator identity, verified on every call. Not a user session alone |
| Authorization | Grants checked on every call, no caching, revocation effective at once |
| Immutable actor | Operator id and user id, for attribution and independence checks |
| Moderation permissions | Separate from verification permissions |
| Review assignment | At least: who holds an item; conflict of interest refused at assignment and decision |
| Audit | Authority value added by reviewed migration; `operation_id` on each action |
| Self-review prevention | By user id, gym row locked, as SF-136 |

Permissions to add to the authority's `permission` type:

| Permission | Allows |
| --- | --- |
| `read_publication_queue` | View applications |
| `read_publication` | Review gym public content and history |
| `approve_publication` | Approve |
| `request_publication_changes` | Request changes |
| `reject_publication` | Reject |
| `suspend_publication` | Suspend |
| `reinstate_publication` | Lift a suspension, where approved |
| `revoke_publication` | Revoke |
| `reopen_publication` | Allow a new application after revocation |
| `read_publication_audit` | Audit history |
| `process_gym_reports` | Work the report queue |

Whether revocation needs a second person (`AD20` draws two-person rules, with no backend) is
a founder and trust and safety decision.

**SF-136 is preserved:** nothing here adds an allowlist, a flag, a shell argument or a
production fixture. Verification itself can't produce an eligible gym in production until SF-110.
