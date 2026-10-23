# SF-82 · 06 — Claude Design Gym inventory and reconciliation

**Status: PROPOSED.** Source: Claude Design project canvas version
`1792675284-1046` (494 artboards; unchanged since SF-79). 116 boards are
Gym-related (Gym sections, Gym commerce, gym-facing emails, entry points
and member-side gym screens). Routes come from `docs/route-registry.json`
(sha `10b5c6c4…`, unchanged by SF-82). **The design was not modified.**

## 1. Classification legend

| Class | Meaning | Count |
| --- | --- | --- |
| MVP | Buildable truthfully once its ticket's backend exists, as drawn | 32 |
| MVP* | MVP with parts removed or copy changed (listed in "Truthful now?") | 20 |
| BLOCKED | Needs a product/legal/vendor decision first (`D-G09`, `D-G10`, `D-G11`); must not be built with placeholder data | 23 |
| FUTURE | Out of the Gym MVP; no backend domain planned in SF-83–SF-104 | 37 |
| — | Flows, route diagrams, galleries (reference only) | 4 |

"Data" says whether the content can come from **real** backend state,
would need **mock** content (never allowed in production UI) or is
**unsupported** today. No screen marked BLOCKED or FUTURE may be shipped
with sample numbers; registry placeholders stay "not available yet".

## 2. Findings that need a design decision (no change made)

| # | Board(s) | Problem | Proposed resolution (needs approval) |
| --- | --- | --- | --- |
| R1 | GymSetupSteps, OG4–OG9, OG12–OG14 | The 14-step wizard gates "open" on plan, KYB, payments, import and publishing | MVP wizard OG1→OG2→OG3→OG6b; OG10/OG11 become GRW1 checklist items ([03 §3](03-registration-workspace-lifecycle.md)) |
| R2 | OG6, OG6b, PR3, PR6m, WG25, L4 | Prices, "Pro trial", plan names | Remove price/trial copy until `D-G09` |
| R3 | OG0 | "Secure setup link valid 24 h · code" = a new cross-device credential | URL only; owner signs in on web (ADR 0012) |
| R4 | INV2 (`mobile.invite.coach._token`) vs OS1 (`mobile.invite.staff._token`) | Two entries for one staff-invitation flow; "invite/coach" already means SF-57 coach→fighter | One `/invite/staff#token=` (`D-G16`) |
| R5 | WG1, G01, GRW1, GR1 | KPI tiles for revenue, MRR, failed payments, leads, trials | Hide until their domain exists (never zero) |
| R6 | WG3, WG14, G04, F16 | Plan, balance, renewal, credits columns | Remove in MVP; F16 becomes a non-commercial member pass |
| R7 | WG16, WG17, OS2 | "Fighter notes (with consent)" permission | FUTURE gym-scoped consent (`D-G06`); not shown in MVP |
| R8 | F13, F16, GC1, GC3, GC5, GC7, GC12, S15, SH1, MK4, MK5, B25 | Member-side gym routes require `FIGHTER` | Member routes become account-level (`D-G07`, [07](07-routing.md)) |
| R9 | WG15 | "Ban across all locations", refunds | Suspend/end only in MVP |
| R10 | E04–E07 | Gym emails are not in the route registry (emails are not routes) | Templates added with their tickets (ADR 0011); E06/E07 links use fragment tokens |
| R11 | OS3, G05 | Shifts | FUTURE; MVP stores home location only |

## 3. Per-screen inventory

Columns: design section · ID · board (file) · title · registry routes
(required capability) · class · capability · backend domain / API ·
data · required states · whether it can be built truthfully now · proposed
ticket ([09](09-dependency-matrix.md)). Common console states are "loading ·
empty · error · 403 role · 404 workspace gone"; mobile adds "offline".

| Section | ID | Board | Title | Registry route(s) | Class | Capability | Backend / API | Data | States | Truthful now? | Ticket |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 19c | AD20 | AdminStaff | Internal access | `web.admin.staff` (ADMIN) | FUTURE | Internal admin access | admin console | unsupported | — | No (not Gym domain) | — |
| 12 | C09 | BookingRequests | Booking requests | `mobile.coach.requests` (COACH) | FUTURE | Coach booking requests (PT) | coaching services | unsupported | — | Not Gym; unaffected | — |
| Style | GymWebNav | GymWebNav | Component · Gym web nav | — (not in registry) | MVP | Gym console navigation | entry `gym_workspaces`, policy | real (nav items hidden per role & per MVP scope) | role-filtered · gym switcher | Yes, with FUTURE items hidden | SF-85 |
| Style | GymSetupSteps | GymSetupSteps | Component · Gym setup stepper (14 steps) | — (not in registry) | MVP* | Owner setup progress | `GET /me/gyms` setup_status | real for OG1–OG3 only | draft · completed | No as drawn (14 steps incl. blocked plan/KYB/payments) — needs design revision | SF-84 |
| Style | GymTabs | GymTabs | Component · Gym tab bar | — (not in registry) | MVP | Gym mobile navigation | entry | real | role-filtered | Yes, with FUTURE tabs hidden | SF-85 |
| 16 | W01 | WebHome | Home · where to go (FUTURE: needs bookings, gyms, camp, challenges, social; the MVP home is FRW1 with its Training card, SF-68) | `web.app.home` (FIGHTER) | FUTURE | Fighter web home (gym cards) | bookings, gyms | partially later | — | Not now (FRW1 is MVP home) | — |
| 18a | FlowGymWeb | FlowGymWeb | Flow · Gym web console | — (not in registry) | — | Flow diagram | — | — | — | Reference only | — |
| 18a | WG1 | WebDashboard | Gym dashboard | `web.app.gym` (GYM_WORKSPACE) | MVP* | Gym dashboard | classes today, bookings, check-ins | real for schedule/attendance; KPIs revenue/MRR/leads unsupported | loading · empty (no classes) · error · 404 | Partially — hide revenue/leads/trial tiles | SF-101 |
| 18a | WG2 | WebGymBoard | Live gym board | `web.app.gym.board` (GYM_WORKSPACE) | FUTURE | Live gym board (floor/rounds) | none | unsupported | — | No | — |
| 18a | WG20 | WebReports | Reports | `web.app.gym.reports` (GYM_WORKSPACE) | FUTURE | Reports | attendance aggregates; revenue | attendance real later; revenue unsupported | — | No for MVP | — |
| 18a | WG3 | WebMembers | Members | `web.app.gym.members` (GYM_WORKSPACE) | MVP | Members list | `GET /gyms/{id}/members` | real (no plan/payment columns) | loading · empty · error · 403 role · 404 workspace gone · search no results | Yes without plan/balance columns | SF-90 |
| 18a | WG14 | WebMemberDetail | Member detail | `web.app.gym.members._member-id` (GYM_WORKSPACE) | MVP | Member detail (staff) | member, bookings, check-ins | real gym-held facts only | loading · empty · error · 403 role · 404 workspace gone · ended member | Yes; never profile/training fields | SF-90 |
| 18a | WG15 | WebMemberBan | Remove / suspend / ban member | `web.app.gym.members._member-id` (GYM_WORKSPACE) | MVP* | Suspend / remove member | `PATCH members/{id}` status | real for suspend/end; "ban across locations" + refunds unsupported | confirm · 409 · success | Suspend/end yes; ban list & refunds no | SF-90 |
| 18a | WG4 | WebLeads | Leads & trials | `web.app.gym.leads` (GYM_WORKSPACE) | FUTURE | Leads & trials | none | unsupported (CRM) | — | No | — |
| 18a | WG16 | WebStaff | Coaches & staff | `web.app.gym.staff` (GYM_WORKSPACE) | MVP | Coaches & staff | staff memberships + invitations | real; "shifts", "fighter notes w/ consent" unsupported | loading · empty · error · 403 role · 404 workspace gone · pending invite · expired invite | Yes without shifts/consent columns | SF-87 |
| 18b | WG5 | WebTimetable | Timetable | `web.app.gym.timetable` (GYM_WORKSPACE) | MVP | Timetable | classes + occurrences | real | loading · empty · error · 403 role · 404 workspace gone · DST note · cancelled occurrence | Yes | SF-93 |
| 18b | WG18 | WebBookings | Bookings | `web.app.gym.bookings` (GYM_WORKSPACE) | MVP | Bookings | bookings per occurrence | real; waitlist after SF-94 | loading · empty · error · 403 role · 404 workspace gone · full · waitlisted | Yes | SF-95 |
| 18b | WG19 | WebAttendance | Attendance | `web.app.gym.attendance` (GYM_WORKSPACE) | MVP | Attendance | check-ins | real | loading · empty · error · 403 role · 404 workspace gone | Yes; no revenue overlay | SF-97 |
| 18b | WG13 | WebGymShared | Shared sessions | `web.app.gym.shared` (GYM_WORKSPACE) | FUTURE | Shared sessions | — | unsupported | — | No | — |
| 18b | WG6 | WebMemberships | Memberships | `web.app.gym.memberships` (GYM_WORKSPACE) | BLOCKED | Membership products | Commerce (D-G10) | unsupported | — | No — would show fabricated plans | SF-104 |
| 18b | WG7 | WebRevenue | Payments & revenue | `web.app.gym.revenue` (GYM_WORKSPACE) | BLOCKED | Payments & revenue | Payments (D-G10) | unsupported | — | No — fabricated revenue | SF-104 |
| 18c | WG8 | WebBranding | Gym public profile · preview as | `web.app.gym.profile` (GYM_WORKSPACE) | FUTURE | Public profile preview | gym profile | real private fields; public page unsupported | — | Preview-only possible after SF-98; publish no | SF-98 |
| 18c | WG9 | WebGymCommunity | Community dashboard | `web.app.gym.community` (GYM_WORKSPACE) | FUTURE | Community dashboard | social domain | unsupported | — | No | — |
| 18c | WG10 | WebCommunitySettings | Community & discoverability settings | `web.app.gym.settings.community` (GYM_WORKSPACE) | FUTURE | Community & discoverability settings | Discover (needs D-G11) | unsupported | — | No | — |
| 18c | WG11 | WebChallengeCreator | Challenge creator | `web.app.gym.challenges.new` (GYM_WORKSPACE) | FUTURE | Challenge creator | challenges | unsupported | — | No | — |
| 18c | WG12 | WebOpenSparring | Open sparring | `web.app.gym.open-sparring._open-sparring-id` (GYM_WORKSPACE) | FUTURE | Open sparring session | sparring domain | unsupported | — | No | — |
| 18c | WG21 | WebAnnouncements | Announcements | `web.app.gym.announcements` (GYM_WORKSPACE) | FUTURE | Announcements | notifications/push | unsupported | — | No (push boundary not built) | — |
| 18c | WG27 | WebOpenSparringList | Open sparring · all sessions | `web.app.gym.open-sparring` (GYM_WORKSPACE) | FUTURE | Open sparring list | sparring domain | unsupported | — | No | — |
| 18d | WG22 | WebGymSettings | Gym settings · general & policies | `web.app.gym.settings` (GYM_WORKSPACE) | MVP* | Gym settings · general & policies | gym record | real for name/type/contact/timezone; cancellation fees/policies unsupported | loading · empty · error · 403 role · 404 workspace gone · 422 | Partially | SF-99 |
| 18d | WG23 | WebLocations | Locations | `web.app.gym.settings.locations` (GYM_WORKSPACE) | MVP | Locations | gym_locations | real (MVP: one location; add more FUTURE) | loading · empty · error · 403 role · 404 workspace gone · 422 address | Yes | SF-99 |
| 18d | WG17 | WebRoles | Roles & permissions | `web.app.gym.settings.roles` (GYM_WORKSPACE) | MVP* | Roles & permissions | fixed matrix in code | real read-only matrix; custom roles, approvals & audit UI FUTURE | loading · empty · error · 403 role · 404 workspace gone | Yes as read-only matrix incl. "never for any role" row | SF-88 |
| 18d | WG24 | WebIntegrations | Integrations | `web.app.gym.settings.integrations` (GYM_WORKSPACE) | FUTURE | Integrations | none | unsupported | — | No | — |
| 18d | WG25 | WebGymBilling | SimpleFit plan | `web.app.gym.settings.plan` (GYM_WORKSPACE) | BLOCKED | SimpleFit plan | Billing (D-G09) | unsupported | — | No — fabricated plan/trial | SF-103 |
| 18d | WG26 | WebGymDanger | Danger zone · transfer ownership | `web.app.gym.settings.danger` (GYM_WORKSPACE) | MVP* | Danger zone · transfer ownership | staff memberships | real transfer; "pause billing", close gym FUTURE | request · pending 7 d · accepted · expired · 409 | Transfer yes; billing/close no | SF-100 |
| 26 | GC2 | WebMembershipCreate | Create membership | `web.app.gym.memberships.new` (GYM_WORKSPACE) | BLOCKED | Create membership product | Commerce (D-G10) | unsupported | — | No | SF-104 |
| 26 | GC6 | WebPackages | Packages & credits | `web.app.gym.packages` (GYM_WORKSPACE) | BLOCKED | Packages & credits | Commerce (D-G10) | unsupported | — | No | SF-104 |
| 26 | GC9 | WebFailedPayments | Failed payments · dunning | `web.app.gym.revenue.failed` (GYM_WORKSPACE) | BLOCKED | Failed payments / dunning | Payments | unsupported | — | No | SF-104 |
| 26 | GC10 | WebGymTransactions | Gym transactions | `web.app.gym.revenue.transactions` (GYM_WORKSPACE) | BLOCKED | Gym transactions | Payments | unsupported | — | No | SF-104 |
| 26 | GC11 | WebGymPayouts | Gym payouts | `web.app.gym.payouts` (GYM_WORKSPACE) | BLOCKED | Gym payouts | Payments (KYB) | unsupported | — | No | SF-104 |
| 27–28 | SH0 | WebStoreManage | Store management · gym web | `web.app.gym.store` (GYM_WORKSPACE) | FUTURE | Store management | marketplace | unsupported | — | No | — |
| 30 | AV6 | WebGymPromoSetup | Promote gym · setup | `web.app.gym.promote` (GYM_WORKSPACE) | FUTURE | Promote gym setup | ads + payments | unsupported | — | No | — |
| 30 | AV7 | WebGymPromoAnalytics | Gym promotion · analytics | `web.app.gym.promote.results` (GYM_WORKSPACE) | FUTURE | Promotion analytics | ads | unsupported | — | No | — |
| 10 | B25 | GymNode | Node sheet · gym | `mobile.board.node.gym._gym-id` (FIGHTER) | FUTURE | Live board gym node | board + discovery | unsupported | — | No | — |
| 25 | CC4 | PTBooking | PT booking · uses a credit | `mobile.book.pt` (FIGHTER) | BLOCKED | PT booking with credit | Commerce/credits | unsupported | — | No | — |
| 26 | GC1 | GymMemberships | Gym memberships · fighter view | `mobile.gym._gym-id.memberships` (FIGHTER) | BLOCKED | Gym memberships · member view | Commerce | unsupported | — | No | SF-104 |
| 26 | GC3 | MembershipDetail | Membership detail | `mobile.gym._gym-id.memberships._membership-id` (FIGHTER) | BLOCKED | Membership detail | Commerce | unsupported | — | No | SF-104 |
| 26 | GC4 | MembershipCheckout | Membership purchase | `mobile.checkout` | BLOCKED | Membership purchase | Payments | unsupported | — | No — no checkout without provider | SF-104 |
| 26 | GC5 | MemberSubscription | Member subscription | `mobile.me.membership` (FIGHTER) | BLOCKED | Member subscription | Payments | unsupported | — | No | SF-104 |
| 26 | GC7 | CreditsWallet | Credits wallet | `mobile.me.credits` (FIGHTER) | BLOCKED | Credits wallet | Commerce | unsupported (no balances) | — | No | SF-104 |
| 26 | GC8 | DropInPurchase | Drop-in purchase | `mobile.checkout` | BLOCKED | Drop-in purchase | Payments | unsupported | — | No | SF-104 |
| 26 | GC12 | PaymentFailedMember | Payment failed · member | `mobile.me.membership` (FIGHTER) | BLOCKED | Payment failed · member | Payments | unsupported | — | No | SF-104 |
| 27 | MK4 | MarketGyms | Gym discovery · promoted labelled | `mobile.marketplace` (FIGHTER) | FUTURE | Gym discovery (promoted) | Discover (D-G11) | unsupported | — | No | — |
| 27 | MK5 | MarketGymProfile | Gym marketplace profile | `mobile.marketplace.gym._gym-id` (FIGHTER) | FUTURE | Gym marketplace profile | Discover | unsupported | — | No | — |
| 28 | SH1 | GymStore | Gym store | `mobile.gym._gym-id.store` (FIGHTER) | FUTURE | Gym store | marketplace | unsupported | — | No | — |
| 7 | F13 | BookClass | Book a class | `mobile.gym._gym-id.classes._class-id.book` (FIGHTER) | MVP | Book a class (member) | occurrences + bookings | real; price/credit line unsupported | loading · empty · error · offline · 403 role · 404 workspace gone · full → waitlist · 409 already booked · not a member 404 | Yes without price/credits | SF-95 |
| 7 | F16 | Membership | Membership pass | `mobile.membership` (FIGHTER) | MVP* | Membership pass (member) | gym_members + pass token | real enrollment + rotating QR; plan/renewal unsupported | loading · empty · error · offline · 403 role · 404 workspace gone · suspended · expired token refresh | Yes as "member pass" without plan/expiry | SF-97 |
| 8 | ST8 | SetBilling | Memberships & billing | `mobile.settings.billing` | BLOCKED | Settings · memberships & billing | Payments | unsupported | — | No (show "My gyms" list only, SF-91) | SF-91 |
| 9 | S15 | GymCommunity | Gym community | `mobile.gym._gym-id.community` (FIGHTER) | FUTURE | Gym community feed | social | unsupported | — | No | — |
| 13 | FlowGym | FlowGym | Flow · Gym mobile + web | — (not in registry) | — | Flow diagram | — | — | — | Reference only | — |
| 13 | G01 | GymPulse | Gym pulse | `mobile.gym.pulse` (GYM_WORKSPACE) | MVP* | Gym pulse (mobile) | occurrences today, check-ins | real schedule/attendance; revenue tiles unsupported | loading · empty · error · offline · 403 role · 404 workspace gone | Partially — hide money | SF-101 |
| 13 | G02 | CheckIn | QR check-in | `mobile.gym.check-in` (GYM_WORKSPACE) | MVP | QR check-in | `POST /gyms/{id}/check-ins` | real | loading · empty · error · offline · 403 role · 404 workspace gone · invalid/expired pass · already checked in · suspended member | Yes | SF-97 |
| 13 | G03 | ClassRoster | Class roster | `mobile.gym.classes._class-id.roster` (GYM_WORKSPACE) | MVP | Class roster | bookings + check-ins | real | loading · empty · error · offline · 403 role · 404 workspace gone · cancelled occurrence | Yes | SF-97 |
| 13 | G04 | MemberCard | Member card | `mobile.gym.members._member-id` (GYM_WORKSPACE) | MVP* | Member card (staff) | member facts | real gym facts; balance/plan unsupported | loading · empty · error · offline · 403 role · 404 workspace gone | Yes without plan/balance | SF-90 |
| 13 | G05 | Staff | Staff on shift | `mobile.gym.staff.on-shift` (GYM_WORKSPACE) | FUTURE | Staff on shift | shifts | unsupported | — | No | — |
| 13 | G06 | Incidents | Incidents | `mobile.gym.incidents.new` (GYM_WORKSPACE) | FUTURE | Incidents | incidents (safeguarding) | unsupported; needs own privacy design | — | No | — |
| 13 | G07 | Announce | Announcement | `mobile.gym.announcements.new` (GYM_WORKSPACE) | FUTURE | Announcement | push/notifications | unsupported | — | No | — |
| 13 | G08 | GymClasses | Classes | `mobile.gym.classes` (GYM_WORKSPACE) | MVP | Classes (mobile) | occurrences | real | loading · empty · error · offline · 403 role · 404 workspace gone | Yes | SF-93 |
| 13 | G09 | GymMembers | Members | `mobile.gym.members` (GYM_WORKSPACE) | MVP | Members (mobile) | members | real | loading · empty · error · offline · 403 role · 404 workspace gone · search no results | Yes | SF-90 |
| 21 | PR6m | PlanCompareMobile | Plan comparison · mobile | `mobile.pricing.compare` | BLOCKED | Plan comparison · gym | Billing (D-G09) | unsupported (prices) | — | No | SF-103 |
| 1a | O05 | Onboarding | Choose your role | `mobile.onboarding.role` | MVP | Choose your role (mobile) | entry intent | real (gym → OG0) | — | Yes (exists; gym routes to OG0) | SF-84 |
| 1a | A03 | JoinInvite | Join with invite (alt. entry) | `mobile.join._code` | MVP | Join gym with invite / code | `POST /me/gym-memberships/join` | real after SF-89 | loading · empty · error · offline · 403 role · 404 workspace gone · invalid/expired code · already member · gym not accepting | Yes | SF-89 |
| 1b | INV2 | InviteGymCoach | Gym invites coach | `mobile.invite.coach._token` | MVP* | Gym invites coach | staff invitation (role coach) | real after SF-86 | preview · wrong account · expired · used | Yes via /invite/staff (D-G16) | SF-87 |
| 5b | WA6 | WebRoleSelect | Choose where to start · /app/onboarding/role | `web.app.onboarding.role` | MVP | Choose where to start (web) | entry intent | real | — | Yes (exists) | SF-84 |
| COACH | OC5 | OnbCWhere | Gym · needs the Gym domain | `mobile.onboarding.coach` | FUTURE | Coach registration · gym step | — | unsupported | — | No (coach profile has no gym) | — |
| COACH | WCR5 | WebRegCGym | Gym · needs the Gym domain | `web.app.onboarding.coach` | FUTURE | Coach web registration · gym step | — | unsupported | — | No | — |
| FIGHTER | OF4 | OnbFBody | Boxing profile · weight class | `mobile.onboarding.fighter` | MVP | Fighter boxing profile | fighters | real (existing) | — | Unaffected | — |
| FIGHTER | OF5 | OnbFGym | Gym | `mobile.onboarding.fighter` | FUTURE | Fighter onboarding · gym | Discover/search | unsupported (no gym search) | — | No; join via code A03 instead | — |
| FIGHTER | OF6 | OnbFMembership | Gym membership | `mobile.onboarding.fighter` | FUTURE | Fighter onboarding · gym membership | Commerce | unsupported | — | No | — |
| FIGHTER | FR3 | FirstRunF3 | Intro · Coach & gym | `mobile.welcome.tour` (FIGHTER) | MVP* | Intro · Coach & gym | static | static copy | — | Yes if copy does not promise gym features before SF-91 | SF-101 |
| FUTURE — NOT IN CURRENT PRODUCTION FLOW | WF2 | WebRegFGym | Gym · needs the Gym domain | `web.app.onboarding.fighter` | FUTURE | Fighter web registration · gym | — | unsupported | — | No | — |
| GYM | GR1 | FirstRunGPulse | Gym pulse · opening week | `mobile.gym.pulse` (GYM_WORKSPACE) | MVP* | Gym pulse · opening week (mobile) | checklist from real state | real checklist | first-run · dismissed | Yes with truthful checklist | SF-101 |
| GYM | GR2 | FirstRunGCheckinTip | Product tour · mobile · interactive · 8 steps + complete | `mobile.gym.pulse` (GYM_WORKSPACE) | MVP | Mobile product tour (8 steps) | first-run ADR 0018 | real | steps 1–8 · done · skipped | Yes (tour copy must match MVP) | SF-101 |
| GYM | GR2 | FirstRunGCheckinTipSteps | Product tour · mobile · all steps · step=1 … 8, done | `mobile.gym.pulse` (GYM_WORKSPACE) | MVP | Mobile product tour (8 steps) | first-run ADR 0018 | real | steps 1–8 · done · skipped | Yes (tour copy must match MVP) | SF-101 |
| GYM | GRW1 | FirstRunWebG | Gym dashboard · opening week | `web.app.gym` (GYM_WORKSPACE) | MVP* | Gym dashboard · opening week (web) | checklist | real; plan/trial/payments rows blocked | first-run | Yes with truthful checklist | SF-101 |
| GYM | GRW2 | FirstRunWebGTour | Product tour · interactive · 9 steps + complete | `web.app.gym.timetable` (GYM_WORKSPACE) | MVP | Web product tour (9 steps) | first-run ADR 0018 | real | steps 1–9 · done · skipped | Yes (drop steps for FUTURE areas) | SF-101 |
| GYM | GRW2 | FirstRunWebGTourSteps | Product tour · all steps · step=1 … 9, done | `web.app.gym.timetable` (GYM_WORKSPACE) | MVP | Web product tour (9 steps) | first-run ADR 0018 | real | steps 1–9 · done · skipped | Yes (drop steps for FUTURE areas) | SF-101 |
| GYM | OS1 | OnbSInvite | Staff invitation · from E06 | `mobile.invite.staff._token` | MVP | Staff invitation landing | `POST /staff-invitations/preview`, accept | real | valid · signed in as invitee · other account · expired · used · revoked | Yes | SF-87 |
| GYM | OS2 | OnbSRole | Role & access | `mobile.onboarding.staff.role` (GYM_WORKSPACE) | MVP | Role & access | policy matrix row | real read-only | — | Yes without "fighter notes" item | SF-87 |
| GYM | OS3 | OnbSLocation | Location & shifts | `mobile.onboarding.staff.location` (GYM_WORKSPACE) | MVP* | Home location & shifts | staff home_location_id | location real; shifts unsupported | — | Location yes; shifts no | SF-87 |
| GYM | OS4 | OnbSTour | Front-desk tour | `mobile.onboarding.staff.tour` (GYM_WORKSPACE) | MVP | Front-desk tour | first-run ADR 0018 | real | done · skipped | Yes | SF-101 |
| GYM | OG0 | OnbGHandoff | Gym owner · continue on web · E04 | `mobile.onboarding.gym` | MVP* | Owner: continue on web | none | real URL; "secure link + code" unsupported | — | Yes without cross-device login link (§4 of 03) | SF-84 |
| GYM | OS1b | OnbSInviteCode | Staff invite · confirm email (code) | `mobile.invite.staff._token.confirm` | MVP | Staff invite · confirm email code | SF-21 sign-in / SF-77 identity link | real | code sent · wrong code · rate-limited | Yes (no new credential) | SF-87 |
| GYM | RouteGym | RouteGym | Route · Gym owner (web) | — (not in registry) | — | Route diagram | — | — | — | Reference only | — |
| GYM | OG1 | WebSetupGym | Gym name & type | `web.app.onboarding.gym` | MVP | Gym name & type | `POST /gyms` | real; handle FUTURE | 422 · 409 limit · idempotent retry | Yes | SF-84 |
| GYM | OG2 | WebSetupLocations | Location · address only | `web.app.onboarding.gym` | MVP | Location | `PATCH /gyms/{id}/locations/{id}` | real | 422 address | Yes | SF-84 |
| GYM | OG3 | WebSetupBrand | Branding | `web.app.onboarding.gym` | MVP | Branding | storage presign + gym fields | real | upload progress · upload failed · skipped | Yes | SF-98 |
| GYM | OG4 | WebSetupSize | Gym size | `web.app.onboarding.gym` | FUTURE | Gym size | plan suggestion | unsupported | — | No (skip) | — |
| GYM | OG5 | WebSetupFeatures | Features | `web.app.onboarding.gym` | FUTURE | Features | plan entitlements | unsupported | — | No (skip) | — |
| GYM | OG6 | WebSetupPlan | Plan · trial | `web.app.onboarding.gym` | BLOCKED | Plan · trial | Billing (D-G09) | unsupported (prices, trial) | — | No | SF-103 |
| GYM | OG6b | WebGymRegDone | Registration complete | `web.app.onboarding.gym` | MVP* | Registration complete | complete-setup | real; "trial started" copy unsupported | — | Yes with revised copy | SF-84 |
| GYM | OG7 | WebSetupVerify | Verify business | `web.app.onboarding.gym` | BLOCKED | Verify business (KYB) | Identity/KYB (D-G11) | unsupported | — | No | SF-104 |
| GYM | OG8 | WebSetupPlans | Memberships | `web.app.onboarding.gym` | BLOCKED | Membership products | Commerce (D-G10) | unsupported | — | No | SF-104 |
| GYM | OG9 | WebSetupPayments | Payments | `web.app.onboarding.gym` | BLOCKED | Payments | Payments (D-G10) | unsupported | — | No | SF-104 |
| GYM | OG10 | WebSetupTimetable | Timetable | `web.app.onboarding.gym` | MVP* | Timetable (setup) | classes | real after SF-92 | — | Yes as checklist item, not a wizard gate | SF-93 |
| GYM | OG11 | WebSetupTeam | Coaches & staff · E06 | `web.app.onboarding.gym` | MVP* | Coaches & staff (setup) | staff invitations | real after SF-86 | — | Yes as checklist item | SF-87 |
| GYM | OG12 | WebSetupImport | Import members · E07 | `web.app.onboarding.gym` | FUTURE | Import members (CSV) | — | privacy-sensitive (D-G08) | — | No | — |
| GYM | OG13 | WebSetupCommunity | Community defaults | `web.app.onboarding.gym` | FUTURE | Community defaults | social | unsupported | — | No | — |
| GYM | OG14 | WebSetupLaunch | Go live · E05 | `web.app.onboarding.gym` | FUTURE | Go live / publish | Discover (D-G11) | unsupported | — | No | — |
| Route gallery | route gallery 2 / 3 | GalleryIndex2 | coach & gym mobile, web app | — (not in registry) | — | Route gallery | — | — | — | Reference only | — |
| 14 | E04 | EmailWelcomeGym | Finish gym setup | — (not in registry) | MVP* | Email · finish gym setup | Email templates (ADR 0011) | real; no credentials in mail | — | Yes as a reminder | SF-84 |
| 14 | E05 | EmailGymLive | Your gym is live | — (not in registry) | FUTURE | Email · your gym is live | publication | unsupported | — | No | — |
| 14 | E06 | EmailStaffInvite | Staff invitation | — (not in registry) | MVP | Email · staff invitation | Email + staff invitations | real | — | Yes (fragment token) | SF-86 |
| 14 | E07 | EmailMemberInvite | Member invite from gym | — (not in registry) | MVP | Email · member invitation | Email + member invitations | real | — | Yes | SF-89 |
| 14 | E08 | EmailCoachInvite | Coach invited you | — (not in registry) | MVP | Email · coach invited you (existing SF-57/80) | Coaching | real (existing) | — | Unaffected; must not be merged with E07 | — |
| 5a | L4 | LandGyms | For gyms | `web.gyms` | MVP* | Marketing · for gyms | static | static; prices unsupported | — | Yes without prices/trial claims | SF-84 |
| 5a | PR3 | PricingGym | Pricing · gym | `web.pricing` | BLOCKED | Pricing · gym | Billing (D-G09) | unsupported | — | No | SF-103 |
