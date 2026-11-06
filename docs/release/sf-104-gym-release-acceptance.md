# SF-104 — Gym MVP release acceptance (SF-81 epic)

* Date: 2026-11-04. Ticket: SF-104 (23 of 23), epic SF-81.
* Branches: `SF-104-gym-e2e-hardening-release-acceptance` in simplefit-api,
  simplefit-platform and simplefit-mobile, from `origin/main` after the
  SF-103 merges. Committed locally; not pushed, merged or deployed.
* **Re-assessed by SF-137 on 2026-11-06** on `main` after SF-133..SF-136 (base:
  api `dc7c9c4`, platform `704bb1a`, mobile `83ef85a`). §1, §2, §7, §8, §9, §10,
  §11 and §12 are current. §3..§6 are the original SF-104 record, kept as history.
* Nothing in this document authorizes a production release, live Stripe
  charges or public gym publishing.
* Status words: **PASS** (executed, and the outcome was observed), **FAIL**
  (executed, and it was wrong), **BLOCKED** (cannot run without an outside
  credential or decision), **NOT VERIFIED** (not executed, whatever the cause).

## 1. Executive summary

Three verdicts, deliberately separate. An Operational verdict implies nothing
about payments or publication.

| Release | Verdict | Why |
| --- | --- | --- |
| A. Operational Gym MVP | **CONDITIONAL GO** for a closed pilot, only under the restrictions in §9 and once the product owner accepts them. **NO-GO** for general availability | F-01 and F-02 are fixed: staff and members now complete the whole journey through the product. No P0 or P1 is open. Android, Google/Apple, a release-signed iOS build, real email and real storage remain NOT VERIFIED |
| B. Commercial Payments | **NO-GO** (**BLOCKED**) | No valid Stripe credentials (expired 2026-03-09), so no sandbox evidence exists. Prices, tax/invoicing and legal terms are unapproved |
| C. Public Gym Publication | **NO-GO** (**BLOCKED**) | Verification review is disabled at compile time until SF-110 (SF-136). No approved publishing policy, legal review or public gym page |

SF-137 fixed one defect in the product (F-08, P2) and test defects only
otherwise. Details and counts are in §12.

## 2. Release scope matrix

| Capability | Classification |
| --- | --- |
| Account registration (email), Gym intent, gym draft, setup, workspace | REQUIRED FOR OPERATIONAL GYM MVP — verified |
| Google / Apple sign-in | REQUIRED only if enabled — **NOT VERIFIED** (no provider test credentials). Recommend leaving both off for the pilot, §9 |
| Staff administration (invite, roles, removal) by owner/manager | REQUIRED — verified (sending) |
| **Staff invitation acceptance by the recipient** | REQUIRED — **PASS on web** in 5 browser configurations (SF-133). Mobile staff acceptance NOT VERIFIED |
| **Member join by code / member invitation acceptance** | REQUIRED — **PASS** on web (SF-134) and native iOS (SF-135). E07 stays gated off in production; turning it on is a separate decision |
| Join requests, approval, rejection, auto-approval (staff side) | REQUIRED — verified |
| CSV member import | Preview: OPTIONAL / SUPPORTED, verified; commit: BLOCKED BY PRODUCT DECISION (D-G27), not reachable |
| Timetable, venues, templates, series, DST rules | REQUIRED — verified |
| Booking, roster, check-in, first-run checklist | REQUIRED — verified |
| Web ↔ mobile synchronization | REQUIRED — **PASS** on native iOS against the real API in both directions (§12.4). Android NOT VERIFIED |
| Native iOS app | REQUIRED for mobile — **PASS** on a dev build on an iPhone 16 simulator (iOS 18.5, dark, default text). Release-signed build, physical device, other sizes and VoiceOver NOT VERIFIED |
| Native Android app | **ANDROID NATIVE — NOT VERIFIED** (no SDK/emulator) |
| SimpleFit SaaS plans and Stripe billing | REQUIRED FOR COMMERCIAL RELEASE — real Stripe Test Mode **BLOCKED**; disabled mode and placeholder test mode refuse before any Stripe call: PASS |
| Gym member products / member payments | REQUIRED FOR COMMERCIAL RELEASE — BLOCKED BY PRODUCT/LEGAL (D-G10 member payments) |
| Stripe Connect payouts | BLOCKED BY PRODUCT/LEGAL; disabled |
| Business verification | Owner flow PASS; operator review **BLOCKED** until SF-110, disabled at compile time (SF-136) |
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

`e2e/real-api/gym-release-journey.spec.ts`, Chromium 1440, **7/7 PASS** in
SF-137. SF-137 removed its API-assisted steps. Every step below is the product
UI unless stated; the emailed link comes from the queued email, and the database
is read only to check results.

1. A new owner registers with Gym intent, completes the account, creates and
   sets up a gym, signs out and in, and reopens the same gym.
2. The owner invites a coach; the coach registers, opens the emailed link and
   accepts on the page. Opening it again says already accepted. The owner's
   roster shows the coach.
3. The owner turns the join code on; a member with no profile joins by code
   twice and gets one request; the owner approves. No Fighter profile, Coach
   profile or Coach–Fighter relationship appears.
4. The owner creates the venue, template and class. The member books and sees it
   after a reload; the owner checks them in from the roster. A repeat check-in
   through the API is the same arrival (1 row). First-run shows all milestones.
5. A coach with a Gym B who is a member of Gym A keeps both contexts in two tabs;
   a stranger gets 404 on every Gym A endpoint.
6. The owner removes the coach with their page open: access ends, Gym B is
   untouched; after an account switch nothing of the previous user is shown.
7. The API log holds no token, code or address of the run.

The journey is single-project by design; the recipient journeys
(`gym-staff-invitation`, `gym-member-join`) run on all five configurations.

## 8. Defect register

| Id | Sev | Finding | Status |
| --- | --- | --- | --- |
| F-01 | **P1** | No client lets a recipient accept a **staff invitation**. The E06 email links to `<web>/invite/staff#token=…`; the production build answers **404** for `/en/invite/staff` (also `/en/invite/gym`, `/en/join`; `/en/invite/coach` is 200 for comparison). The mobile `/invite/staff/:token` routes are placeholders. The SF-82 plan assigned the acceptance UI to SF-87; the actual SF-87 scope differed and SF-94 recorded it as "not in this ticket". Staff invitations are **not gated** in production, so real recipients would receive a dead link. | **FIXED** by SF-133; PASS in 5 browser configurations in SF-137 |
| F-02 | **P1** | No client offers **joining a gym by code** or accepting a **member invitation** (`joinGym`, `previewGymJoin`, `acceptMyGymInvitation` have no consumer in web or mobile). Members can book in the UI but cannot become members in the UI. | **FIXED** by SF-134 (web) and SF-135 (mobile); PASS in SF-137 |
| F-03 | P1 (security) | `mix gyms.verification` accepted any email as the operator; anyone with shell access could act as any operator. | **FIXED** api `a8d9883`: operator allowlist `GYM_VERIFICATION_OPERATORS`, fail-closed without it; tests added. Residual: a shell user can claim another listed address — keep production review disabled until an operator identity exists. **SF-136 closes the impersonation: production review is disabled at compile time, with no configuration to enable it; review needs SF-110** (ADR 0026, SF-136) |
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
| F-08 | P2 | SF-137. After verifying an email in place, the screen says invitations sent to it now appear, but the gym inbox was not re-read: on iOS it stayed empty until relaunch (native C3, attempt 1). Web has the same gap in the code. Cause: `useEmailIdentityLink` did not invalidate `gymBookingKey`. | **FIXED** mobile `d4c7f3f`, platform `d9e08f2`. Each new test fails without the fix. Mobile: native C3 PASS. Web: unit test, build and geometry only; the real-API web suites were not re-run after this fix |
| T-07 | test defect (timing) | SF-137. `gym-journey.spec.ts` J: the WebKit navigation retry covered the first completion step, not the second. | **FIXED** platform `7e04af4`; gym-journey 4/4 on WebKit |
| T-08 | test defect (stale) | SF-137. The release journey still used API-assisted steps from before SF-133/SF-134. | **FIXED** platform `7e04af4` |

**Open P0: none. Open P1: none.** Open: F-06 and F-07 (P3). No cross-tenant
exposure, capacity bypass, double booking, duplicated attendance, forged payment
or self-verification was observed. This covers what was executed; see §9 for
what was not.

## 9. Verdicts and conditions

### A. Operational Gym MVP — CONDITIONAL GO (closed pilot); NO-GO for general availability

* **Implemented and PASS:** owner registration, gym setup, staff invitation and
  acceptance, member join by code, approval, timetable, booking, check-in,
  web ↔ iOS sync, multi-gym, account switching, tenant isolation.
* **Excluded:** payments, publication, CSV import commit, member invitations
  (E07) in production, mobile staff and owner operations.
* **Open defects:** P0 none, P1 none. P2 none open. P3: F-06, F-07.
* **Native QA:** iOS PASS on one simulator configuration with a dev build;
  Android NOT VERIFIED.

The GO holds only while all of these hold, each enforced as shown:

| # | Restriction | Enforced by |
| --- | --- | --- |
| 1 | Closed pilot: named gyms only, no public signup campaign | Product owner's list |
| 2 | Owners and staff work on the web; mobile is for members | Pilot instructions. Mobile staff acceptance is NOT VERIFIED |
| 3 | No Android distribution | Do not submit an Android build |
| 4 | iOS through TestFlight only, after the release-signed smoke below | TestFlight access list |
| 5 | Email-code sign-in only | Google off by empty client IDs; `APPLE_SIGN_IN_CLIENT_IDS` and `GOOGLE_OAUTH_CLIENT_IDS` empty on the API. **Open:** the iOS login screen still shows an Apple button in this configuration, and no mobile switch for it was found. Tapping it is NOT VERIFIED; resolve it before the pilot |
| 6 | Member invitations stay off | `GYM_MEMBER_INVITATIONS` off. Members join by code |
| 7 | No payments | `STRIPE_BILLING_ENABLED=false`, `STRIPE_CONNECT_ENABLED=false` |
| 8 | No publication | Review disabled at compile time (SF-136) |

Required before the first pilot gym, none of which SF-137 did:

1. Product owner accepts this table.
2. Release-signed iOS smoke on a physical device: sign in, join by code, book,
   cancel, sign out.
3. Pilot environment smoke with real Resend delivery (E06, sign-in codes) and
   real S3 storage; every SF-137 run used a test email adapter and an S3 emulator.
4. A database backup and a restore check before the migration.

No assisted onboarding procedure is proposed or needed: staff and members use
the product's own flows. Support follows §10.

### B. Commercial Payments — NO-GO (BLOCKED)

* **Implemented:** plan catalog, plan page, webhooks, Stripe boundary.
* **PASS:** with billing disabled, and with placeholder test credentials, the
  plan page refuses before any Stripe call; webhooks verify the raw body and
  signature and record one event; a manager and a stranger are refused. 0
  `stripe_checkouts`, 0 `stripe_customers`.
* **BLOCKED:** real Test Mode checkout, subscription lifecycle, refund and failure
  reconciliation. Stripe CLI test and live keys expired 2026-03-09; live keys were
  not used.
* **Awaiting approval or decision:** pricing (the catalog is provisional; the
  SF-137 publish was on a disposable database, reference
  `sf137-disposable-fixture-not-a-pricing-approval`, and is not an approval), tax
  and invoicing, legal terms, member payments, Connect.
* **Rollout prerequisites:** fresh test credentials, sandbox evidence for the
  whole lifecycle, then the approvals above.

### C. Public Gym Publication — NO-GO (BLOCKED)

* **Implemented:** owner verification submission, go-live readiness (derived,
  read-only), tenant isolation.
* **Excluded:** a public gym page; no such surface was tested.
* **BLOCKED:** trusted operator identity and review (SF-110), business verification
  review, publishing policy, legal review.
* SF-136's restriction was kept: `gym_verification` race suite 11/11, review
  refused in production builds, no allowlist or CLI argument added.

## 10. Rollout (when the verdicts change)

* **Migration order:** chronological `20261026090000` → `20261112090000`;
  all forward-only in production. SF-137 ran no `down` migration; `20261112090000`
  (SF-136) is refused on rollback once new attribution exists. Take a backup immediately before; verify
  with a dry run on a restored copy (as in §5.2).
* **Configuration:** `GYM_MEMBER_INVITATIONS` (keep off; F-02 is fixed, but enabling E07 is a separate decision),
  (`GYM_VERIFICATION_OPERATORS` is removed by SF-136 and does nothing), `STRIPE_BILLING_ENABLED`
  (false until Test Mode is verified and a release approval exists),
  `STRIPE_CONNECT_ENABLED` (false), `TRUSTED_PROXY_HOPS` (required),
  storage `AWS_*` (private bucket, CORS for the web origin, HTTPS endpoint),
  `WEB_APP_URL`, `CORS_ALLOWED_ORIGINS`, Resend for E06/E07.
* **Secrets readiness:** Stripe keys are not available (expired); storage
  and email credentials must be provisioned per environment.
* **Backward compatibility:** SF-136 removes `--operator`; `mix
  gyms.verification` refuses every command in a production build.
* **Monitoring:** `[:simple_fit, :gyms, :access, :denied]` (cross-gym
  probing), rate-limit refusals, Oban failures (`VerificationCleanupWorker`,
  `SweepWorker`), Stripe webhook outcomes, `[:simple_fit, :gyms,
  :verification, :decided]`.
* **Forward recovery:** a faulty gym-era migration is corrected by a new
  forward migration; data is never restored by running `down` in
  production. Restore from the pre-deploy backup only as a last resort, with
  the loss window accepted explicitly.
* **Runbook:** staff invitation support (resend or re-invite from the staff page), verification
  review (disabled), Stripe incidents (`mix billing.stripe status`,
  `reconcile`).

## 11. Follow-up tasks (proposed Jira)

1. Android SDK/emulator acceptance; VoiceOver and TalkBack.
2. Release-signed iOS smoke on a physical device; native small, large, light and
   AX5 pass; native RU/PL.
3. Resolve the Apple button shown when Apple sign-in is off; Google/Apple E2E with
   provider test credentials if they are to be enabled.
4. Real Stripe Test Mode end-to-end with fresh credentials.
5. Platform operator identity for verification review (SF-110).
6. Rate limit gym setup writes (F-06); reorder SaaS cancel provider call (F-07).
7. Native check of the Decline confirmation; distinct accessibility labels would
   make it testable.
8. Re-run `gym-member-join` on web with the F-08 fix.

## 12. SF-137 evidence (2026-11-06)

**Environment.** API `MIX_ENV=dev` on port 4209, database
`simple_fit_sf137_e2e`, test-only legal fixtures, test email adapter, S3 emulator
(moto); production web build on 3100; Metro on 8109 with the SF-87 dev client.
Untouched: `simple_fit_dev`, staging, production. Raw logs and screenshots stay
outside the repositories (`.worktrees/sf-137/evidence/`).

### 12.1 Quality gates

| Gate | Result |
| --- | --- |
| API `mix test` (code unchanged from `dc7c9c4`) | PASS, 1797 passed |
| API `mix quality`, format, Redocly | PASS |
| API race suites | PASS: verification 11, bookings 13, members 10, staff 12, gyms 14, entry 6, first run 9, setup 13, timetable 12 |
| Platform lint, format, typecheck, `api:check`, build | PASS |
| Platform unit | PASS, 104 files, 1390 passed |
| Platform geometry (targeted, once; not the full suite) | PASS: `production` gym and verify-invited specs 203; `sf133-*` and `sf134-*` 416 |
| Mobile `pnpm quality` (with Expo Doctor and iOS/Android JS export) | PASS, 1143 passed, 27 skipped; Doctor 21/21 |
| Contract parity | PASS: OpenAPI identical in all three repositories; route registry identical on web and mobile |

A JavaScript export is not native evidence and is not counted as such.

### 12.2 Real-API web suites

Each complete suite ran once, on the code before F-08; failures were re-run in
isolation.

| Run | Passed | Failed | Skipped | Did not run | Notes |
| --- | --- | --- | --- | --- | --- |
| All specs, Chromium | 50 | 1 | 2 | 3 | Failure and did-not-run: gym-billing, no published plan, **a setup omission of this run**. Skipped: SF-78 Journey 7 (needs sharing off), the mobile handoff leg of gym-member-booking (replaced by native D) |
| gym-billing, disabled, isolated | 4 | 0 | 0 | 0 | |
| gym-billing, placeholder test mode, isolated | 4 | 0 | 0 | 0 | No Stripe call |
| gym-journey and gym-console, WebKit | 7 | 1 | 0 | 0 | Failure: J, T-07 |
| gym-journey, WebKit, isolated after T-07 | 4 | 0 | 0 | 0 | |
| Release journey, staff and member recipients: Firefox, WebKit, mobile Chromium, mobile WebKit | 8 | 0 | 28 | 0 | Skips: the release journey is Chromium-only by design |
| gym-members, invitations off, Chromium | 1 | 0 | 0 | 0 | |

Unresolved flakes: none in the web suites.

### 12.3 Coverage by area

| Area | Status | Evidence |
| --- | --- | --- |
| Owner journey, persistence, sign out and in | PASS | Release journey 1 |
| Staff positive and negatives (foreign identity, expired, revoked, replay, malformed, sign-out, account switch, wrong gym) | PASS | `gym-staff-invitation` A–T, 5 configurations |
| Member web, code and invitation, negatives | PASS | `gym-member-join`, 5 configurations; no profile or relationship created |
| Timetable: venue, template, one-time, series, conflicts, cancel, unauthorized | PASS | `gym-timetable`, API timetable suites |
| DST: Warsaw spring gap, autumn repeat, across DST, invalid time, explicit offset, series skips | PASS at API level | `gym_timetable_test.exs`; not re-driven in a browser |
| Booking and check-in, one attendance event, idempotency, races | PASS | Release journey 4, `gym-member-booking`, race suites |
| Cancel after start | PASS native | Journey D, attempt 2: "This class has started. Your booking can't be cancelled any more." |
| Security: tenant, roles, revocation, replay, account switch, roster privacy | PASS | Release journey 5–7, `gym-console`, `gym-staff` |
| Token secrecy | PASS | No session or invitation token pattern in `api.log` or `metro.log` |
| First run | PASS | `gym-first-run`, API suite |
| Stripe, publication | BLOCKED | §9 |
| Web accessibility: keyboard, focus, dialogs | PASS within the geometry and recipient specs | No screen reader |
| VoiceOver, TalkBack | NOT VERIFIED | Accessibility tree audit only: its one finding is the dev build's own gear button |
| RU, PL and other locales | NOT VERIFIED at runtime | Message parity gates only; native ran in English |
| Google, Apple | NOT VERIFIED | Not enabled in this build |

### 12.4 Native iOS (iPhone 16 simulator, iOS 18.5, dev client, dark, default text)

Real API and database, codes read from queued emails, web legs in a production
browser build, database checks after each step.

| Journey | Result | Attempts |
| --- | --- | --- |
| A Sign up, wrong code, join by code, cancel sheet, web approval, relaunch, book, visible on web | PASS | 1; repeated on a new fixture |
| B Auto-approval, active at once, book | PASS | 1 |
| C E07 link signed out, signup, inbox, keep, accept, book; opening accepts nothing | PASS | 1 |
| C3 Other primary email verified in place, same user, no merge, accept | PASS | 2. Attempt 1 found F-08 |
| D Cancel on mobile → web; book on web → mobile; cancel again | PASS | 3. Attempt 1: wrong account on the device (run order). Attempt 2: the fixture class had started, and the app refused correctly |
| E Two gyms, separate classes, leaving one keeps the other | PASS | 3. Same causes as D |
| F Rotated code, another's link warm and cold, invalid link, foreign gym, sign out, gate, next account sees nothing, invitation states, ended session | PASS, except one step | 2. Attempt 1: wrong account, and the driver limit below |
| G Web join, approval, booking and check-in, each seen on mobile after a cold relaunch; one attendance event | PASS | 1 |
| M Existing account signs in; memberships restored | PASS | 1 |

**Native gaps (NOT VERIFIED):**

* **Decline confirmation:** the sheet opens and Keep works, but its Decline shares
  a label with the row's button behind it and the driver cannot separate them.
  This is an automation limit, not an application failure. Decline PASS on web and
  in mobile unit tests.
* Android: no SDK or emulator on this host.
* Release-signed build; physical device; real push or OS-level link handling
  beyond `simctl` URLs.
* 375 and 430 widths, light mode, AX5 in this cycle.
* Mobile owner and staff surfaces; the Fighter → Coach → Gym switch on native.

One run took about 80 minutes of wall time (C3's end to M's end, 11:29–12:49)
with no failure; the cause was not investigated. It is why D's fixture expired.

### 12.5 Migrations (disposable databases only)

| Check | Result |
| --- | --- |
| Fresh | PASS, 31 migrated, `20261112090000` |
| Repeat | PASS, 0 |
| Upgrade: copy of a populated pre-SF-136 database | PASS, 30 → 31 |
| Row counts before and after | Unchanged: 22 users, 8 gyms, 8 staff, 11 members, 8 classes, 7 bookings, 8 member invitations; 0 verification rows and 0 staff invitations, so those tables had no data to carry |
| Duplicate current members, active staff, confirmed bookings | 0 each |
| `gym_verification_events_trusted_actor` | Present and `NOT VALID` on purpose (SF-136: it must not re-evaluate history) |
| `down` | NOT VERIFIED in SF-137, deliberately. Treat as forward-only |
