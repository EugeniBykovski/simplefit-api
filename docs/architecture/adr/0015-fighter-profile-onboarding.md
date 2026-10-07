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
    `competitive_amateur` (with an optional bout count, 0-500), `professional`.
  * Stance: `orthodox`, `southpaw`, `switch`.
  * Goals (any number, no repeats): `fitness`, `learn_boxing`,
    `improve_technique`, `competition`, `fight_preparation`.
  * Weight class: `minus_63_5` … `plus_86`, `not_sure`.
* **The OF1 account step is split.** The fighter profile owns the public
  fighter identity: display name, username, country (ISO 3166-1 alpha-2) and
  city. Date of birth and consents are account-level (O04, before the role is
  chosen) and belong to a separate ticket. The avatar is deferred (it needs
  uploads).
* **Weight data is persisted and private:** weight class, current weight
  (kg, one decimal, 30-200) and height (cm, 120-230). It is returned only to
  its owner.
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
  value; nothing is required while in progress. The first save creates the
  row (`INSERT … ON CONFLICT DO NOTHING`, then `FOR UPDATE`, so concurrent
  first saves converge). An invalid save, including a first one, changes and
  creates nothing.
* **Completion.** The requirements are the steps without Skip: OF1 (display
  name, username, country, city) and OF2 (experience, stance). Goals, weight,
  next fight, gym, coach, friends and notifications are skippable.
  * Only `complete-onboarding` sets `onboarding_completed_at`, after
    `validate_required`.
  * Failures are `422 validation_error` with a `required` field code per
    missing field.
  * A database check constraint enforces the same invariant.
  * Completing again keeps the first time.
  * After completion the profile stays editable, but required fields can
    no longer be cleared.
* **Endpoints.** These are the first `/api/v1` product resources (ADR
  0003), on the `:authenticated` pipeline, always for the session's own user:
  * `GET /api/v1/me/fighter-profile` always answers `200`. Without a profile
    it returns `not_started` with empty fields, so clients render onboarding
    without client-side rules. Reading creates nothing.
  * `PATCH /api/v1/me/fighter-profile`
  * `POST /api/v1/me/fighter-profile/complete-onboarding`
* **Response.** `{"fighter_profile": {"onboarding": {status, completed_at,
  missing_requirements}, …fields}}`. Ids, `user_id` and internal timestamps
  are not exposed.
* **Canonical forms.** Usernames are stored in lowercase and are unique (a
  taken one is `already_exists`); format: a letter, then 2-29 letters, digits
  or underscores. Country codes are stored in uppercase. Text is trimmed;
  blank becomes `null`.
* **Privacy.** Personal fields are `redact: true` and profile queries run with
  `log: false` (ADR 0008).

## Consequences

* The web and mobile clients regenerate their API clients from
  `openapi/simplefit.api.json`. Web WF1 must adopt the mobile vocabularies
  before it is built.
* `GET /api/me` is unchanged. A summary of the fighter profile as a sibling of
  `user` (ADR 0010) can be added when a client needs it for routing.
* Follow-ups:
  * date of birth and consents (account level);
  * the avatar (uploads);
  * a live username-availability check (OF1 "✓ available"; today a save
    reports `already_exists`);
  * privacy and notification settings;
  * gym, membership, coach and friends links.
* Country codes are checked for format, not against the ISO list.
