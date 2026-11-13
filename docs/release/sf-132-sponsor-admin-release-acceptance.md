# SF-132 — Sponsor & Founder Admin release acceptance

Date: 2026-11-13. Epic SF-106. Integration candidate: `origin/main` of each repository (SF-107–SF-131 all
merged): simplefit-api `4f40121`, simplefit-platform `40d023d`, simplefit-mobile `c95a4a5`. Hardening fixes on
`SF-132-sponsor-admin-release-acceptance` (api `6ea4c7e`; platform `1aace75`, `b12de22`); not pushed.

## Verdicts

| Release area | Decision | Blocking evidence |
| --- | --- | --- |
| Sponsor Application / Workspace | **Technically accepted; production NO-GO** | No P0/P1 open. Production blocked by policy: the sponsor declaration is unpublished (counsel), D-SA13 operator bootstrap PROPOSED, D-SA14 and D-SA22 BLOCKED (no second operator or staffed review), D-SA05/D-SA09/D-SA11 NEEDS DECISION |
| Sponsor Partnership Requests | **Technically accepted; production NO-GO** | Depends on approved organizations (above) and on design approval of the interim pages (D-SF131-PARTNERSHIP-BOARDS) |
| Founder Admin | **Technically accepted; production NO-GO** | D-SA13 PROPOSED (production bootstrap NO-GO), D-SA14 BLOCKED, D-SA28 NEEDS DECISION |
| Commerce / Stripe Live | **NO-GO** | No commercial domain, Stripe Live NO-GO (SF-138), refunds and every financial write BLOCKED (D-SA34), D-SA23 PROPOSED |
| Public Opportunities / Marketplace | **NO-GO** | D-SA21: no inventory exists by decision; nothing to publish |
| Mobile affected contracts | **GO** (contracts only) | Generated client matches the API artifact; `pnpm quality` 21/21; no mobile Sponsor/Admin surface by decision |

## Defects found and fixed

| ID | Sev | Domain | Finding | Fix | Regression |
| --- | --- | --- | --- | --- | --- |
| SF132-1 | P1 | Web security | No security headers: the signed-in Control Plane and partner portal could be framed (clickjacking; a frame can be delegated WebAuthn) | platform `1aace75`: CSP `frame-ancestors 'none'`, `X-Frame-Options: DENY`, nosniff, referrer policy, HSTS | `e2e/production/security-headers.spec.ts` (headers on 6 pages, a real framing attempt) |
| SF132-2 | P1 | Founder Admin | SF-130's five permissions made the add-operator dialog taller than 900 px; its submit was unreachable (real operator journey timed out) | platform `b12de22`: operator dialogs scroll | Storybook check at 1280×560; real `control-plane-operators` journey passes |
| SF132-3 | P2 | Evidence | Operator document download checked only the applicant, not organization members (party rule) | api `6ea4c7e` | `sponsor_application_decisions_test.exs` (fails without the fix) |
| SF132-4 | P2 | Proposals | Accept/claim didn't lock the organization; could race a suspension | api `6ea4c7e`: organization share-locked before the proposal | race test, 5 rounds × 3 runs (window not reproduced without the fix; fix from lock analysis) |
| SF132-5 | P2 | History | Refused writes inserted unlimited append-only history rows | api `6ea4c7e`: 300/user/hour | `sponsor_partnerships_test.exs` |
| SF132-6 | P2 | Web | Many Control Plane pages lacked `noindex` | platform `1aace75` | production spec |
| SF132-7 | P2 | Test | SF-131 real spec called the API before the key check completed (flaky) | platform `b12de22` | journey passes |

Deferred P2 (documented, not fixed): submitted evidence can be re-uploaded to its key until the presigned PUT
expires (no content hash at submission); refusal-history cap is per user, not per organization.

## Evidence

Real Phoenix + PostgreSQL + Next.js production build, a fresh disposable `*_e2e` database per spec, S3 stand-in
(no signature checks), virtual WebAuthn keys (no bypass): `sponsor-application`, `sponsor-portal`,
`sponsor-portal-settings`, `sponsor-first-run` (5 browser projects each; with the SF-117 standalone HTTP leg),
`sponsor-partnerships`, and all ten `control-plane*` journeys passed; the SF-116 standalone HTTP review leg passed.
API logs of every run hold no signed URL, token or code. Gates: api 2228 tests, `mix quality`, Redocly, no OpenAPI
drift; platform 1608 tests, `pnpm quality`, Storybook build, Playwright geometry 3482 (22 provider-ID failures of
a build without the CI placeholders passed on the CI-equivalent build); mobile `pnpm quality`. Migrations: fresh,
upgrade from the pre-SF-130 schema, rollback and re-apply, and the SF-130 rollback refused with data present.
