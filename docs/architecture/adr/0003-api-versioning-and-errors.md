# ADR 0003 — API URL layout, versioning and error contract

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-2

## Context

Mobile clients stay installed for months and cannot be force-upgraded
instantly, so the API must evolve without breaking them. All clients also
need one predictable way to understand failures.

## Decision: URL layout and versioning

* **Operational endpoints** live unversioned under `/api`: `/api/health`,
  `/api/openapi`, `/api/docs`. Their contracts are tiny and stable.
* **Product resources** will live under **`/api/v1`**, starting with the
  first domain endpoint. No `/api/v1` scope exists yet because there are no
  routes to put in it.
* Within v1, changes are **additive only**: new endpoints, new optional
  request fields, new response fields, new error codes. Clients must ignore
  unknown response fields and treat unknown error codes by HTTP status.
* A breaking change requires an explicit ticket. It is shipped as a new
  endpoint, or as `/api/v2` for a broad redesign, with v1 kept alive through a
  documented deprecation window.
* `info.version` in OpenAPI (from `mix.exs` `version`) is the contract
  revision; the URL major version changes only on breaking changes.

Rejected: header/media-type versioning (harder to debug, cache and document)
and starting with no version prefix (moving later would itself be breaking
for every mobile build already in the field).

## Decision: error envelope

Every non-2xx response has this body:

```json
{
  "error": {
    "code": "validation_error",
    "message": "Request validation failed",
    "details": { "fields": { "email": ["has invalid format"] } },
    "request_id": "GHx3kP0vZ8sAAAAB"
  }
}
```

| Field | Contract |
| --- | --- |
| `code` | Required. Stable snake_case identifier; clients branch on it. |
| `message` | Required. Fixed English summary per code; for developers, not end users; may change. |
| `details` | Required object, `{}` when empty. Code-specific. For `validation_error`: `fields` → `{field: [message, ...]}` (nested fields use dotted paths). |
| `request_id` | Required, nullable. Equals the `x-request-id` response header. |

Catalog (source of truth: `SimpleFitWeb.APIError`):

| Code | Status | Typical cause |
| --- | --- | --- |
| `bad_request` | 400 | Malformed JSON, invalid parameter types |
| `unauthorized` | 401 | Missing/invalid/expired credentials |
| `forbidden` | 403 | Authenticated but not allowed |
| `not_found` | 404 | Unknown route or resource (also returned instead of 403 when existence itself must not leak) |
| `not_acceptable` | 406 | `Accept` does not allow JSON |
| `conflict` | 409 | Uniqueness/state conflicts, stale updates |
| `payload_too_large` | 413 | Body over the parser limit |
| `unsupported_media_type` | 415 | Body is not `application/json` |
| `validation_error` | 422 | Well-formed request that fails validation |
| `rate_limited` | 429 | Rate limit exceeded (with `retry-after` when implemented) |
| `internal_error` | 500 | Unexpected failure |
| `service_unavailable` | 503 | Dependency down, maintenance |

Statuses outside the catalog get a code derived from the reason phrase
(e.g. 405 → `method_not_allowed`), so the envelope is always complete.

Rules:

* Responses never include exception messages, stack traces, SQL, request
  bodies or configuration.
* Exceptions are rendered by `SimpleFitWeb.ErrorJSON` (Phoenix
  `render_errors`). Parser errors are re-raised with the current conn so they
  keep the request id and security headers.
* Domain errors (`{:error, reason}` from contexts) will be mapped by a
  `FallbackController` built on `APIError.envelope/2` when the first context
  exists.
* OpenAPI: `ErrorResponse`/`Error` schemas plus one reusable response per code
  (`#/components/responses/NotFound`, ...), referenced via
  `SimpleFitWeb.ApiSpec.error_response/1`.

We did not adopt RFC 9457 (`application/problem+json`). The `{"error": {...}}`
envelope is simpler for mobile clients to decode, has a guaranteed
machine-readable `code`, and carries `request_id` explicitly. Migrating later
would be a breaking change, so this is a deliberate commitment.
