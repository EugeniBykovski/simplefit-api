# ADR 0004 — Deferred infrastructure and dependencies

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-2

## Context

SF-2 is the foundation ticket. Installing packages "because SimpleFit will
need them" adds attack surface, upgrade work, configuration and dead code
before there is a use case to design against. Each item below was evaluated
and deliberately **not** installed.

## Decision

| Item | Why deferred | Introduced by |
| --- | --- | --- |
| **Oban** (background jobs) | No asynchronous work exists. Adding it now means a migration, config, supervision and test setup with no worker to exercise them. Installing it later is one migration plus config, with no rework. **Oban remains the canonical job system** (PostgreSQL-backed, no Redis). | First async use case, most likely transactional email in the authentication ticket. Configure `testing: :manual` in test. |
| **Sentry** (`sentry`) | Error tracking needs release/environment tagging and a deploy target to be meaningful, and belongs with the rest of production observability. | Observability ticket. Must stay disabled unless `SENTRY_DSN` is set. |
| **OpenTelemetry** (SDK, exporter, phoenix/bandit/ecto instrumentation) | Needs a collector/backend decision. Telemetry events are already emitted, and `logger_json` already picks up trace metadata. | Observability ticket (see architecture README §5). |
| **CORS** (`corsica`) | No browser client exists. Deny-by-default (no CORS headers) is the safest state until real origins are known. | Web client integration ticket: allow-list from `CORS_ALLOWED_ORIGINS`, never `*` in prod, expose `x-request-id`. |
| **Trusted proxy client IP** (`remote_ip`) | Nothing consumes the client IP yet; misconfigured proxy trust is a spoofing risk. HTTPS detection already uses `x-forwarded-proto` via `force_ssl`. | Rate limiting / audit logging, configured with the load balancer's CIDRs. |
| **Rate limiting** (e.g. `hammer` with ETS/PostgreSQL backend) | No authentication or abuse-prone endpoints exist. `429 rate_limited` is already in the error contract. | Authentication ticket (login, OTP, password reset endpoints). |
| **Authentication** (token library, password hashing such as `argon2_elixir`/`bcrypt_elixir`) | Out of scope for SF-2. `bearerAuth` is reserved in OpenAPI. | Authentication ticket. |
| **Google / Apple identity** (`JOSE`/JWKS verification) | Out of scope. Will sit behind a `SimpleFit.Identity` provider behaviour. | Social sign-in ticket. Env: `GOOGLE_CLIENT_ID`, `APPLE_*`. |
| **AWS SDK** (`ex_aws` + `ex_aws_s3`, or `req` + SigV4) | No media features. Will sit behind `SimpleFit.Storage`, using presigned direct uploads. | Media/profile photo ticket. Env: `AWS_*`. |
| **Resend client** (likely plain `req` or `swoosh` with the Resend adapter) | No email features. Will sit behind `SimpleFit.Email`. | Authentication ticket (verification, password reset). Env: `RESEND_API_KEY`. |
| **Stripe** (`stripity_stripe` or `req`) | Billing is out of scope. Webhooks need signature verification and idempotent processing (an Oban use case). | Payments ticket. Env: `STRIPE_*`. |
| **PostHog** | Product analytics is primarily a client concern. Server-side events need an event taxonomy first. | Analytics ticket. Env: `POSTHOG_*`. |
| **Push notifications** (APNs/FCM) | No notifications domain yet. | Notifications ticket. |
| **File/media processing** (`image`/`vix`, ffmpeg) | No media pipeline. Heavy native dependencies. | Media ticket. |
| **HTTP client** (`req`) | No outbound HTTP calls exist. | First provider integration. |
| **Factories** (`ex_machina`) | No domain entities to build. | First context with schemas, and only if plain helper functions become insufficient. |
| **Mocks** (`mox`) | No behaviours to mock. | First provider behaviour. |
| **`phoenix_live_dashboard`, PubSub, DNSCluster, Swoosh, Gettext** | HTML/real-time/clustering/i18n features not needed by a JSON API today. | Messaging (PubSub), multi-node deploys (DNSCluster), localized server-side messages (Gettext). |

## Consequences

* Every future addition must name its use case and update this table (move
  the row to "introduced" with the ticket reference) or the architecture
  README.
* `.env.example` already reserves variable names for the planned providers,
  clearly marked as not yet read by the application.
