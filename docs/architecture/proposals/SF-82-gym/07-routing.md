# SF-82 · 07 — Cross-platform Gym routing

**Status:** `D-G07`, `D-G15` and `D-G16` are approved; `D-G22`, `D-G23`
and `D-G24` are open. SF-82 changes neither the route registry
(`simplefit-platform/docs/route-registry.json`, synced to mobile) nor
`docs/route-architecture.md`. The changes below are made by the implementing
tickets, each with its own registry PR.

## 1. Today

* 53 registry routes have `gym` in their id or path. All are `IMPLEMENTED`
  as SF-32/SF-33 feature placeholders ("not available yet"), so no Gym screen
  shows fabricated data.
* Console routes require `GYM_WORKSPACE`, which the entry projection never
  emits yet, so they are unreachable.
* Member-facing routes require `FIGHTER` (§5).
* Owner onboarding: `web.app.onboarding.gym` and `mobile.onboarding.gym`
  (account level, phase `ONBOARDING`).
* Invitation placeholders with a token in the path: `mobile.invite.coach._token`
  (INV2), `mobile.invite.staff._token` (OS1), `mobile.invite.staff._token.confirm`
  (OS1b) (§6).

## 2. Route groups

| Group | Web | Mobile | Gate | Ticket |
| --- | --- | --- | --- | --- |
| Public | `/gyms` (L4), `/pricing` (PR3 stays FUTURE) | — | guest | SF-84 (copy only) |
| Owner creation | `/app/onboarding/gym` (OG1, OG2, OG3, OG6b) | `/onboarding/gym` (OG0 handoff) | authenticated, account registration complete, **no** capability | SF-84 |
| Staff invitation | `/invite/staff` (reads `#token=`) | `/invite/staff` (token-free app-link entry) → staff-invitation inbox | preview anonymous (web); accept needs a session | SF-87 |
| Staff onboarding | — | `/onboarding/staff/role\|location\|tour` | `GYM_WORKSPACE` | SF-87, SF-101 |
| Gym console | `/app/gym/**` | `/gym/**` (Gym tabs) | `GYM_WORKSPACE` + active gym; role enforced by the backend | SF-85 onward |
| Member side | `/app/me/gyms` (new, account area) | `/gym/:gymId/**`, `/membership` (member pass) | account level (`D-G07`) + backend membership check | SF-91, SF-95, SF-97 |
| Join | `/join/:code` (new) | `/join/:code` (A03) | preview anonymous; join needs a session | SF-89 |

## 3. Explicit `gym_id`: consistency across layers (`D-G15`)

| Layer | Where the gym id comes from | Authorization | Failure behaviour |
| --- | --- | --- | --- |
| Backend | The path: `/api/v1/gyms/{gym_id}/…`, on every gym-scoped operation | `Gyms.Policy.authorize/3` re-reads the caller's active staff (or member) row for **that** gym inside the operation; child resources are checked with composite `(gym_id, id)` keys | 404 for non-staff, cross-gym and revoked access; 403 `forbidden` for a role without the permission |
| Web console | The client store of the active gym (`sessionStorage` per tab, seeded from `/me/entry` `gym_workspaces` + `last_gym`); console URLs stay id-free (`D-G23`) | The web calls the API from the browser with the session bearer (`callWithSession`), so every request carries the id it shows | A gym 404 drops the active gym, refetches the entry and opens the switcher; a 403 shows the role state (`D-G24`) |
| Web member side | The URL (`/app/me/gyms/:gymId/…`) | Backend member check | 404 → not found in shell |
| Mobile console | The active-gym store (memory + secure store keyed by user); `/gym/**` is id-free | as web | as web; switching through A04 / `/workspaces` |
| Mobile member side | The URL (`/gym/:gymId/…`, already in the registry) | Backend member check | 404 → not found |
| Workspace switching | `PUT /me/entry/context {"context":"gym","gym_id":…}` stores the last choice (additive) | Server validates staff membership before storing; re-validates on every read | Ended membership → the stored choice is ignored; the next entry read omits it |
| Emails and push (future) | Deep links carry the gym id in the URL (`D-G23` option B, only when needed) | as backend | the link opens the switcher if the user is not staff there |

Consistency rules:

1. The backend never infers the gym from a session, header or "current
   gym". The id in the path is the only source.
2. A client never sends a gym id it did not receive from the API.
3. Two tabs or devices can work on two gyms at once; a switch in one does not
   retarget the other's requests.
4. Responses include the gym's `id` and `name`, and the shell renders the
   name from the response, so a stale tab shows which gym it acts on (T6).

## 4. Gates and resume

| Situation | Web | Mobile |
| --- | --- | --- |
| Not signed in, opens a gym route | `/login?returnTo=` | `/welcome` / sign-in with `returnTo` |
| Signed in, no `GYM_WORKSPACE` | existing capability redirect | same |
| `intent=gym`, no gym | `/app/onboarding/gym` (OG1) | `/onboarding/gym` (OG0) |
| `intent=gym`, draft gym | `/app/onboarding/gym` at the first missing step | OG0 |
| Completed gym, first visit | `/app/gym` + GRW1/GRW2 | `/gym/pulse` + GR1/GR2 |
| FUTURE or BLOCKED area | registry placeholder stays; navigation item hidden | same |

## 5. Member-route capabilities (`D-G07` approved)

The member's access is decided by the backend (`gym_members`). The route
capability only decides whether the screen may render. Proposed registry
change for SF-91:

| Route id | Path | Today | Proposed | Why |
| --- | --- | --- | --- | --- |
| `mobile.gym._gym-id.classes._class-id.book` | `/gym/:gymId/classes/:classId/book` | `FIGHTER`, ACTIVE | `null` (account level), phase `null` | Booking needs gym membership, not a FighterProfile |
| `mobile.membership` | `/membership` | `FIGHTER`, ACTIVE | `null` | F16 member pass (`D-G19`) |
| `mobile.gym._gym-id.community` | `/gym/:gymId/community` | `FIGHTER` | unchanged until built (FUTURE) | Decide with the social domain |
| `mobile.gym._gym-id.store` | `/gym/:gymId/store` | `FIGHTER` | unchanged (FUTURE) | Marketplace domain |
| `mobile.gym._gym-id.memberships`, `…._membership-id`, `mobile.me.membership`, `mobile.me.credits` | — | `FIGHTER` | unchanged (blocked by `D-G10`); account level when commerce is decided | Commerce |
| `mobile.marketplace.gym._gym-id`, `mobile.board.node.gym._gym-id` | — | `FIGHTER` | unchanged (FUTURE) | Fighter-app discovery surfaces |
| new `web.app.me.gyms`, `web.app.me.gyms._gym-id` | `/app/me/gyms[/:gymId]` | — | `null` | Web member view |
| new `web.join._code` | `/join/:code` | — | `PUBLIC` | Web join (A03 equivalent) |

A non-fighter member reaches these screens from the account area (web
`/app/me/gyms`, mobile Settings → "My gyms"), and a fighter also reaches them
from the Fighter app. The routes never expose fighter data, and a member
without a FighterProfile is never sent to fighter onboarding.

## 6. Staff-invitation routes (`D-G16` approved, `D-G22` open)

Constraints from the existing Coach–Fighter invitations, all kept unchanged:

* E08 link `<WEB>/invite/coach#token=sfi_…`. The web page (SF-60) reads the
  fragment once and sends the token only in request bodies.
* The mobile app claims exactly `https://<app link host>/invite/coach`,
  **discards the fragment** and routes to the fighter's invitation inbox
  (`systemPathOf`, SF-80). Tokens never enter navigation state, `returnTo`,
  storage or logs. Putting the token into an app route was rejected in SF-80.
* The AASA and Android intent filter claim only `/invite/coach`.

Proposal:

| Item | Change | Effect on Coach–Fighter |
| --- | --- | --- |
| E06 link | `<WEB>/invite/staff#token=sfs_…` | none (other path, other prefix, other table) |
| Web | New `web.invite.staff` page: reads the fragment once, preview, accept (SF-60 pattern) | none |
| Mobile app link | Later native build: also claim `/invite/staff`; `systemPathOf` maps it to the signed-in staff-invitation inbox and drops the fragment | `/invite/coach` mapping unchanged; tests for both |
| Mobile inbox | New `mobile.gym-invitations` (token-free list from `GET /me/staff-invitations`, by verified email) and `mobile.gym-invitations._invitation-id` (OS1 by invitation **id**, OS1b via SF-77 add-email) | none |
| `mobile.invite.staff._token`, `mobile.invite.staff._token.confirm` | Retire. The paths are reserved and render not found | none |
| `mobile.invite.coach._token` (INV2) | Retire. A gym coach invitation is a staff invitation with role coach. `simplefit://invite/coach/<x>` and `/invite/coach/<x>` stop reaching a placeholder that would hold a token in a route param | the exact `/invite/coach` mapping is untouched |

**No live links break.** No E06 or INV2 email has ever been sent (there is no
Gym backend), and the only link in the wild, E08 `/invite/coach#token=`, is
unchanged.

## 7. Other registry changes the tickets will propose

1. `route-architecture.md` §7 wording for `D-G15`/`D-G23`, and the §8
   rule-9 exception for gym 403s (`D-G24`) — SF-85.
2. Design IDs of revised boards (C1–C17 in [12](12-design-reconciliation-plan.md))
   once Claude Design is updated.
