# ADR 0001 — Architecture baseline

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-2

## Context

SimpleFit Boxing will connect fighters, coaches, gyms, training, fight camps,
sparring, social features, messaging, scheduling, bookings, payments, a
marketplace, sponsorship and admin. A small team builds it initially, and
web and mobile clients must share one source of truth for business rules.

## Decision

1. **Elixir + Phoenix, API-only.** Generated with
   `--no-html --no-assets --no-mailer --no-dashboard --no-gettext --binary-id`.
   No server-rendered UI, no LiveView, no cookie session, no static files.
2. **Modular monolith.** One OTP application (`:simple_fit`), domain in
   `SimpleFit.*` contexts, HTTP in `SimpleFitWeb.*`. Boundaries are enforced by
   convention and review (see `docs/architecture/README.md`), not by separate
   services.
3. **PostgreSQL via Ecto** as the only datastore. `DATABASE_URL` in deployed
   environments; local defaults for dev; an isolated test database that never
   reads `DATABASE_URL`.
4. **REST + JSON, contract in OpenAPI 3** (ADR 0002).
5. **UUID primary and foreign keys** (`binary_id`) by default for
   generators and migrations, so public identifiers do not reveal row counts or
   creation order and records can be created client-side or merged without
   collisions. Ecto generates UUIDv4. Moving to time-ordered UUIDv7 for index
   locality can be decided when the first high-volume table is designed.
6. **Bandit** as the HTTP server (Phoenix 1.8 default).
7. **Toolchain pinned** in `.tool-versions`: Erlang/OTP 29.1.1, Elixir
   1.20.4 (`mix.exs` requires `~> 1.20`). CI uses the same file.
8. **Configuration through environment variables** read only in
   `config/runtime.exs`. No dotenv loader: the runtime environment
   (shell, CI, platform secrets) is the single mechanism everywhere, and the
   app has no extra dependency or code path for loading files.

## Consequences

* One deploy, one database, simple transactions across domains, and simple
  local setup.
* Discipline is required to keep contexts from reaching into each other.
  This is called out in `CLAUDE.md` and the architecture README.
* Generator defaults that serve HTML apps (PubSub, DNSCluster, sessions,
  static files, method override) were removed. Re-add one only when a feature
  needs it (e.g. PubSub for real-time messaging).
