# ADR 0007 — Cross-origin (CORS) policy

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-6 (supersedes the CORS row of ADR 0004)

## Context

SF-2 shipped deny-by-default CORS: no CORS headers at all, because no
browser client existed. `simplefit-platform` now calls the API from the
browser:
- **App:** `http://localhost:3000` in development.
- **API:** `http://localhost:4000`.

`GET /api/health` returned 200, but the browser blocked the response: there
was no `Access-Control-Allow-Origin`, and the `OPTIONS` preflight answered
404. The API owns its cross-origin policy, so a Next.js proxy is not an
option: it would only hide the problem.

## Decision

`SimpleFitWeb.CORS` is a small plug in the endpoint, after `Plug.RequestId`
and the security headers.
- **Explicit allow-list.** Only exact origins (`scheme://host[:port]`) from
  `config :simple_fit, SimpleFitWeb.CORS, allowed_origins:` get CORS
  headers. There is no wildcard and no pattern matching.
- **Allowed origin:**
  - `access-control-allow-origin: <origin>`, `vary: origin`, and
    `access-control-expose-headers: x-request-id`, so clients can read the
    id for support.
  - This applies to error responses too.
- **Unknown origin:** no CORS headers, only `vary: origin`. The request is
  still processed, as CORS is browser-enforced, but the browser blocks the
  response. Requests without `Origin` (mobile apps, servers) are unaffected.
- **Preflight** (`OPTIONS` + `access-control-request-method`):
  - **Allowed:** answered with `204`. Methods `GET, POST, PUT, PATCH, DELETE`;
    headers `accept, accept-language, authorization, content-type`;
    `max-age 600`.
  - **Refused:** an unknown origin, method or header gets
    `403 forbidden` in the standard error envelope, with no CORS headers.
- **No credentials.** `access-control-allow-credentials` is never sent.
  Authentication will use bearer tokens in `Authorization`, not cookies.
  **Revisit this policy before any cookie-based or credentialed flow.**

## Configuration

`CORS_ALLOWED_ORIGINS`: comma-separated exact origins, parsed by
`SimpleFitWeb.CORS.parse_origins!/2` in `config/runtime.exs`.

| Environment | Behaviour |
| --- | --- |
| dev | Default `http://localhost:3000` (`pnpm dev` in simplefit-platform). Setting the variable replaces the list; add `http://127.0.0.1:3000` only if you browse the app that way (Next prints `localhost`). |
| test | Fixed `["http://localhost:3000"]` in `config/test.exs`. |
| prod | Explicit **https** origins only. Unset or blank: no browser origin allowed (fail closed). `*`, paths, trailing slashes, non-https or malformed values **stop the boot** with an explicit error. No future domain is hard-coded. |

## Alternatives

- **`corsica`** (planned in ADR 0004): its last release is 2.1.3, from
  October 2023, which falls short of the dependency policy's
  active-maintenance bar for a security-relevant plug. The needed policy is
  small (~100 lines) and fully tested, so we own it.
- **Next.js rewrites/proxy:** rejected, because it hides the API's policy and
  breaks for other browser clients.
