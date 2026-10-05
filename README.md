# simplefit-api

Backend for **SimpleFit Boxing**, the operating system and professional
network for boxing, connecting fighters, coaches and gyms.

This repository is the canonical owner of SimpleFit's domain logic,
authorization, business rules, validation, persistence and API contract. Web
and mobile applications are clients of the REST API it exposes.

> Status: foundation (SF-2). Infrastructure, conventions, health endpoint,
> error contract, OpenAPI and CI are in place. No product domains yet.

## Architecture at a glance

* **Elixir / Phoenix 1.8**, API-only, **modular monolith**: domain contexts
  in `lib/simple_fit/`, HTTP layer in `lib/simple_fit_web/`
* **PostgreSQL** via Ecto, UUID primary keys
* **REST + JSON**, contract in **OpenAPI 3** (code-first, committed artifact)
* One JSON **error envelope** for every failure

Read [`docs/architecture/README.md`](docs/architecture/README.md) before
contributing; decisions live in [`docs/architecture/adr/`](docs/architecture/adr/).
Rules for AI-assisted sessions are in [`CLAUDE.md`](CLAUDE.md).

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Erlang/OTP | 29.1.1 | pinned in `.tool-versions` |
| Elixir | 1.20.4 (OTP 29 build) | pinned in `.tool-versions` |
| PostgreSQL | 14+ (CI runs 17) | local server on `localhost:5432` |
| Node.js | 22+ | optional; only for `redocly` OpenAPI linting |

With [mise](https://mise.jdx.dev) or [asdf](https://asdf-vm.com), run
`mise install` / `asdf install` in the repo root. Homebrew also works
(`brew install erlang elixir`) as long as the versions match.

## Getting started

```bash
git clone https://github.com/EugeniBykovski/simplefit-api.git
cd simplefit-api

mix setup            # deps.get + ecto.create + ecto.migrate
mix phx.server       # or: iex -S mix phx.server
```

The API listens on <http://localhost:4000>:

```bash
curl -s localhost:4000/api/health
# {"status":"ok","service":"simplefit-api"}
```

## Environment

Configuration comes from environment variables, read only in
[`config/runtime.exs`](config/runtime.exs). [`.env.example`](.env.example)
documents every variable, split into **required now**, **optional**,
**providers** (S3 storage and Resend email, implemented) and **future
providers** (reserved names that are not read yet).

```bash
cp .env.example .env          # .env is git-ignored; never commit secrets
set -a; source .env; set +a   # export into your shell (or use direnv)
```

The app deliberately does not auto-load `.env` (see ADR 0001). Development
works with **no variables set**: storage returns fake URLs and emails are
logged instead of sent unless you export AWS / Resend credentials. Production
requires `DATABASE_URL`, `SECRET_KEY_BASE` and `PHX_HOST` and refuses to boot
without them; storage and email fail closed until their variables are set
(see [ADR 0005](docs/architecture/adr/0005-provider-boundaries-and-http-client.md)).
Background jobs run on Oban in the same PostgreSQL database
([ADR 0006](docs/architecture/adr/0006-background-jobs-oban.md)).

## PostgreSQL

Development defaults (`config/dev.exs`): user `postgres`, password `postgres`,
host `localhost`, database `simple_fit_dev`. Override with `DATABASE_URL`.

Tests use the separate database `simple_fit_test` (with the same local
credentials). They **ignore `DATABASE_URL`** so they can never touch your dev
data. Use `TEST_DATABASE_URL` to point them elsewhere.

If your local server has no `postgres` role:

```bash
createuser -s postgres
psql -d postgres -c "ALTER USER postgres PASSWORD 'postgres';"
```

## Database commands

| Command | What it does |
| --- | --- |
| `mix ecto.create` | Create the database for the current `MIX_ENV` |
| `mix ecto.migrate` | Run pending migrations |
| `mix ecto.rollback` | Roll back the last migration |
| `mix ecto.reset` | Drop, create and migrate (destroys local data) |
| `mix ecto.gen.migration name` | Create a new migration (UUID keys by default) |

There are no product tables yet. Ecto manages its own `schema_migrations`
table.

## Tests

```bash
mix test                 # creates/migrates the test DB, then runs ExUnit
mix test --cover         # with coverage (output in cover/, git-ignored)
```

Tests run against PostgreSQL through the Ecto SQL sandbox, so they are
isolated and can run `async: true`.

## Quality checks

```bash
mix quality
```

runs, in order:

1. `deps.unlock --check-unused`: no stale entries in `mix.lock`
2. `format --check-formatted`
3. `compile --warnings-as-errors --force`
4. `credo --strict`
5. `openapi.check`: OpenAPI validation and drift detection
6. `dialyzer`: the first run builds PLTs into `priv/plts/` (a few minutes)

Run `mix quality && mix test` before pushing. CI runs the same checks.

## OpenAPI

The contract is **code-first** (`open_api_spex`): operations are declared on
controllers, schemas in `lib/simple_fit_web/schemas/`, and the root document
in `SimpleFitWeb.ApiSpec`. The canonical artifact
[`openapi/simplefit.api.json`](openapi/simplefit.api.json) is generated and
committed. See [ADR 0002](docs/architecture/adr/0002-openapi-strategy.md).

```bash
mix openapi.gen                              # regenerate the artifact after API changes
mix openapi.check                            # validate + fail on drift (also in mix quality)
npx --yes @redocly/cli@2.57.0 lint           # OpenAPI 3 structural lint (CI runs this)
```

Never edit the JSON by hand. Commit the regenerated artifact with the code
change that caused it.

## API documentation

With the server running in dev:

* **Interactive reference (Scalar):** <http://localhost:4000/api/docs>
* **OpenAPI document:** <http://localhost:4000/api/openapi>

Both are disabled in production unless `API_DOCS_ENABLED=true`.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/health` | Liveness check |
| GET | `/api/openapi` | OpenAPI document (when docs are enabled) |
| GET | `/api/docs` | Interactive API reference (when docs are enabled) |

Errors always use this shape (see [ADR 0003](docs/architecture/adr/0003-api-versioning-and-errors.md)):

```json
{"error": {"code": "not_found", "message": "The requested resource was not found", "details": {}, "request_id": "GHx3kP0vZ8sAAAAB"}}
```

## Repository conventions

* `lib/simple_fit/`: contexts own business rules, authorization and
  persistence. `lib/simple_fit_web/`: thin controllers, `*JSON` views,
  OpenAPI schemas.
* API changes include OpenAPI changes (`mix openapi.gen`) and tests.
* Product endpoints go under `/api/v1` and change additively.
* Migrations are immutable once merged.
* No secrets in Git; configuration is read only in `config/runtime.exs`.
* New dependencies need a written justification (see
  [ADR 0004](docs/architecture/adr/0004-deferred-infrastructure.md) for
  what was deliberately deferred).
* Branch per Jira ticket (e.g. `SF-12-fighter-profiles`); PRs must pass CI.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull
request and on pushes to `main`:

* **Test**: deps (locked), unused-deps check, compile with warnings as
  errors, `mix test` against PostgreSQL 17
* **Quality**: format, compile, Credo, `openapi.check`, Dialyzer (cached PLT)
* **OpenAPI lint**: Redocly `recommended-strict`
