# ADR 0015 — Fighter profile and resumable Fighter onboarding

* Status: Accepted
* Date: 2026-10-08
* Ticket: SF-25 (builds on ADR 0003 URL layout, ADR 0009 one global user and
  ADR 0010 sessions)

## Context

Claude Design `1791360430-48c0` draws Fighter onboarding twice: mobile
O04 → O05 → OF1-OF11 (390 px) and web WF1-WF6 (1440 px). Web states the
behaviour: "Saved as you go · finish later from any device", with "Save &
exit". The two platforms agree on stance and next fight, but use different
vocabularies for experience, goals, privacy and notifications. Gym,
membership, coach and friends steps need domains that do not exist yet.

The user record holds no profile data (ADR 0009): a fighter profile is a
separate record, and having one is what makes a user a fighter.

## Decisions (product decisions confirmed for SF-25)

* **Mobile OF2-OF4 vocabularies are canonical.** Web WF1 is to be aligned
  in design.
  * Experience: `new_to_boxing`, `recreational`, `amateur`,
    `competitive_amateur`, `professional`.
  * `amateur_bout_count`: OF2 draws a bout count only on the Competitive
    Amateur option ("Competing in amateur events"), so it is an amateur
    record. It is optional, an integer ≥ 0, and independent of the level:
    changing the experience level never clears it.
  * Stance: `orthodox`, `southpaw`, `switch`.
  * Goals (any number, no repeats): `fitness`, `learn_boxing`,
    `improve_technique`, `competition`, `fight_preparation`.
  * Weight class: `minus_63_5` … `plus_86`, `not_sure`.
* **The OF1 account step is split.** The fighter profile owns the public
  fighter identity: display name, username, country and city. Date of birth and consents are account-level (O04, before the role is
  chosen) and belong to a separate ticket. The avatar is deferred (it needs
  uploads).
* **Weight data is persisted and private:** weight class, current weight
  and height. It is returned only to its owner.
  * Units follow OF4: kilograms with at most one decimal place (more
    precision is rejected with `invalid_format`, never rounded), whole
    centimetres.
  * The only bounds are technical validity, not boxing or eligibility policy:
    measurements are positive and below 1000 (the weight column's
    precision); counts are non-negative and fit a 32-bit integer. The
    database checks only sign.
* **Privacy and notification settings are out of scope.** Their vocabularies
  conflict and notifications are account-wide; completion does not require
  them.

## Decisions (domain and API)

* `SimpleFit.Fighters` owns `fighter_profiles`: one row per user (unique
  `user_id`, `ON DELETE CASCADE`). Explicit columns, no JSON blob.
  Vocabularies are plain text enforced by the domain, as for
  `identities.provider`.
* **States are derived from stored facts**, never reported by clients:
  * no row → `not_started`;
  * a row without `onboarding_completed_at` → `in_progress`;
  * `onboarding_completed_at` set → `completed`.
* **Saving.** `PATCH` accepts any subset of the fields and validates each
  value; nothing is required while in progress.
  * A profile starts existing only when a save persists at least one value.
    A save with nothing to persist (no fields, unknown fields only, or values
    equal to the defaults) returns the current state and never moves
    `not_started` to `in_progress`.
  * The first persisting save creates the row (`INSERT … ON CONFLICT DO
    NOTHING`, then `FOR UPDATE`, so concurrent first saves converge).
  * An invalid save, including a first one, changes and creates nothing.
* **Completion requirements**, from the approved source:

  | Field | Why it is required |
  | --- | --- |
  | display name | OF1 has no Skip; of its fields only the avatar is labelled "Optional" |
  | username | OF1, as above (with a live "✓ available" check) |
  | country | OF1, as above |
  | city | OF1, as above |
  | experience level | OF2 has no Skip and its CTA continues only with a selection |
  | stance | OF2 (same step, segmented control always set) |

  Not required:
  * goals: OF3 has Skip;
  * next fight: labelled "optional" on OF3 and WF1. Date and event name are
    independent: either, both or neither can be saved (the design states no
    dependency);
  * weight class: OF4 has Skip;
  * current weight and height: labelled "optional" on OF4;
  * amateur bout count: a detail of one experience option;
  * gym, coach, friends, notifications: skippable steps.
  * Only `complete-onboarding` sets `onboarding_completed_at`, after
    `validate_required`.
  * Failures are `422 validation_error` with a `required` field code per
    missing field.
  * A database check constraint enforces the same invariant.
  * Completing again keeps the first time. A database trigger rejects any
    change to, or removal of, `onboarding_completed_at` once it is set.
  * After completion the profile stays editable, but required fields can
    no longer be cleared.
* **Endpoints.** `/api/v1` is the established convention for product
  resources:
  * ADR 0003: product resources under `/api/v1`, "starting with the first
    domain endpoint"; operational endpoints unversioned.
  * `CLAUDE.md` rule 11: "Product endpoints live under `/api/v1`".
  * ADR 0010 explains why `/api/me` and `/api/auth/*` are unversioned:
    session infrastructure rather than versioned product resources.
  * The design's proposed backend surface also uses `/api/v1`.

  SF-25 is the first domain resource, so it opens that scope rather than
  inventing one. The endpoints use the `:authenticated` pipeline and always
  act for the session's own user:
  * `GET /api/v1/me/fighter-profile` always answers `200`. Without a profile
    it returns `not_started` with empty fields, so clients render onboarding
    without client-side rules. Reading creates nothing.
  * `PATCH /api/v1/me/fighter-profile`
  * `POST /api/v1/me/fighter-profile/complete-onboarding`
* **Response.** `{"fighter_profile": {"onboarding": {status, completed_at,
  missing_requirements}, …fields}}`. Ids, `user_id` and internal timestamps
  are not exposed.
* **Username policy.**
  * Trimmed and stored in lowercase.
  * 3-30 ASCII lowercase letters, digits or underscores; the first and last
    characters are a letter or digit.
  * Unique regardless of case: a unique index on `lower(username)` is the
    final arbiter, and a conflict is `already_exists`.
  * A format check constraint mirrors the rule.
* **Country.** OF1 shows a country name; everywhere else the design draws
  Country as a selector (SP1, OG2, with ▾), while City is always free text.
  So the API stores the selection as an ISO 3166-1 alpha-2 code:
  * trimmed and uppercased;
  * checked against the 249 officially assigned codes
    (`SimpleFit.Fighters.CountryCodes`, a static copy generated from the IANA
    tz `iso3166.tab` and cross-checked with CLDR region names; no runtime
    dependency);
  * unassigned codes are `invalid_choice`, malformed input
    `invalid_format`.
* Other text is trimmed; blank becomes `null`.
* **Privacy.** Personal fields are `redact: true` and profile queries run with
  `log: false` (ADR 0008).

## Consequences

* Client synchronisation: `simplefit-platform` and `simplefit-mobile`
  regenerate their clients from `openapi/simplefit.api.json`. Their `api:check`
  requires the snapshot to be byte-identical to this artifact, so SF-25 ships
  dedicated client-sync commits (`SF-25-fighter-profile-client-sync`) with
  the regenerated clients and no hand-written calls. Web WF1 must adopt the
  mobile vocabularies before it is built.
* `GET /api/me` is unchanged. A summary of the fighter profile as a sibling of
  `user` (ADR 0010) can be added when a client needs it for routing.
* Follow-ups:
  * date of birth and consents (account level);
  * the avatar (uploads);
  * a live username-availability check (OF1 "✓ available"; today a save
    reports `already_exists`);
  * privacy and notification settings;
  * gym, membership, coach and friends links.
