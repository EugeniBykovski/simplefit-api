# ADR 0002 — OpenAPI strategy

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-2

## Context

OpenAPI is a first-class contract for SimpleFit. Web and mobile clients (and
generated SDKs) depend on it. Requirements: one canonical source, a committed
artifact, deterministic generation, validation, drift detection in CI,
reusable error schemas, a reserved bearer auth scheme, and good interactive
docs.

## Options considered

| Option | Notes |
| --- | --- |
| **`open_api_spex` 3.22 (code-first)** | De-facto standard for Phoenix (~12M downloads). Actively maintained (3.22.4, Aug 2026), MPL-2.0. Operations declared next to controllers; specs collected from the router. Provides spec export, request casting/validation plugs and test assertions. Emits OpenAPI 3.0. |
| `oaskit` 0.17 (code- or spec-first, JSON Schema via JSV) | Modern design and OpenAPI 3.1 support, but pre-1.0 with releases almost weekly (0.16 → 0.17 in one week). Too young to anchor the canonical contract. Worth re-evaluating at 1.0. |
| Spec-first (hand-written YAML + validation plug) | One readable file, but every endpoint is then defined twice (YAML + router/controller) unless code is generated from YAML. The Elixir tooling for that is thin, and nothing prevents drift between spec and behaviour. |

## Decision

**Code-first with `open_api_spex`.** The single source of truth is the Elixir
code:

* `SimpleFitWeb.ApiSpec` builds the document: info, servers, tags, reusable
  error responses, `bearerAuth` security scheme, and paths collected from
  `SimpleFitWeb.Router`.
* Each controller action declares its `operation` (camelCase `operation_id`,
  summary, tags, request body, responses).
* Shapes live in `SimpleFitWeb.Schemas.*`, each with a constant `example`.
* The error schemas and one reusable response per error code are generated
  from `SimpleFitWeb.APIError`, so the error catalog is defined only once.

**Canonical artifact:** `openapi/simplefit.api.json` is generated, committed
and never edited by hand.

| Command | Purpose |
| --- | --- |
| `mix openapi.gen` | Regenerate the artifact (pretty JSON, recursively sorted keys, trailing newline, so it is byte-for-byte deterministic) |
| `mix openapi.check` | Contract validation (operation ids, summaries, declared tags, every example valid against its schema) **plus** drift detection (artifact must equal freshly generated output). Part of `mix quality` and CI. |
| `npx --yes @redocly/cli@2.57.0 lint` | Structural validation against the OpenAPI 3 spec plus the `recommended-strict` ruleset (`redocly.yaml`). Runs in CI. Requires Node locally. |

The test suite also asserts the artifact is current and that real responses
match their schemas (`OpenApiSpex.TestAssertions.assert_schema/3`).

**Served document:** `GET /api/openapi` renders the same spec at runtime
(`OpenApiSpex.Plug.RenderSpec`). A test asserts it is identical to the
committed artifact.

**Interactive docs:** `GET /api/docs` serves **Scalar**, chosen over Swagger
UI for clearer navigation, better schema/example rendering, a built-in
request client with bearer-token support, and a modern UI. It is a static HTML
shell (no custom frontend) that loads a version-pinned bundle from jsDelivr
with Subresource Integrity, under a page-specific CSP that allows network
calls only to the API's own origin. Scalar telemetry, AI agent, MCP and
remote fonts are disabled.

**Exposure:** docs and the served document are enabled in dev/test and
disabled in production unless `API_DOCS_ENABLED=true`. When disabled, they are
indistinguishable from unknown routes (404 `not_found`). The committed
artifact is the way to share the contract without exposing it.

## Consequences

* Every API change must include the regenerated artifact; CI fails otherwise,
  and contract changes are visible in PR diffs.
* `open_api_spex` emits OpenAPI 3.0.3, not 3.1 (nullable via `nullable: true`).
  Moving to 3.1 means a library change, so it would get its own ADR.
* Request validation (`OpenApiSpex.Plug.CastAndValidate`) is available for
  endpoints that take input. Its error rendering must be adapted to the
  `validation_error` envelope when the first such endpoint lands.
* Upgrading Scalar means updating the version and SRI hash in
  `SimpleFitWeb.ApiDocsController`.
