# Sponsor & Admin — artboard inventory (SF-107)

**Status: inventory only. Claude Design wasn't changed.** Source: the structured canvas
(`project/canvas.json` and each board's source) of
[the design artifact](https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY), **version `1794038955-2ed3`**, read
2026-11-07. The version moved from `1793992374-f69c` during the audit: another writer is active, so
recheck before relying on this.

**Coverage: 83 of 83 boards**, generated from the canvas: all 46 on page Admin, all 14 on Sponsor
Portal, sections 5f, 34g and 34h, the two nav components and the fighter placement views. A script refused to
produce this file if any board on those pages had no row. The whole canvas has 494 boards; the rest
aren't Sponsor or Admin.

Classes: FUTURE 45, MVP 14, MVP, reduced 16, MVP, reworked 3, Reference 5. The canvas itself marks none of these
boards MVP or FUTURE, so **the class is this document's proposal**, not an approval.

**Read with care**

* **Historical names differ from the brief.** All of AD0–AD21 are present. SP8 is "Create account to submit",
  not an application review: **no review step exists.** SP9 is "Submitted", and SPX3 to SPX9 are the sign-in and portal.
* **Every board is static:** one populated state, except SRW2's `step`. Only those are listed under states.
* **Responsive:** all screens are 1440 wide (AdRules 1600), fighter views 390. No other variant exists (G-S20).
* **Sample content isn't data:** names, companies, figures, service times, audit ids and retention periods
  on these boards are illustrations.
* **Build status** comes from the registry's `production.file`. "Placeholder" pages show no data.
* **API names** refer to the [matrix](sponsor-admin-api-matrix.md) and none exist. **Permissions** refer to the
  [catalog](sponsor-admin-permissions.md). Gap ids refer to the [register](sponsor-admin-design-gap-register.md).
* Other design references: Route Gallery `GalleryIndex4` lists these rows; `WebRoleSelect`, `WebLoginWorkspace`,
  `ContextSwitcher`, `WebContextSelect`, `Workspaces` and `Onboarding` touch them
  ([route matrix §6](sponsor-admin-route-matrix.md#6-other-boards-touching-these-routes)).

## Sponsor application · section 5f

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SP1 | `SponsorReg1.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=company` | Applicant | Session, registration | Draft: Company, country, industry, logo | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S01 G-S02 G-S03 G-S20 | MVP |
| SP2 | `SponsorReg2.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=contact` | Applicant | Session, registration | Draft: Contact name, position, work email, phone | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S02 G-S03 G-S20 | MVP |
| SP3 | `SponsorReg3.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=interests` | Applicant | Session, registration | Draft: Interest list | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S03 G-S20 | MVP |
| SP4 | `SponsorReg4.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=markets` | Applicant | Session, registration | Draft: Countries, cities | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S03 G-S20; remove reach estimate | MVP |
| SP5 | `SponsorReg5.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=budget` | Applicant | Session, registration | Draft: Budget band | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S03 G-S20; D-SA05 | MVP |
| SP6 | `SponsorReg6.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=goals` | Applicant | Session, registration | Draft: Goals text | `updateSponsorApplication` | 1440×820 | Filled | Not built (application closed) | G-S03 G-S20 | MVP |
| SP7 | `SponsorReg7.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor?step=uploads` | Applicant | Session, registration | Draft: Files | `updateSponsorApplication`, file operations | 1440×820 | Filled | Not built (application closed) | G-S04 G-S05 G-S20 | MVP |
| SPX1 | `PartnersLanding.dc.html` | `1794038955-2ed3` | web.partners | `/partners` | Anyone | None | Static content | None | 1440×1140 | Static | Real page | Live metrics stay out (SF-43) | MVP |
| SPX2 | `BecomeSponsor.dc.html` | `1794038955-2ed3` | web.partners.apply | `/partners/apply` | Anyone | None | Static content | None | 1440×900 | Static | Real page | G-S01 G-S20 | MVP |
| SP8 | `SponsorRegAuth.dc.html` | `1794038955-2ed3` | web.app.onboarding.sponsor ✱ | `/app/onboarding/sponsor` | Applicant | None, then session | Identity | Existing auth | 1440×820 | Modal, one state | Not built (application closed) | G-S01: replaced by sign-in before SP1. The brief's "review/submission" step isn't this board: G-S05 | MVP, reworked |
| SP9 | `SponsorSubmitted.dc.html` | `1794038955-2ed3` | web.sponsor.application ✱ | `/sponsor/application` | Applicant | Own application | Application | `getMySponsorApplication` | 1440×900 | Submitted | Not built (application closed) | G-S06 G-S07 | MVP |
| SPX3 | `SponsorLogin.dc.html` | `1794038955-2ed3` | web.sponsor.login | `/sponsor/login` | Anyone | GUEST_ONLY | Identity | Existing auth | 1440×900 | One state | Placeholder | Generic auth errors exist; C2 redirect | MVP |
| Route map | `RouteSponsor.dc.html` | `1794038955-2ed3` | — | `—` | Design reference | — | — | — | 2920×1070 | Static | Not a screen | Old paths (D-ROUTE-MAP-BOARDS) | Reference |

## Sponsor first run · section 34g

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SRW1 | `FirstRunSponsor.dc.html` | `1794038955-2ed3` | web.sponsor._sponsor-id.dashboard ✱ | `/sponsor/:sponsorId/dashboard` | Sponsor member | Active membership | Organization, first-run | `getSponsorHome`, first-run | 1440×900 | Approved | Placeholder | G-S17 G-S18; assumes campaigns, fees, "Sarah" | MVP, reduced |
| SRW2 | `FirstRunSponsorTour.dc.html` | `1794038955-2ed3` | web.sponsor._sponsor-id.dashboard ✱ | `/sponsor/:sponsorId/dashboard` | Sponsor member | Active membership | First-run | `PUT /me/first-run/{experience}` | 1440×900 | `step` 1–9, done; end tour | Placeholder | G-S17; steps 3, 4, 5, 6, 8, 9 cover FUTURE or unstaffed features | MVP, reduced |
| SRW2 sheet | `FirstRunSponsorTourSteps.dc.html` | `1794038955-2ed3` | — | `—` | Design reference | — | Same as SRW2 | — | 15120×952 | All 10: launch checklist, overview, campaigns, creative, analytics, invoices, settings, where your brand appears, partner manager, complete | Not a screen | As SRW2 | Reference |

## Sponsor portal · sections 29, 30

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SPX4 | `SponsorDashboard.dc.html` | `1794038955-2ed3` | web.sponsor._sponsor-id.dashboard ✱ | `/sponsor/:sponsorId/dashboard` | Sponsor member | Active membership | Organization | `getSponsorHome` | 1440×900 | Approved, populated | Placeholder | G-S16 G-S18; all metrics invented | MVP, reduced |
| SPX5 | `SponsorApp.dc.html` | `1794038955-2ed3` | web.sponsor.application | `/sponsor/application` | Applicant | Own application | Application, message, history | `getMySponsorApplication`, update, submit | 1440×900 | `needs-info` only | Placeholder | G-S07 G-S08 G-S09 G-S10; route C1 | MVP |
| SPX6 | `SponsorCampaigns.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns | `/sponsor/campaigns` | Sponsor member | Future | Campaigns | None | 1440×900 | Populated | Placeholder | No empty or error state | FUTURE |
| SPX7 | `SponsorAnalytics.dc.html` | `1794038955-2ed3` | web.sponsor.analytics._campaign-id | `/sponsor/analytics/:campaignId` | Sponsor member | Future | Tracking that doesn't exist | None | 1440×900 | Populated | Placeholder | Blocked: no tracking (D-SA24) | FUTURE |
| SPX8 | `SponsorInvoices.dc.html` | `1794038955-2ed3` | web.sponsor.invoices | `/sponsor/invoices` | Sponsor member | Future, owner or manager | Invoices | None | 1440×900 | Populated | Placeholder | Blocked (D-SA23) | FUTURE |
| SPX9 | `SponsorSettings.dc.html` | `1794038955-2ed3` | web.sponsor._sponsor-id.settings ✱ | `/sponsor/:sponsorId/settings` | Sponsor member | View; edits per matrix | Organization, members | Organization and member operations | 1440×900 | Populated | Placeholder | G-S14 G-S15; data agreement G-S12 | MVP, reduced |
| SPC1 | `CampType.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain | FUTURE |
| SPC2 | `CampObjective.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain | FUTURE |
| SPC3 | `CampMarket.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain | FUTURE |
| SPC4 | `CampBudget.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain; D-SA05 | FUTURE |
| SPC5 | `CampCreative.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain | FUTURE |
| SPC6 | `CampReview.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns.new | `/sponsor/campaigns/new` | Sponsor member | Future | Campaign | None | 1440×900 | Filled | Placeholder | FUTURE domain | FUTURE |
| SPC7 | `CampSubmitted.dc.html` | `1794038955-2ed3` | web.sponsor.campaigns._campaign-id | `/sponsor/campaigns/:campaignId` | Sponsor member | Future | Campaign | None | 1440×900 | Submitted | Placeholder | FUTURE domain | FUTURE |
| Sheet | `AdRules.dc.html` | `1794038955-2ed3` | — | `—` | Design reference | — | Draft policy | — | 1600×920 | Static | Not a screen | Not an approved policy | Reference |

## Sponsored placements · fighter views

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AV1 | `SponsoredChallenge.dc.html` | `1794038955-2ed3` | mobile.challenges._challenge-id | `/challenges/:challengeId` | Fighter | Future | Campaign | None | 390×1140 | Populated | Placeholder | FUTURE domain | FUTURE |
| AV2 | `SponsoredFeed.dc.html` | `1794038955-2ed3` | mobile.community | `/community` | Fighter | Future | Campaign | None | 390×880 | Populated | Placeholder | FUTURE domain | FUTURE |
| AV2b | `SponsoredWhy.dc.html` | `1794038955-2ed3` | mobile.community | `/community` | Fighter | Future | Campaign | None | 390×844 | Populated | Placeholder | FUTURE domain | FUTURE |
| MK11 | `EventDetail.dc.html` | `1794038955-2ed3` | mobile.events._event-id | `/events/:eventId` | Fighter | Future | Event | None | 390×1040 | Populated | Placeholder | FUTURE domain; sponsored variant | FUTURE |

## Admin first run · section 34h

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ARW1 | `FirstRunAdmin.dc.html` | `1794038955-2ed3` | web.admin.welcome | `/admin/welcome` | Operator | Active operator | First-run, permissions | `getCurrentOperator`, first-run | 1440×900 | 2 of 5 | Placeholder | G-A07 | MVP, reduced |

## Admin access and platform · section 19a

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AD0 | `AdminSignIn.dc.html` | `1794038955-2ed3` | web.admin.verify ✱ | `/admin/verify` | Operator | Signed in; non-revoked operator | Session, credential | Step-up operations | 1440×900 | Waiting for key | Placeholder | G-A01 G-A02 G-A06 | MVP, reworked |
| AD0b | `AdminAccess.dc.html` | `1794038955-2ed3` | web.admin.access | `/admin/access` | Operator | Future permission | Session scopes | None | 1440×900 | Populated | Placeholder | Not proposed: self-chosen scope (C5) | FUTURE |
| AD1 | `AdminOverview.dc.html` | `1794038955-2ed3` | web.admin | `/admin` | Operator | `platform.dashboard.read` | Real counts, queues | `getAdminOverview` | 1440×900 | Populated, 24 h, 7 d, 30 d | Placeholder | G-A08; figures invented | MVP, reduced |
| AD2 | `AdminTenants.dc.html` | `1794038955-2ed3` | web.admin.tenants | `/admin/tenants` | Operator | `gyms.read` | Gyms | `listAdminGyms` | 1440×900 | Filters | Placeholder | G-A05 G-A08-style states; independent coaches out | MVP, reduced |
| AD12 | `AdminTenantDetail.dc.html` | `1794038955-2ed3` | web.admin.tenants._tenant-id | `/admin/tenants/:tenantId` | Operator | `gyms.read` | Gym, verification status | `getAdminGym` | 1440×900 | Healthy | Placeholder | G-A16 G-A17 G-A19; health score, GMV out | MVP, reduced |
| AD7 | `AdminUsers.dc.html` | `1794038955-2ed3` | web.admin.users | `/admin/users` | Operator | `users.read` | Exact match | `searchUsers` | 1440×900 | Filters, browse-all | Placeholder | G-A20; browse-all out | MVP, reduced |
| AD8 | `AdminUserDetail.dc.html` | `1794038955-2ed3` | web.admin.users._user-id | `/admin/users/:userId` | Operator | `users.read` | Minimal identity, context types | `getAdminUser` | 1440×900 | Review | Placeholder | G-A20; risk score, strikes, devices out | MVP, reduced |

## Admin trust and safety · section 19b

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AD4 | `AdminModeration.dc.html` | `1794038955-2ed3` | web.admin.moderation | `/admin/moderation` | Operator | Future permission | Reports | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD9 | `AdminBan.dc.html` | `1794038955-2ed3` | web.admin.users._user-id | `/admin/users/:userId` | Operator | `users.restrict` | Restriction | `restrictUser` | 1440×900 | 2-person | Placeholder | G-A03 G-A20; suspend only | MVP, reduced |
| AD11 | `AdminEnforcement.dc.html` | `1794038955-2ed3` | web.admin.enforcement | `/admin/enforcement` | Operator | Future permission | Enforcement, appeals | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD10 | `AdminDelete.dc.html` | `1794038955-2ed3` | web.admin.users | `/admin/users` | Operator | Future permission | Deletion policy | None | 1440×900 | Populated | Placeholder | FUTURE; two-person rule (D-SA17) | FUTURE |
| AD18 | `AdminPrivacy.dc.html` | `1794038955-2ed3` | web.admin.privacy | `/admin/privacy` | Operator | Future permission | DSAR | None | 1440×900 | Populated | Placeholder | FUTURE; counsel may need a manual process | FUTURE |
| AD5 | `AdminSupport.dc.html` | `1794038955-2ed3` | web.admin.support._session-id | `/admin/support/:sessionId` | Operator | Future permission | Tickets, scoped sessions | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD21 | `AdminSupportList.dc.html` | `1794038955-2ed3` | web.admin.support | `/admin/support` | Operator | Future permission | Tickets | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD14 | `AdminAudit.dc.html` | `1794038955-2ed3` | web.admin.audit | `/admin/audit` | Operator | `audit.read` | Operator audit | `listOperatorAuditEvents` | 1440×900 | Today | Placeholder | G-A21; unproven claims removed | MVP |

## Admin money and system · section 19c

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AD13 | `AdminSubscriptions.dc.html` | `1794038955-2ed3` | web.admin.subscriptions | `/admin/subscriptions` | Operator | Future permission | Subscriptions | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD3 | `AdminPayments.dc.html` | `1794038955-2ed3` | web.admin.payouts | `/admin/payouts` | Operator | Future permission | Payouts, KYC | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD15 | `AdminNotifications.dc.html` | `1794038955-2ed3` | web.admin.notifications | `/admin/notifications` | Operator | Future permission | Email metrics | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD16 | `AdminEmailEditor.dc.html` | `1794038955-2ed3` | web.admin.notifications._template-id | `/admin/notifications/:templateId` | Operator | Future permission | Templates in code (ADR 0011) | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD17 | `AdminIntegrations.dc.html` | `1794038955-2ed3` | web.admin.integrations | `/admin/integrations` | Operator | `system.health.read` | Queues, jobs, last webhook | `getAdminHealth` | 1440×900 | Degraded | Placeholder | G-A23; unused vendors, key rotation out | MVP, reduced |
| AD19 | `AdminMarkets.dc.html` | `1794038955-2ed3` | web.admin.markets | `/admin/markets` | Operator | Future permission | Market config | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD6 | `AdminFlags.dc.html` | `1794038955-2ed3` | web.admin.flags | `/admin/flags` | Operator | Future permission | Flags | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AD20 | `AdminStaff.dc.html` | `1794038955-2ed3` | web.admin.staff | `/admin/staff` | Operator | `operators.read`, `operators.manage` | Operators, grants | Operator operations | 1440×900 | Elevated | Placeholder | G-A22; break-glass, access requests out | MVP, reduced |

## Admin revenue · section 31

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AR1 | `AdminRevenue.dc.html` | `1794038955-2ed3` | web.admin.revenue | `/admin/revenue` | Operator | Future permission | Revenue | None | 1440×960 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AR2 | `AdminTransactions.dc.html` | `1794038955-2ed3` | web.admin.transactions | `/admin/transactions` | Operator | Future permission | Transactions | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AR3 | `AdminRefunds.dc.html` | `1794038955-2ed3` | web.admin.refunds | `/admin/refunds` | Operator | Future permission | Refunds | None | 1440×960 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AR4 | `AdminPricing.dc.html` | `1794038955-2ed3` | web.admin.pricing | `/admin/pricing` | Operator | Future permission | Catalog | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AR5 | `AdminPlanEditor.dc.html` | `1794038955-2ed3` | web.admin.pricing._plan-id | `/admin/pricing/:planId` | Operator | Future permission | Catalog | None | 1440×1000 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AR6 | `AdminPromos.dc.html` | `1794038955-2ed3` | web.admin.promos | `/admin/promos` | Operator | Future permission | Promos | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |

## Admin sponsors · section 32a

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AS1 | `AdminSponsors.dc.html` | `1794038955-2ed3` | web.admin.sponsor-applications ✱ | `/admin/sponsor-applications` | Operator | `sponsors.applications.read` | Applications | `listSponsorApplications` | 1440×930 | Populated | Placeholder | G-A10; budget bands | MVP |
| AS2 | `AdminSponsorDetail.dc.html` | `1794038955-2ed3` | web.admin.sponsor-applications._application-id ✱ | `/admin/sponsor-applications/:applicationId` | Operator | `.read`, `.claim`, `.decide`, `.read_files` | Revision, events | Review operations | 1440×900 | Under review | Placeholder | G-A03 G-A11 G-A12 G-A13 G-A14 | MVP, reworked |
| AS3 | `AdminSponsorEdit.dc.html` | `1794038955-2ed3` | web.admin.sponsors._sponsor-id.edit | `/admin/sponsors/:sponsorId/edit` | Operator | Future permission | CRM | None | 1440×910 | Populated | Placeholder | Not for applications (F5). CRM is FUTURE | FUTURE |
| AS4 | `AdminSponsorCRM.dc.html` | `1794038955-2ed3` | web.admin.sponsors._sponsor-id | `/admin/sponsors/:sponsorId` | Operator | `sponsors.read`, `sponsors.restrict` | Organization | `getAdminSponsor` | 1440×900 | Active, CRM | Placeholder | G-A15; stages, spend, agreements out | MVP, reduced |
| AS5 | `AdminSponsorTimeline.dc.html` | `1794038955-2ed3` | web.admin.sponsors._sponsor-id.timeline | `/admin/sponsors/:sponsorId/timeline` | Operator | Future permission | History | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AS6 | `AdminSponsorRevenue.dc.html` | `1794038955-2ed3` | web.admin.sponsors.revenue | `/admin/sponsors/revenue` | Operator | Future permission | Invoices | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |

## Admin campaigns · section 32b

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AC1 | `AdminCampaigns.dc.html` | `1794038955-2ed3` | web.admin.campaigns | `/admin/campaigns` | Operator | Future permission | Campaigns | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AC2 | `AdminCampaignReview.dc.html` | `1794038955-2ed3` | web.admin.campaigns._campaign-id | `/admin/campaigns/:campaignId` | Operator | Future permission | Campaigns | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AC2b | `AdminCampaignApproved.dc.html` | `1794038955-2ed3` | web.admin.campaigns._campaign-id | `/admin/campaigns/:campaignId` | Operator | Future permission | Campaigns | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AC3 | `AdminCampaignEdit.dc.html` | `1794038955-2ed3` | web.admin.campaigns._campaign-id.edit | `/admin/campaigns/:campaignId/edit` | Operator | Future permission | Campaigns | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AC4 | `AdminChallengeEditor.dc.html` | `1794038955-2ed3` | web.admin.challenges.new | `/admin/challenges/new` | Operator | Future permission | Challenges | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AC5 | `AdminEventEditor.dc.html` | `1794038955-2ed3` | web.admin.events._event-id | `/admin/events/:eventId` | Operator | Future permission | Events | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |

## Admin enterprise · section 33

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AE1 | `AdminEnterprise.dc.html` | `1794038955-2ed3` | web.admin.enterprise | `/admin/enterprise` | Operator | Future permission | Leads | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AE2 | `AdminEnterpriseLead.dc.html` | `1794038955-2ed3` | web.admin.enterprise._lead-id | `/admin/enterprise/:leadId` | Operator | Future permission | Leads | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |
| AE3 | `AdminWhiteLabel.dc.html` | `1794038955-2ed3` | web.admin.enterprise | `/admin/enterprise` | Operator | Future permission | Leads | None | 1440×900 | Populated | Placeholder | FUTURE; no empty, loading or error state | FUTURE |

## Components and flows

| Artboard | Source file | Version | Route id (✱ proposed) | Target path | Viewer | Permission | Data | API (proposed) | Size | States on the board | Build status | Missing or to change | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Component | `SponsorNav.dc.html` | `1794038955-2ed3` | — | `—` | Sponsor member | Active membership | Organization | `getSponsorHome` | 240×900 | `active` prop | Not built | G-S13; show MVP items only | MVP, reduced |
| Component | `AdminNav.dc.html` | `1794038955-2ed3` | — | `—` | Operator | Active operator | Permissions | `getCurrentOperator` | 240×900 | `active` prop | Not built | G-A09 | MVP, reduced |
| Flow | `FlowAdmin.dc.html` | `1794038955-2ed3` | — | `—` | Design reference | — | — | — | 2040×1080 | Static | Not a screen | Redraw after approval | Reference |
| Flow | `FlowSponsor.dc.html` | `1794038955-2ed3` | — | `—` | Design reference | — | — | — | 2520×1340 | Static | Not a screen | Redraw after approval | Reference |
