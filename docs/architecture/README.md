# SimpleFit API — Architecture

This document describes how the SimpleFit backend is structured and the
conventions every change must follow. Decisions with trade-offs are recorded
as ADRs in [`adr/`](adr/).

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-architecture-baseline.md) | Phoenix modular monolith, API-only, PostgreSQL, UUID keys |
| [0002](adr/0002-openapi-strategy.md) | OpenAPI: code-first with `open_api_spex`, committed artifact, Scalar docs |
| [0003](adr/0003-api-versioning-and-errors.md) | URL layout / versioning and the JSON error contract |
| [0004](adr/0004-deferred-infrastructure.md) | Infrastructure intentionally deferred (Sentry, auth, PostGIS, ...) |
| [0005](adr/0005-provider-boundaries-and-http-client.md) | Provider boundaries, Req as the HTTP client, S3 storage, Resend email |
| [0006](adr/0006-background-jobs-oban.md) | Background jobs with Oban (queues, pruning, testing, worker conventions) |
| [0007](adr/0007-cors-policy.md) | Cross-origin (CORS) policy: explicit allow-list, preflight, no credentials |
| [0008](adr/0008-observability.md) | Observability: structured logs, Sentry, OpenTelemetry, privacy rules |
| [0009](adr/0009-identity-domain.md) | Identity domain: one global user, many identities, no silent account merging |
| [0010](adr/0010-sessions.md) | SimpleFit sessions: access/refresh tokens, rotation, reuse detection, web cookie vs mobile body, `/api/me` |
| [0011](adr/0011-transactional-email-templates.md) | Transactional email templates: app-owned rendering, HTML + text, encrypted job payloads, dev preview |
| [0012](adr/0012-passwordless-email-authentication.md) | Passwordless email authentication: verification vs sign-in challenges, keyed code verifiers, Version 66 device rule, PostgreSQL rate limits, client IP |
| [0013](adr/0013-google-authentication.md) | Google authentication: ID-token verification (jose, cached Google keys), aud/azp allowlist, `sub` identity, no email linking, SF-20 sessions |

---

## 1. Role of the backend

The backend is the **canonical owner** of domain logic, authorization,
business rules, validation, persistence, identity relationships, billing
state, permissions and the API contract. Web and mobile apps are API clients:
they render state and collect input, they never decide what is allowed.

## 2. Shape: a modular monolith

One Phoenix application, one deployable, one PostgreSQL database. Modularity
comes from **context boundaries inside the codebase**, not from network
boundaries. No microservices, GraphQL, CQRS/event sourcing, Redis,
Elasticsearch or Kubernetes. Each is a deliberate future decision with its
own ADR, not a default.

```
lib/
  simple_fit/                 # Domain: contexts, schemas, business rules
    application.ex            # OTP supervision tree (Repo, Oban, Endpoint)
    repo.ex                   # Ecto repo (the only DB entry point)
    accounts.ex, accounts/    # Users, sign-in identities (ADR 0009), sessions (ADR 0010) and
                              # passwordless email authentication (ADR 0012)
    identity.ex, identity/    # Provider identity verification: Google ID tokens + signing-key cache (ADR 0013)
    rate_limit.ex             # PostgreSQL fixed-window limits for abuse-sensitive endpoints (ADR 0012)
    provider.ex               # Shared provider error vocabulary
    http.ex                   # Canonical outbound HTTP client (Req) for adapters
    storage.ex, storage/      # Object storage boundary + S3 / Fake adapters
    email.ex, email/          # Transactional email boundary + Resend / Log adapters, delivery worker,
                              # templates (ADR 0011) and encrypted job payloads
  simple_fit_web/             # HTTP interface: no business rules
    endpoint.ex               # Plug pipeline: request id, security headers, JSON parsing
    router.ex                 # Routes and pipelines
    api_error.ex              # Error code catalog + envelope (the error contract)
    api_spec.ex               # OpenAPI root document
    api_spec/validation.ex    # Contract checks used by mix openapi.check + tests
    schemas/                  # OpenAPI schemas (request/response shapes)
    controllers/              # Controllers + *JSON view modules
    plugs/authenticate.ex     # Bearer access token -> current user/session (ADR 0010)
    session_transport.ex      # Refresh token transport: JSON body (mobile) or cookie (web)
    telemetry.ex              # Telemetry metric definitions
  mix/tasks/                  # openapi.gen, openapi.check
openapi/simplefit.api.json    # Generated, committed OpenAPI contract
```

Directories appear when they have a real module to hold. Do not create empty
folders or placeholder modules to "reserve" architecture.

## 3. Conventions

### Contexts (`lib/simple_fit/<context>.ex`, `lib/simple_fit/<context>/`)

* A context is the public API of one domain boundary (e.g.
  `SimpleFit.Accounts`, future `SimpleFit.Training`, `SimpleFit.Gyms`).
* Contexts own their schemas, queries, changesets, authorization rules and
  transactions. Only a context calls `Repo` for its own schemas.
* Other contexts and the web layer call the context's public functions, never
  its internal modules, schemas' changesets or queries.
* Public functions return `{:ok, value}` / `{:error, reason}` for operations
  that can fail. `reason` is an `Ecto.Changeset`, or an atom from a small
  vocabulary (`:not_found`, `:forbidden`, `:conflict`, ...) that maps 1:1 to
  the error catalog.
* Cross-context workflows live in the context that owns the outcome, or in a
  dedicated module under it. They do not live in controllers.

### Schemas (`lib/simple_fit/<context>/<schema>.ex`)

* Ecto schemas with UUID primary keys (`binary_id`, already the generator and
  migration default) and `utc_datetime` timestamps.
* Changesets are the validation boundary for persisted data.
* Ecto schemas are internal. They are never serialized directly; JSON views
  choose fields explicitly.

### Controllers (`lib/simple_fit_web/controllers/*_controller.ex`)

* Thin: parse/validate params → call one context function → render.
* No `Repo` calls, no business decisions, no authorization logic beyond
  passing the current actor to the context.
* Every action declares its OpenAPI `operation` (with a camelCase
  `operation_id`, `summary`, tags, request body and all responses).

### JSON views (`lib/simple_fit_web/controllers/*_json.ex`)

* One `FooJSON` module per controller (Phoenix 1.7+ convention), plain
  functions returning maps. Explicit field lists only. The response shape
  must match the OpenAPI schema; tests assert it with
  `OpenApiSpex.TestAssertions.assert_schema/3`.

### OpenAPI schemas (`lib/simple_fit_web/schemas/*.ex`)

* One module per named schema via `OpenApiSpex.schema/2` with `struct?: false`
  unless casting into a struct is needed. Every schema has a `title`,
  `description`, `required` and a constant `example`.
* See [ADR 0002](adr/0002-openapi-strategy.md).

### Services (only when justified)

A module under a context (e.g. `SimpleFit.Billing.InvoiceCalculator`) is
fine when a piece of logic is large, pure, or reused across functions of the
same context. Do not create a generic `services/` layer; logic belongs to a
context.

### Providers / adapters

Vendor integrations sit behind a SimpleFit-owned boundary named for the
capability, never the vendor ([ADR 0005](adr/0005-provider-boundaries-and-http-client.md)):

```
Domain context
    ↓
SimpleFit.Storage           SimpleFit.Email            (boundary + behaviour)
    ↓                           ↓
SimpleFit.Storage.S3        SimpleFit.Email.Resend     (adapter, the only vendor-aware module)
    ↓                           ↓
AWS S3 (presigned URLs)     Resend API via SimpleFit.HTTP
```

* Domain code calls the boundary (`Storage.presign_upload/2`,
  `Email.deliver_later/1`), never an adapter, `Req` or a vendor library.
* The adapter is chosen by application config. Production always uses the
  real adapters; tests use `SimpleFit.Storage.Fake` and a test email adapter;
  development uses the real adapters only when credentials are exported,
  otherwise Fake / `SimpleFit.Email.Log`.
* Adapters return `{:error, reason}` with reasons from
  `SimpleFit.Provider` (`:invalid_request`, `:unauthorized`, `:rate_limited`,
  `:timeout`, `:unavailable`, `:configuration_error`). Vendor payloads,
  credentials and signed URLs never cross the boundary or reach logs.
* Outbound HTTP goes only through `SimpleFit.HTTP` (Req with verified TLS,
  short timeouts, no redirects, no automatic retries). Base URLs are
  constants or trusted config, never user input.
* A boundary is introduced with its first real adapter. Future ones:
  `Payments`, `Identity` (Google/Apple), `Push`. See ADR 0004.

### Workers (background jobs)

Oban, PostgreSQL-backed ([ADR 0006](adr/0006-background-jobs-oban.md)).
Queues: `default`, `mailers`. Workers live next to their capability or
context (`SimpleFit.Email.DeliveryWorker`), stay thin, take small
JSON-serializable arguments that `perform/1` re-validates, use idempotency
keys for side effects, and retry only transient provider failures. Tests run
Oban in `:manual` mode.

### Authorization

Authorization is a **domain** concern. Context functions take the acting
user/scope as an explicit argument and decide. Controllers never branch on
roles. The web layer only authenticates (who is calling) and passes the
actor along. The policy mechanism (per-context `can?/3`-style functions vs.
a library) will be chosen in the authentication/authorization ticket.

### API errors

All non-2xx responses use the envelope defined in `SimpleFitWeb.APIError`
(see [ADR 0003](adr/0003-api-versioning-and-errors.md)):

```json
{ "error": { "code": "not_found", "message": "...", "details": {}, "request_id": "..." } }
```

* Exceptions are rendered by `SimpleFitWeb.ErrorJSON` (generic per status;
  the exception is never rendered).
* Context `{:error, reason}` results go through
  `SimpleFitWeb.FallbackController`; plugs call `APIError.send_error/3`.
* `validation_error` details: `fields` (messages, SF-2) plus `field_codes`
  (aligned machine-readable reasons, SF-6) from `SimpleFitWeb.ChangesetErrors`.
* Public versus internal errors: the response carries only the catalogued
  code, its fixed message and structured details. The diagnosis (exception,
  reason, stack) is logged server-side under the same `request_id`. Error
  tracking (Sentry/OpenTelemetry) belongs to SF-8.
* Clients branch on `code` and `field_codes`, never on human-readable
  messages. See [ADR 0003](adr/0003-api-versioning-and-errors.md) for the
  catalog, HTTP mapping, reason codes and the rules for future domain errors.

### Migrations

* Immutable once merged to `main`. Fix mistakes with a new migration.
* Reversible (`change/0` or `up/0` + `down/0`).
* Data backfills are separate from schema changes and safe to re-run.

## 4. Security baseline

| Concern | Current state | Where it evolves |
| --- | --- | --- |
| Secrets | Read only from env in `config/runtime.exs`; prod raises if required ones are missing. `.env*` git-ignored. Dev/test `secret_key_base` values are non-secret placeholders. | Deployment ticket: secret manager |
| Request IDs | `Plug.RequestId` on every request; `x-request-id` response header; echoed as `request_id` in error bodies; in every log line. Valid client-supplied IDs are kept for end-to-end correlation. | — |
| Response headers | Endpoint sets `content-security-policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'`, `x-content-type-options: nosniff`, `x-frame-options: DENY`, `referrer-policy: no-referrer`, `x-permitted-cross-domain-policies: none` on every response including errors. `/api/docs` gets its own CSP. | — |
| JSON only | `Plug.Parsers` accepts only `application/json` (others → 415); `:accepts ["json"]` (others → 406). No cookie session, no method override, no static files. | — |
| Object storage | Private bucket, uploads/downloads direct to S3 with short-lived presigned URLs (content type and exact size signed; max 1 h). Keys from validated segments only. AWS credentials stay server-side; signed URLs are redacted from `inspect`/logs. | Media domains add per-purpose content-type and size limits |
| Outbound HTTP / providers | Only adapters call out, via `SimpleFit.HTTP`: verified TLS, 5 s/15 s timeouts, no redirects (no SSRF steering), no automatic retries (Oban owns bounded retries with idempotency keys). Provider errors normalized; bodies, headers, API keys never logged. Missing provider config fails closed (`:configuration_error`), never falls back to fakes in prod. | — |
| Error handling | Fixed messages per error code; exception messages, stack traces and request bodies never reach responses. `debug_errors` only in dev. | — |
| CORS | `SimpleFitWeb.CORS` ([ADR 0007](adr/0007-cors-policy.md)). Explicit allow-list from `CORS_ALLOWED_ORIGINS`: dev default `http://localhost:3000`; prod https only, fail closed when unset; malformed values stop the boot. Never `*`; credentials only on the two refresh-cookie endpoints ([ADR 0010](adr/0010-sessions.md)). Preflights answered (204, or `403 forbidden` envelope); `x-request-id` exposed. | Credentials allowed on the refresh-cookie endpoints only (ADR 0010) |
| HTTPS / proxies | `force_ssl` + HSTS in prod, trusting `x-forwarded-proto` from the load balancer (`/api/health` excluded so plain-HTTP health checks work). The app must only be reachable through that proxy. Client IPs (auth rate limits) come from `SimpleFitWeb.ClientIP`: the direct peer unless `TRUSTED_PROXY_HOPS` is set (ADR 0012). | Deployment ticket: verify the proxy topology, then set `TRUSTED_PROXY_HOPS` |
| Logging | Phoenix `filter_parameters` redacts keys containing `password`, `secret`, `token`, `api_key`, `private_key`, `authorization`, `credential`. JSON logs in prod. Never log full request bodies or tokens. | — |
| Authentication | SimpleFit sessions ([ADR 0010](adr/0010-sessions.md)) on the identity domain ([ADR 0009](adr/0009-identity-domain.md)). `Authorization: Bearer sfa_...` access tokens (15 min, HMAC-signed, session re-checked on every request); opaque `sfr_` refresh tokens (30 days, stored as SHA-256, rotated on use, reuse revokes the session); 90-day absolute sessions. Web keeps the refresh token in an `HttpOnly; Secure; SameSite=Strict` cookie with an Origin + `x-simplefit-csrf` check; mobile uses the JSON body. Routes behind the `:authenticated` pipeline. | Sign-in flows (SF-21/22/23) call `Accounts.create_session/1`; sign out everywhere and device management later |
| Rate limiting | Email authentication endpoints: per-target, per-IP and per-challenge limits in PostgreSQL (`SimpleFit.RateLimit`, ADR 0012), `429 rate_limited` with `retry-after`. Refresh and logout stay unlimited (256-bit refresh tokens, ADR 0010). | SF-29: broader abuse hardening (reputation, CAPTCHA, adaptive limits) |
| API docs exposure | `/api/docs` and `/api/openapi` are on in dev/test and **off in prod** unless `API_DOCS_ENABLED=true`. When off they respond exactly like unknown routes. | — |

## 5. Observability

See [ADR 0008](adr/0008-observability.md). **Observe system behaviour, never
user content.**

* **Logs** (`Logger`, JSON in prod):
  * one `request completed` event per request (method, route template, status,
    duration) and one event per job outcome (worker, queue, state; never args)
  * `request_id`, `otel_trace_id`/`otel_span_id`, `service`, `environment`,
    `release` metadata
  * conventions: log events with identifiers in metadata; never secrets,
    tokens, bodies or personal data; `:error` means someone should look at it
    (and goes to Sentry)
* **Error tracking** (Sentry, `SENTRY_DSN`): unexpected failures only, every
  event sanitized by `SimpleFit.Observability.SentryFilter`.
* **Tracing** (OpenTelemetry, `OTEL_EXPORTER_OTLP_ENDPOINT`): Bandit/Phoenix,
  Ecto (no SQL), Oban (no args), Req (no query or headers) and provider
  boundary spans; `SimpleFit.Observability.SpanSanitizer` strips sensitive
  attributes. Not exported without an endpoint.
* **Metrics**: definitions in `SimpleFitWeb.Telemetry.metrics/0`; no reporter
  yet (no Prometheus/Grafana/vendor agent).
* Every backend is optional and asynchronous: their absence or outage never
  affects requests.

## 6. Health

`GET /api/health` is a **liveness** check: it does not touch the database and
returns only `{"status":"ok","service":"simplefit-api"}`. If a deployment
needs a **readiness** check (DB reachable, migrations applied), add a
separate `GET /api/health/ready` rather than changing this contract.

## 7. Database extensions

PostgreSQL with UUID keys only. **PostGIS is intentionally deferred** to the
first gyms/discovery/location-search ticket, which will add
`CREATE EXTENSION postgis` in a migration together with the Ecto types it
needs (ADR 0004). Oban's tables (`oban_jobs`, `oban_peers`) are the only
infrastructure tables.

## 8. Dependencies

Every dependency in `mix.exs` has a comment-level justification and a
current use. Adding one requires stating in the PR: the problem it solves
now, why the standard library / existing deps are insufficient, maintenance
status, and license. The deferred list is in ADR 0004.
