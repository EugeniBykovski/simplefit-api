# SF-82 · 05 — Scheduling boundary and commercial architecture

**Status: ACCEPTED (ADR 0026; `D-G14` approved; `D-G09`–`D-G11` deferred; `D-G17` open).** See the [package index](README.md).

## 1. Private training vs group classes (`D-G14`)

| | ADR 0023 TrainingSession | Gym class occurrence |
| --- | --- | --- |
| Who | one coach ↔ one fighter of an **active relationship** | a gym, many members |
| Created by | the coach (relationship-scoped) | owner/manager (gym-scoped) |
| Visibility | coach and that fighter only | gym staff; members of that gym |
| Participation | assignment (the fighter does not book) | booking with capacity and waitlist |
| Completion | the fighter marks it completed (SF-63) | attendance = check-in recorded by staff |
| Training data | lives with the fighter (logs later) | none; attendance only |
| Ends with | relationship end (future planned sessions cancelled) | class archived / occurrence cancelled / gym closed |

**Decision: gym classes are not TrainingSessions.** Making each class a
batch of ADR 0023 sessions would require a relationship per member (forbidden
by [04](04-gym-vs-coaching-contract.md)) and would put many-person capacity
logic into a one-to-one model.

**Reuse without coupling.** The time rules of ADR 0023 (RFC 3339 instants
with explicit offset, PostgreSQL-validated IANA zone, gap rejected, overlap
chosen by offset, UTC storage, no Elixir tz database) are extracted into a
small shared module, `SimpleFit.Scheduling` (zone validation + instant/offset
check + local-time expansion for weekly recurrence), owned by neither
domain and introduced by SF-92 together with its first second consumer. ADR
0023's behaviour must stay identical (its tests are the regression suite).

**Recurrence.** MVP: `none` or `weekly` (one weekday + local start time),
materialized into occurrences for a rolling 8-week window by an idempotent
Oban job and on every class edit. Weekly local times are expanded in the
class's zone, so 18:00 stays 18:00 across DST; occurrences falling into a
spring-forward gap are skipped and reported (not silently shifted). RRULE,
exceptions calendars and multi-day patterns are FUTURE.

**Future domains.** Fight camps and sparring (open sparring WG12/WG27, member
pairing) are separate future domains. Open sparring at a gym will be a gym
occurrence type with approval; sparring between relationship parties stays on
the coaching side. Neither is designed here beyond this boundary.

## 2. Five commercial concepts that must not be confused

| # | Concept | Example in design | Owner | Status |
| --- | --- | --- | --- | --- |
| A | **Member enrollment** — being a member of a gym | WG3, G09, A03, E07 | `Gyms.Members` (`gym_members`) | **MVP**, no money |
| B | **Membership products / subscriptions** a gym sells to members | WG6, GC1–GC8, GC2 create membership, F16 pass | `Gyms.Commerce` (plans) + `Payments` | DEFERRED PRODUCT DECISION `D-G10` |
| C | **SimpleFit platform subscription** the gym business pays SimpleFit | OG6 plan/trial, WG25, PR3/PR6m | `Billing` (new) | DEFERRED PRODUCT DECISION `D-G09` |
| D | **Class bookings and attendance** | WG18, WG19, F13, G02, G03 | `Gyms.Bookings`, `Gyms.Attendance` | **MVP**, no money |
| E | **Payment transactions, invoices, payouts, dunning** | WG7, GC9–GC12, OG9 | `Payments` provider boundary (ADR 0005) | DEFERRED PRODUCT DECISION `D-G10` |

Rules that follow:

* Enrollment (A) is free and stands alone; it never implies an entitlement
  (B). A member with no product can book in MVP when the gym allows it
  (MVP gyms are effectively "free entry" until B exists). When B arrives,
  *entitlement checks* ("has an active plan with credits") become an extra
  booking rule, not a change to A.
* No screen may show a price, MRR, revenue, balance, trial, invoice or
  payment status until its source table exists. KPI tiles for them are
  hidden, not zeroed (a zero is a false statement).
* No payment provider is chosen here. When `D-G10` is decided, money goes
  through a `SimpleFit.Payments` boundary with the first real adapter
  (CLAUDE.md rule 6); production never falls back to a fake adapter; local
  development uses the provider's own test mode, never a SimpleFit-side
  "mock paid" flag that could grant entitlements.
* EU consumer-law points visible in GC2 (recurring terms and in-app
  cancellation shown before paying) are requirements for B, recorded for
  that decision.

## 3. Local development (`D-G17`)

ADR 0025's coaching legal bypass (the LOCAL DEVELOPMENT coaching mode, SF-105) is **not** extended to Gyms. Nothing in the
Gym MVP needs a legal gate, an external verification or a payment provider:
gym creation, staff and member invitations, classes, bookings and check-ins
all run locally with the Log email adapter and the dev email-code tools
(`mix e2e.email_code`, a future `mix e2e.invitation_link` style task for E06/E07
links if wanted). Future gates stay fail-closed in every environment:

| Future gate | Local behaviour |
| --- | --- |
| Business verification (`D-G11`) | Not required for MVP features; when built, local uses the KYB provider's sandbox, never a "verified" fixture in `simple_fit_dev` |
| Publication / Discover | Unavailable until verification exists |
| Payments, payouts, platform plan | Provider test mode only, behind the boundary; no entitlement from a mock |
