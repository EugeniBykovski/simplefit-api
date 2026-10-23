# SF-82 · 12 — Claude Design reconciliation plan (R1–R11)

**Status: architecture approved; design changes C1–C17 still need separate approval before they are published.** Source: Claude Design
canvas version `1792675284-1046`. The artifact has **not** been edited,
republished or overwritten. Section 2 is a change specification for the
designer to apply after approval.

"Current" quotes the visible text of the artboard. "Conflict" names the
approved or proposed decision the artboard contradicts.

## 1. Discrepancies

### R1 — the 14-step wizard makes unavailable domains part of creating a gym

| | |
| --- | --- |
| Artboards | `GymSetupSteps` (Component · Gym setup stepper, 14 steps); OG1 `WebSetupGym` … OG14 `WebSetupLaunch` (section GYM · 5e); OG6b `WebGymRegDone` |
| Current | One linear stepper, "Create your gym (6) · get ready to open (8)". OG1 says "nothing is public until step 11". OG6b continues into "GET READY TO OPEN · 8 STEPS": verify business, memberships, payments, timetable, coaches & staff, import members, community defaults, go live |
| Conflict | `D-G05` (approved: the gym exists after the first valid submission); `D-G09`/`D-G10`/`D-G11` (deferred); `D-G21` (approved: minimal creation). OG1's "step 11" contradicts the design itself, where publishing is step 14 |
| Correction | Keep the 14 steps as a **product journey** in four phases ([03 §3](03-registration-workspace-lifecycle.md)). Only phase 2 (OG1 + OG2) is required. Unavailable steps appear as "coming later" in the stepper and the checklist and are never required. OG1 copy: "Nothing is public. Publishing comes later." |

### R2 — prices, plans, trials, verification and publishing presented as facts

| | |
| --- | --- |
| Artboards | OG4 `WebSetupSize`; OG5 `WebSetupFeatures`; OG6 `WebSetupPlan`; OG6b `WebGymRegDone`; OG7 `WebSetupVerify`; WG25 `WebGymBilling`; PR3 `PricingGym`; PR6m `PlanCompareMobile`; L4 `LandGyms`; OG3 `WebSetupBrand` (preview "✓ verified", public URL); OG1 (public handle); WG26 `WebGymDanger` ("verified person", "Pause billing", "refunds pro-rata, keeps records 5 years") |
| Current | Free/Starter/Pro/Business/Club+ at €0–€299, a 14-day Pro trial ("no charge until Oct 18"), plan suggestions by size, "YOUR SELECTION NEEDS Pro", KYB with tax ID and documents, a verified badge, a public URL |
| Conflict | `D-G09`, `D-G11`: deferred product decisions. Invariant 4 (no fabricated plans or prices) |
| Correction | Remove prices, plan names, trial, usage limits and "verified" from every MVP screen. OG4/OG5/OG6/OG7 stay in the journey as "coming later". OG6b becomes "Your gym is created" (no plan). L4 keeps the product story without prices or "Compare gym plans". PR3/PR6m stay unchanged as FUTURE boards, not linked from MVP screens. The public handle and URL move to the publishing step |

### R3 — OG0 sends a cross-device setup link and code

| | |
| --- | --- |
| Artboard | OG0 `OnbGHandoff` (GYM · 4) |
| Current | "We emailed you a secure setup link … valid 24 h · Or open on your computer sfit.box/setup · code 4K7-Q2 · 14 steps · about 20 minutes" |
| Conflict | ADR 0012: a session is issued only for a code entered by the requesting client, never through a link, so a link plus code would be a new credential. `D-G21`: there are no longer 14 required steps |
| Correction | "Set up your gym on a computer: open simplefit.box/app/onboarding/gym and sign in with this account. Your progress is saved." There is no link, no code and no "Resend email". The optional E04 reminder carries no credential. Duration copy is "about 3 minutes to create your gym" |

### R4 — staff-invitation entries collide with Coach–Fighter invitations and carry tokens in paths

| | |
| --- | --- |
| Artboards | INV2 `InviteGymCoach` (route `mobile.invite.coach._token`, `/invite/coach/:token`); OS1 `OnbSInvite` (`/invite/staff/:token`); OS1b `OnbSInviteCode` (`/invite/staff/:token/confirm`); E06 `EmailStaffInvite` |
| Current | INV2 is "Warsaw Boxing Club invited you as Coach … ✓ Fighter notes with consent ✓ Sparring approvals … the club becomes a new workspace next to your personal one". OS1 and OS1b use the token in the path |
| Conflict | `D-G16` (approved: separate staff domain, no reuse of conflicting routes); `D-G22`; `D-G06`. `/invite/coach` is the SF-57/SF-80 Coach→Fighter link, and SF-80 keeps tokens out of app navigation |
| Correction | Retire INV2 as a separate screen: a gym coach invitation is OS1 with role "Coach". OS1 and OS1b keep their layout but are reached through the web `/invite/staff#token=` page or the token-free mobile invitation inbox (`D-G22` approved; [07 §6](07-routing.md)). Remove "Fighter notes with consent" and "Sparring approvals". Keep "same account — the gym becomes a workspace next to your personal one" (true under `D-G15`) |

### R5 — dashboards and first-run screens show money, leads, incidents and publication that do not exist

| | |
| --- | --- |
| Artboards | WG1 `WebDashboard`; G01 `GymPulse`; GRW1 `FirstRunWebG`; GR1 `FirstRunGPulse` |
| Current | WG1: "Revenue · 30 days 171 800 PLN", MRR mix, "3 failed payments · 1 140 PLN", "1 incident", "4 trials not contacted", community, coaches on shift. G01: "FAILED PAYMENTS 3", "SALES TODAY €1.2k". GRW1/GR1: "Gym published … Discover", "175 member invites sent", "Payout account verified", store products, welcome challenge |
| Conflict | Invariant 4; `D-G08` (no import); `D-G09`/`D-G10`/`D-G11` |
| Correction | MVP tiles are limited to today's classes, bookings, check-ins today and members (count). The opening checklist is built from real state ([03 §7](03-registration-workspace-lifecycle.md)). Revenue, MRR, failed payments, sales, leads, incidents, community, shifts, payout and publication tiles are **hidden**, not shown as zero |

### R6 — member screens carry plans, payments, balances and credits

| | |
| --- | --- |
| Artboards | WG3 `WebMembers`; WG14 `WebMemberDetail`; G04 `MemberCard`; F16 `Membership`; F13 `BookClass`; E07 `EmailMemberInvite` |
| Current | Plan and renewal columns, "Payment Card · auto", "Waiver Signed", Export CSV (WG3). Payments, lifetime value, plan, freezes, incidents, staff notes (WG14). "Payment failed … Retry", "Send pay link", PT credits, freeze, add credits (G04). "MONTHLY UNLIMITED … Renews Oct 10", "PT PACK 3 / 5", "8 credits left" (F16). "Book 8 credits", "Uses 1 credit" (F13) |
| Conflict | `D-G10` (deferred); `D-G19`; invariant 4; `D-G08` (no export in MVP) |
| Correction | Members (WG3/G09): name, status, joined, home location, last visit, visits in 30 days. Member detail (WG14/G04): the same, plus bookings and check-ins. F16 becomes the "Member pass": gym name, status and a rotating QR. F13 books without credits or prices. Keep WG3's "GYM ADMIN CAN'T SEE …" panel, without "and billing" |

### R7 — permissions imply access to training data, refunds and sales

| | |
| --- | --- |
| Artboards | WG16 `WebStaff`; WG17 `WebRoles`; OS2 `OnbSRole`; OG11 `WebSetupTeam`; INV2 |
| Current | Rows such as "Fighter notes (with consent)", "Payments & refunds", "Refunds up to 100 zł", "Sell passes & drop-ins", "See revenue & payouts" and "Export member list". "Add custom role", approvals and an audit list. OS2 front desk: "Sell drop-ins, passes, gear · Log incidents · Message members". OG11 "Coach: own classes, rosters, fighter notes" |
| Conflict | `D-G06`, `D-G03`; [04](04-gym-vs-coaching-contract.md) |
| Correction | The matrix shows only the MVP permissions of [02 §4](02-identity-roles-permissions.md). Keep the "NEVER, FOR ANY ROLE" row. "Head coach" is a title on a coach. Custom roles, approvals and the audit UI are marked "coming later" |

### R8 — member-side gym routes and the join screen assume a fighter

| | |
| --- | --- |
| Artboards and routes | F13 (`mobile.gym._gym-id.classes._class-id.book`), F16 (`mobile.membership`), S15, SH1, GC1, GC3, GC5, GC7, GC12, MK5, B25 (all `FIGHTER`); A03 `JoinInvite` ("ROLE · FIGHTER", "Join as fighter", "GROUP · COMPETITION TEAM") |
| Current | Member-side gym screens live in the Fighter app, and A03 joins "as fighter" |
| Conflict | `D-G07` (approved) |
| Correction | A03 says "Join Warsaw Boxing Club" and does not mention a role. The "competition team" group is future. Member screens are reachable for any registered account: from the Fighter app for fighters, and from the account area ("My gyms") for others. The A03 privacy line stays |

### R9 — remove / suspend / ban with incidents and refunds

| | |
| --- | --- |
| Artboard | WG15 `WebMemberBan` |
| Current | "Remove or ban…", incidents with descriptions of injuries, payments, "refunds pro-rata" |
| Conflict | `D-G10`; incidents are a future safeguarding domain that needs its own privacy design |
| Correction | MVP actions are **Suspend** (can't book or check in), **Resume** and **End membership**, each confirmed and audited (`D-G18`). Ban lists, incidents and refunds are future |

### R10 — e-mails promise features and data that do not exist

| | |
| --- | --- |
| Artboards | E04 `EmailWelcomeGym`; E05 `EmailGymLive`; E06 `EmailStaffInvite`; E07 `EmailMemberInvite` |
| Current | E04: "Company details and NIP for payouts … A CSV export of current members", progress "of 14". E05: "Members can find you, book and pay", Discover, payouts. E06: "Sell drop-ins and passes · Log incidents". E07: "Claim your Unlimited membership … Pay with BLIK or card … the gym shared your name, email and plan" |
| Conflict | `D-G08`–`D-G11`; ADR 0011 (templates are code; these are not in the route registry because e-mails are not routes) |
| Correction | E04: a credential-free reminder ("Finish creating your gym"). E05: stays FUTURE (publishing). E06: role abilities from the MVP matrix. E07: "Simple Boxing Gym invited you to join on SimpleFit — book classes and check in" with no plan, payment or import wording. Privacy line: "the gym used your e-mail address to invite you" |

### R11 — shifts and on-shift views

| | |
| --- | --- |
| Artboards | OS3 `OnbSLocation` ("Mon, Wed, Fri 16:00–22:00", "Shift reminders"); G05 `Staff` (on shift, sick, substitution); WG16 "ON SHIFT NOW"; WG1 "COACHES ON SHIFT" |
| Current | Shifts, sickness and substitution |
| Conflict | No shift domain is planned. Sickness data is health data |
| Correction | OS3 picks only the home location. G05 and the on-shift tiles are future. The WG16 status column shows Active / Invited |

## 2. Proposed Claude Design changes (not applied)

Each change is a revision of an existing board. Original boards stay as
"FUTURE" references where they describe later features.

| # | Board(s) | Change |
| --- | --- | --- |
| C1 | GymSetupSteps | Replace "Create your gym (6) · get ready to open (8)" with four groups: **Create** (OG1, OG2: required), **Make it yours** (OG3: optional), **Set up operations** (OG10 timetable, OG11 staff, members invite: checklist), **Coming later** (OG4–OG9, OG12–OG14, greyed out, no click-through to blocked content) |
| C2 | OG1 | Remove the public handle and "nothing is public until step 11"; add "Nothing is public. You can publish later" |
| C3 | OG2 | Keep. "Add another location" stays visible but goes to "coming later" in MVP |
| C4 | OG3 | Remove "✓ verified", "Public URL" and "Book a free trial" from the preview |
| C5 | OG6b | New copy: "Simple Boxing Gym is created". Primary action: "Go to dashboard". Secondary: "Continue setup" (checklist). No plan, trial or price |
| C6 | OG0 | Text-only handoff as in R3; remove the link, code and resend |
| C7 | WG1, G01, GRW1, GR1 | Tile set as in R5; checklist items: create gym ✓, add a class, invite staff, invite members, first check-in |
| C8 | WG3, WG14, G04, G09 | Columns and actions as in R6; add the states: empty, suspended, ended, invited (pending) |
| C9 | F16, F13 | "Member pass" without plan, renewal or credits; booking without credits; add the states: full → waitlist, booked, cancelled, not a member |
| C10 | WG16, WG17, OS2, OG11 | MVP permission matrix (owner, manager, coach, front desk) with the "never for any role" row; "head coach" as a title; custom roles, approvals and audit as "coming later" |
| C11 | INV2 | Mark as superseded by OS1 (role Coach) |
| C12 | OS1, OS1b | Keep the layout; add the states: wrong account, expired, revoked, already accepted |
| C13 | A03 | "Join <gym>" without a role; the competition-team group is future |
| C14 | WG15 | Suspend / resume / end only |
| C15 | E04, E06, E07 | Copy as in R10 |
| C16 | OS3, WG16 | Home location only; status Active / Invited |
| C17 | L4 | Remove prices and "Compare gym plans"; keep "Set up your gym" |

After approval, the designer applies C1–C17 and the screen inventory
([06](06-claude-design-inventory.md)) is re-run against the new canvas
version before SF-84.

## 3. Final reconciliation checklist

One row per screen. **R** is the discrepancy and **C** the proposed change.
Every row is unapplied: the canvas stays at version `1792675284-1046` until
these changes are approved. ⓡ marks screens whose route moves with
`D-G23`/`D-G07`. The route change is made in the registry, and the board
itself needs no visual change for it.

| ☐ | Screen ID | Board | R | Exact correction | C | Decision | Needed by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ☐ | GymSetupSteps | Component · Gym setup stepper | R1 | Four groups: Create (OG1, OG2: required) · Make it yours (OG3: optional) · Set up operations (timetable, staff, invite members: checklist) · Coming later (OG4–OG9, OG13, OG14, greyed out, not clickable). Remove the "14 steps · about 20 minutes" count | C1 | D-G21 | SF-84 |
| ☐ | OG1 | WebSetupGym | R1, R2 | Remove "Public handle" and "nothing is public until step 11"; add "Nothing is public. You can publish later." Keep the six type chips, single-select (D-G13), plus optional phone and website | C2 | D-G21, D-G13, D-G11 | SF-84 |
| ☐ | OG2 | WebSetupLocations | R1 | Keep one location. "Add another location" becomes "coming later"; the LOCATIONS list shows one row | C3 | D-G02 | SF-84 |
| ☐ | OG3 | WebSetupBrand | R2 | Remove "✓ verified", "Public URL" and "Book a free trial" from the preview; keep logo, cover, accent colour and tagline; mark the step "Optional · Skip" | C4 | D-G11, D-G21 | SF-98 |
| ☐ | OG4, OG5, OG6 | WebSetupSize, WebSetupFeatures, WebSetupPlan | R2 | Keep the boards as FUTURE references; no MVP entry point | C1 | D-G09 | — |
| ☐ | OG6b | WebGymRegDone | R1, R2 | "Simple Boxing Gym is created." Primary "Go to dashboard", secondary "Continue setup". Remove the trial, €89 and "GET READY TO OPEN · 8 STEPS"; show the checklist items instead | C5 | D-G21, D-G09 | SF-84 |
| ☐ | OG7, OG8, OG9, OG13, OG14 | WebSetupVerify, WebSetupPlans, WebSetupPayments, WebSetupCommunity, WebSetupLaunch | R1, R2 | FUTURE references only ("coming later" in C1) | C1 | D-G10, D-G11 | — |
| ☐ | OG10 | WebSetupTimetable | R1 | Checklist destination "Add your first class": manual class only; remove "Import CSV" and "Google Calendar" | C1, C7 | D-G21 | SF-93 |
| ☐ | OG11 | WebSetupTeam | R1, R7 | Checklist destination "Invite staff": roles from the MVP matrix; Coach row "Own classes, rosters, attendance" (no "fighter notes"); Owner row without "payouts" | C1, C10 | D-G03, D-G06 | SF-87 |
| ☐ | OG12 | WebSetupImport | R1, R6 | Replace with "Invite members" (email invitations, E07); CSV import stays a FUTURE reference | C1, C15 | D-G08 | SF-91 |
| ☐ | OG0 | OnbGHandoff | R3 | "Set up your gym on a computer: open simplefit.box/app/onboarding/gym and sign in with this account. Your progress is saved." Remove the setup link, "code 4K7-Q2", "Resend email" and "14 steps · about 20 minutes" | C6 | ADR 0012, D-G21 | SF-84 |
| ☐ | INV2 | InviteGymCoach | R4 | Mark as superseded by OS1 (role Coach); retire the route `/invite/coach/:token` | C11 | D-G16, D-G22 | SF-87 |
| ☐ | OS1 | OnbSInvite | R4 | Same layout, opened from the inbox (by invitation id) or the web `/invite/staff` page; add states for wrong account, expired, revoked and already accepted | C12 | D-G16, D-G22, D-G12 | SF-87 |
| ☐ | OS1b | OnbSInviteCode | R4 | Same layout; the code proves the invited address through SF-77 (add a verified email to *this* account); add state "this email belongs to another account" | C12 | D-G22 | SF-87 |
| ☐ | OS2 | OnbSRole | R7 | Front desk "you can": check members in, see today's classes and rosters. "You can't": training logs, weight and messages; revenue; export; changing the timetable. Remove sell/refund/incidents/messaging | C10 | D-G03, D-G06 | SF-87 |
| ☐ | OS3 | OnbSLocation | R11 | Home location only; remove shift times, "Shift reminders" and "Check-in sounds" | C16 | — | SF-87 |
| ☐ | WG1 ⓡ | WebDashboard | R5 | Tiles: today's classes, bookings today, check-ins today, active members. Remove revenue, MRR mix, failed payments, incident, trials, community, open sparring and coaches on shift | C7 | D-G09, D-G10 | SF-101 |
| ☐ | G01 ⓡ | GymPulse | R5 | Check-ins today, classes today (with booked / capacity), QR check-in action. Remove failed payments, sales and occupancy % | C7 | D-G10 | SF-101 |
| ☐ | GRW1 ⓡ | FirstRunWebG | R5 | Checklist: gym created ✓ · add a class · invite staff · invite members · first check-in. Remove "published", "175 invites", "payout verified", store and challenge | C7 | D-G21 | SF-101 |
| ☐ | GR1 ⓡ | FirstRunGPulse | R5 | Same checklist as GRW1 (mobile) | C7 | D-G21 | SF-101 |
| ☐ | GRW2, GR2 | FirstRunWebGTour(Steps), FirstRunGCheckinTip(Steps) | R5 | Drop the tour steps that point at FUTURE areas | C7 | D-G21 | SF-101 |
| ☐ | WG3 ⓡ | WebMembers | R6 | Columns: member, status (requested / active / suspended / ended), joined, home location, last visit, visits in 30 days. Remove plan, renewal, payment, waiver, discoverable and "Export CSV". Keep the "GYM ADMIN CAN'T SEE …" panel, without "and billing". Add a join-requests tab | C8 | D-G08, D-G10 | SF-90 |
| ☐ | WG14 ⓡ | WebMemberDetail | R6, R9 | Gym-held facts only: status, joined, home location, bookings, check-ins. Remove payments, lifetime value, plan, freezes, incidents and staff notes | C8 | D-G06, D-G10 | SF-90 |
| ☐ | WG15 ⓡ | WebMemberBan | R9 | Suspend / Resume / End membership with confirmation; remove ban, incidents and refunds | C14 | D-G18 | SF-90 |
| ☐ | G04 ⓡ | MemberCard | R6 | Status, home location, last visit, visits in 30 days, today's booking. Remove payment failed, retry, pay link, credits, freeze and staff note | C8 | D-G10 | SF-90 |
| ☐ | G09 ⓡ | GymMembers | R6 | As WG3 (mobile) | C8 | — | SF-90 |
| ☐ | WG16 ⓡ | WebStaff | R7, R11 | Status Active / Invited; permissions panel from the MVP matrix; remove "ON SHIFT NOW", "fighter notes (with consent)", "Payments & refunds" and "Approve sparring" | C10, C16 | D-G03, D-G06 | SF-87 |
| ☐ | WG17 ⓡ | WebRoles | R7 | Read-only matrix: Owner / Manager / Coach / Front desk; keep the "NEVER, FOR ANY ROLE" row. Remove "Add custom role", the Head coach column, refunds, revenue, sell passes, export and approvals; mark the audit list "coming later" | C10 | D-G03, D-G06, D-G18 | SF-88 |
| ☐ | WG26 ⓡ | WebGymDanger | R2 | Keep "Transfer ownership" (target: an active staff member; accepts within 7 days). Remove "identity verified", "Unpublish", "Pause billing", "Close gym" and "payouts account" | — | D-G04, D-G26, D-G11 | SF-100 |
| ☐ | WG25, PR3, PR6m ⓡ | WebGymBilling, PricingGym, PlanCompareMobile | R2 | FUTURE references; no MVP link to them | C17 | D-G09 | — |
| ☐ | L4 | LandGyms | R2 | Remove prices, "Compare gym plans", the revenue/failed-payments hero numbers, memberships/packages, payouts and the store; keep "Set up your gym" | C17 | D-G09, D-G10 | SF-84 |
| ☐ | F13 ⓡ | BookClass | R6 | Book without credits or prices; states: full → waitlist, booked, cancelled, not a member | C9 | D-G07, D-G10 | SF-95 |
| ☐ | F16 ⓡ | Membership | R6 | "Member pass": gym name, home location, status, rotating QR. Remove plan, renewal, PT pack and credits | C9 | D-G19 (open) | SF-97 |
| ☐ | A03 | JoinInvite | R8 | "Join Warsaw Boxing Club". Remove "ROLE · FIGHTER", "Join as fighter" and "GROUP · COMPETITION TEAM"; result is "Request sent" or "You're in" (with auto-approval); keep the privacy line | C13 | D-G07, D-G08 | SF-91 |
| ☐ | E04 | EmailWelcomeGym | R10 | "Finish creating Simple Boxing Gym", with no credential; remove "NIP for payouts", "price list" and "CSV export"; progress counts only the required steps | C15 | D-G21 | SF-84 |
| ☐ | E05 | EmailGymLive | R10 | FUTURE reference (publishing) | — | D-G11 | — |
| ☐ | E06 | EmailStaffInvite | R10 | Abilities from the MVP matrix (remove "sell drop-ins and passes" and "log incidents"); link `/invite/staff#token=`; expiry 7 days | C15 | D-G12, D-G16 | SF-86 |
| ☐ | E07 | EmailMemberInvite | R10 | "Simple Boxing Gym invited you to join on SimpleFit: book classes and check in." Remove the Unlimited membership, BLIK/card payment and "shared your name, email and plan". Privacy line: "the gym used your email address to invite you"; link `/invite/gym#token=` | C15 | D-G08, D-G10 | SF-89 |
| ☐ | G05 | Staff | R11 | FUTURE reference (shifts, sickness) | C16 | — | — |

