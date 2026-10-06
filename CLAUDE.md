# CLAUDE.md — SimpleFit API engineering rules

Rules for every Claude Code session in this repository. They are
non-negotiable unless the Jira ticket you are working on explicitly says
otherwise. If a ticket seems to require breaking one, stop and ask.

Read `docs/engineering-standards.md` (shared SimpleFit workflow, commits,
ownership, quality gates, Definition of Done) and `docs/architecture/README.md`
with the ADRs in `docs/architecture/adr/` before making structural changes.

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
6. **Vendors sit behind provider boundaries** named for the capability
   (`SimpleFit.Storage`, `SimpleFit.Email`; future `Payments`, `Identity`,
   `Push`), introduced together with the first real adapter. Domain code
   calls the boundary, never an adapter, `Req` or a vendor library. Adapters
   make outbound HTTP calls only through `SimpleFit.HTTP` (never with user
   supplied URLs) and return `SimpleFit.Provider` error reasons; raw vendor
   responses never cross the boundary. Production never falls back to fake
   adapters. See ADR 0005.
7. **Background work uses Oban** (ADR 0006). Workers stay thin, take small
   JSON-serializable args re-validated in `perform/1`, use idempotency keys
   for side effects, retry only transient failures with bounded attempts.
   Add a queue only for a real isolation/concurrency need. Tests keep
   `testing: :manual`.

### API contract
8. **OpenAPI changes accompany API changes.** Any route, param, request or
   response change must update the `operation`/schemas, then run
   `mix openapi.gen` and commit `openapi/simplefit.api.json`. Never hand-edit
   that file.
9. **Never silently change public API contracts.** Preserve backwards
   compatibility unless the ticket explicitly permits a breaking change.
   Additive changes only within `/api/v1`. No renaming/removing fields,
   tightening validation or changing types or error codes without an explicit
   ticket.
10. **All errors use the envelope** from `SimpleFitWeb.APIError`
   (`{"error": {code, message, details, request_id}}`). Add new codes to the
   catalog there (OpenAPI follows automatically). Never put exception
   messages, stack traces or internal details into responses. Context errors
   go through `SimpleFitWeb.FallbackController`; validation details carry
   `fields` plus aligned `field_codes` derived from Ecto metadata (ADR 0003).
   Clients branch on codes, never on messages.
11. Product endpoints live under `/api/v1`. Every operation has a camelCase
    `operation_id`, a summary, a declared tag and all its responses
    (reference shared errors with `ApiSpec.error_response/1`).

### Data
12. **Migrations are immutable after merge.** Fix forward with a new
    migration. Migrations must be reversible.
13. UUID primary keys (already the default). Never expose Ecto schemas
    directly in JSON; views pick fields explicitly.
    **One global user** (`SimpleFit.Accounts`, ADR 0009): never add a role,
    type, profile, credential or provider column to `users`; identities are
    keyed by `{provider, provider_subject}` and never linked or merged because
    an email matches.

### Security
14. **Secrets never enter Git.** No keys, tokens, passwords or real `.env`
    files. Read configuration only in `config/runtime.exs` from env vars and
    document every new variable in `.env.example`.
15. Do not weaken the security baseline (security headers, JSON-only parsing,
    explicit-allow-list CORS (ADR 0007), docs disabled in prod, log filtering)
    without an explicit ticket. Never enable `*` CORS, never allow origins by
    pattern, never send CORS credentials without an authentication ticket that
    requires them.
16. Never log secrets, tokens, full request bodies or personal data, nor
    API keys, authorization headers, provider response bodies or presigned
    URLs. **Observe system behaviour, not user content** (ADR 0008): job args,
    query strings, SQL text and headers never reach logs, Sentry or traces;
    keep `SentryFilter`/`SpanSanitizer` allow-lists tight and use `:error`
    only for failures someone must act on (they go to Sentry). Storage stays private: clients upload/download directly with
    short-lived presigned URLs; Phoenix never proxies file bytes.

### Quality
17. **Tests accompany behaviour.** New or changed behaviour ships with ExUnit
    tests. Assert JSON responses against OpenAPI schemas
    (`OpenApiSpex.TestAssertions.assert_schema/3`).
18. **Do not add dependencies without justification**: the current problem,
    why existing tools fall short, maintenance status, license. Check
    `docs/architecture/adr/0004-deferred-infrastructure.md` and update it.
19. **Avoid speculative abstractions.** No empty modules, behaviours,
    directories or "future" layers. Build what the ticket needs.
20. Fix warnings, Credo issues and Dialyzer errors. Do not suppress them.
21. Do not leave TODO implementations disguised as finished work.

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

## Git and pull requests

See `docs/engineering-standards.md` §2–3 (identical in all SimpleFit repos).

* Branch per ticket from `main`: `SF-<ticket>-<kebab-description>`
  (e.g. `SF-16-identity-authentication`). Never commit or push to `main`,
  never force-push `main`, never rewrite pushed history.
* Commits: `<type>: SF-<ticket> - <description>` with type `feat`, `fix`,
  `refactor`, `test`, `docs`, `chore`, `build`, `ci` or `perf`
  (e.g. `feat: SF-16 - add identity domain`). CI rejects other PR commits.
* Run `mix quality`, `mix test` and the Redocly lint before pushing; open a PR
  titled `SF-<ticket> — <Title>`. **Never merge a PR** unless the user
  explicitly asks. Keep changes to the ticket's scope.
* Finish with the final report described in the standards (§12): commands
  actually run and their results, what was not validated, branch/PR/CI status.
