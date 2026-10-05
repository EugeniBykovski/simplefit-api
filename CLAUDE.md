# CLAUDE.md — SimpleFit API engineering rules

Rules for every Claude Code session in this repository. They are
non-negotiable unless the Jira ticket you are working on explicitly says
otherwise. If a ticket seems to require breaking one, stop and ask.

Read `docs/architecture/README.md` and the ADRs in `docs/architecture/adr/`
before making structural changes.

## What this is

Elixir/Phoenix 1.8 JSON API (OTP app `:simple_fit`, modules `SimpleFit.*`
and `SimpleFitWeb.*`), PostgreSQL via Ecto, OpenAPI 3 via `open_api_spex`.
Toolchain pinned in `.tool-versions` (OTP 29.1.1, Elixir 1.20.4).

## Non-negotiable rules

### Architecture
1. **The backend owns business logic.** Validation, authorization, pricing,
   state transitions and permissions are decided here. Never design an API
   that relies on the client to enforce a rule.
2. **Modular monolith.** One app, one database. Do not introduce
   microservices, GraphQL, Redis, Elasticsearch, Neo4j, Kubernetes, event
   sourcing or CQRS.
3. **Contexts own domain boundaries.** Only a context touches its schemas and
   `Repo` queries. Other code calls the context's public functions.
4. **Controllers stay thin.** Params in → one context call → render via a
   `*JSON` module. No `Repo`, no business branching, no role checks.
5. **Authorization is a domain concern.** Pass the actor into context
   functions; the context decides.
6. **Vendors sit behind provider behaviours** named for the capability
   (`Storage`, `Email`, `Payments`, `Identity`), introduced together with the
   first real adapter. Domain code never calls a vendor SDK directly.

### API contract
7. **OpenAPI changes accompany API changes.** Any route, param, request or
   response change must update the `operation`/schemas, then run
   `mix openapi.gen` and commit `openapi/simplefit.api.json`. Never hand-edit
   that file.
8. **Never silently change public API contracts.** Preserve backwards
   compatibility unless the ticket explicitly permits a breaking change.
   Additive changes only within `/api/v1`. No renaming/removing fields,
   tightening validation or changing types or error codes without an explicit
   ticket.
9. **All errors use the envelope** from `SimpleFitWeb.APIError`
   (`{"error": {code, message, details, request_id}}`). Add new codes to the
   catalog there (OpenAPI follows automatically). Never put exception
   messages, stack traces or internal details into responses.
10. Product endpoints live under `/api/v1`. Every operation has a camelCase
    `operation_id`, a summary, a declared tag and all its responses
    (reference shared errors with `ApiSpec.error_response/1`).

### Data
11. **Migrations are immutable after merge.** Fix forward with a new
    migration. Migrations must be reversible.
12. UUID primary keys (already the default). Never expose Ecto schemas
    directly in JSON; views pick fields explicitly.

### Security
13. **Secrets never enter Git.** No keys, tokens, passwords or real `.env`
    files. Read configuration only in `config/runtime.exs` from env vars and
    document every new variable in `.env.example`.
14. Do not weaken the security baseline (security headers, JSON-only parsing,
    deny-by-default CORS, docs disabled in prod, log filtering) without an
    explicit ticket. Never enable `*` CORS in production.
15. Never log secrets, tokens, full request bodies or personal data.

### Quality
16. **Tests accompany behaviour.** New or changed behaviour ships with ExUnit
    tests. Assert JSON responses against OpenAPI schemas
    (`OpenApiSpex.TestAssertions.assert_schema/3`).
17. **Do not add dependencies without justification**: the current problem,
    why existing tools fall short, maintenance status, license. Check
    `docs/architecture/adr/0004-deferred-infrastructure.md` and update it.
18. **Avoid speculative abstractions.** No empty modules, behaviours,
    directories or "future" layers. Build what the ticket needs.
19. Fix warnings, Credo issues and Dialyzer errors. Do not suppress them.
20. Do not leave TODO implementations disguised as finished work.

## Commands

```bash
mix setup                 # deps + create/migrate DB
mix phx.server            # http://localhost:4000 (docs at /api/docs)
mix test                  # tests (PostgreSQL test DB)
mix quality               # unused deps, format, warnings, credo --strict, openapi.check, dialyzer
mix openapi.gen           # regenerate openapi/simplefit.api.json
mix openapi.check         # validate spec + detect drift
npx --yes @redocly/cli@2.57.0 lint   # OpenAPI structural lint
```

**Definition of done:** `mix quality` and `mix test` pass, the OpenAPI
artifact is regenerated if the API changed, docs/ADRs are updated if a
convention or dependency changed.

## Git

* Branch per ticket (`SF-<n>-short-description`). Never rewrite published
  history. Never push or merge without passing checks.
* Commit messages: imperative, reference the ticket (`SF-12: Add fighter profile API`).
