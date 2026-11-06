# 05 — Routes, API, search and cache

**Status: PROPOSED. Nothing here exists.** No route or endpoint is added by SF-139, and the
registry and OpenAPI contract are unchanged.

## 1. Route topology

### What is taken

| Path | Owner | Why it matters |
| --- | --- | --- |
| `/gyms` (web) | `web.gyms`, L4 "For gyms" marketing | The obvious listing URL is taken |
| `/gyms` (mobile) | `mobile.gyms`, MGC1 gym chooser, authenticated | A deep link here must stay the chooser |
| `/gym/:gymId/*` (mobile) | `mobile.gym._gym-id.*` | Member-context routes, UUIDs |
| `/gyms/:gymId/*` (mobile) | Staff workspace | Same |
| `/app/gyms/:gymId/*` (web) | Gym console | Same |
| `/marketplace` (web) | `web.marketplace`, L5, tagged examples | Could host a listing later |
| `/marketplace/gym/:gymId` (mobile) | MK5, FIGHTER required | Wrong key and wrong capability |
| `/discover`, `/app/discover` | Fighter discovery | People, not gyms |
| `/:anything` (root) | `[...rest]` catch-all, plus every site route | A root-level slug, as E05 shows, would collide forever |

### Proposed

| Surface | Route id (proposed) | Path | Access | Release |
| --- | --- | --- | --- | --- |
| Web public page | `web.gym-public` | `/g/:gymSlug` (under `/[locale]`) | Public | 1 |
| Mobile public page | `mobile.gym-public` | `/g/:gymSlug`, shared shell | Public | 1 or later |
| Web listing | `web.marketplace.gyms` | `/marketplace/gyms` | Public | Later |
| Mobile listing | `mobile.marketplace?type=gym` (existing) | Existing, capability reconsidered | Session | Later |
| Owner editor | `web.app.gyms._gym-id.profile` (existing placeholder) | Existing | GYM_WORKSPACE | 1 |
| Owner status | Same page, or `…settings.go-live` | Existing | GYM_WORKSPACE | 1 |
| Operator | New under `/admin/gyms/publication` | New | ADMIN, SF-110 | With SF-110 |

`/g/` matches the design's WG8 and WG10, has no registry collision (`/gym/` and `/gyms/` are
different prefixes), and is short for sharing. Reserve it in the registry only when the task
that builds it is approved. `MK5`'s `/marketplace/gym/:gymId` should be retired in that task:
it exposes an internal id and wrongly requires a FighterProfile.

## 2. Domain proposal

**Context:** `SimpleFit.Gyms.Publication`, inside the Gyms context (no new service). It calls
`Verification` and `Access` through their public functions. Nothing else writes its tables.

| Table | Purpose | Key rules |
| --- | --- | --- |
| `gym_public_profiles` | The editable draft, one per gym | `revision` bumped on each edit; validated like other gym text |
| `gym_public_profile_versions` | Immutable snapshots of what was requested | Append-only trigger; holds only allowlisted fields |
| `gym_publications` | Current state, one per gym | `status`, `revision`, `live_version_id`, `requested_version_id`; trigger enforces [transitions](02-lifecycle-and-permissions.md#4-transitions) |
| `gym_publication_events` | History | Append-only; actor, `operator_actor_id`, `operator_authority`, `operation_id`, reason, version |
| `gym_public_slugs` | Current and past slugs | Unique on lower-cased slug; past slugs stay reserved |
| `gym_public_listings` (later) | Coach consent | Later; cascades on staff end |
| `gym_abuse_reports` | Reports | Digest of reporter contact where possible; retention decision needed |

**Audit:** new `gym_audit_events` types: `publication_requested`, `_approved`,
`_changes_requested`, `_rejected`, `_withdrawn`, `_republished`, `_suspended`, `_reinstated`,
`_revoked`. Same transaction as the change. Ids and codes only.

**Eligibility** is one function and one SQL predicate, used by every public read, the sitemap,
the search query and the transition checks:

```
status = 'published'
AND live_version_id IS NOT NULL
AND gym setup_status = 'completed'
AND the gym is not closed                     -- needs a closure state
AND an active primary location in an allowed country
AND the current verification is approved
AND its approval has trusted attribution      -- not legacy, not local_fixture
AND reverification is not overdue
```

Unknown or unreadable means not eligible. The country allowlist is empty until approved.

## 3. API proposal

Conventions as elsewhere: `/api/v1`, `operation_id`, error envelope, explicit JSON views.

| Operation | Method and path | Auth | Notes |
| --- | --- | --- | --- |
| `getPublicGym` | `GET /api/v1/public/gyms/{slug}` | None | 200 or 404. Explicit view |
| `listPublicGyms` (later) | `GET /api/v1/public/gyms?country=&city=&cursor=` | None | Discoverable and eligible only |
| `reportPublicGym` | `POST /api/v1/public/gyms/{slug}/reports` | None | Rate limited; same answer whether or not found |
| `getGymPublicProfile` | `GET /api/v1/gyms/{gym_id}/public-profile` | Session | Draft, live snapshot, state, eligibility reasons |
| `updateGymPublicProfile` | `PATCH /api/v1/gyms/{gym_id}/public-profile` | Session | `expected_revision` |
| `requestGymPublication` | `POST /api/v1/gyms/{gym_id}/publication/request` | Session, owner | `expected_revision`, `client_request_id`, attestation version |
| `withdrawGymPublication` | `POST /api/v1/gyms/{gym_id}/publication/withdraw` | Session, owner | Idempotent |
| `republishGymPublication` | `POST /api/v1/gyms/{gym_id}/publication/republish` | Session, owner | Only an unchanged, still-valid snapshot |
| Operator operations | With SF-110 | Operator credential | Not designed here; no HTTP route before SF-110 |

| Case | Response |
| --- | --- |
| Public read of anything not eligible | **404**, indistinguishable from an unknown slug. `Cache-Control` per §5 |
| Staff without the permission | 403; stranger 404, as other gym routes |
| Stale revision | 409 with `publication_revision` |
| Ineligible request | 409 with a code the owner can act on |
| Already in that state | 200, same result (idempotent) |
| Rate limited | 429 |

**DTO test:** a contract test should assert the public response's exact key set, and that a
canary value in every never-public field never appears.

## 4. Search and discovery

* **No new infrastructure.** No search engine. Filtering by country and city with ordinary
  indexes covers a pilot; `pg_trgm` is a later, separate decision. Neither `pg_trgm`, `tsvector`
  nor PostGIS is in use today.
* **One query.** Listing, sitemap and detail use the eligibility predicate in SQL, on the
  server. No frontend-only hiding.
* **No separate projection table** until load requires it, because a stale copy is exactly
  how a suspended gym would leak.
* **Ordering:** neutral, and stated. No paid ordering without an ads decision.
* **Enumeration:** cursors and rate limits; no count of hidden gyms; no status in any response.

## 5. Cache

There is no CDN or cache layer today, and gym routes answer `no-store`.

| Layer | Rule |
| --- | --- |
| API, release 1 | `Cache-Control: no-store`, as now. Simple and correct |
| Next.js page | Dynamic rendering, no ISR, for release 1 |
| If a CDN is added | `s-maxage` no more than 60 s, with purge by slug on every state change, and no caching of 404s for long. Needs its own task and a test that a suspended page disappears within the stated bound |
| Mobile | Query cache cleared on session boundary, as now; revalidate on focus |
| Metadata | Link previews and social caches can't be recalled: state this in the owner's withdrawal copy |

The stated service level for removal should be measured, not assumed.

## 6. SEO

| Topic | Rule |
| --- | --- |
| Robots | The web app has no `robots.ts` or sitemap today. Add both in the SEO task |
| Release 1 | `noindex` on every public gym page until D-G11.8 is decided |
| After approval | Index only eligible gyms that consented. A page not eligible returns 404 |
| Sitemap | Generated from the eligibility query, excluding `noindex` gyms |
| Canonical | `/{locale}/g/{slug}`, with `hreflang`; one canonical per locale |
| Metadata | Built only from the live snapshot. No private field in `<title>`, JSON-LD or Open Graph |
| Structured data | None at first: `LocalBusiness` markup is a claim that needs review |
| Slug change | Rare. The old slug 301s to the new one only while eligible; a past slug is never given to another gym |
| 404 or 410 | 404 for everything, including withdrawn. A 410 would reveal that a gym once existed, for a modest deindexing benefit. Counsel can override this for takedowns |
| Removal | **Deindexing by external search engines is asynchronous and can't be guaranteed.** Stopping serving is immediate; for legal removals, an operator also uses the search engines' removal tools |
| Preview | The owner's preview is authenticated and `noindex`, never a public URL with a token |
