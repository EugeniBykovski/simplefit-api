# Sponsor & Admin — route matrix (SF-107)

**Status: PROPOSED. The registries aren't changed by SF-107.** Read from
`simplefit-platform` `a4c4b1b` and `simplefit-mobile` `d248076`, whose `docs/route-registry.json` are
identical (317 routes: 162 web, 155 mobile).

## 1. Today

| Area | Routes | Access | Real page |
| --- | --- | --- | --- |
| Partners | `web.partners`, `web.partners.apply` | PUBLIC | Yes, truthful, application closed |
| Sign-in | `web.sponsor.login`, `web.admin.login` | GUEST_ONLY | Placeholder |
| Portal | 8 `web.sponsor.*` | `SPONSOR_WORKSPACE` | Placeholder |
| Admin | 39 `web.admin*` | `ADMIN` | Placeholder |
| Mobile | None | — | `D-MOBILE-SPONSOR-ADMIN`: no surfaces. Sponsor intent opens `mobile.onboarding.role` |

Route gates check only the session today (`session-gate.tsx`). **Capability and step-up gates must
ship before any admin page shows real data.**

## 2. Circular prerequisites

| # | Loop today | Fix |
| --- | --- | --- |
| C1 | `web.sponsor.application` needs `SPONSOR_WORKSPACE`, which needs approval, which an applicant is waiting on (also `capabilities.SPONSOR_WORKSPACE.onboarding` points there) | Access becomes AUTHENTICATED, capability null. The backend authorizes the applicant's own application. Own minimal shell, no portal nav |
| C2 | SP9 "Go to Sponsor Dashboard", and SPX3 "Track your application" leading to the dashboard | Both go through entry, which picks status or workspace |
| C3 | `web.partners.apply` holds SPX2 and SP1–SP9 as a PUBLIC route, while a draft needs an account | SPX2 stays public. SP1–SP9 move to `web.app.onboarding.sponsor` |
| C4 | SRW2 is mapped to `web.sponsor.campaigns.new` (FUTURE), and its tour points at the sidebar | SRW2 becomes a state of the dashboard |
| C5 | `web.admin.access` (AD0b) needs `ADMIN` and sets the scope that AD0 led to | AD0b is FUTURE. Permissions come from grants |
| C6 | `web.admin.welcome` and every `ADMIN` route need capability, but enrolling is how a new operator becomes capable | `web.admin.verify` is reachable by `pending_enrollment`. `ADMIN` at route level means "has a non-revoked row"; the API decides everything else |
| C7 | `web.admin.login` is GUEST_ONLY, so a signed-in operator can't use it | Already noted in `D-ADMIN-IDENTITY`. A signed-in user at `/admin/login` goes to `/admin`, then the gate decides |

## 3. Proposed routes

Conventions kept: `/app/onboarding/*` for journeys, `:camelCaseId` named after its collection,
`sponsorId` as already used by admin routes, and no state in query strings for backend truth.

### Sponsor

| Route id | Path | Session | Capability | Phase | Shell | Boards | Change |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `web.partners` | `/partners` | PUBLIC | — | — | `web.site` | SPX1 | None |
| `web.partners.apply` | `/partners/apply` | PUBLIC | — | — | `web.site` | SPX2 | **Remove** SP1–SP9 from `screens`. CTA carries `intent=sponsor` |
| `web.app.onboarding.sponsor` | `/app/onboarding/sponsor?step=` | AUTHENTICATED | null | ONBOARDING | `web.app.onboarding` | SP1–SP7, new review | **New.** Steps `company`, `contact`, `interests`, `markets`, `budget`, `goals`, `uploads`, `review` |
| `web.sponsor.application` | `/sponsor/application` | AUTHENTICATED | **null** | null | **`web.minimal`** | SP9, SPX5, new states | **Changed** (C1) |
| `web.sponsor.login` | `/sponsor/login` | GUEST_ONLY | — | — | `web.auth` | SPX3 | Then entry with `intent=sponsor` |
| `web.sponsor._sponsor-id.dashboard` | `/sponsor/:sponsorId/dashboard` | AUTHENTICATED | `SPONSOR_WORKSPACE` | ACTIVE | `web.sponsor` | SPX4 reduced, SRW1, SRW2 | **Re-keyed** |
| `web.sponsor._sponsor-id.settings` | `/sponsor/:sponsorId/settings` | Same | Same | Same | `web.sponsor` | SPX9 reduced | **Re-keyed** |
| `web.invite.sponsor` | `/invite/sponsor` | PUBLIC | — | — | `web.minimal` | New | **New**, as `web.invite.staff` |

**First run and tour** aren't routes. SRW1 is a state of the dashboard, and SRW2 an overlay on it, both
from `first_run_outcomes`. Skip, resume and completion follow ADR 0018.

**Why id-based:** the registry's `D-WORKSPACE-NOT-IN-URL` assumed the backend session holds the active
workspace. It doesn't, and the gym consoles left that model (D-G23), for reasons that apply here: tabs
on different organizations, links from email, and no server-side state that resembles authority.
Everything is still a placeholder, so moving costs little. This reopened a RESOLVED registry
decision; [D-SA26](sponsor-admin-decision-register.md) was **approved on 2026-11-10 for SF-117**, which re-keys the
dashboard. The settings route is re-keyed when its page is built.

### Sponsor, deferred

Stay as placeholders, hidden from nav, re-keyed when built: `web.sponsor.campaigns`, `.campaigns.new`,
`.campaigns._campaign-id`, `.analytics._campaign-id`, `.invoices`. Nav shows only Overview, Application
and Settings. `GAP-SPONSOR-ANALYTICS-INDEX` stays open.

### Admin

All web only, shell `web.admin`, session AUTHENTICATED, capability `ADMIN`, unless stated.

| Route id | Path | Boards | Permission | Change |
| --- | --- | --- | --- | --- |
| `web.admin.login` | `/admin/login` (GUEST_ONLY, `web.auth`) | AD0 first half | — | Standard sign-in methods. C7 |
| `web.admin.verify` | `/admin/verify` | AD0 key step, enroll | Non-revoked operator | **New** |
| `web.admin.welcome` | `/admin/welcome` | ARW1 | Any active | Phase becomes null: presentation only |
| `web.admin` | `/admin` | AD1 | `platform.dashboard.read` | |
| `web.admin.staff` | `/admin/staff` | AD20 | `operators.read` | |
| `web.admin.staff._operator-id` | `/admin/staff/:operatorId` | New | `operators.read` | **New** |
| `web.admin.audit` | `/admin/audit` | AD14 | `audit.read` | |
| `web.admin.audit._event-id` | `/admin/audit/:eventId` | New | `audit.read` | **New** |
| `web.admin.sponsor-applications` | `/admin/sponsor-applications` | AS1 | `sponsors.applications.read` | **New.** AS1 moves here |
| `web.admin.sponsor-applications._application-id` | `/admin/sponsor-applications/:applicationId` | AS2 | Same | **New.** The domain makes applications addressable, as `D-ADMIN-SPONSOR-CAMPAIGN-PATHS` anticipated |
| `web.admin.sponsors` | `/admin/sponsors` | New list | `sponsors.read` | **Screens change:** AS1 out |
| `web.admin.sponsors._sponsor-id` | `/admin/sponsors/:sponsorId` | AS4 reduced | `sponsors.read` | AS2 out |
| `web.admin.gyms.verification` | `/admin/gyms/verification` | New | `gyms.verification.read_queue` | **New** |
| `web.admin.gyms.verification._application-id` | `/admin/gyms/verification/:applicationId` | New | `.read_application` | **New** |
| `web.admin.gyms.publication` | `/admin/gyms/publication` | SF-139 PO1–PO3 | `gyms.publication.read_queue` | **New, only if SF-139 is approved** |
| `web.admin.tenants`, `._tenant-id` | Unchanged | AD2, AD12 reduced | `gyms.read` | Gyms only in MVP. `tenantId` is the gym id |
| `web.admin.users`, `._user-id` | Unchanged | AD7, AD8, AD9 reduced | `users.read` | AD10 out |
| `web.admin.integrations` | Unchanged | AD17 reduced | `system.health.read` | |

**Everything else under `/admin` stays a placeholder, hidden from nav and refused by the API:**
`access`, `moderation`, `enforcement`, `privacy`, `support*`, `subscriptions`, `payouts`, `notifications*`,
`markets`, `flags`, `revenue`, `transactions`, `refunds`, `pricing*`, `promos`, `sponsors.revenue`,
`sponsors.*.edit`, `sponsors.*.timeline`, `campaigns*`, `challenges.new`, `events.*`, `enterprise*`.

**The placeholder itself is a change.** Those 39 pages render for any signed-in user. Task A2's gate
must give non-operators a 404 on all of them, including ones left unbuilt, to avoid advertising the
map of an internal tool. Client gating is UX: the API remains the control.

### Guard order on `/admin/*`

```
no session → /admin/login?returnTo=
GET /admin/me → 404 → render web.not-found (no "you are not an admin" page)
pending_enrollment → /admin/verify
suspended, revoked → web.not-found
assurance too low → /admin/verify?returnTo=
first_run pending → may show /admin/welcome once; never blocks
permission missing → in-shell permission state; API refuses regardless
```

## 4. Web-only and mobile

| Surface | Web | Mobile | Basis |
| --- | --- | --- | --- |
| Partners, application, status | Yes, responsive | No | `D-MOBILE-SPONSOR-ADMIN`; the canvas has no 390-wide Sponsor board |
| Workspace | Yes | No | Same |
| Admin | Desktop first | **No. Never listed** | Same. A hardware key flow on a phone isn't a design goal |
| Sponsor context on A04 | — | "Continue on the web" row | Registry note; no board |
| Sponsored placements (AV1, AV2, MK11) | FUTURE | FUTURE | Fighter views, in a future campaign task |

No full mobile admin console is proposed.

## 5. Client parity requirements

For the task that changes the registry:

1. Edit `docs/route-registry.json` in Platform and copy it byte-identical to Mobile, in the same task.
2. `guards.entryDestinations`: add `sponsor_application_draft`, `sponsor_application_status`,
   `sponsor_home` for both platforms. On mobile each maps to `mobile.onboarding.role`, the existing handoff.
3. `capabilities.SPONSOR_WORKSPACE`: `home` → `web.sponsor._sponsor-id.dashboard`; `onboarding` →
   `web.app.onboarding.sponsor`; `grantedBy` stays conceptual.
4. `capabilities.ADMIN.grantedBy` → `PlatformOperator (SF-110)`.
5. New discrepancies recording this: `D-SPONSOR-APPLICATION-ACCESS`, and an update to
   `D-WORKSPACE-NOT-IN-URL`, `D-ADMIN-SPONSOR-CAMPAIGN-PATHS` and `D-ADMIN-IDENTITY`.
6. Update `source.version` and re-run both repos' registry checks and generated route types.
7. `mobile.workspaces` lists sponsor organizations only with the handoff.

## 6. Other boards touching these routes

| Board | Today | Needed |
| --- | --- | --- |
| WA6 `WebRoleSelect`, O05 | "Sponsor / Brand" → SPX2 | Keep. Copy already says "Choosing here doesn't add a role" |
| WA2 `WebLoginWorkspace` | Lists "Partner portal" | Show only real memberships |
| WCX1, `ContextSwitcher`, A04 | No sponsor | Add organizations ([gap](sponsor-admin-design-gap-register.md)) |
| Footers | Link SPX1, SPX2, SPX3 | Keep |
| `RouteSponsor`, `FlowSponsor` | Show the old path | Update after approval |
