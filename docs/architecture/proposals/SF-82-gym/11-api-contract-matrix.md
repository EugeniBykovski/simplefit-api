# SF-82 · 11 — Proposed `/api/v1` contract matrix

**Status: PROPOSED (path scoping approved, `D-G15`). Not in OpenAPI.** `openapi/simplefit.api.json` is
unchanged by SF-82; each ticket adds its operations with schemas and tests
(CLAUDE.md rules 8–11). All gym-scoped paths carry `{gym_id}` (`D-G15`) and
follow the 401/403/404 rules of [02 §5](02-identity-roles-permissions.md).
Errors use the existing envelope; new codes are listed per row.

| Method & path | Purpose | Actor / permission | Idempotency & concurrency | Notable errors | Ticket |
| --- | --- | --- | --- | --- | --- |
| `POST /gyms` | Create draft gym + first location + owner row | registered user | `client_request_id`; per-user advisory lock | 409 `gym_draft_exists`, 409 `gym_limit_reached`, 409 `client_request_id` reused, 422 | SF-83 |
| `GET /me/gyms` | Gyms where caller is staff, with `setup_status`, `missing_requirements` | registered user | — | — | SF-83 |
| `GET /gyms/{gym_id}` | Gym details | staff | — | 404 | SF-83 |
| `PATCH /gyms/{gym_id}` | Edit name, type, contact, branding fields | owner, manager | `lock_version` | 409 `stale`, 422 | SF-83/SF-98/SF-99 |
| `DELETE /gyms/{gym_id}` | Discard a **draft** gym (no automatic deletion, `D-G20`) | owner | gym row lock | 409 `gym_not_draft` | SF-83 |
| `POST /gyms/{gym_id}/complete-setup` | Backend-checked completion | owner | monotonic; repeat → 200 | 422 `setup_incomplete` with `missing_requirements` | SF-83 |
| `GET/POST /gyms/{gym_id}/locations`, `PATCH …/{location_id}` | Locations | read: staff; write: owner, manager | `lock_version` | 422 address | SF-83/SF-99 |
| `PUT /me/entry/context` (additive `gym_id`) | Remember last active gym | staff of that gym | — | 404 (not staff) | SF-85 |
| `GET /gyms/{gym_id}/staff` | Staff list + pending invitations | staff | — | — | SF-86 |
| `POST /gyms/{gym_id}/staff-invitations` | Invite by email + role | owner (any role but owner), manager (coach, front desk) | one pending per recipient digest; resend rotates | 403, 409 `already_staff`, 429 | SF-86 |
| `DELETE /gyms/{gym_id}/staff-invitations/{id}` | Revoke | inviter's roles | — | 404 | SF-86 |
| `POST /staff-invitations/preview` | Anonymous preview (token in body) | anyone | — | 404 `invitation_invalid` (uniform) | SF-86 |
| `POST /me/staff-invitations/accept` | Accept (token in body, web) | session with verified invited email | invitation `FOR UPDATE` | 409 `invitation_email_mismatch`, 404 | SF-86 |
| `GET /me/staff-invitations`, `GET …/{invitation_id}/preview`, `POST …/{invitation_id}/accept`, `POST …/{invitation_id}/decline` | Token-free staff-invitation inbox matched by the caller's verified email identities (SF-73 pattern; mobile entry, `D-G22`) | registered user | invitation `FOR UPDATE` | 404 (not addressed to a verified identity) | SF-86 |
| `PATCH /gyms/{gym_id}/staff/{staff_id}` | Change role / home location | per matrix | staff row lock | 403, 409 `owner_role_immutable` | SF-88 |
| `DELETE /gyms/{gym_id}/staff/{staff_id}` | Remove staff / leave | per matrix; self (not owner) | — | 409 `owner_cannot_leave` | SF-88 |
| `POST /gyms/{gym_id}/ownership-transfers`, `POST /me/ownership-transfers/{id}/accept` | Transfer ownership | owner → active staff; target accepts within 7 d | gym row `FOR UPDATE` | 409 `transfer_pending`, 404 | SF-100 |
| `GET /gyms/{gym_id}/members`, `GET …/{member_id}` | Members | owner, manager, front desk; coach limited | cursor pagination | — | SF-89 |
| `PATCH /gyms/{gym_id}/members/{member_id}` | Suspend / resume / end | owner, manager | member row lock | 409 `invalid_transition` | SF-89 |
| `POST /gyms/{gym_id}/member-invitations` | Invite by email (E07) | owner, manager, front desk | one pending per recipient | 409 `already_member`, 429 | SF-89 |
| `PUT /gyms/{gym_id}/join-code` | Rotate / disable code, auto-approve flag | owner, manager | — | — | SF-89 |
| `POST /gym-join/preview`, `POST /me/gym-memberships/join` | Preview, join by code or invitation | anyone / registered user | unique `(gym_id, user_id)` | 409 `already_member`, 404, 429 | SF-89 |
| `GET /me/gym-memberships` | Member's gyms | registered user | — | — | SF-91 |
| `GET/POST /gyms/{gym_id}/classes`, `PATCH/DELETE …/{class_id}` | Class definitions | read: staff; write: owner, manager | `client_request_id`, `lock_version` | 422 time zone/recurrence | SF-92 |
| `GET /gyms/{gym_id}/occurrences?from&to` | Timetable window | staff; members (member view) | — | 422 window > 31 d | SF-92 |
| `POST /gyms/{gym_id}/occurrences/{id}/cancel` | Cancel one occurrence | owner, manager, coach (own) | occurrence lock | 409 `already_started` | SF-92 |
| `POST /gyms/{gym_id}/occurrences/{id}/bookings` | Book (self, or for a member by staff) | active member / owner, manager, front desk | occurrence `FOR UPDATE`; `client_request_id` | 409 `occurrence_full` (→ waitlist option), 409 `already_booked`, 409 `booking_closed` | SF-94 |
| `DELETE /gyms/{gym_id}/bookings/{booking_id}` | Cancel booking (promotes waitlist) | the member / staff | occurrence lock | 409 `cancellation_window_closed` | SF-94 |
| `GET /gyms/{gym_id}/occurrences/{id}/roster` | Roster | staff (coach: own) | — | — | SF-94 |
| `GET /me/gym-memberships/{gym_id}/pass` | Rotating pass token | active member | short TTL | 404 if suspended | SF-96 |
| `POST /gyms/{gym_id}/check-ins` | Record check-in (pass scan or manual) | any staff role | unique per member+occurrence | 409 `already_checked_in`, 422 `pass_expired`, 404 `member_not_found` | SF-96 |
| `GET /gyms/{gym_id}/check-ins?date` | Attendance | owner, manager, front desk (today), coach (own) | — | — | SF-96 |
| `POST /gyms/{gym_id}/uploads` | Presigned logo/cover upload | owner, manager | storage boundary | 422 content type/size | SF-98 |

**Not proposed** (blocked or future): any `/plans`, `/subscriptions`,
`/payments`, `/payouts`, `/invoices`, `/verification`, `/publish`,
`/leads`, `/announcements`, `/imports` endpoint.
