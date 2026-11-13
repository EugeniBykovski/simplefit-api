# ADR 0034 — Sponsor partnership preferences and proposals

* Status: **Accepted for implementation in non-production environments** (SF-130, 2026-11-12). Epic SF-106.
  The policy decisions behind it were approved by the founder in the SF-130 session: D-SA21 (no opportunity
  inventory), D-SA37 (proposal lifecycle), D-SA38 (roles), D-SA39 (no budget outside the application). Nothing
  here runs in production while organizations can't be created there (D-SA13; SF-116's approval is operator-only).
* Context: ADR 0027 (proposed), 0029 (admin actions), 0030 (organizations), 0031 (applications), 0033
  (decisions), the [decision register](../sponsor-admin-decision-register.md), the
  [overview](../sponsor-admin-overview.md)'s commercial scope. Unblocks SF-131 (web).

## Problem

An approved sponsor organization had a workspace but no way to say what it wants from SimpleFit after
applying, and no way to ask. The design shows opportunities, proposals and campaigns, but no board exists for
opportunities or proposals and nothing behind them: no inventory, placements, contracts or payments. Building
the design's marketplace would invent offers, athletes and reach (F9).

## Decision

1. **Preferences** (`sponsor_partnership_preferences`, one row per organization): interests, market scope,
   countries, cities and goals, with SF-113's vocabularies (`Sponsors.PartnershipPolicy`, version
   `sponsor-partnership-2026-11.v1`). Created by the first save with `expected_revision: 0`, then saved by
   revision (a trigger raises it). **No budget** (D-SA39). The application's submitted answers are shown
   beside them read-only, from its last immutable submission: preferences never touch the application or its
   snapshot.
2. **Opportunities don't exist** (D-SA21). `GET .../partnership-opportunities` answers members with
   `availability: unavailable`, `reason: no_inventory` and no entries. No table, no example rows.
3. **Proposals** (`sponsor_partnership_proposals`): a **nonbinding general inquiry** (`kind`
   `general_inquiry`, the only kind; it names no opportunity, athlete, gym or person, and carries no amount).
   Answers: title, interests, markets, summary. Lifecycle (D-SA37), enforced by a trigger:

   | From | To | By |
   | --- | --- | --- |
   | `draft` | `submitted`, `withdrawn` | Organization |
   | `submitted` | `under_review` (claim), `withdrawn` | Operator, organization |
   | `under_review` | `changes_requested`, `accepted`, `declined` (operator); `withdrawn` (organization) | |
   | `changes_requested` | `submitted` (resubmission), `withdrawn` | Organization |

   `accepted`, `declined` and `withdrawn` are final. **`accepted` means SimpleFit will follow up outside the
   product and creates nothing**: no payment, campaign, placement, advertising entitlement, exposure
   guarantee, contract or access to athlete or gym data. Answers are locked outside `draft` and
   `changes_requested`; the organization, creator and creating request are immutable; nothing is deleted.
4. **Submission** is its own operation under the proposal's row lock: idempotency key with a request digest,
   revision, completeness (`422` naming each missing answer), an immutable schema-tagged snapshot
   (`sponsor-partnership-proposal-snapshot.v1`, `binding: false`) with its SHA-256, the status and the event.
   A resubmission resolves the open change request.
5. **Create** is idempotent by `client_request_id` (same key and answers: the same draft; other answers:
   `conflict client_request_id: reused`). An organization has at most **25 open proposals**; creates are
   serialized per organization by a transaction advisory lock so the limit holds under concurrency.
   **Withdrawal** is idempotent by its own key.
6. **Authorization** (D-SA38): the existing per-request membership check. Every role reads; the owner and
   managers write (`manage_partnerships`), only while the organization is `active` (`suspended`:
   `conflict organization: suspended`). Writes share-lock the organization and the membership first
   (`Sponsors.lock_access/3`, the provisioning lock order), so a revocation or suspension either commits
   first (the write is refused) or after. Another organization's proposal is `not_found`.
7. **Review** through the SF-111 framework, one permission per action (proposed naming, D-SA16):
   `sponsors.proposals.read` (audited queue and detail, key check), `.claim`, `.request_changes`, `.accept`,
   `.decline` (fresh key check). Accept and decline need a preview confirmation. An operator who created the
   proposal or holds a non-revoked membership of its organization is a party (`target: self`). Claiming,
   requesting changes and accepting need an active organization; declining doesn't. Reason codes are proposed
   defaults, internal, and never shown to the organization; it sees status changes as `simplefit`, never the
   operator.
8. **History**: `sponsor_partnership_events`, append-only, ids and codes only, sponsor and operator actions,
   allowed and refused.
9. **No email** is sent: no template, wording or staffed response exists (D-SA22).

## Alternatives rejected

| Alternative | Why not |
| --- | --- |
| Example opportunities or a seeded marketplace | Invented offers and reach (D-SA21, F9) |
| Reusing the application's states and table | An application asks to become a sponsor; a proposal is a later, repeatable, nonbinding inquiry |
| Editing the application's answers as "preferences" | The submitted snapshot is the record of what was applied with |
| A budget band on proposals | D-SA05 is undecided; D-SA39 keeps money out |
| Accept creating a campaign or entitlement | No campaign, placement or contract domain exists; commercial layer stays FUTURE (ADR 0027 §13) |

## Consequences

* SF-131 can build interests, an honest opportunities state, a proposal list, detail, form, change handling
  and withdrawal on generated clients.
* An accepted proposal leads nowhere in the product until a commercial domain exists; the follow-up is
  manual and unstaffed (D-SA22).
* Reason codes, the open limit (25) and rate limits are proposed defaults.
