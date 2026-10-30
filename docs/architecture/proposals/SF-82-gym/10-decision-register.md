# SF-82 · 10 — Decision register

**Review status (final SF-82 approval, 2026-10-23).** The architecture is
approved. SF-83 is not started and needs its own start authorization.

* **APPROVED**: approved by the product owner.
* **OPEN**: awaiting a decision; nothing that depends on it may be built.
* **DEFERRED PRODUCT DECISION**: a business, legal or vendor decision. It is
  not an engineering fact; nothing that depends on it is designed further or
  built, and no stub or mock stands in for it.

## 1. Approved decisions

| ID | Decision | Binding details |
| --- | --- | --- |
| D-G01 | `gyms` is the tenant root, owned by `SimpleFit.Gyms` | No polymorphic `workspaces` table. No `gym_id`, role or type on `users` |
| D-G02 | A separate `gym_locations` table (address only), ≥ 1 per gym | The first UI manages one location. Rooms and opening hours are future |
| D-G03 | Fixed MVP roles: `owner`, `manager`, `coach`, `front_desk` | Authorization is one `Gyms.Policy` matrix in code. "Head coach" is a display title on a coach. Custom roles are future |
| D-G04 | One canonical owner per gym; ownership moves only by a safe, transactional transfer | Partial unique index "one active owner"; the transfer locks the gym row; the target is an existing active staff member and accepts within 7 days |
| D-G05 | A gym is created as a **draft** at the first valid onboarding submission, with idempotency and resume | `client_request_id`; `GET /me/gyms` resumes. Creation limits are `D-G25` |
| D-G06 | Gym permissions **never** imply access to a fighter's private training data | No gym role reads training logs, RPE, weight, notes, videos or messages. The only path is an ADR 0021 Coach–Fighter relationship. A future gym-scoped consent would be a separate decision |
| D-G07 | Gym membership does not require a FighterProfile; gym members and Coach–Fighter relationships are independent | Member-side routes move to account level |
| D-G08 | Request-based member enrollment | A join code creates a **request** that staff approve. Auto-approval only applies when the gym explicitly enables it in its configuration, and it **never bypasses identity verification**: the joiner must be signed in with a completed account and must have proved control of their sign-in identity (email code, or a verified Google/Apple identity). An E07 invitation is accepted only by an account holding a **verified** identity for the invited address. CSV import is future |
| D-G12 | Staff invitations expire after **7 days** | Single use, hashed `sfs_` tokens, bound to a verified email identity, revocable; resending rotates the token |
| D-G13 | Six canonical gym types | Validated against the design (OG1 `WebSetupGym`, canvas `1792675284-1046`). The design defines six **single-select display labels** and no machine values. The keys map 1:1: Boxing Gym → `boxing_gym`, Boxing Club → `boxing_club`, Amateur Club → `amateur_club`, Professional Team → `professional_team`, Combat Sports Gym → `combat_sports_gym`, Fitness Boxing Studio → `fitness_boxing_studio`. The OG1 preview line "Boxing · Fitness boxing" shows disciplines, which are future and not types |
| D-G14 | Gym classes and occurrences are separate from coach-assigned TrainingSessions | Shared `SimpleFit.Scheduling` time rules; ADR 0023's behaviour stays unchanged |
| D-G15 | Explicit path-scoped Gym APIs `/api/v1/gyms/{gym_id}/…`, with backend membership and permission checks on every request | The backend never infers a gym from a session or header |
| D-G16 | A canonical Gym staff-invitation domain, separate from Coach–Fighter invitations | No reuse of conflicting token routes. The SF-57/SF-80 `/invite/coach` link and its security stay unchanged |
| D-G18 | Audit events from the initial Gym domain (SF-83) | Append-only `gym_audit_events`: actor, action, target id, time; no free text |
| D-G20 | No automatic deletion of draft gyms until a retention policy is approved | Drafts are visible only to their owner; the owner may discard one; account deletion removes the user's drafts |
| D-G21 | Minimal required gym creation, followed by optional setup and a truthful first-run checklist | Required: name, type and one location (OG1, OG2). The 14 steps stay as a product journey; unavailable steps are "coming later" and never required |
| D-G22 | Native invitation entry is a token-free inbox matched by verified email | Web reads `#token=` once (SF-60 pattern). The app never receives a token (SF-80 rule). The same pattern applies to staff (E06) and member (E07) invitations |
| D-G23 | **ID-based Gym navigation** and explicit `gymId` authorization | Gym UI routes carry the gym id ([07 §3](07-routing.md)). This supersedes `D-WORKSPACE-NOT-IN-URL` for Gym. The id is never authorization: every request is checked by the backend |
| D-G24 | 403 for insufficient permissions **inside a gym the caller is authorized for**; outsiders never learn that a private gym exists | Non-staff, cross-gym and revoked access get 404. Active staff whose role lacks the permission get 403 `forbidden`, and the console shows a role-restriction state. This is an exception to route-architecture rule 9 for Gym |
| D-G26 | The sole owner's account cannot be deleted before a successful ownership transfer | Enforced inside account deletion, which asks `Gyms`. The account-deletion feature does not exist yet ([09 §3](09-dependency-matrix.md)) |

## 2. Deferred product decisions

| ID | Decision | What is blocked | Engineering position |
| --- | --- | --- | --- |
| D-G09 | Pricing, gym SaaS subscriptions, trials, SimpleFit billing, and any **commercial ownership limits** (e.g. gyms per plan) | OG4–OG6, OG6b trial copy, WG25, PR3, PR6m, L4 prices, plan tiles | No plan, price, trial or plan-based limit is stored or shown. Gym creation never depends on a plan |
| D-G10 | Payment provider and payment architecture (member commerce, payouts, refunds, dunning) | OG8, OG9, WG6, WG7, GC1–GC12, F16 renewals, credits | No provider is selected or stubbed. No mock payment grants an entitlement |
| D-G11 | Business verification (KYB) and public publishing policy | OG7, OG14, E05, Discover, MK4/MK5, "verified" badges | Gyms stay private. Nothing shows "verified" or "published" |

## 3. Remaining decisions

| ID | Full definition | Proposed choice | Alternatives | Recommendation |
| --- | --- | --- | --- | --- |
| D-G17 | **Local development for Gym.** Should the Gym domain get a local-development mode like ADR 0025 (SF-105, the LOCAL DEVELOPMENT coaching mode that bypasses unpublished legal documents)? | No Gym bypass. The Gym MVP has no legal, verification or payment gate, so it runs locally with the normal stack: Log email adapter, `mix e2e.email_code` and real draft/complete flows. ADR 0025 stays limited to coaching. Future gates (KYB, payments) use the provider's own sandbox and never a "verified" or "paid" flag in `simple_fit_dev` | B: extend ADR 0025's `LegalPolicy` bypass to Gyms; C: a separate Gym dev-mode flag that marks gyms verified or published | **Approve A.** B and C would create a second fail-open path with nothing to bypass today. Does not block SF-83 |
| D-G19 | **Member pass without commerce.** What F16 ("Membership pass") shows before gym commerce exists (`D-G10` deferred) | A non-commercial **member pass**: gym name, home location, member status (active / suspended) and a rotating, server-signed QR used for check-in (T11). No plan, renewal date, credits, visits-left or price. Route `mobile.membership` becomes account level (`D-G07`) | B: no pass until commerce exists, so check-in is manual only; C: show the designed plan card with placeholder values (violates invariant 4) | **Approve A.** It makes the approved check-in flow work without fabricated commerce and needs design change C9. Needed by SF-96/SF-97, not SF-83 |
| D-G25 | **Gym creation anti-abuse** (revised; the hard cap of three owned gyms was **not approved**) | Rate limits only, keyed by user and by a digest of the client IP, as in ADR 0012: at most **5 gym creations per user per 24 h** and **20 per IP digest per 24 h**, answered with 429 `rate_limited` and `Retry-After`. **One open draft per user** at a time: a second create returns the existing draft, which keeps resume unambiguous (it is not an ownership cap). No limit on the number of completed gyms owned | B: no limits; C: hard cap of owned gyms (rejected); D: plan-based ownership limits (deferred with `D-G09`) | **Approve the rate limits and the one-open-draft rule.** The values are configuration and can be tuned without a migration. Needed by SF-83 |
| D-G27 | **Member-list import commit, contact retention and lawful processing** (proposed by SF-95, **not approved**). Whether, and on what lawful basis, a gym may make SimpleFit store contact data of people who have no SimpleFit account (names, email addresses, phones, plans, start dates from a CSV), for how long, how those people are told and can object or have the data erased, who the controller and processor are, and whether bulk E07 invitations may be sent from such a list | Until approved, only the stateless dry run exists (`previewGymMemberImport`, SF-95): nothing from a list is stored, queued, audited or logged. **Blocked:** an import commit and its idempotency; "unclaimed contact" records; storing any list field other than transiently in the request; bulk or scheduled E07 sending from a list; any opt-out or suppression list fed by imports. A gym can still invite people one by one (E07, under the approved `D-G08`) | A: no import ever (invite one by one). B: commit creates only member invitations (the same data as a manual invite: a sealed address and digest), with per-gym daily caps, a retention limit for unaccepted invitations and an opt-out/suppression list. C: unclaimed contact records with names and plans (needs a DPA position, retention and erasure flows) | B, after legal review; C stays out of the MVP. The decision must name the lawful basis, the retention period for unaccepted invitations, the erasure path and the E07 opt-out wording. This ID does not change `D-G08`, whose approved meaning is request-based enrollment with explicit, verified-identity auto-approval |

## 4. Conflicts with approved documents

These need amendments in the implementing tickets. SF-82 changes none of
them.

| Document | Current text | Required change | Ticket |
| --- | --- | --- | --- |
| `route-architecture.md` §7 | Workspace paths carry no workspace id; the active workspace is "session context held by the backend session" (`D-WORKSPACE-NOT-IN-URL`) | For Gym: the id is in the UI path (`D-G23`) and in every API path (`D-G15`). The backend remembers only the last chosen gym for landing | SF-85 |
| `route-architecture.md` §8 rule 9 | 403 and 404 both render not found | Gym exception: 403 inside an authorized gym renders the role-restriction state (`D-G24`) | SF-85 |
| Route registry | Gym console routes are id-free (`/app/gym/**`, `/gym/**`) | Id-based console routes ([07 §3](07-routing.md)) | SF-85 |
| Route registry | Member gym routes require `FIGHTER`; mobile member paths `/gym/:gymId/**` | Account level (`D-G07`); member paths moved under `/me/gyms/:gymId` ([07 §5](07-routing.md)) | SF-91 |
| Route registry | `/invite/coach/:token` (INV2), `/invite/staff/:token`, `/invite/staff/:token/confirm` | Token-free entries (`D-G22`) | SF-87 |
| Claude Design | R1–R11 | Checklist in [12 §3](12-design-reconciliation-plan.md) | per screen |
