# SimpleFit Engineering Standards

Canonical rules for every SimpleFit ticket (SF-14). **This file is shared and
kept identical** in `simplefit-api`, `simplefit-platform` and
`simplefit-mobile`; change it only through an SF ticket that updates all
three. Repository-specific rules live in each repository's `CLAUDE.md` and
`docs/architecture/`.

## 1. Repository map and ownership

| Repository           | Stack                        | Owns                                                                                                                                                                                                                                  |
| -------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simplefit-api`      | Elixir / Phoenix, PostgreSQL | Business and domain rules, persistence, authentication and authorization enforcement, permissions, billing rules, provider orchestration, background jobs, server-side validation, security decisions, **the API contract (OpenAPI)** |
| `simplefit-platform` | Next.js                      | Public website, authenticated web app, Coach / Gym Web, Sponsor Portal, Admin, web presentation, browser behaviour                                                                                                                    |
| `simplefit-mobile`   | Expo / React Native          | Fighter, Coach and Gym mobile experiences, native-device integration, mobile presentation                                                                                                                                             |

Frontends render, collect input and call the API. They never become a second
owner of business rules, never persist product data themselves and never
decide what is allowed. Cross-product material (product, design, investor
documents) lives in the workspace-level `docs/`, which is not a repository;
engineering rules live here.

## 2. Git workflow

```
main → SF-<ticket>-<kebab-description> → implementation → local quality gates
     → push → pull request → CI → review → merge (by an authorized human)
```

- Branch name: `SF-<ticket>-<short-kebab-description>`, e.g.
  `SF-16-identity-authentication`. No `feature/`, `fix/` or `chore/` prefixes.
- One Jira ticket → one branch per affected repository, same name in each.
- Never commit or push directly to `main`. Never force-push `main`. Never
  rewrite shared (pushed) history; fix forward with new commits.
- Claude prepares branches, commits, pushes and PRs but **never merges a PR**
  unless the user explicitly says so.

## 3. Commits

```
<type>: SF-<ticket> - <description>

feat: SF-16 - add identity domain
test: SF-16 - cover session rotation
docs: SF-16 - document authentication architecture
```

- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`,
  `perf`. No scopes. Header ≤ 100 characters, imperative description.
- Enforced by commitlint (hooks + CI) in web and mobile and by a CI check in
  the API. Merge commits and GitHub's `Revert "…"` commits are exempt.
- Small, coherent commits; no commits made only to satisfy the convention.
  Already-merged history is never rewritten to comply.
- PR title: `SF-<ticket> — <Title>`, e.g. `SF-16 — Identity Authentication`.

## 4. API contract

```
Phoenix implementation → OpenAPI (code-first) → committed deterministic artifact
  (simplefit-api/openapi/simplefit.api.json) → generated TypeScript clients → web / mobile
```

- `simplefit-api` is the only contract owner. Contract changes start there,
  with the regenerated artifact committed in the same PR.
- Web and mobile copy the artifact into their own snapshot and generate the
  client with Orval (`pnpm api:generate`), then commit snapshot and generated
  code together in a ticket branch. `pnpm api:check` fails on drift. Generated
  code and snapshots are never edited by hand.
- No hand-written duplicates of backend DTOs. No second database owner:
  no Prisma, Drizzle, Supabase or similar as an application persistence layer.

## 5. Quality gates

Run locally before pushing; CI runs the same commands on every PR and on `main`.

| Repository           | Gates                                                                                                                                                                                                                                                                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simplefit-api`      | `mix deps.get --check-locked`, `mix deps.unlock --check-unused`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test --warnings-as-errors`, `mix openapi.check`, `mix dialyzer`, `npx --yes @redocly/cli@2.57.0 lint`. Aggregate: `mix quality` (everything except tests and Redocly) **plus** `mix test`. |
| `simplefit-platform` | `pnpm install --frozen-lockfile`, then `pnpm quality` = lint, format check, typecheck, Vitest, `api:check`, production build.                                                                                                                                                                                                                              |
| `simplefit-mobile`   | `pnpm install --frozen-lockfile`, then `pnpm quality` = lint, format check, typecheck (with typed routes), Jest, `api:check`, `expo install --check`, `expo config`, expo-doctor, iOS + Android JS bundle export.                                                                                                                                          |

- Tests are deterministic and offline: no provider accounts, no production
  credentials, no internet.
- Native iOS/Android builds need Xcode / the Android SDK (or EAS Build) and are
  validated outside CI; CI proves the JavaScript bundles only.
- Gates are never weakened or skipped (`--no-verify`, disabled rules) to land
  a change.

## 6. Package management (web and mobile)

- pnpm version comes from `packageManager` (`pnpm@12.9.1`) through Corepack;
  Node from `.nvmrc`. Setup: `nvm use && corepack enable`. Do not maintain a
  global pnpm; a stray global pnpm can rewrite `pnpm-lock.yaml`.
- Install with `pnpm install --frozen-lockfile`. Lockfile changes are
  committed only with an intentional dependency change, never incidental
  churn from a different pnpm.
- CI installs the pinned pnpm from `packageManager` and uses the frozen lockfile.
- The API pins Erlang/Elixir in `.tool-versions`; `mix.lock` is committed and
  CI uses `mix deps.get --check-locked`.

## 7. Styling (web and mobile)

- Ordinary styling uses utility classes directly on components: Tailwind in
  web, NativeWind `className` in mobile, with semantic design tokens
  (`bg-surface`, `text-muted-foreground`) and shared UI primitives instead of
  repeated raw values.
- No `StyleSheet.create` blocks, CSS modules, styled-components/emotion or
  static inline style objects for routine UI. ESLint enforces this.
- `style` is allowed only when technically justified: Reanimated / gesture
  styles, runtime-computed values (safe-area insets, dynamic sizes), CSS
  variables (`vars()`), native APIs or libraries that require style objects.
  Static exceptions carry an inline lint-disable with the reason.
- The SimpleFit design system itself is SF-13's scope.

## 8. Dependencies and architecture guardrails

- A dependency is added only for a current need, with the justification
  (problem, why existing tools fall short, maintenance, license) in the PR.
  Nothing is added "for later". Versions are pinned through lockfiles.
- Backend: modular monolith; PostgreSQL / Ecto is the system of record;
  REST + OpenAPI is the client contract. No microservices, GraphQL, Redis,
  Elasticsearch, Neo4j or Kubernetes without a demonstrated need recorded in an ADR.
- External providers sit behind SimpleFit-owned boundaries (`SimpleFit.Storage`,
  `SimpleFit.Email`, …); domain and client code never call vendors directly.
- Large media goes directly between clients and object storage through
  presigned URLs; Phoenix never proxies file bytes.
- Architectural decisions are recorded as ADRs in the owning repository.

## 9. Environment and secrets

- `.env.example` holds variable names and safe placeholders only; real `.env`
  files are git-ignored. Every variable read by code is documented there.
- No secrets in Git, logs, tests, fixtures or examples. Production
  configuration comes from the runtime environment / secret manager.
- Public client variables (`NEXT_PUBLIC_*`, `EXPO_PUBLIC_*`) are visible to
  everyone: never put credentials in client bundles.

## 10. Generated artifacts

| Artifact                                                                 | Generated by        | Rule                                       |
| ------------------------------------------------------------------------ | ------------------- | ------------------------------------------ |
| `simplefit-api/openapi/simplefit.api.json`                               | `mix openapi.gen`   | Committed; drift fails `mix openapi.check` |
| `openapi/simplefit.api.json` + `src/shared/api/generated/` (web, mobile) | `pnpm api:generate` | Committed; drift fails `pnpm api:check`    |
| `pnpm-lock.yaml`, `mix.lock`                                             | package managers    | Committed; frozen in CI                    |
| `AGENTS.md` (web)                                                        | `next dev`          | Committed as maintained by Next.js         |
| `ios/`, `android/`, `dist/`, `.next/`, `_build/`, `deps/`                | build tools         | Never committed                            |

## 11. Definition of Done

A ticket is Done when, normally:

1. the ticket scope and acceptance criteria are implemented, and nothing unrelated changed;
2. architecture boundaries and these standards are respected;
3. relevant tests are added or updated;
4. formatters, linters, type checks / static analysis and builds pass locally;
5. the API contract (and generated clients) are updated when applicable;
6. migrations are forward-safe, reversible where practical and verified;
7. docs / ADRs are updated for architectural decisions;
8. no secrets or incidental lockfile/generated changes are included;
9. the branch is pushed, a PR is open and CI is green;
10. the PR is reviewed and **merged by an authorized human**.

Claude may complete steps 1–9 but never reports a ticket as merged or CI as
green unless that actually happened.

## 12. Final report (Claude)

Every ticket ends with a report covering: repositories and branches, commits,
files added/modified, decisions and dependency changes with justification,
commands run with their actual results, what was not validated and why,
working-tree / push / PR / CI status per repository, known limitations and
follow-up tickets. Never report a command as passing unless it ran.
