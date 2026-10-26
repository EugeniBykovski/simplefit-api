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

## Amendment — SF-51 (2026-10-14): Coach capability and multiple contexts

Accepted with SF-51 (SF-49 revision 3 §5, rows E1–E14; product decision:
two onboardings in progress lead to `context_selection`).

* **Facts.** The Coach profile (ADR 0020) joins the facts:
  `coach_profile: not_started | in_progress | completed`, alongside the
  account registration, the Fighter profile and the user's last explicit
  context choice. `capabilities` is `FIGHTER` and/or `COACH`, each derived
  only from its completed profile; both can be held. `COACH` opens the
  user's own Coach application; it grants no access to fighters,
  relationships, invitations, sessions or gyms.
* **Inputs.** `intent` (`fighter`, `coach`, `gym`, `sponsor`) is the
  journey the user asked for and may lead into onboarding. New: `context`
  (`fighter`, `coach`) asks to open an application context and is honoured
  only when that profile is completed, otherwise ignored (it never starts
  onboarding and is not echoed). Neither grants anything; invalid values are
  `invalid_choice`.
* **Rules, first match wins.**
  1. Account registration not complete → `account_registration`
     (mandatory); the intent is echoed as the continuation.
  2. `intent: fighter` / `coach` → that profile's home when completed,
     otherwise its onboarding (mandatory), **whatever the other profile's
     state**. `gym` / `sponsor` → unchanged.
  3. `context` naming a completed profile → its home (`requested_context`).
  4. Default by completed profiles: none → `role_selection` when nothing is
     started, the one onboarding in progress (mandatory), or
     `context_selection` when both are in progress; one → its home (the other
     unfinished journey stays reachable with its intent); both → the last
     explicit choice's home (`last_context`), or `context_selection`.
* **Destinations** gain `coach_home` and `context_selection`; reasons gain
  the Coach onboarding reasons, `requested_context`, `last_context`,
  `context_choice_required` and `multiple_roles_in_progress`. `coach_intent`
  stays in the enum for compatibility and is no longer returned. All
  changes are additive; Fighter-only users resolve exactly as before.
* **Last explicit context choice.** `SimpleFit.Entry` owns
  `entry_context_choices` (one row per user, `fighter` or `coach`,
  cascading with the user). Only `PUT /api/v1/me/entry/context`
  (`chooseMyEntryContext`) writes it: an explicit choice on a context
  switcher or the context-selection screen, for a completed profile only
  (`409 conflict` otherwise; unknown body fields are `invalid`). The latest
  choice wins across devices. Resolving the entry still writes nothing, and
  the choice is re-validated on every read, so it never grants access.
* **Workspaces stay separate.** Profile contexts are not organizational
  workspaces; choosing a gym will be a later step owned by the Gyms domain.
* **Observability.** The resolution log line adds `coach_profile` and
  `entry_context` metadata (allow-listed); no identifiers, tokens or
  `returnTo` values.
* **Clients** (follow-up tickets): map `coach_home` and
  `context_selection`, gate areas on `capabilities` rather than on
  `fighter_home`, treat every `*_home` as a completed journey, and call
  `chooseMyEntryContext` from their switchers.

## Amendment — SF-84 (2026-10-27): Gym intent and gym workspaces

Accepted with SF-84 (epic SF-81; ADR 0026 D-G05, D-G07, D-G15, D-G21–D-G24).
The resolver stays the only entry decision; gyms extend its facts and rules.

* **Intent.** `gym` was already an allowed intent and stays the only Gym
  value: no aliases. It remains ephemeral navigation. It is validated,
  echoed and never stored, and clients carry it through Email, Google and
  Apple sign-in and account registration as a continuation, as for every
  intent. It creates no gym, no staff membership and no capability, and it
  never replaces another context.
* **Facts.** `SimpleFit.Gyms.workspace_overview/2` supplies the gym facts.
  It reads only the viewer's own active staff memberships, re-read on every
  resolution:
  * counts of all workspaces and of completed gyms;
  * the one completed gym, when there is exactly one;
  * the draft the viewer owns;
  * at most 25 summaries.

  Entry runs no gym query of its own, and gym authorization stays in
  `Gyms`.
* **Capability.** `GYM_WORKSPACE` comes from an active staff membership at a
  gym with a **completed** setup. The role doesn't matter: per-role
  permissions stay per operation (`Gyms.Policy`). A draft grants no
  capability; its owner resumes setup through the rules below, without any
  capability gate (D-G05: any registered user may start a gym).
* **Rules** (first match wins; Fighter and Coach rules unchanged):
  1. Account registration not complete → `account_registration`.
  2. `intent: fighter` / `coach` → unchanged.
  3. `intent: gym`, by real workspaces:
     * none → `gym_onboarding` (`gym_setup_not_started`, no `gym_id`);
     * only the owned draft → `gym_onboarding` (`gym_setup_in_progress`,
       `gym_id` = the draft);
     * one completed gym and no draft → `gym_home` (`gym_workspace_completed`,
       `gym_id`);
     * several, no draft, and a still-valid remembered gym → `gym_home`
       (`last_context`);
     * otherwise → `gym_selection` (`gym_choice_required`). A completed gym
       together with a draft always goes to the chooser, so both setup states
       are visible.
  4. `context: fighter` / `coach` (completed), or `context: gym` with the
     `gym_id` of a completed gym where the viewer is active staff → that home
     (`requested_context`). Anything else is ignored, never reported.
  5. Defaults, by completed contexts (completed profiles plus each completed
     gym):
     * none → resume the single journey in progress (an onboarding, or the
       owned draft as `gym_onboarding`), `role_selection`, or
       `context_selection`;
     * one → its home;
     * several → the last choice while still valid, otherwise
       `context_selection`.

  A user who once chose Gym is never forced into it: with a completed
  Fighter or Coach profile and only a draft gym, the default stays that
  profile's home.
* **Destinations and reasons** (additive):
  * destinations `gym_home` and `gym_selection`;
  * reasons `gym_setup_not_started`, `gym_setup_in_progress`,
    `gym_workspace_completed` and `gym_choice_required`;
  * `gym_intent` stays in the enum for compatibility and is no longer
    returned, as with `coach_intent`.
* **Response** (additive):
  * `gym_id`: the gym the destination refers to, or `null`;
  * `gym_workspaces`: at most 25 entries. Each has the gym id, its name, the
    viewer's role, its setup status, the backend-decided
    `available_actions` (`enter` for a completed gym, `continue_setup` for
    a draft when the role completes setup) and `selected`;
  * `gym_workspace_count`: the total. `listMyGyms` pages the rest.

  Nothing else about a gym is exposed: no member, staff, booking, revenue,
  plan, verification or publication data.
* **Context choice** (`PUT /api/v1/me/entry/context`, extended, not
  duplicated):
  * **Request:** `{"context": "gym", "gym_id": …}` records a gym with a
    completed setup where the viewer is active staff. Unknown, foreign and
    malformed-in-tenancy ids get `404` (existence never revealed), a draft
    gets `409` (`setup_status: draft`), and `gym_id` without `context: gym`
    (or the reverse) gets `422`.
  * **Locking:** the write share-locks the gym row, then the membership, in
    the same order as every gym write, so a concurrent revocation commits
    either before (`404`) or after. In the latter case the choice is ignored
    on every read.
  * **Storage:** `entry_context_choices` gains `gym_id` (`ON DELETE
    CASCADE`), with `CHECK ((context = 'gym') = (gym_id IS NOT NULL))`
    (migration `20261027090000`, explicit up/down; rolling back forgets gym
    choices only).
* **Preference vs active gym.** The remembered choice is a per-account
  navigation preference (SF-51 semantics: the latest choice wins on every
  device and session, and it survives refresh and logout for the same
  account). It is never authority.
  * The **active gym** is the id each request carries in its path
    (`/api/v1/gyms/{gym_id}/…`, D-G15/D-G23). Two tabs or devices on
    different gyms never interfere, and nothing server-side changes which gym
    a request acts on.
  * Clients clear their own active-gym state on logout. Another account
    never reads this account's choice, because the row is keyed by user.
* **Observability.** Unchanged: the resolution log line carries no gym ids
  or names.
