# SF-82 · 08 — Gym security and lifecycle threat model

**Status: ACCEPTED (ADR 0026) as requirements.** Controls are requirements for SF-83 onwards; each
needs a test in the ticket that introduces the surface.

| # | Threat | Example | Control |
| --- | --- | --- | --- |
| T1 | Cross-gym IDOR | `GET /gyms/A/members/{member of B}` | Every query filters by `gym_id` from the path **and** the resource; composite FKs `(gym_id, id)` so child rows cannot point at another gym's parent; 404 |
| T2 | Forged / enumerated gym id | Random UUIDs against `/gyms/{id}` | 404 for non-staff identical to unknown id; per-user rate limit on 404s logged as a metric, no PII |
| T3 | Privilege escalation | Manager makes self owner; coach edits timetable | `Gyms.Policy` matrix; owner role only through transfer; role changes re-check actor's role in the same transaction |
| T4 | Last-owner removal / orphan gym | Owner removes self, two transfers race | Partial unique index "one active owner per gym"; owner cannot leave; transfer locks the gym row |
| T5 | Stale permissions after revocation | Removed front desk keeps checking people in | Membership re-read per request inside the transaction (`FOR SHARE`); no role in tokens or client |
| T6 | Workspace switching confusion | Tab 1 acts on gym A while UI shows gym B | Gym id in every API path (`D-G15`) and every UI route (`D-G23`), so each tab names its gym; the shell renders the gym name from API responses |
| T7 | Concurrent bookings over capacity | 30 members book the last place | Occurrence row `FOR UPDATE`; count + insert in one transaction; unique `(occurrence_id, member_id)` |
| T8 | Duplicate gym creation | Double click, two tabs, retries | `client_request_id` unique per creator; one open draft per user (a second create returns it); rate limits 5/user and 20/IP digest per 24 h (`D-G25`); no ownership cap |
| T9 | Invitation replay / forwarding | Forwarded E06 accepted by another account | Hashed `sfs_` tokens only in the web fragment and request bodies, never in app routes (SF-80 rule; mobile uses a token-free inbox by verified email, `D-G22`), single use, 7-day expiry, bound to a **verified** email identity of the accepter (ADR 0021/SF-73 pattern); revocation; preview reveals only gym name, role, inviter first name |
| T10 | Member invitation / join-code abuse | Brute-forcing join codes | Codes ≥ 8 chars from a 32-symbol alphabet, per-IP + per-user limits (digests only), owner can rotate/disable; a code join creates a `requested` membership unless the gym explicitly enabled auto-approval, and never without a verified identity (`D-G08`) |
| T11 | Check-in pass replay | Screenshot of a member QR | Rotating pass token (short TTL, HMAC over member id + window), single check-in per occurrence, server-side verification only |
| T12 | Financial data access | Front desk reads revenue | No financial data exists in MVP; when it does, owner-only by default |
| T13 | Member privacy (training data) | Gym coach reads RPE via gym | No gym permission reads training data ([04](04-gym-vs-coaching-contract.md)); contract tests |
| T14 | Contact data over-exposure | Coach exports member emails | Email visible to owner/manager only (02 §4); no export in MVP |
| T15 | CSV import of third parties | Owner uploads 400 contacts | FUTURE (`D-G08`): needs legal basis, notice, deletion |
| T16 | Consent confusion | "Fighter notes (with consent)" assumed from membership | Separate future consent object (`D-G06`); never implied |
| T17 | Account deletion | Owner deletes account; member deletes account | Owner blocked until transfer/close; member/staff rows ended and personal fields removed per retention; bookings anonymised |
| T18 | Gym closure / retention | Closed gym keeps member data forever | FUTURE close flow with retention job (SF-100 follow-up) |
| T19 | Logging / PII | Member names in logs/Sentry | ADR 0008: log ids and codes only; invite emails as digests; tokens never logged |
| T20 | Multi-tab / stale writes | Two managers edit the same class | `lock_version` on `gym_classes`/`gyms` → 409 `stale` |
| T21 | Local bypass leak | Coaching bypass reused to fake gym verification | ADR 0025 not extended (`D-G17`); no gym "dev verified" flag |
| T22 | Mock payment granting entitlements | Dev flag marks a plan paid | No entitlement model until `D-G10`; then provider test mode only, production refuses fake adapters (ADR 0005) |

Audit: owner/manager actions on staff, roles, ownership and member status
are written to a `gym_audit_events` table (actor, action, target id, at;
no free text), visible to the owner (WG17 "audit" is FUTURE UI, the table
is MVP so history is not lost; `D-G18`).
