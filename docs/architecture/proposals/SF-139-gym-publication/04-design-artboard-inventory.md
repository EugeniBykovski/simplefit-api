# 04 — Design and artboard inventory

Read from Claude Design version `1793198527-a0fc` and the route registry on 2026-11-06.

## 1. Editing status

**The canvas was not changed.** Three reasons:

1. The standing project rule is never to edit or republish Claude Design.
2. The canvas holds 512 files, the stated maximum, so new artboards would probably be refused.
3. The policy these boards depend on isn't approved.

§5 is the handoff for whoever updates it.

## 2. A warning about the registry

The registry marks almost every route `IMPLEMENTED`, including those below. For the
marketplace, discover, admin and gym profile routes that means a **`FeaturePlaceholder` in
the right shell**, not a working screen. Registry status isn't evidence of a public surface.

Its `source.version` (`1791448557-b0b9`) is older than the canvas, though individual route
notes cite later versions.

## 3. Existing screens

All boards below exist on the canvas. None is approved for public publication. "Readiness"
is about this policy, not the drawing.

### Public and discovery

| Design id | Board | Route id | Viewer | State | Data today | Permission | Status | Readiness | Missing | Privacy dependency |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| L4 | `LandGyms` | `web.gyms` (`/gyms`) | Anyone | Live marketing page | Tagged examples | Public | Implemented as marketing | Not a listing; **owns `/gyms`** | — | None |
| L5 | `LandMarket` | `web.marketplace` (`/marketplace`) | Anyone | Search disabled, tagged examples | Examples | Public | Implemented, marketplace "not open" | Blocked by policy | Real data, empty and unavailable states | Field allowlist; shows full addresses, prices, Sponsored |
| MK1 | `Market` | `mobile.marketplace` | Fighter | Placeholder | None | Session, FIGHTER | Placeholder | Blocked by backend | Everything | Capability conflict, §4 |
| MK1d | `WebMarket` | `web.app.marketplace` | Signed-in | Placeholder | None | Session | Placeholder | Blocked | Everything | "Verified only" filter, cart |
| MK4 | `MarketGyms` | `mobile.marketplace?type=gym` | Fighter | Placeholder | None | Session, FIGHTER | Placeholder | Blocked | Empty, loading, error states; real filters | Drop-in prices, Open now, Sponsored |
| x-mobile-promoted-gym | `MarketGyms` | `mobile.marketplace?type=gym&promoted=1` | Fighter | Placeholder | None | Session, FIGHTER | Placeholder | Out of scope | — | Ads policy |
| MK5 | `MarketGymProfile` | `mobile.marketplace.gym._gym-id` | Fighter | Placeholder | None | Session, FIGHTER | Placeholder | Blocked | Unavailable state, report action | `✓ verified`, named coach, spot counts, id in the URL |
| WG8 | `WebBranding` | `web.app.gyms._gym-id.profile` | Staff | Placeholder; board FUTURE | None | GYM_WORKSPACE | FUTURE | Blocked | Status, request flow | Counts, coaches, "Publish changes", §4 |
| S21 | `Search` | `mobile.search` | Signed-in | Placeholder | None | Session | Placeholder | Blocked | Gym results contract | "12 friends" |
| S02, W04 | `Discover`, `WebDiscover` | `mobile.discover`, `web.app.discover` | Fighter | Placeholder | None | FIGHTER | Placeholder | **Discover fighters, not gyms** | — | Not this surface |
| S15, GC1 | `GymCommunity`, `GymMemberships` | `mobile.gym._gym-id.*` | Fighter | Placeholder | None | FIGHTER | Placeholder | Blocked by other decisions | — | D-G10, community |
| B23, B25 | `BoardPlaces`, `GymNode` | `mobile.board*` | Fighter | Placeholder | None | FIGHTER | Placeholder | Not this surface | — | Personal visit data |

### Owner

| Design id | Board | Route id | Viewer | State | Data today | Permission | Status | Readiness | Missing | Privacy dependency |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| OG3 | `WebSetupBrand` | `web.app.onboarding.gym?step=branding` | Owner | Implemented | Setup fields | Session | Implemented | Reference only | Must not imply publication | — |
| OG7 | `WebSetupVerify` | `web.app.gyms._gym-id.settings.verification` | Owner | Implemented with adaptations | Real | `manage_business_verification` | Implemented; board FUTURE | Verification only | — | Board's badge and "under 24 h" aren't approved claims |
| OG13, WG10 | `WebSetupCommunity`, `WebCommunitySettings` | `…settings.community` | Owner | Coming-later page | Not stored | GYM_WORKSPACE | Implemented with adaptations | Blocked | Real settings | **Default-on public profile**, §4 |
| OG14 | `WebSetupLaunch` | `…settings.go-live` | Owner, manager | Readiness only | Derived; `publication: unavailable` | `view_go_live` | Implemented with adaptations | Blocked | Request flow | Board's "Publish gym" and "publishing allowed" while in review, §4 |
| E05 | `EmailGymLive` | Email, not a route | Owner | Template exists, never sent | — | — | Not triggered | Blocked | New copy | Promises Discover, bookings, payouts |

### Operator

Designed admin console: placeholder routes, no backend, no operator identity (SF-110).

| Design id | Board | Route id | Purpose | Status | Readiness |
| --- | --- | --- | --- | --- | --- |
| AD2, AD12 | `AdminTenants`, `AdminTenantDetail` | `web.admin.tenants*` | Tenant view; has "Suspend tenant", which isn't publication suspension | Placeholder | Blocked by SF-110 |
| AD4 | `AdminModeration` | `web.admin.moderation` | Social reports queue; useful pattern: redaction, reasons | Placeholder | Blocked by SF-110; no gym profile queue |
| AD8, AD9, AD11 | `AdminUserDetail`, `AdminBan`, `AdminEnforcement` | `web.admin.users*`, `web.admin.enforcement` | User enforcement and appeals | Placeholder | Pattern only |
| AD14 | `AdminAudit` | `web.admin.audit` | Audit log | Placeholder | Blocked by SF-110 |
| AD19 | `AdminMarkets` | `web.admin.markets` | Market configuration; candidate for the country allowlist | Placeholder | Blocked by SF-110 |
| AD20 | `AdminStaff` | `web.admin.staff` | Internal access, two-person rules | Placeholder | Blocked by SF-110; policy input |
| S20 | `ReportBlock` | `mobile.report?target=user` | Report a **user**; no gym target | Placeholder | Pattern only |

## 4. Conflicts between the design and this policy

| Id | Board | The design shows | Conflict | Proposed resolution |
| --- | --- | --- | --- | --- |
| C1 | WG8, WG10 vs E05, OG14 | `sfit.box/g/simple-boxing` and `sfit.box/simple-boxing` | Two URL forms | `/g/:gymSlug`; a root-level slug would collide with every route |
| C2 | WG10 | "Allow public profile · DEFAULT ON" | Public by default | Off; publication is a request |
| C3 | WG8 | "Publish changes" | Self-service publishing | "Request review"; edits don't go live unreviewed |
| C4 | OG14 | "Proof of address in review — publishing allowed", "Publish gym" | Publishing before verification; owner self-publish | Requires approved verification and operator approval |
| C5 | OG14, E05 | "Publishing puts the gym in Discover and opens bookings"; member invites, payouts | Bundles unrelated effects | Publication does only one thing |
| C6 | MK5, L5, MK1d | `✓ verified`, "Verified only" | Undefined badge | "Business details reviewed" with explanation, later |
| C7 | OG7 | "ID + selfie", "payments partner", "under 24 h", "Verified gyms get a badge" | Not what SF-103 does | Remove |
| C8 | WG8, WG10 | "142 athletes trained today", "12 of your friends train here" | Forbidden aggregates | Remove |
| C9 | MK5, WG8 | "Coach Marek", coach avatars | Disclosure without opt-in. WG8's footnote does say "coaches who opted in" | Show only opted-in, later |
| C10 | MK5, WG8 | "6 SPOTS", "1 spot" | Reveals attendance | Remove |
| C11 | MK4, MK5 | Drop-in prices, Memberships, Store | Commerce, D-G10 unapproved | Remove until approved |
| C12 | MK1, MK4, MK5 | FIGHTER capability required | D-G07: members needn't have a FighterProfile | Public pages need no capability |
| C13 | MK4, L5 | Sponsored labels | Ads policy, none approved | Out of scope |
| C14 | WG8 | "Follow gym", "Book a trial" | No follow or trial domain | Remove |

## 5. Design handoff: boards needed (all PROPOSED)

Label every board **PROPOSED · D-G11, not approved**. Use Graphite × Olive, the existing
tokens and type, 390×844 for mobile and the fluid web PAGE layout.

| New code (proposed) | Screen | Viewer | Route | Required states |
| --- | --- | --- | --- | --- |
| PG1, PG1m | Public gym page, release 1 fields | Anyone | `web.gym-public`, mobile shared | Full; minimal (no optional fields); not found |
| PG2, PG2m | Not found or no longer available | Anyone | Same | One state, deliberately saying nothing about why |
| PG3 | Report this gym | Anyone | Page action | Form, sent, rate limited |
| PP1 | Public profile editor, replaces WG8 | Owner, manager | `…profile` | Draft, validation, saved, read-only for other roles, stale revision |
| PP2 | Publication status panel | Owner, manager | `…profile` or `…go-live` | Each state in [02 §3](02-lifecycle-and-permissions.md); ineligible, with the reason |
| PP3 | Request publication, with attestation | Owner | Dialog | Ready, submitting, stale, ineligible |
| PP4 | Changes requested, rejected | Owner | Panel | Reason in plain language, next step |
| PP5 | Withdraw and republish | Owner | Dialog | Confirm, done, unchanged or changed snapshot |
| PP6 | Suspended, revoked notice | Owner | Panel | Reason, how to appeal; no republish control |
| PP7m | Mobile owner status | Owner | Later | Read-only first |
| PO1 | Publication review queue | Operator | `web.admin.*` new | Oldest first, empty, conflict of interest |
| PO2 | Review detail with draft-to-live diff | Operator | New | Approve, changes, reject, stale revision |
| PO3 | Suspend, reinstate, revoke | Operator | Dialog | Reason, confirmation, two-person if adopted |
| PO4 | Reports queue, gym target | Operator | Extends AD4 | Open, resolved, outcome |
| PC1 | Coach listing consent | Coach | Later | Request, accept, decline, withdraw |
| E05b | Replacement emails: approved, changes, suspended, withdrawn | Owner | Email | New copy, no Discover or payments claims |

Later, after their decisions: public listing (reconcile MK4 and L5) with empty and filter states, and the badge explanation.
