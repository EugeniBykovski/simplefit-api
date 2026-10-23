# SF-82 · 07 — Cross-platform Gym routing

**Status:** approved (`D-G07`, `D-G15`, `D-G16`, `D-G22`, `D-G23`,
`D-G24`). SF-82 changes neither the route registry
(`simplefit-platform/docs/route-registry.json`, synced to mobile) nor
`docs/route-architecture.md`. The paths below are the target for the
registry PRs of SF-85, SF-87 and SF-91. Exact route ids are fixed in those
PRs.

## 1. Today

* 53 registry routes have `gym` in their id or path. All are `IMPLEMENTED`
  as SF-32/SF-33 feature placeholders ("not available yet").
* Console routes are id-free (`/app/gym/**`, `/gym/**`) and require
  `GYM_WORKSPACE`, which the entry projection never emits yet.
* Member-facing mobile routes `/gym/:gymId/**`, `/membership`,
  `/me/membership` and `/me/credits` require `FIGHTER`.
* Owner onboarding: `web.app.onboarding.gym`, `mobile.onboarding.gym`.
* Invitation placeholders with a token in the path: `/invite/coach/:token`
  (INV2), `/invite/staff/:token` (OS1), `/invite/staff/:token/confirm` (OS1b).

## 2. Target route groups

| Group | Web | Mobile | Gate | Ticket |
| --- | --- | --- | --- | --- |
| Public | `/gyms` (L4), `/pricing` (PR3 stays FUTURE) | — | guest | SF-84 (copy) |
| Owner creation | `/app/onboarding/gym` (new: OG1), then `/app/onboarding/gym/:gymId/…` (resume a draft: OG2, OG3, OG6b) | `/onboarding/gym` (OG0 text handoff) | account registration complete, **no** capability; the draft id is authorized like any gym id | SF-84 |
| Gym chooser | `/app/gyms` | `/gyms` (also reachable from A04 / `/workspaces`) | `GYM_WORKSPACE` | SF-85 |
| Gym console | `/app/gyms/:gymId` (WG1) and `/app/gyms/:gymId/<area>` (members, timetable, bookings, attendance, staff, settings, …) | `/gyms/:gymId/pulse`, `/gyms/:gymId/check-in`, `/gyms/:gymId/classes/…`, `/gyms/:gymId/members/…` (Gym tabs) | `GYM_WORKSPACE` + backend staff check on `:gymId` | SF-85 onward |
| Staff onboarding | — | `/gyms/:gymId/onboarding/role\|location\|tour` (OS2–OS4) | as console | SF-87, SF-101 |
| Staff invitation | `/invite/staff` (reads `#token=` once) | `/invite/staff` app-link entry (token-free) → `/me/gym-invitations` inbox → `/me/gym-invitations/:invitationId` (OS1; OS1b via SF-77) | preview anonymous on web; accept needs a session | SF-87 |
| Member invitation | `/invite/gym` (reads `#token=` once) | same inbox, member invitations included | as staff | SF-91 |
| Member side | `/app/me/gyms`, `/app/me/gyms/:gymId/…` | `/me/gyms`, `/me/gyms/:gymId/…` (timetable, book, pass) | account level (`D-G07`) + backend member check on `:gymId` | SF-91, SF-95, SF-97 |
| Join by code | `/join/:code` | `/join/:code` (A03) | preview anonymous; joining needs a session and a verified identity (`D-G08`) | SF-89, SF-91 |

Staff and member views of the same gym use different prefixes
(`/app/gyms/:gymId` vs `/app/me/gyms/:gymId`, mobile `/gyms/:gymId` vs
`/me/gyms/:gymId`). A person who is both sees two clearly separate surfaces,
and a member link never opens the console.

## 3. ID-based navigation and authorization (`D-G15`, `D-G23`, `D-G24`)

| Layer | Source of the gym id | Authorization | Failure behaviour |
| --- | --- | --- | --- |
| Backend | The API path `/api/v1/gyms/{gym_id}/…`, on every gym-scoped operation | `Gyms.Policy.authorize/3` re-reads the caller's active staff or member row for **that** gym inside the operation; child resources use composite `(gym_id, id)` keys | Outsider, other gym, revoked or unknown → 404 `not_found`; active staff without the permission → 403 `forbidden` |
| Web | The UI path `:gymId` (console and member side); the page passes it unchanged to the API | Browser calls with the session bearer (`callWithSession`); the route guard checks `GYM_WORKSPACE` only, and the backend decides | 404 → not found in shell (existence not revealed); 403 → role-restriction state (`D-G24`) |
| Mobile | The route param `:gymId` | as web | as web |
| Chooser and landing | `/app/gyms` and `/gyms` read `gym_workspaces` from `/me/entry`: one gym → redirect to it; several → list, preselecting `last_gym` | The server stores `last_gym` via `PUT /me/entry/context {"context":"gym","gym_id":…}` after validating staff membership | A stored gym that is no longer valid is ignored |
| Switching | Navigating to another `:gymId` (in-shell switcher, A04) | Each request is authorized on its own | none |
| Emails and push | Links carry the gym id (`/app/gyms/:gymId/…`) | as backend | Non-staff recipient → not found; signed out → sign-in with `returnTo` |

Rules:

1. **The id is navigation, not authorization.** The backend never trusts
   the URL beyond using it as the lookup key, and never infers a gym from
   the session.
2. Tabs and devices are independent: each URL names its gym (T6 is closed
   by construction).
3. Gym ids are UUIDs. They are not secret, and knowing one grants nothing.
   URLs never contain tokens or personal data (member detail uses the
   member's opaque id).
4. The shell renders the gym name from API responses, never from the URL.
5. `route-architecture.md` must replace `D-WORKSPACE-NOT-IN-URL` for Gym
   and add the rule-9 exception (`D-G24`) in SF-85.

## 4. Gates and resume

| Situation | Web | Mobile |
| --- | --- | --- |
| Signed out, opens a gym URL | `/login?returnTo=<the URL>` | sign-in with `returnTo` |
| Signed in, no `GYM_WORKSPACE`, opens a console URL | not found (no hint the gym exists) | same |
| Staff of other gyms only, opens a console URL | not found (backend 404) | same |
| `intent=gym`, no gym | `/app/onboarding/gym` | `/onboarding/gym` (OG0) |
| `intent=gym`, draft gym | `/app/onboarding/gym/:gymId/<first missing step>` | OG0 |
| Completed gym, first visit | `/app/gyms/:gymId` + GRW1/GRW2 | `/gyms/:gymId/pulse` + GR1/GR2 |
| FUTURE or BLOCKED area | placeholder; navigation item hidden | same |

## 5. Member-route capabilities (`D-G07`)

| Route id (today) | Path (today) | Today | Target | Why |
| --- | --- | --- | --- | --- |
| `mobile.gym._gym-id.classes._class-id.book` | `/gym/:gymId/classes/:classId/book` | `FIGHTER`, ACTIVE | `/me/gyms/:gymId/classes/:classId/book`, account level | Booking needs gym membership, not a FighterProfile |
| `mobile.membership` | `/membership` | `FIGHTER`, ACTIVE | `/me/gyms/:gymId/pass`, account level | F16 member pass (`D-G19`, open) |
| `mobile.gym._gym-id.community`, `mobile.gym._gym-id.store` | `/gym/:gymId/…` | `FIGHTER` | unchanged until their domains exist (FUTURE) | social and marketplace |
| `mobile.gym._gym-id.memberships`, `…._membership-id`, `mobile.me.membership`, `mobile.me.credits` | — | `FIGHTER` | unchanged (deferred `D-G10`) | commerce |
| `mobile.marketplace.gym._gym-id`, `mobile.board.node.gym._gym-id` | — | `FIGHTER` | unchanged (FUTURE) | fighter discovery |
| new | `/app/me/gyms[/:gymId/…]`, `/me/gyms[/:gymId/…]` | — | account level | member views |
| new | web `/join/:code` | — | `PUBLIC` | web join |

## 6. Invitation routes (`D-G16`, `D-G22`)

Unchanged Coach–Fighter constraints:

* E08 link `<WEB>/invite/coach#token=sfi_…`, read once by the web page
  (SF-60).
* The app claims exactly `https://<app link host>/invite/coach`, discards
  the fragment and routes to the fighter's invitation inbox (`systemPathOf`,
  SF-80). Tokens never enter navigation state, `returnTo`, storage or logs.
* AASA (`APP_LINKS_APPLE_TEAM_ID`) and the Android intent filter claim only
  `/invite/coach`.

Changes for Gym:

| Item | Change | Effect on Coach–Fighter |
| --- | --- | --- |
| E06 / E07 links | `<WEB>/invite/staff#token=sfs_…`, `<WEB>/invite/gym#token=sgm_…` | none (other paths, prefixes and tables) |
| Web | `/invite/staff` and `/invite/gym` pages: read the fragment once, preview, accept | none |
| Mobile in-app | `/me/gym-invitations` inbox (`GET /me/staff-invitations` + member invitations, by verified email); items by **id** | none |
| Mobile app links | A later native build also claims `/invite/staff` and `/invite/gym`; `systemPathOf` maps both to the inbox and drops the fragment | the `/invite/coach` mapping and its tests stay; new tests are added next to them |
| Retired placeholders | `/invite/staff/:token`, `/invite/staff/:token/confirm`, `/invite/coach/:token` (INV2) | `simplefit://invite/coach/<x>` stops reaching a token-shaped route; the exact `/invite/coach` path is untouched |

No live links break: no E06, E07 or INV2 email has ever been sent.
