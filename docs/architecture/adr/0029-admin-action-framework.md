# ADR 0029 — Admin action framework, immutable audit and sensitive-operation safety

* Status: **Accepted for implementation in non-production environments** (SF-111, 2026-11-09). Epic SF-106.
  Builds on [ADR 0028](0028-platform-operator-identity.md). Production use still waits on ADR 0028's
  blockers: no production operator can exist until the D-SA13 signing authority does.
* Context: ADR 0003 (errors), 0008 (observability), 0027 (proposed Sponsor and operator architecture),
  0028 (operators), [platform-operator-trust.md](../platform-operator-trust.md) §8 (audit),
  [sponsor-admin-api-matrix.md](../sponsor-admin-api-matrix.md) (`expected_revision`, `revision_conflict`,
  `operation_id`), [sponsor-admin-threat-model.md](../sponsor-admin-threat-model.md) (T13, monitoring).

## Problem

SF-110 gave operators an identity, permissions and key checks, and its writes were locked, idempotent and
audited. Later admin modules (Sponsor review, gym verification, user restriction) need the same guarantees
plus things SF-110 lacked: protection from stale decisions, an explicit confirmation step for actions that
widen or end access that a frontend modal can't fake, one coherent audit record per attempt, and safe,
paginated audit reads. Each module inventing its own would drift. A generic "execute anything" endpoint or
admin CRUD would be a backdoor.

## Decision

1. **Declared actions only.** `SimpleFit.Operators.Action` declares an action: id, permission, key-check
   assurance, target type, its own reason codes, input types and checks, confirmation policy, audit event,
   a side-effect-free `plan` and the domain `apply`. `SimpleFit.Operators.Actions` runs only declared
   actions. Each has its own typed routes (`…/suspend/preview`, `…/suspend`); there is no generic execute
   endpoint, and no table, query, module, function name or field patch is taken from a request.
2. **One pipeline, in one transaction** (`Actions.execute`): session held → the session user's operator
   (body ids are ignored) → permission and fresh key check before validation, and again under
   `FOR UPDATE` locks on actor and target (id order) → target resolved (unknown: `not_found`), never the
   actor → operation id → expected revision → one-time confirmation → plan again → domain change →
   operation recorded → audit event. Any failure rolls everything back.
3. **Revisions.** `platform_operators.revision` is maintained by triggers: raised on every row update and
   touched by every grant insert or revocation, so the application can neither set nor forget it.
   Executions require `expected_revision`; a stale one is `409 revision_conflict` with
   `details.current_revision`. Nothing is retried with newer state.
4. **Preview and confirmation.** A preview runs the same authorization, target and plan and returns
   current and proposed state, impact codes, the needed permission and assurance, and the current revision.
   It changes nothing else: no email, job or provider call. For actions that require confirmation it issues
   a token (`sfc_` + 32 random bytes; only its SHA-256 is stored) bound to operator, session, action,
   target, a SHA-256 digest of the canonical parameters (action, target, revision, reason, action fields)
   and the revision. It expires after 120 s and can be consumed once: the consuming `UPDATE` matches every
   binding, and a trigger allows nothing but that single consumption. A preview authorizes nothing:
   execution checks everything again. Missing token: `428 confirmation_required`; mismatched, expired,
   tampered, foreign-session or used token: `422 confirmation_invalid`.
5. **Idempotency, separate from confirmation.** `operation_id` is recorded with the digest of the request.
   The same actor, action, target and digest returns the current state and changes nothing (it is checked
   before the revision and the confirmation, so an ambiguous network retry is safe); the id with anything
   else is `409 conflict` (`operation_id: "reused"`).
6. **Reason codes** are per action, from a fixed list in its declaration (see `OperatorActions`). They
   are operational categories for operator access management **proposed by SF-111**, not a legal or
   compliance taxonomy. No free-text explanation is accepted or stored (none is approved).
7. **Audit, extended in place.** `operator_audit_events` (SF-110, append-only by trigger, no foreign keys)
   gains `command`, `result_code`, `from_state`, `to_state`, `revision`, `confirmation_id` and the outcomes
   `conflict`, `invalid`, `failed`. Ownership policy: **one event per attempt by an identified operator.**
   An allowed execution writes its event inside the transaction (if the event can't be written, nothing
   commits). Any other outcome writes one event after the rollback: `refused` (permission, step-up,
   enrolment, unknown target, self-action, missing confirmation, revoked session), `conflict` (stale
   revision, state, reused operation id), `invalid` (validation, confirmation), `failed` (mutation).
   Previews audit only refusals. Non-operators leave no row (SF-110 concealment). Refusal events are rate
   limited (300 per operator and hour) so they can't fill the table; suppression is counted in telemetry.
8. **Privileged reads are projections** with a permission and an audit action: `operators.detail`
   (`operator.viewed`), `audit.events` (`audit.events_read`), `audit.event` (`audit.event_viewed`), per
   platform-operator-trust §8 ("every query"). The operator directory stays an unaudited
   `operators.read` list.
9. **Audit queries.** Newest first by `(occurred_at, id)`, stable on equal timestamps. Equality filters on
   a fixed set of columns plus a time range; `limit` 1..100. Cursors are signed (`Plug.Crypto.sign`,
   `SECRET_KEY_BASE`, own salt), expire after an hour and are bound to a digest of the filters and to the
   reading operator: altered, foreign or re-scoped cursors are `validation_error`. No offsets, sorts or
   expressions from requests. SF-110's `before` remains, exclusive with `cursor`.
10. **Redaction by allowlist** (`SimpleFit.Operators.Redaction`): audit DTO fields and conflict detail
    keys are listed; nothing else leaves. Validation errors carry messages and codes, never values. Tokens,
    token hashes, request digests, keys and credential ids never appear in responses, audit, logs or
    telemetry.
11. **Telemetry** `[:simple_fit, :admin_action, event]` (`started`, `authorized`, `confirmed`, `previewed`,
    `committed`, `replayed`, `denied`, `conflicted`, `invalid`, `failed`, `audit_persisted`,
    `audit_suppressed`, `audit_failed`) with metadata `action`, `phase` and `result` only: no user,
    operator, target or session id, reason or token. Counters in `SimpleFitWeb.Telemetry` are tagged by
    action and result. Mutation and audit-write failures log at `:error` (action id and exception module
    only), with the request id from Logger metadata.

## Integrated actions (real SF-110 domain operations)

| Action | Confirmation | Notes |
| --- | --- | --- |
| `operator.permission.grant` | required | widens access |
| `operator.permission.revoke` | none | narrows access only |
| `operator.suspend` | required | ends key checks |
| `operator.reinstate` | required | restores access |
| `operator.revoke` | required | final |

**Contract change, approved in this ticket's session:** SF-110's five endpoints for these actions were
tightened in place (no client used them): they now require `expected_revision`, catalogued reason codes
and, except permission revocation, a `confirmation_token`. Provisioning and revoking another operator's key
stay on SF-110's write path (locked, fresh key, reason, idempotent, audited) without revision or
confirmation; moving them is a follow-up.

## Not done here

* No gym verification or user restriction actions: SF-136's verification authority stays its own and
  disabled in production; the restriction domain doesn't exist (D-SA29). *SF-114 added Sponsor review
  (claim, request changes) and three permissions ([ADR 0032](0032-sponsor-application-evidence-review-and-notifications.md)).*
* No new permissions, no two-person rule (D-SA17), no free-text explanations, no bulk export, no UI.

## Trust boundary

Append-only and single-consumption guarantees are triggers that bind the application's database role. **A
database superuser or infrastructure administrator can bypass them**: change or delete audit rows, disable
triggers, or mint confirmations. Separate database roles and restricted shell access are D-SA28 (NEEDS
DECISION). Audit history is irreversible by design: the SF-111 migration's rollback refuses once any
framework event or confirmation exists.

## Consequences

* A new admin module declares its actions in its own context and gets authorization, revisions,
  confirmation, idempotency, audit and telemetry by running them through `Actions`. Targets other than
  operators implement `Operators.ActionTarget` (fetch, lock, party, status, projection; SF-114) and carry a
  revision on their own table.
* Clients must preview before executing confirmed actions and carry `expected_revision`.
* Audit reads grow the audit table by one row per query; retention is still undecided (D-SA18).

## Amendment (SF-121)

The overview (`SimpleFit.Operators.overview/4`) is a read outside the audited projection map: it authorizes with
`authorize/4` (refusals audited) and returns aggregate counts only, which SF-107 classifies as "view not logged per
load". Any read that returns a record, a name or an identifier still goes through the audited projections.

## Amendment (SF-122)

User accounts become the third target kind (`SimpleFit.Operators.UserTarget`: the account state's id and revision),
with three actions in `SimpleFit.Operators.UserActions`. Read projections may now record extra audit fields; the
user reads record their reason code (`user.searched`, `user.viewed`, `user.email_revealed`).
