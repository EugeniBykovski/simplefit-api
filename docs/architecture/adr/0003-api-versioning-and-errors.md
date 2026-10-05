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
    "details": {
      "fields": { "email": ["can't be blank", "has invalid format"] },
      "field_codes": { "email": ["required", "invalid_format"] }
    },
    "request_id": "GHx3kP0vZ8sAAAAB"
  }
}
```

| Field | Contract |
| --- | --- |
| `code` | Required. Stable snake_case identifier; clients branch on it. |
| `message` | Required. Fixed English summary per code; for developers, not end users; may change. |
| `details` | Required object, `{}` when empty. Code-specific. For `validation_error`: `fields` → `{field: [message, ...]}` and, since SF-6, `field_codes` → `{field: [reason_code, ...]}` (nested fields use dotted paths). |
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
* Domain errors (`{:error, reason}` from contexts) are mapped by
  `SimpleFitWeb.FallbackController` (SF-6); plugs use
  `APIError.send_error/3` directly. See "Validation and domain errors (SF-6)".
* OpenAPI: `ErrorResponse`/`Error` schemas plus one reusable response per code
  (`#/components/responses/NotFound`, ...), referenced via
  `SimpleFitWeb.ApiSpec.error_response/1`.

We did not adopt RFC 9457 (`application/problem+json`). The `{"error": {...}}`
envelope is simpler for mobile clients to decode, has a guaranteed
machine-readable `code`, and carries `request_id` explicitly. Migrating later
would be a breaking change, so this is a deliberate commitment.

## Validation and domain errors (SF-6)

**Field reason codes are additive.** `details.fields` keeps its published
SF-2 shape: field to a list of messages. Changing those strings into objects
would silently break the shipped web and mobile parsers.

`details.field_codes` is the machine-readable companion:
- **Keys:** the same keys as `fields`.
- **Entries:** per field, the same number of entries in the same order (the
  order the validations ran). `field_codes[f][i]` explains `fields[f][i]`.
- **Source:** `SimpleFitWeb.ChangesetErrors` derives codes from Ecto's
  structured error metadata (`:validation`, `:kind`, `:constraint`,
  `:type`), never from message text.

| Reason code | From |
| --- | --- |
| `required` | `validate_required` |
| `invalid_format` | `validate_format` |
| `too_short` / `too_long` / `wrong_length` | `validate_length` (`min` / `max` / `is`) |
| `out_of_range` | `validate_number` |
| `invalid_choice` | `validate_inclusion`, `validate_subset`, `validate_exclusion` |
| `invalid_type` | cast failures |
| `already_exists` | `unique_constraint`, `unsafe_validate_unique` |
| `does_not_exist` | `foreign_key_constraint`, `assoc_constraint` |
| `must_be_accepted` / `does_not_match` | `validate_acceptance` / `validate_confirmation` |
| `invalid` | anything else (e.g. custom `add_error/3`) |

The list is additive; clients treat unknown codes as `invalid`.
Domain-specific reasons are added by the domain ticket that needs them, with a
structured `add_error/4` option rather than a message convention.

**Fallback mapping** (`SimpleFitWeb.FallbackController`):

| Context result | Public code |
| --- | --- |
| `%Ecto.Changeset{}` | `validation_error` |
| `:not_found`, `:forbidden`, `:conflict` | same code |
| retryable provider reason (`:rate_limited`, `:timeout`, `:unavailable`) | `service_unavailable` |
| other provider reason (`:unauthorized`, `:invalid_request`, `:configuration_error`) | `internal_error` |
| anything else | `internal_error`, with the reason logged under the request id |

Provider reasons describe SimpleFit's own call to a vendor, so they never
become a client 401/429. Client authentication and rate limiting send
`unauthorized` / `rate_limited` from their plugs with `APIError.send_error/3`
(`retry_after:` sets `retry-after`).

**Rule for clients:** web and mobile branch on `code` and `field_codes`, never
on `message` or `fields` text. Code such as `message.includes("already exists")`
is a defect.

