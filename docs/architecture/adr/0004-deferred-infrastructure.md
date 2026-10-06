# ADR 0004 — Deferred infrastructure and dependencies

* Status: Accepted (amended by SF-15: Oban, Req, S3 and Resend introduced; SF-6: CORS introduced; SF-8: Sentry and OpenTelemetry introduced)
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
| **Oban** (background jobs) | **Introduced in SF-15** ([ADR 0006](0006-background-jobs-oban.md)): queues `default` and `mailers`, first worker delivers transactional email. | SF-15 |
| **Sentry** | **Introduced in SF-8** ([ADR 0008](0008-observability.md)): unexpected failures only, sanitized, off without `SENTRY_DSN`. | SF-8 |
| **OpenTelemetry** | **Introduced in SF-8** ([ADR 0008](0008-observability.md)): Phoenix/Bandit, Ecto, Oban, Req and provider spans, sanitized; exported only with `OTEL_EXPORTER_OTLP_ENDPOINT`. Metrics reporters remain deferred. | SF-8 |
| **CORS** | **Introduced in SF-6** ([ADR 0007](0007-cors-policy.md)): an owned `SimpleFitWeb.CORS` plug with an explicit `CORS_ALLOWED_ORIGINS` allow-list (never `*`, https-only in prod, fail closed), exposing `x-request-id`. `corsica` was not adopted (no release since 2023). | SF-6 |
| **Trusted proxy client IP** | **Introduced in SF-21** ([ADR 0012](0012-passwordless-email-authentication.md)) as the owned `SimpleFitWeb.ClientIP` (no `remote_ip` dependency): the direct peer by default, `X-Forwarded-For` only for an explicit `TRUSTED_PROXY_HOPS`. | SF-21 |
| **Rate limiting** | **Introduced in SF-21** ([ADR 0012](0012-passwordless-email-authentication.md)) as `SimpleFit.RateLimit`: fixed windows in PostgreSQL (atomic upserts, shared by every instance). No `hammer` and no Redis: one table and one query cover the auth endpoints. | SF-21; broader hardening in SF-29 |
| **Authentication** (token library, password hashing such as `argon2_elixir`/`bcrypt_elixir`) | Sessions use `plug_crypto` (SF-20, ADR 0010). SimpleFit is passwordless (SF-21, ADR 0012): no password hashing library is needed. | Only if passwords are ever introduced. |
| **Google / Apple identity** (`JOSE`/JWKS verification) | **Google introduced in SF-22** ([ADR 0013](0013-google-authentication.md)): `SimpleFit.Identity` with `jose` and a cached Google key set over `SimpleFit.HTTP`; env `GOOGLE_OAUTH_CLIENT_IDS`. Apple remains deferred. | Apple: SF-23 (`APPLE_*`). |
| **AWS S3** | **Introduced in SF-15** ([ADR 0005](0005-provider-boundaries-and-http-client.md)) as `SimpleFit.Storage` with an S3 adapter using Req SigV4 presigning (no `ex_aws`). Media domains (avatars, video, documents) are still future tickets. | SF-15 |
| **Resend** | **Introduced in SF-15** ([ADR 0005](0005-provider-boundaries-and-http-client.md)) as `SimpleFit.Email` with a Resend adapter over Req (no SDK, no Swoosh). Verification/password-reset flows are future tickets. | SF-15 |
| **Stripe** (`stripity_stripe` or `req`) | Billing is out of scope. Webhooks need signature verification and idempotent processing (an Oban use case). | Payments ticket. Env: `STRIPE_*`. |
| **PostHog** | Product analytics is primarily a client concern. Server-side events need an event taxonomy first. | Analytics ticket. Env: `POSTHOG_*`. |
| **Push notifications** (APNs/FCM) | No notifications domain yet. | Notifications ticket. |
| **File/media processing** (`image`/`vix`, ffmpeg) | No media pipeline. Heavy native dependencies. | Media ticket. |
| **HTTP client** (`req`) | **Introduced in SF-15** as `SimpleFit.HTTP` ([ADR 0005](0005-provider-boundaries-and-http-client.md)). | SF-15 |
| **PostGIS** | No location data exists. Enabling the extension needs a managed-database capability check and adds `geo_postgis`/`geo` dependencies; nothing would use it yet. | First gyms/discovery/location-search ticket (migration `CREATE EXTENSION postgis`). |
| **Factories** (`ex_machina`) | No domain entities to build. | First context with schemas, and only if plain helper functions become insufficient. |
| **Mocks** (`mox`) | Still not needed: provider adapters take explicit config and are tested with `Req.Test` stubs and in-process test adapters. | Only if a behaviour needs call-level expectations those cannot express. |
| **`phoenix_live_dashboard`, PubSub, DNSCluster, Swoosh, Gettext** | HTML/real-time/clustering/i18n features not needed by a JSON API today. | Messaging (PubSub), multi-node deploys (DNSCluster), localized server-side messages (Gettext). |

## Consequences

* Every future addition must name its use case and update this table (move
  the row to "introduced" with the ticket reference) or the architecture
  README.
* `.env.example` already reserves variable names for the planned providers,
  clearly marked as not yet read by the application.
