# ADR 0020 — Coach profile and resumable Coach onboarding

* Status: Accepted
* Date: 2026-10-13
* Ticket: SF-50 (architecture: SF-49 revision 3,
  `docs/architecture/proposals/SF-49-coach-training-architecture.md` §4.2,
  §20; builds on ADR 0009 one global user, ADR 0015 fighter profile and
  ADR 0016 shared account registration)

## Context

The Coach–Fighter vertical (epic SF-48) needs a backend-owned Coach
profile before any Coach entry, UI, relationship or training work. Claude
Design `1791877903-9d9a` draws Coach registration twice (mobile OC1–OC11,
web WCR1–WCR7) with different vocabularies; SF-49 reconciled them and the
product owner approved the contract (O-1, O-2, A-3, A-13, A-14).

## Decision

* `SimpleFit.Coaches` owns `coach_profiles`: one row per user
  (`unique (user_id)`, `ON DELETE CASCADE`), never created with the user,
  no gym column, no role on `users`. It is independent of the account
  profile (ADR 0016) and the fighter profile (ADR 0015): a user may hold
  both, and neither profile reads or writes the other.
* Fields (SF-49 §4.2.3):

  | Field | Required to complete | Contract |
  |---|---|---|
  | `display_name` | yes | trimmed, 1–60 characters, no control characters; never derived from `AccountProfile.full_name` |
  | `brand_name` | no | trimmed, 1–80, no control characters |
  | `country_code` | yes | assigned ISO 3166-1 alpha-2 (the fighter profile's `CountryCodes` list), trimmed, uppercase |
  | `city` | yes | trimmed, 1–80, no control characters |
  | `bio` | no | trimmed, 1–500, plain text, line breaks allowed |
  | `languages` | no | ⊆ `en pl ru be uk` (coaching languages, not app locales) |
  | `coaching_formats` | yes, ≥ 1 | ⊆ `personal_training group_coaching online_coaching fight_camps` |
  | `competition_levels` | no | ⊆ `amateur professional` (the fighter profile's experience-level keys) |

  Formats, competition levels, audiences and training types never share a
  vocabulary; audiences (`fitness`, `womens`), `youth`, the
  Independent / Gym coach / Both choice, credentials, gym, billing and
  business data are not part of this model.
* Lengths count code points (as PostgreSQL `char_length`), checked by the
  domain and by database constraints. Vocabularies are plain text arrays
  checked by the domain (as `fighter_profiles.goals`), so a new value needs
  no migration; the database enforces shape: country format, lengths, no
  NULL elements, the completion invariant and an immutable completion time
  (trigger `coach_profiles_completion_immutable`).
* Lifecycle, identical to ADR 0015: `not_started` (no row) →
  `in_progress` (first save that stores a value) → `completed` (only
  `POST …/complete-onboarding`, with every requirement and completed
  account registration). A profile that has every required field is still
  `in_progress`. Repeat completion keeps the original time. After
  completion every field stays editable; required ones cannot be cleared.
* Saves: omitted fields are unchanged; `null`, empty or blank text clears an
  optional text; `null` or `[]` clears a selection; repeated selection
  values are rejected (never dropped). An invalid save changes and creates
  nothing; a save storing nothing creates nothing. Saving does not require
  account registration; completion does.
* Concurrency: every save and completion locks the profile row; first saves
  converge on one row through `INSERT … ON CONFLICT DO NOTHING` + lock. Saves
  of different fields all persist; for the same field the last committed
  save wins (no optimistic locking, as for fighter profiles).
* API (`Coach profile` tag): `GET /api/v1/me/coach-profile`
  (`getMyCoachProfile`), `PATCH` (`updateMyCoachProfile`),
  `POST /api/v1/me/coach-profile/complete-onboarding`
  (`completeMyCoachOnboarding`). Always the session's own user; unknown or
  ownership fields in a body are ignored. Responses carry
  `cache-control: no-store`. Errors use the existing envelope and codes
  (`required`, `too_long`, `invalid_format`, `invalid_choice`,
  `invalid_type`, `invalid` for a repeated value); no new codes.
* A completed coach profile grants nothing else: the entry resolver reports
  `COACH` for routing only (SF-51, ADR 0017 amendment), and
  Coach-to-Fighter access belongs to the future Coaching context behind its
  legal feature gate (SF-49 §7.4). The coach data-rules acknowledgement is
  not a completion requirement.

## Consequences

* Web and mobile render Coach onboarding from `CoachProfileResponse` alone
  and resume across devices; no client stores completion state.
* SF-49 §20 listed `duplicate` and `too_many` codes; the catalog has
  neither, so a repeated value is `invalid` (as for fighter goals) and the
  selection size is bounded by its vocabulary and the no-repeat rule.
* Follow-ups: Coach web/mobile onboarding UI (Coach entry resolution and
  the `COACH` capability landed in SF-51, ADR 0017 amendment); the fighter and account profile responses
  do not send `cache-control: no-store` yet (separate hardening ticket).
