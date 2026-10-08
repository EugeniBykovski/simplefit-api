# ADR 0016 — Shared account registration: basics and consent

* Status: Accepted
* Date: 2026-10-08
* Ticket: SF-44 (builds on ADR 0009 one global user, ADR 0010 sessions,
  ADR 0003 URL layout and ADR 0015 fighter profile)

## Context

Every SimpleFit user, whatever roles they take on, completes the same
account basics before any role journey. Claude Design `1791399379-cc08`
draws them as mobile O02 (full name) and O04 "Basics & consent" (date of
birth, Terms, Privacy, optional product news). Web WA3 shows the same
consents as checkboxes before authentication. Settings put the full name and
date of birth under "Account details", separate from a role profile's public
display name.

Authentication proves who the user is (ADR 0009, ADR 0012–0014). It does not
complete registration.

## Decisions (product decisions approved for SF-44)

* **Date of birth.**
  * The full date is stored (`date`) and required to complete registration.
  * It must be a real calendar date, not in the future.
  * The user must be at least **16** by calendar date: the year difference,
    minus one until this year's birthday. A 29 February birthday counts from
    1 March in common years.
  * Under 16 is rejected (`too_young`). There is no guardian flow.
  * After completion the date of birth cannot be changed through the API
    (`immutable`); corrections are a support concern. A database trigger
    enforces this as well.
  * The web "I am 16 or older" checkbox is not a persisted model.
* **Required legal consents: Terms of Service and Privacy Policy only.**
  * The contact-sport / health notice is not global: a future role- or
    activity-specific ticket may add it.
* **Consent timing.** Registration happens after authentication, for every
  provider: authenticated user → Basics & Consent if incomplete → entry
  resolution (SF-45) → role journey. Pre-auth checkboxes are never
  authoritative. Provider claims (Google/Apple name or email) never fill
  registration fields.
* **Names.**
  * `AccountProfile.full_name` is the person's name.
  * `FighterProfile.display_name` and `FighterProfile.username` stay
    fighter-facing.
  * There is no account username. A client may prefill the fighter display
    name from the full name; both stay independently stored and editable.
* **Product news** is optional, withdrawable and never required.
* **Checkout** gating is not part of registration (future Commerce work).

## Decisions (domain and API)

* **`account_profiles`**, one per user (unique `user_id`, `ON DELETE
  CASCADE`): `full_name`, `date_of_birth`, `registration_completed_at`,
  timestamps. It lives in `SimpleFit.Accounts`: nothing is added to `users`,
  no role or type, no JSON.
* **`account_consents`**, an append-only decision history keyed by user
  (`ON DELETE CASCADE`): `kind` (`terms`, `privacy`, `product_news`),
  `document_version`, `decision` (`accepted`, `withdrawn`), `recorded_at`.
  Nothing else is stored: no IP address, device or text. Database rules:
  * rows are never updated (a trigger enforces it);
  * `terms` and `privacy` always carry a version and are always `accepted`;
  * `product_news` has no version.
* **Versions.** The current version of each required document is
  configuration (`config :simple_fit, SimpleFit.Accounts.Consents,
  current_versions: %{terms: "terms-v1", privacy: "privacy-v1"}`).
  * A required consent is current only when accepted at the configured
    version, so changing the version makes earlier acceptances not current
    for completion. Document text is outside the domain.
  * A completed registration stays complete after a version change;
    prompting for re-acceptance is a later ticket.
* **State is derived:**
  * no profile row → `not_started`;
  * a row without `registration_completed_at` → `in_progress`;
  * `registration_completed_at` set → `complete`.
* **Saving.** `PATCH` takes any subset of `full_name`, `date_of_birth`,
  `accept_terms` (only `true`), `accept_privacy` (only `true`) and
  `product_news` (`true` / `false`).
  * The first save that persists a field or a consent decision creates the
    profile (`INSERT … ON CONFLICT DO NOTHING`, then `FOR UPDATE`).
  * A save with nothing to persist creates nothing.
  * An invalid save, including a first one, changes and creates nothing.
  * Repeating a current decision appends nothing. Consent decisions are
    written in the same transaction, under the profile lock.
* **Completion.** `POST …/complete-registration` requires a full name, a
  date of birth showing at least 16 years, and current Terms and Privacy
  acceptance.
  * Each missing item is a `required` field code (`full_name`,
    `date_of_birth`, `terms`, `privacy`); the server returns them as
    `missing_requirements`.
  * It is explicit and idempotent: completing again keeps the first time.
  * After completion the full name stays editable but cannot be cleared.
* **Endpoints.** These are `/api/v1` product resources on the
  `:authenticated` pipeline, always for the session's own user:
  * `GET /api/v1/me/account-profile` always answers `200` (`not_started`
    before anything is saved);
  * `PATCH /api/v1/me/account-profile`;
  * `POST /api/v1/me/account-profile/complete-registration`.

  `/api/me` is unchanged.
* **Public context API.** `SimpleFit.Accounts.get_account_registration/1`,
  `update_account_registration/2`, `complete_account_registration/1` and
  `registration_complete?/1`.

## Cross-context invariant (SF-25)

Fighter onboarding completion requires completed account registration:
`SimpleFit.Fighters.complete_onboarding/1` asks
`SimpleFit.Accounts.registration_complete?/1` and otherwise fails with
`account_registration` / `required`, alongside any missing fighter field.

* Creating and saving a FighterProfile is not gated.
* A fighter profile completed earlier stays idempotent, because
  registration never becomes incomplete again.
* `Fighters` depends on `Accounts`, never the reverse: there is no circular
  dependency.
* SF-45 routing additionally sends users with incomplete registration to
  Basics & Consent before role onboarding.

## Privacy

* `full_name` and `date_of_birth` are `redact: true`, and every
  registration query runs with `log: false` (ADR 0008).
* Request logs carry the route only; the Sentry filter and span sanitizer
  allow-lists are unchanged.
* OpenAPI examples use placeholder people.
* Consent records are auditable (what, which version, when) without
  personal data.

## Consequences

* Two validation reason codes are added (additive): `too_young` and
  `immutable`.
* Client SDKs regenerate (`getMyAccountProfile`, `updateMyAccountProfile`,
  `completeAccountRegistration`).
* Design follow-up: web needs a shared post-auth Basics & Consent screen
  (date of birth, Terms, Privacy, product news) for every sign-in method,
  replacing the pre-auth WA3 checkboxes. A web or mobile settings control
  for withdrawing product news is not designed yet; the API already
  supports it.
