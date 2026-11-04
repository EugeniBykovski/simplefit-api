# SF-104 — Gym MVP release acceptance (SF-81 epic)

* Date: 2026-11-04. Ticket: SF-104 (23 of 23), epic SF-81.
* Branches: `SF-104-gym-e2e-hardening-release-acceptance` in simplefit-api,
  simplefit-platform and simplefit-mobile, from `origin/main` after the
  SF-103 merges. Committed locally; not pushed, merged or deployed.
* Nothing in this document authorizes a production release, live Stripe
  charges or public gym publishing.

## 1. Executive summary

Three verdicts, deliberately separate:

| Release | Verdict | Why |
| --- | --- | --- |
| A. Operational Gym MVP | **NO-GO** for general availability (CONDITIONAL GO only for an operator-assisted pilot, see §9) | Every backend-owned journey works end to end on real infrastructure, but **staff and members cannot join a gym through any client**: the staff invitation email (E06) links to `/invite/staff`, which returns 404, and no client offers joining by code or accepting a member invitation (F-01, F-02, P1) |
| B. Commercial payments | **NO-GO** | Real Stripe Test Mode is NOT VERIFIED (credentials expired 2026-03-09); prices are provisional drafts; tax/invoicing and Connect decisions are unapproved |
| C. Public gym publication | **NO-GO** | No approved public gym surface or publishing policy (D-G11 publishing half); verification review has no operator identity (review is fail-closed since SF-104) |

What passed: the full backend suite, every PostgreSQL race suite three times
in a row, migrations from zero, upgrade with data, repeat and full rollback
on disposable copies, contract parity, the platform and mobile quality gates,
and the real-backend web journeys for registration, setup, staff
administration, members, timetable (with DST), booking, roster check-in,
first run, billing (Stripe disabled), verification and go-live, plus a new
end-to-end release journey.

What failed or is missing: the recipient side of staff and member
enrollment (no UI), native iOS and Android acceptance (toolchain), real
Stripe Test Mode (credentials), and several real-API specs whose
assertions predated later tickets (fixed as test defects, §6).

## 2. Release scope matrix

| Capability | Classification |
| --- | --- |
| Account registration (email), Gym intent, gym draft, setup, workspace | REQUIRED FOR OPERATIONAL GYM MVP — verified |
| Google / Apple sign-in | REQUIRED — **NOT VERIFIED** (no provider test credentials; scripts blocked in E2E) |
| Staff administration (invite, roles, removal) by owner/manager | REQUIRED — verified (sending) |
| **Staff invitation acceptance by the recipient** | REQUIRED — **MISSING UI (F-01, P1)**; API verified |
| **Member join by code / member invitation acceptance** | REQUIRED — **MISSING UI (F-02, P1)**; API verified; member invitations gated off in production |
| Join requests, approval, rejection, auto-approval (staff side) | REQUIRED — verified |
| CSV member import | Preview: OPTIONAL / SUPPORTED, verified; commit: BLOCKED BY PRODUCT DECISION (D-G27), not reachable |
| Timetable, venues, templates, series, DST rules | REQUIRED — verified |
| Booking, roster, check-in, first-run checklist | REQUIRED — verified |
| Web ↔ mobile booking synchronization | REQUIRED — verified at API-client level (mobile JS client against the real API); native NOT VERIFIED |
| Native iOS app | REQUIRED for mobile — **NOT VERIFIED** (Expo SDK 57 needs Swift 6.2 / Xcode 26; host has Xcode 16.4) |
| Native Android app | **ANDROID NATIVE — NOT VERIFIED** (no SDK/emulator) |
| SimpleFit SaaS plans and Stripe billing | REQUIRED FOR COMMERCIAL RELEASE — **STRIPE TEST MODE — NOT VERIFIED**; disabled-mode path verified |
| Gym member products / member payments | REQUIRED FOR COMMERCIAL RELEASE — BLOCKED BY PRODUCT/LEGAL (D-G10 member payments) |
| Stripe Connect payouts | BLOCKED BY PRODUCT/LEGAL; disabled |
| Business verification | Owner flow verified; operator review BLOCKED (no operator identity), fail-closed |
| Community defaults | FUTURE (no enforcing domain); guarantees page only |
| Go-live readiness | OPTIONAL / SUPPORTED — verified (derived, read-only) |
| Publication | **BLOCKED BY PRODUCT / LEGAL POLICY** |

## 3. Baseline and dependency matrix

Tested baseline (`origin/main`): api `8fcdff2`, platform `f3e60f0`, mobile
`3fdd625`. SF-104 commits: api `a8d9883` (fix) and the docs commit, platform
(specs and the gym-id guard), mobile `8ee37f2` (registry parity).

Every ticket is merged (merge commit per repository it touched):

| Ticket | api | platform | mobile | Contract | Runtime |
| --- | --- | --- | --- | --- | --- |
| SF-82 ADR | `050e89f` | `fa2e2b8` | `12a8aa2` | docs | — |
| SF-83 tenant, RBAC | `933a145` | `d2ac51b` | `84559ae` | in OpenAPI | verified |
| SF-84 entry | `0b161d7` | `fa7fb30` | `4532b78` | in OpenAPI | verified |
| SF-85 setup API | `48f8e44` | `98b635f` | `890de61` | in OpenAPI | verified |
| SF-86 web registration | — | `2aa9055` | `521350b` | client | verified |
| SF-87 mobile registration | — | `3378306` | `4b0b5a2` | client | native NOT VERIFIED |
| SF-88 web shell | — | `7d467ac` | — | client | verified |
| SF-89 mobile shell | — | `2b59731` | `1abf837` | client | native NOT VERIFIED |
| SF-90 first run API | `44a4fd0` | `ff3620f` | `072b1b0` | in OpenAPI | verified |
| SF-91 web first run | — | `d046e0e` | `19713fb` | client | verified |
| SF-92 mobile first run | — | `1dc612a` | `f21e105` | client | native NOT VERIFIED |
| SF-93 staff API | `eda48ff` | `bdceed3` | `3f1e784` | in OpenAPI | verified (API); recipient UI missing (F-01) |
| SF-94 web staff | — | `9fe6cc5` | `91b78dd` | client | verified |
| SF-95 members API | `b0515af` | `5518b6e` | `788c29d` | in OpenAPI | verified (API); recipient UI missing (F-02) |
| SF-96 web members | — | `3f70c0a` | `22b03b1` | client | verified |
| SF-97 timetable API | `c8a4e72` | `a3375c3` | `00ae1f2` | in OpenAPI | verified |
| SF-98 web timetable | — | `8ff9d1f` | `05ca10a` | client | verified |
| SF-99 booking API | `6eb2f86` | `44e3d64` | `cb4e207` | in OpenAPI | verified |
| SF-100 booking UI | — | `6820442` | `9f665b2` | client | web verified; mobile JS verified, native NOT VERIFIED |
| SF-101 plans/entitlements | `c94115a` | `697da24` | `0ecdb59` | in OpenAPI | verified (domain) |
| SF-102 Stripe | `8a16bba` | `e02e4b0` | `65c5d09` | in OpenAPI | disabled mode verified; Test Mode NOT VERIFIED |
| SF-103 verification/go-live | `8fcdff2` | `f3e60f0` | `3fdd625` | in OpenAPI | verified; review fail-closed (SF-104) |

Parity: `openapi/simplefit.api.json` is byte-identical in all three repos
(sha256 `189b477259b4638a…`). The route registry differed in two SF-102
entries between web and mobile; fixed (mobile `8ee37f2`), now byte-identical.
Open PRs could not be listed (`gh` is not authenticated on this machine).
Claude Design: `1793198527-a0fc` (unchanged since SF-103).

## 4. Environment

* API: `simplefit-api` at the SF-104 branch, `MIX_ENV=dev`, port **4204**,
  database **`simple_fit_sf104_e2e`** (created and migrated from zero, 30
  migrations), test-only legal fixtures, member invitations off (as in
  production), Coach–Fighter sharing on with test disclosures, Stripe
  disabled, storage on a **local S3 emulator** (moto; private bucket, CORS
  for `http://127.0.0.1:3100`; it does not enforce SigV4 signatures),
  `GYM_VERIFICATION_OPERATORS=reviewer@trust.simplefit.test`, test email
  adapter (codes read with `mix e2e.email_code`).
* Web: production build (`next build`, `next start` on 3100) against 4204.
* The billing spec's documented prerequisite (a published plan) was created
  **in the disposable database only**: `mix billing.catalog
  seed-provisional` and `publish … --approval
  sf104-e2e-fixture-not-commercial --confirm-provisional`. This is not a
  commercial approval.
* Untouched: `localhost:3000`, `localhost:4000`, `simple_fit_dev` (still at
  `20261023090000`), every existing E2E database and backup.

## 5. Evidence

### 5.1 Layers 1–3 (static, domain, races)

| Gate | Result |
| --- | --- |
| API `mix test` (baseline main) | 1752 passed |
| API `mix test` (SF-104) | 1754 passed (2 new operator-authorization tests) |
| API `mix quality` | format, warnings, Credo strict, `openapi.check`, Dialyzer 0 |
| PostgreSQL race suites (170 tests: booking, members, staff, timetable, billing, verification, first run, entry, coaching) | 3 consecutive runs: 170/170 each |
| Platform lint, format, typecheck, unit (98 files), `api:check` | 1324 passed |
| Mobile `pnpm quality` | 1094 passed, 27 skipped; Expo Doctor 21/21; iOS and Android JS bundles exported |

Required races present and green: 20 members for one seat, 30 for five,
one key 20×, booking vs cancellation, vs class cancellation, vs series
cancellation, vs capacity reduction, vs member removal, vs session
revocation, duplicate check-in, check-in vs cancellation, check-in vs staff
revocation, plus the staff, member, timetable, billing and verification
races.

### 5.2 Migrations (disposable copies only)

| Check | Result |
| --- | --- |
| Fresh database from zero | 30 migrations, `20261110090000` |
| Upgrade from the SF-102 schema with data (copy of `simple_fit_sf102_upg_e2e`: 12 gyms, 33 staff, 30 members, 36 classes, 26 bookings, 4 check-ins, 2 SaaS subscriptions, 8 price versions, 1 training session, 1 Coach–Fighter relationship, 64 users) | 1 migration; every count unchanged |
| Repeat `ecto.migrate` | 0 migrations; counts unchanged |
| Full rollback of the 13 gym-era migrations on an empty schema, then up | 13 down, 13 up, back to `20261110090000` |

**Rollback safety.** The gym-era `down` migrations drop tables and delete
audit rows of the new types: they are **rollback-unsafe once live data
exists** (members, bookings, check-ins, financial rows, verification
evidence and history). Treat every gym-era migration as **forward-only in
production**; recover forward (§8).

### 5.3 Real-backend web journeys

See §6 for the run summary and §7 for the release journey.

## 6. Real-API suite (Layer 6)

Production web build against the API above; five projects (Chromium 1440,
Firefox 1280, WebKit 1920, mobile Chromium 412, mobile WebKit 390); most gym
journeys are serial, single-project (Chromium) suites, others repeat per
project. Logs: the SF-104 evidence directory (not committed).

| Run | Scope | Passed | Failed | Skipped | Did not run | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Whole real-API suite, specs as on `main` (only the verification spec adapted to F-03) | 131 | 36 | 53 | 20 | Every failure reproduced on the unchanged baseline specs: T-01, T-02, T-03, T-04, T-06 (SF-78, 20 failures), the billing prerequisite (no published plan), T-05 |
| 2 | Gym specs with T-01..T-05 fixed, billing with its plan, the new release journey | 49 | 10 | 81 | 10 | **Billing, member booking (all engines), verification, gym journey (Chromium/Firefox) green.** Remaining: T-02b (a second stale timetable assertion), T-03b (phone gym switcher), T-04 on WebKit (needed a bounded retry), one column name in the new journey |
| 3 | Fixed specs (partial: stopped at 42/135 on request) | 41 | 1 | — | — | **Release journey 7/7, SF-78 email link 11/11 in Chromium and Firefox (T-06 fixed), gym journey 4/4, timetable green.** The one failure was a race in the T-03b helper itself (fixed by a width-based check; **not re-run**) |

Not re-run after their last fix: gym-console on all projects (T-03b
helper), gym-journey J on WebKit (bounded retry), and the remaining
projects of run 3. These are test-harness fixes only; no product code was
involved.

Cross-client web ↔ mobile: the SF-100 handoff leg (web → mobile JS client
against the real API → web) was **not run** in SF-104 (time); SF-100's
evidence stands, and both clients use the same backend-owned state.

## 7. Release journey

`e2e/real-api/gym-release-journey.spec.ts` (new, SF-104), Chromium 1440,
**7/7 passed** (run 3):

1. New owner registers by email with Gym intent, completes the account,
   creates and sets up a gym (UI); signs out and in; reopens the same gym.
   DB: 1 gym, 1 active owner membership, 0 drafts.
2. Owner invites a coach (UI, staff page). The recipient opens
   `/en/invite/staff#token=…`: **no acceptance control, not-found page**
   (F-01 evidence). API-ASSISTED: the recipient accepts from the token-free
   inbox with their own session; the owner's session cannot take it
   (403/404); a replay creates nothing; one active staff membership; the
   coach's workspace loads; coach gets 403 on verification and inviting.
3. A member without any profile joins by code (API-ASSISTED, F-02); a
   second join creates nothing; the owner approves in the members UI. DB:
   one membership, no Fighter/Coach profile, no staff membership, no
   Coach–Fighter relationship created.
4. A class (API) → the member books in the UI ("Booking confirmed"), sees
   it in My bookings after a reload → the owner checks the member in from
   the roster dialog (UI; no email in the roster) → a second check-in via
   the API is the same arrival (1 row) → the first-run checklist returns
   all five milestones `completed`, in canonical order; staff get 403 on
   the owner's first run.
5. The coach (staff at A) creates and completes Gym B and joins Gym A as a
   member (201): two staff memberships, relationships unchanged. Two tabs
   show A and B independently. A stranger gets 404 on every Gym A endpoint
   (gym, staff, members, classes, go-live, verification, billing, first
   run); random and malformed ids are 404; the stranger's browser shows
   nothing of Gym A.
6. The owner removes the coach while the coach's page is open: the API
   answers 404, a reload shows nothing of Gym A, Gym B is untouched. The
   coach signs out and the member signs in in the same browser: nothing of
   Gym B is shown; the member's own gyms are.
7. The API log contains no bearer token and no address of the run.

## 8. Defect register

| Id | Sev | Finding | Status |
| --- | --- | --- | --- |
| F-01 | **P1** | No client lets a recipient accept a **staff invitation**. The E06 email links to `<web>/invite/staff#token=…`; the production build answers **404** for `/en/invite/staff` (also `/en/invite/gym`, `/en/join`; `/en/invite/coach` is 200 for comparison). The mobile `/invite/staff/:token` routes are placeholders. The SF-82 plan assigned the acceptance UI to SF-87; the actual SF-87 scope differed and SF-94 recorded it as "not in this ticket". Staff invitations are **not gated** in production, so real recipients would receive a dead link. | OPEN — needs a product decision: build the recipient UI (design OnbSInvite, OnbSInviteCode exist) or gate staff invitations off like member invitations until it exists |
| F-02 | **P1** | No client offers **joining a gym by code** or accepting a **member invitation** (`joinGym`, `previewGymJoin`, `acceptMyGymInvitation` have no consumer in web or mobile). Members can book in the UI but cannot become members in the UI. | OPEN — follow-up ticket (design JoinInvite exists) |
| F-03 | P1 (security) | `mix gyms.verification` accepted any email as the operator; anyone with shell access could act as any operator. | **FIXED** api `a8d9883`: operator allowlist `GYM_VERIFICATION_OPERATORS`, fail-closed without it; tests added. Residual: a shell user can claim another listed address — keep production review disabled until an operator identity exists |
| F-04 | P2 (contract parity) | Route registry differed between web and mobile (SF-102 entries). | **FIXED** mobile `8ee37f2` |
| F-05 | P3 (hardening) | The web used `gymId` from the URL in API paths unvalidated. | **FIXED** platform (UUID guard → not-found page), tests added |
| F-06 | P3 | Gym setup writes (`setup.ex` update / primary location / complete / discard) have no rate limit, unlike every other gym write. | OPEN — follow-up |
| F-07 | P3 | `cancelGymSaasSubscription` calls Stripe before the rate limit and session hold. | OPEN — follow-up (Stripe quota only; no state risk) |
| T-01 | test defect | `gym-member-booking.spec.ts` asserted that no table named like `subscription|entitlement` exists — written before SF-101/SF-102 added them. | **FIXED** (asserts no booking-created commercial row and no waitlist/credit/QR table) |
| T-02 | test defect | `gym-timetable.spec.ts` asserted the front desk sees no button on a class — written before SF-100 added the Roster button for roles that read rosters. | **FIXED** (asserts exactly `Roster`) |
| T-03 | test defect | `gym-console.spec.ts` signed out through the desktop sidebar only; on phone widths Sign out is in the navigation sheet. | **FIXED** |
| T-04 | test defect (timing) | `gym-journey.spec.ts` J navigated before the coach onboarding's own `?step=complete` navigation landed (WebKit). | **FIXED** (waits for that URL) |
| T-05 | test infra | `gym-verification.spec.ts` updated for F-03 (operator from `E2E_OPERATOR`; staff refused as `forbidden`). | **FIXED** |
| T-02b | test defect | `gym-timetable.spec.ts` asserted that no booking/check-in table exists — written before SF-99. | **FIXED** (no booking or check-in row for the gym) |
| T-03b | test defect | `gym-console.spec.ts` used the desktop-only gym switcher on phone projects. | **FIXED** (width-based shell helper; not re-run) |
| T-06 | test defect (environment) | `email-identity-link.spec.ts` (SF-78) wrote and compared naive UTC timestamps with the server-local `now()`; on a PostgreSQL server in CET every expiry/"since" was an hour off (20 failures across all projects). Passes where PostgreSQL runs in UTC. | **FIXED** (`now() AT TIME ZONE 'UTC'`); 22/22 in Chromium and Firefox |

No P0 was found. No cross-tenant exposure, capacity bypass, double booking,
duplicated attendance, forged payment or self-verification was observed.

## 9. Verdicts and conditions

**A. Operational Gym MVP — NO-GO** for general availability while F-01 and
F-02 are open: the core journey (owner → staff invitation → member
enrollment → class → booking → attendance) cannot be completed by staff and
members through the product. **CONDITIONAL GO for a closed pilot** only if
all of the following hold: staff invitations are gated off or recipients
are told not to use the emailed link; staff and members are onboarded by an
approved, audited assisted procedure (none exists today; the API operations
require the person's own session); native mobile is limited to builds
verified on Xcode 26 hardware; Google/Apple sign-in is verified with test
credentials or disabled.

**B. Commercial payments — NO-GO.** STRIPE TEST MODE — NOT VERIFIED. Live
mode, provisional prices, member payments, Connect payouts, tax and
invoicing stay disabled. Operational access is not gated on a SaaS
subscription (`enforced: false`), and that must stay so until a commercial
enforcement policy is approved.

**C. Public gym publication — NO-GO.** PUBLICATION — BLOCKED BY PRODUCT /
LEGAL POLICY. Verification review is disabled unless operators are listed;
keep it disabled in production until an operator identity exists.

## 10. Rollout (when the verdicts change)

* **Migration order:** chronological `20261026090000` → `20261110090000`;
  all forward-only in production. Take a backup immediately before; verify
  with a dry run on a restored copy (as in §5.2).
* **Configuration:** `GYM_MEMBER_INVITATIONS` (keep off until F-02),
  `GYM_VERIFICATION_OPERATORS` (keep unset), `STRIPE_BILLING_ENABLED`
  (false until Test Mode is verified and a release approval exists),
  `STRIPE_CONNECT_ENABLED` (false), `TRUSTED_PROXY_HOPS` (required),
  storage `AWS_*` (private bucket, CORS for the web origin, HTTPS endpoint),
  `WEB_APP_URL`, `CORS_ALLOWED_ORIGINS`, Resend for E06/E07.
* **Secrets readiness:** Stripe keys are not available (expired); storage
  and email credentials must be provisioned per environment.
* **Backward compatibility:** the SF-104 operator change makes `mix
  gyms.verification` require `--operator` on `list` and `show`.
* **Monitoring:** `[:simple_fit, :gyms, :access, :denied]` (cross-gym
  probing), rate-limit refusals, Oban failures (`VerificationCleanupWorker`,
  `SweepWorker`), Stripe webhook outcomes, `[:simple_fit, :gyms,
  :verification, :decided]`.
* **Forward recovery:** a faulty gym-era migration is corrected by a new
  forward migration; data is never restored by running `down` in
  production. Restore from the pre-deploy backup only as a last resort, with
  the loss window accepted explicitly.
* **Runbook:** staff invitation support (F-01 until fixed), verification
  review (disabled), Stripe incidents (`mix billing.stripe status`,
  `reconcile`).

## 11. Follow-up tasks (proposed Jira)

1. Staff invitation recipient UI (web `/invite/staff`, mobile inbox), or gate E06 until it exists (F-01).
2. Member join by code and member invitation recipient UI (F-02).
3. Platform operator identity and admin authorization for verification review (F-03 residual).
4. Rate limit gym setup writes (F-06); reorder SaaS cancel provider call (F-07).
5. Native iOS acceptance on Xcode 26 hardware; Android SDK/emulator acceptance; VoiceOver/TalkBack.
6. Real Stripe Test Mode end-to-end with fresh credentials.
7. Mobile booking history design and screen (API data exists).
8. Google/Apple sign-in E2E with provider test credentials.
