# ADR 0018 — First-run experiences

* Status: Accepted
* Date: 2026-10-10
* Ticket: SF-40 (builds on ADR 0009 one global user, ADR 0015 fighter
  profile, ADR 0016 shared account registration, ADR 0017 entry resolution)

## Context

After Fighter onboarding, Claude Design (`1791484446-8cb2`, section 34b)
opens the Fighter web Home in its first-run state (FRW1) and offers a
product tour (FRW2). The design's first-run flow says that tips and tours
can be skipped and never come back once dismissed, on any platform.

Nothing in the backend recorded presentation state. Completing Fighter
onboarding (`fighter_profiles.onboarding_completed_at`) says the profile is
complete. It does not say that a tour was seen, finished or ended. Browser
storage cannot be the record: it is per browser, so a second browser or the
mobile app would show a dismissed tour again.

## Decisions

* **A small context of its own.** `SimpleFit.FirstRun` owns one table,
  `first_run_outcomes`. Nothing is added to `users` (no role, no type, no
  flags) or to `fighter_profiles`, and registration, onboarding and entry
  resolution (ADR 0017) are unchanged. It reads `SimpleFit.Fighters` for
  availability, so it sits beside `Entry`, not inside a context it depends
  on.
* **Only the outcome is stored.** Each row has:
  * `user_id`, deleted with the user;
  * `experience`, plain text enforced by the domain (an allow-list,
    `fighter_web_tour` today);
  * `outcome`: `completed` (finished) or `dismissed` (ended early);
  * `recorded_at`.

  No device, platform, step, IP address or free text is stored.
* **Status is derived on every read:**
  * `unavailable` when the user cannot have the experience: the Fighter web
    tour needs a completed Fighter onboarding, which itself needs a
    completed account registration;
  * `pending` when it is available and has no outcome;
  * otherwise the stored outcome.

  Completing onboarding records nothing: a newly onboarded Fighter's tour
  is `pending`.
* **The first outcome is final.** A unique index on
  `(user_id, experience)` and an insert that does nothing on conflict make
  recording idempotent and safe across tabs, devices and retries. A later
  request, with the same or the other outcome, returns the kept one with
  its original time. A trigger rejects updates.
* **Account-wide.** The record belongs to the user, not to a browser or a
  session. Another browser, a new sign-in or (later) the mobile app reads
  the same state.
* **Unfinished is not an outcome.** A tour closed by a reload or a lost
  connection stays `pending` and is offered again. Only an explicit finish
  or end is recorded.
* **API** (tag "First run"):
  * `GET /api/v1/me/first-run` (`listMyFirstRunExperiences`, `no-store`)
    lists every experience with its status.
  * `PUT /api/v1/me/first-run/{experience}` (`recordMyFirstRunOutcome`)
    takes `{outcome}`. It returns `404 not_found` for an unknown
    experience, `409 conflict` while the experience is unavailable
    (nothing is recorded), and `422 validation_error` for a missing or
    unknown outcome.
* **Rollout.** There is no backfill. Nothing has been deployed, so no
  completed Fighter predates the feature. The tour is offered, never
  forced, and one action dismisses it for good.

## Consequences

* A future tour (Coach, Gym, Sponsor, mobile) adds an allow-listed key and
  its availability rule. It needs no migration.
* The first-run checklist is not stored here. Its items are derived from
  their domains (gym membership, bookings, training) once those exist, so
  finishing a step on one platform ticks it on the other.
