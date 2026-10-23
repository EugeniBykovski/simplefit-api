# SF-82 · 04 — Gym membership vs Coach–Fighter relationship contract

**Status: PROPOSED.** This contract is the most important boundary of the Gym
epic. It restates and extends SF-49 §9 and ADR 0021.

## 1. The rule

> **No gym fact creates, implies, widens or ends a Coach–Fighter
> relationship.** A coach affiliated with a gym gains **no** access to the
> training data of that gym's members. SF-56/SF-57 disclosure and consent
> (ADR 0021, 0022) remain the only way a coach sees a fighter's profile
> fields and assigns training.

Equally, no Coach–Fighter fact creates or changes a gym membership.

## 2. Relationship catalogue

| Relationship | Table / fact | Created by | Authorizes | Does **not** authorize |
| --- | --- | --- | --- | --- |
| Gym ↔ Owner | `gym_staff_memberships` role `owner` | creating the gym | everything at that gym's console incl. billing (when it exists) | members' training data; other gyms |
| Gym ↔ Staff (manager, front desk) | staff membership | accepted E06 invitation | the role's row of the matrix ([02 §4](02-identity-roles-permissions.md)) at that gym | training data, messages; other gyms |
| Gym ↔ Coach (affiliation) | staff membership role `coach` | accepted E06 invitation | coaching *classes*, rosters and attendance of occurrences they coach | fighter profile fields beyond roster display name; RPE, logs, notes, weight, videos; assigning ADR 0023 sessions to gym members |
| Gym ↔ Member | `gym_members` | invitation or join code | booking, check-in, member pass, seeing the gym's timetable | that any staff sees their training data; a coach relationship |
| Coach ↔ Fighter | `coach_fighter_relationships` | fighter's explicit acceptance (ADR 0021) | disclosed fields (C1+C2), private training sessions (ADR 0023) | anything at a gym; other fighters |
| Gym ↔ TrainingSession | **none** | — | — | Training sessions stay relationship-scoped (ADR 0023); no `gym_id` on them |
| Gym ↔ Class booking | `gym_bookings` (member ↔ occurrence) | the member (or staff on their behalf) | a place in that occurrence, appearing on its roster | a coach relationship with the class coach |

## 3. Overlaps that must stay separate

* **A gym coach who is also the fighter's independent coach.** Two rows:
  staff membership at the gym and an ADR 0021 relationship. Ending one never
  ends the other (SF-49 §9: "leaving a gym never ends a relationship"). The
  coach's gym roster shows the member's display name; their Coach app shows
  the relationship's disclosed fields. The two views are never merged.
* **Member invited by a gym coach to "Join my team".** A gym invitation (E07)
  and a coach invitation (E08) are different emails, tokens and acceptance
  transactions. A combined "join the gym and connect with me" offer, if ever
  wanted, is two explicit acceptances.
* **Roster vs disclosure.** A roster shows only: display name (from the
  account/fighter profile as the member chose to show it), booking status,
  check-in status, and a staff-only note field *about the booking*
  (FUTURE). Member detail for staff (WG14) shows gym-held facts only:
  membership status, visits, bookings, invitations — never profile fields
  like weight, goals or experience (WebMembers states "GYM ADMIN CAN'T SEE
  private trainings, RPE, weight, coach notes, videos and direct messages").
* **Shared sessions (WG13) and open sparring (WG12, WG27).** FUTURE; when
  built, attendance stays gym-side and each athlete's result stays with the
  athlete (WebGymShared copy).
* **"Fighter notes (with consent)" in WG16/WG17/OS2.** This is a future
  *gym-scoped consent* (a member grants a gym's coaches a narrow view), a new
  consent object with its own legal text — not the ADR 0021 relationship and
  not in MVP (`D-G06`).

## 4. Data flow constraints (enforced in code and tests)

1. `SimpleFit.Gyms.*` never reads `coach_fighter_relationships`,
   `training_sessions` or fighter profile fields other than the public
   display projection already used by coaching (`Fighters.coach_projection`
   is **not** used by Gyms).
2. `SimpleFit.Coaching` and `SimpleFit.Training` never read gym tables.
3. A contract test asserts that a user who is coach-staff at a gym, with
   several members booked into their classes, gets `404` from every ADR 0021
   and ADR 0023 endpoint for those members unless a relationship exists.
4. The legal registry (ADR 0022) and its local-development bypass (ADR 0025)
   are untouched by Gyms; a future gym-scoped consent gets its own documents
   and its own decision.
