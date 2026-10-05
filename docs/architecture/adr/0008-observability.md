# ADR 0008 — Observability: logs, error tracking, tracing

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-8 (introduces Sentry and OpenTelemetry deferred by ADR 0004)

## Context

SimpleFit will process athlete, authentication, payment, health-adjacent,
location and private coaching data. Observability has to be privacy-safe
before those domains exist.

**Observe system behaviour, not user content.** Observability never logs or
exports user content by default.

The audit found an existing leak. Oban's default logger, attached in SF-15,
wrote each job's `args` into every job log line. Email jobs carry the
recipient, subject and body. SF-8 removes it.

## Decision: three concerns, three standard tools

| Concern | Tool | Owns |
| --- | --- | --- |
| Logs | `Logger` (text in dev, `logger_json` in prod) | Operational events and request correlation |
| Error tracking | Sentry (`sentry` 13.5) | Unexpected, actionable failures |
| Tracing | OpenTelemetry (SDK 1.7, OTLP exporter, contrib instrumentation) | Request, database, job and provider execution |

`SimpleFit.Observability.setup/0` attaches them all from
`SimpleFit.Application`. There is no custom framework: each concern uses the
ecosystem library plus a small policy module.

### Logs

- **Request log:** one "request completed" event per request
  (`RequestLogger`, from Phoenix telemetry):
  - `method`
  - `route`: the router template (`/api/v1/fighters/:id`), never the raw path
    or query
  - `status`
  - `duration_ms`
  - `request_id`, and `otel_trace_id`/`otel_span_id` while a span is active

  Phoenix's text request logs are off.
- **Job log:** one event per job outcome (`JobLogger`): `worker`, `queue`,
  `job_id`, `attempt`, `max_attempts`, `state`, `duration_ms`, and on failure
  `error_kind`/`error_type`. Never `args`, `meta`, `tags` or error messages.
  Failures log at `:warning`, since retries are expected.
- **Providers:** failures keep the SF-15 behaviour: `provider`, `status` and
  the normalised `reason` only.
- **Global metadata:** `service`, `environment` and `release` on every event
  (logger primary metadata).
- **Production format:** JSON, one object per line, with an explicit metadata
  allow-list. Credential-named keys are redacted
  (`LoggerJSON.Redactors.RedactKeys`).
- **Development:** readable text with the same metadata.
- **`request_id` vs `trace_id`:**
  - `request_id` (from `x-request-id`, SF-6) is the client-visible id. It is
    in error bodies, response headers and logs.
  - `trace_id`/`span_id` identify the trace for the operator.

  Both are on request log lines, so a client report leads to the logs, then
  to the trace. Neither replaces the other.

### Error tracking (Sentry)

- **Off by default:** sends nothing without `SENTRY_DSN`. Delivery is
  asynchronous, and the logger handler is rate limited (10 events/s).
- **Event policy (`SentryFilter`):**
  - **Captured:** crashes (500s logged by Bandit, process crashes) and
    `Logger.error` events. By convention, `:error` means someone should look
    at it: missing provider configuration, unhandled context error results.
  - **Oban jobs:** reported only when attempts are exhausted
    (`report_job_error?/2`).
  - **Never captured:** expected API errors (`validation_error`,
    `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`) and
    provider failures surfaced as `service_unavailable`. These are warnings or
    plain responses.
  - **One path per failure:** for example, job errors go through the Oban
    integration only, and `JobLogger` uses `:warning`.
- **Sanitization (`before_send/1`):**
  - **Removed:** the request interface (headers, cookies, query string, body)
    and the user context.
  - **Extra and metadata:** reduced to allow-lists, so job `args`/`meta` are
    dropped.
  - **Stack frames:** lose `vars` (function arguments).
  - **Redacted:** in messages and exception values, bearer/basic tokens,
    `key=value` credentials, presigned signatures, and AWS and Resend keys.
  - **Base settings:** `send_default_pii: false`,
    `enable_source_code_context: false`.

### Tracing (OpenTelemetry)

- **Instrumentation (maintained contrib libraries):**
  - `opentelemetry_bandit`: server spans. `public_endpoint: true`, so client
    trace context is linked rather than trusted as a parent.
  - `opentelemetry_phoenix`: span name `GET /api/health`, plus `http.route`.
  - `opentelemetry_ecto`: timing and table only; `db_statement: :disabled`,
    and parameters are never captured.
  - `opentelemetry_oban`: job spans with worker, queue and attempt, never
    args. Plugin spans are off.
  - `opentelemetry_req`: attached in `SimpleFit.HTTP` for every provider
    client. No headers, and no trace headers injected into vendor requests.
- **Provider spans:** `ProviderTracing` turns the SF-15 boundary telemetry
  into `provider email.deliver` and `provider storage.presign` spans with the
  adapter, method and normalised result.
- **`SpanSanitizer`:** a span processor first in the chain. When any span
  starts, it removes:
  - `url.query`, which Bandit always records
  - client and peer addresses
  - `db.statement`/`db.query.text`
  - captured headers
  - the query, fragment and userinfo of `url.full`

  Exception events recorded later are server-side diagnostics, governed like
  logs.
- **Export:**
  - Only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, over OTLP/HTTP protobuf
    through the batch processor (asynchronous; drops spans when the backend
    is down).
  - Without it, spans are still created (trace ids in logs) but not exported.
  - Standard `OTEL_*` variables apply (headers, resource attributes,
    sampler).
  - No collector is deployed by this ticket.
- **Sampling:** parent-based always-on by default, which suits early traffic.
  Use `OTEL_TRACES_SAMPLER=parentbased_traceidratio` with
  `OTEL_TRACES_SAMPLER_ARG` when volume grows.

### Service metadata

| Value | Source | Used by |
| --- | --- | --- |
| service | `simplefit-api` | logs, Sentry, OTel `service.name` |
| environment | `SENTRY_ENVIRONMENT`, else the Mix env | logs, Sentry, OTel `deployment.environment.name` |
| release | `SENTRY_RELEASE` (e.g. git SHA), else `simplefit-api@<version>` | logs, Sentry, OTel `service.version` |

No fake commit SHA is invented. Deployments pass the real one in
`SENTRY_RELEASE`.

## Failure behaviour

Observability is never on the critical path:
- Sentry and OTLP calls are asynchronous and batched.
- Their outages only drop data. This was verified with both backends
  pointing at a closed port: `/api/health` stayed at about 6 ms.
- Telemetry handlers do not raise into requests or jobs.

## Health and readiness

`GET /api/health` stays a cheap liveness check (no database, no providers).

Readiness is deferred until a deployment platform needs it. It would be a
separate endpoint, checking the database only, never Sentry, OTLP or vendor
APIs.

## Metrics boundary

Phoenix, Ecto, Oban and provider events are defined in
`SimpleFitWeb.Telemetry.metrics/0`. No reporter or metrics backend is added:
no Prometheus, Grafana or vendor agent. Exporting metrics is a later decision
(OTel metrics or a Prometheus reporter fed from the same definitions).

## Dependencies

All are pinned through `mix.lock`, compiled warning-free for our code on
OTP 29 / Elixir 1.20, and from official or ecosystem sources:
- `sentry` 13.5.1 (MIT). Uses the existing Finch, so no new HTTP stack.
- `opentelemetry` 1.7.0, `opentelemetry_api` 1.5.0, `opentelemetry_exporter`
  1.11.0 (Apache-2.0, OpenTelemetry project). The exporter pulls
  `grpcbox`/`chatterbox` transitively; we use HTTP/protobuf.
- From `opentelemetry-erlang-contrib` (Apache-2.0):
  - `opentelemetry_phoenix` 2.0.1
  - `opentelemetry_bandit` 0.3.0
  - `opentelemetry_ecto` 1.2.0
  - `opentelemetry_oban` 1.2.0
  - `opentelemetry_req` 1.0.0

  Some have infrequent releases. They are the official instrumentation and
  thin telemetry adapters; their privacy gaps are closed by `SpanSanitizer`.
