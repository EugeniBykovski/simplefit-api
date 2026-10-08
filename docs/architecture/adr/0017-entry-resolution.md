# ADR 0017 — Post-authentication entry resolution

* Status: Accepted
* Date: 2026-10-08
* Ticket: SF-45 (builds on ADR 0009 one global user, ADR 0015 fighter
  profile, ADR 0016 shared account registration)

## Context

After any authentication (email registration, email sign-in, Google,
Apple) and on every neutral app entry, web and mobile must decide where the
user goes next. Until SF-45 each client decided alone ("a safe `returnTo`,
else the app root"), and generic Google / Apple sign-up drifted towards
Fighter onboarding. The state that decides it lives in the backend: shared
account registration (ADR 0016) and the Fighter profile (ADR 0015). Claude
Design V78 (`1791448557-b0b9`) draws the web surfaces WA5 (account basics
and consent) and WA6 (choose where to start); mobile has O04 and O05.

## Decisions

* **One resolver, one context.** `SimpleFit.Entry` resolves the entry from
  the public functions of `SimpleFit.Accounts` and `SimpleFit.Fighters`.
  It is its own small context because `Fighters` already depends on
  `Accounts`; putting the resolver inside either would create a cycle. It
  owns no schema and no table.
* **Read-only and derived.** Every call derives the answer from current
  persisted state. Nothing is written: no intent, no "current destination",
  no returnTo. Concurrent and repeated calls (several tabs, several devices)
  are therefore safe and advance on their own as registration and
  onboarding complete.
* **Semantic destinations, not paths.** `account_registration`,
  `role_selection`, `fighter_onboarding`, `fighter_home`,
  `coach_onboarding`, `gym_onboarding`, `sponsor_application`. Each client
  maps them to its own route registry ids; no locale, framework group or
  path reaches the API.
* **Intent is ephemeral navigation.** `intent` (`fighter`, `coach`, `gym`,
  `sponsor`) records which journey the user explicitly tried to enter, for
  this request only. It is validated against the allow-list
  (`invalid_choice` otherwise), echoed, never stored and never authorizes
  anything. There is no `User.role` or `User.type` (ADR 0009).
* **Rules, in order.**
  1. Account registration not complete → `account_registration`
     (mandatory). Completion is monotonic, so a later Terms or Privacy
     version never reopens it.
  2. `fighter` intent → `fighter_onboarding` until the Fighter profile is
     completed, then `fighter_home`.
  3. `coach`, `gym`, `sponsor` intent → `coach_onboarding`,
     `gym_onboarding`, `sponsor_application`. An explicit intent wins over
     unrelated Fighter progress. Nothing is created for them.
  4. No intent: the Fighter profile is the only role state that exists, so
     in progress → `fighter_onboarding`, completed → `fighter_home`,
     otherwise `role_selection`. Generic Google / Apple sign-up never
     implies Fighter.
* **`mandatory`.** `true` for `account_registration` and
  `fighter_onboarding`: the client goes there even with a safe `returnTo`,
  keeps the `returnTo` as a continuation and resolves again afterwards.
* **Capabilities are a projection.** `capabilities` lists capabilities
  derived from real domains, in the client route registry's vocabulary:
  today only `FIGHTER`, once Fighter onboarding is complete. Coach, Gym and
  Sponsor workspaces do not exist, so they are never reported. The list is
  for routing UX; every context still authorizes on its own.
* **API.** `GET /api/v1/me/entry?intent=…` (`resolveMyEntry`, tag
  `Entry`), authenticated, `Cache-Control: no-store`. Without registration
  the response is still `200` with `account_registration`.
* **Observability.** One `info` log line per resolution with only `intent`,
  `destination`, `reason`, `account_registration` and `fighter_profile`
  metadata (ADR 0008). Routing outcomes are not errors and never reach
  Sentry.

## Consequences

* Web and mobile share one decision; their mapping tables and the
  `returnTo` path policy stay on the clients, next to their route
  registries.
* Workspace choice (web WA2, mobile A04) is not part of entry resolution
  until real multi-context data exists.
* New role domains (Coach profile, Gym and Sponsor workspaces) extend the
  rules and the capability projection when they exist.
