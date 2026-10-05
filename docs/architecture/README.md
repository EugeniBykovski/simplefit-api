# SimpleFit API — Architecture

This document describes how the SimpleFit backend is structured and the
conventions every change must follow. Decisions with trade-offs are recorded
as ADRs in [`adr/`](adr/).

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-architecture-baseline.md) | Phoenix modular monolith, API-only, PostgreSQL, UUID keys |
| [0002](adr/0002-openapi-strategy.md) | OpenAPI: code-first with `open_api_spex`, committed artifact, Scalar docs |
| [0003](adr/0003-api-versioning-and-errors.md) | URL layout / versioning and the JSON error contract |
| [0004](adr/0004-deferred-infrastructure.md) | Infrastructure intentionally deferred (Oban, Sentry, CORS, providers, ...) |

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
    application.ex            # OTP supervision tree
    repo.ex                   # Ecto repo (the only DB entry point)
  simple_fit_web/             # HTTP interface: no business rules
    endpoint.ex               # Plug pipeline: request id, security headers, JSON parsing
    router.ex                 # Routes and pipelines
    api_error.ex              # Error code catalog + envelope (the error contract)
    api_spec.ex               # OpenAPI root document
    api_spec/validation.ex    # Contract checks used by mix openapi.check + tests
    schemas/                  # OpenAPI schemas (request/response shapes)
    controllers/              # Controllers + *JSON view modules
    telemetry.ex              # Telemetry metric definitions
  mix/tasks/                  # openapi.gen, openapi.check
openapi/simplefit.api.json    # Generated, committed OpenAPI contract
```

Directories appear when they have a real module to hold. Do not create empty
folders or placeholder modules to "reserve" architecture.

## 3. Conventions

### Contexts (`lib/simple_fit/<context>.ex`, `lib/simple_fit/<context>/`)

* A context is the public API of one domain boundary (e.g. future
  `SimpleFit.Accounts`, `SimpleFit.Training`, `SimpleFit.Gyms`).
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

Vendor integrations (S3, Resend, Google/Apple identity, Stripe, push) sit
behind a behaviour owned by the domain, named for the capability, not the
vendor:

```
SimpleFit.Storage         (behaviour: put/get/presign ...)
  SimpleFit.Storage.S3    (adapter, the only module that knows about AWS)
  SimpleFit.Storage.Local (adapter for dev/test, or a Mox mock)
```

* Domain code calls the behaviour (resolved via application config), never a
  vendor SDK.
* Vendor payloads are translated to domain terms at the adapter edge.
* The behaviour is introduced **with the first real adapter**, not before.
  No speculative empty behaviours exist today.

Future boundaries: `Storage`, `Email`, `Payments`, `Identity` (Google/Apple
token verification), `Push`. See [ADR 0004](adr/0004-deferred-infrastructure.md).

### Workers (background jobs)

Oban will be the job system (PostgreSQL-backed, no Redis). Workers will live
next to their context (`SimpleFit.Accounts.Workers.SendWelcomeEmail`), stay
thin, and call context functions. Oban is not installed yet; see ADR 0004.

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

* Exceptions are rendered by `SimpleFitWeb.ErrorJSON`.
* When the first context returns `{:error, ...}`, add a
  `SimpleFitWeb.FallbackController` that maps `:not_found`, `:forbidden`,
  `%Ecto.Changeset{}` (→ `validation_error` with `details.fields`), ... onto
  `APIError.envelope/2`. It does not exist yet because nothing produces those
  tuples.

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
| JSON only | `Plug.Parsers` accepts only `application/json` (others → 415); `:accepts ["json"]` (others → 406). No cookie session, no method override, no static files. | Uploads will go direct-to-S3 via presigned URLs, not multipart through the API |
| Error handling | Fixed messages per error code; exception messages, stack traces and request bodies never reach responses. `debug_errors` only in dev. | — |
| CORS | **Deny by default**: no CORS headers are sent, so browsers block cross-origin calls. No browser client exists yet. | Web-client ticket: add `Corsica` in the endpoint with an explicit `CORS_ALLOWED_ORIGINS` allow-list (never `*` in prod), exposing `x-request-id` |
| HTTPS / proxies | `force_ssl` + HSTS in prod, trusting `x-forwarded-proto` from the load balancer (`/api/health` excluded so plain-HTTP health checks work). The app must only be reachable through that proxy. | Deployment ticket. When client IPs matter (rate limiting, audit), add `remote_ip` configured with the proxy's CIDRs only |
| Logging | Phoenix `filter_parameters` redacts keys containing `password`, `secret`, `token`, `api_key`, `private_key`, `authorization`, `credential`. JSON logs in prod. Never log full request bodies or tokens. | — |
| Authentication | Not implemented. `bearerAuth` security scheme is reserved in OpenAPI. | Auth ticket: a `:authenticated` router pipeline with a plug that resolves the bearer token to an actor |
| Rate limiting | Not implemented. | Auth/abuse ticket: per-IP and per-account limits on auth endpoints, returning `429 rate_limited` |
| API docs exposure | `/api/docs` and `/api/openapi` are on in dev/test and **off in prod** unless `API_DOCS_ENABLED=true`. When off they respond exactly like unknown routes. | — |

## 5. Observability

* **Telemetry**: Phoenix, Ecto and VM metrics are defined in
  `SimpleFitWeb.Telemetry.metrics/0`; no reporter is attached yet.
* **Logging**: Elixir `Logger` with `request_id` metadata. Plain text in dev,
  one JSON object per line in prod (`logger_json`, `Basic` formatter).
  Conventions:
  * log events, not prose: `Logger.info("booking confirmed", booking_id: id)`;
    put identifiers in metadata, not interpolated into the message
  * never log secrets, tokens, full request/response bodies or personal data
    beyond opaque IDs
  * `:error` level means someone should look at it
* **Error tracking (Sentry)**: deferred to the observability ticket
  (ADR 0004). `SENTRY_DSN` is reserved in `.env.example`.
* **OpenTelemetry (future)**: add `opentelemetry`, `opentelemetry_exporter`,
  `opentelemetry_phoenix`, `opentelemetry_bandit` and `opentelemetry_ecto`,
  started from `SimpleFit.Application`. Traces correlate with logs via
  `otel_trace_id` metadata, which `logger_json` already understands. No code
  changes in contexts are needed for the baseline instrumentation.

## 6. Health

`GET /api/health` is a **liveness** check: it does not touch the database and
returns only `{"status":"ok","service":"simplefit-api"}`. If a deployment
needs a **readiness** check (DB reachable, migrations applied), add a
separate `GET /api/health/ready` rather than changing this contract.

## 7. Dependencies

Every dependency in `mix.exs` has a comment-level justification and a
current use. Adding one requires stating in the PR: the problem it solves
now, why the standard library / existing deps are insufficient, maintenance
status, and license. The deferred list is in ADR 0004.
