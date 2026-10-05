# ADR 0005 — Provider boundaries, canonical HTTP client, storage and email

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-15

## Context

SimpleFit will integrate many external providers (object storage, email,
payments, identity, push, analytics). Before the first domain feature uses
one, we need a consistent shape so vendor details never leak into contexts,
tests never need accounts or network access, and failures are predictable.
SF-15 introduces the first two real providers: AWS S3 (private media) and
Resend (transactional email).

## Decision

### Boundaries

Each capability has a SimpleFit-owned boundary module that defines a
behaviour, validates input and dispatches to the adapter selected in
application config. Adapters are the only modules that know a vendor.

```
Domain context (future: Accounts, Media, Gyms ...)
        ↓
SimpleFit.Storage / SimpleFit.Email        (boundary + behaviour)
        ↓
SimpleFit.Storage.S3 / SimpleFit.Email.Resend   (adapter)
        ↓
AWS S3 / Resend
```

* Adapters receive their config explicitly (`deliver(message, config, opts)`,
  `presign(request, config)`), which keeps them pure and async-testable.
* Dev/test adapters: `SimpleFit.Storage.Fake` (URLs on the non-resolvable
  `.invalid` domain), `SimpleFit.Email.Log` (dev, logs subject and recipient
  count only) and a test adapter in `test/support` that messages the test
  process. Production config always selects the real adapters.
* No registries, service locators or generic "external API" layer: one
  boundary per capability, introduced with its first real adapter.

### Error vocabulary

Every adapter returns `{:error, reason}` with `reason` from
`SimpleFit.Provider.error()`: `:invalid_request`, `:unauthorized`,
`:rate_limited`, `:timeout`, `:unavailable`, `:configuration_error`.
`SimpleFit.Provider.retryable?/1` separates transient from permanent
failures. Raw HTTP bodies, headers, credentials and signed URLs never cross
the boundary and are never logged.

### Canonical HTTP client: Req

`SimpleFit.HTTP` wraps `Req` (0.7, Apache-2.0, Finch/Mint underneath):

* TLS peer and hostname verification (default; never disabled),
* 5 s connect / 15 s receive timeouts,
* `retry: false`: retries belong to Oban jobs with bounded attempts and
  idempotency keys, so a failing provider cannot trigger request storms or
  duplicate side effects,
* `redirect: false`: provider responses cannot steer requests elsewhere,
* `normalize/2` maps statuses and transport errors to the vocabulary above
  and logs only provider, status and reason.

Base URLs are constants or trusted configuration, never user input (SSRF).
`Req.Test` stubs providers in tests without network access.

Considered: `Tesla` (adapter-agnostic but more configuration surface, no
built-in SigV4) and raw `Finch`/`Mint` (too low-level for every adapter).

### Storage: S3 via Req SigV4, presigned direct transfer

* Clients upload and download directly with presigned URLs; Phoenix never
  proxies bytes. Buckets are private; there are no public URLs.
* Presigning is local computation with `Req.Utils.aws_sigv4_url/1` (no
  network call). Uploads sign `content-type` and the exact
  `content-length`, so S3 rejects a different type or size; domains enforce
  their own limits before presigning. Lifetimes: default 15 min upload /
  5 min download, at most 1 hour. Single PUT up to 5 GiB; multipart uploads
  come with the media ticket if needed.
* Keys are built from validated segments (`SimpleFit.Storage.ObjectKey`):
  no traversal, absolute paths or characters needing encoding. Environments
  are separated by bucket, optionally by `AWS_S3_KEY_PREFIX`.
* `SimpleFit.Storage.Presigned` redacts the URL in `inspect/1`: a signed URL
  is a bearer credential until it expires.
* Credentials: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, plus
  `AWS_SESSION_TOKEN` for temporary credentials. `AWS_S3_ENDPOINT` supports
  S3-compatible services (MinIO) locally.

Considered: `ex_aws` + `ex_aws_s3`. Mature and it includes the AWS
credential provider chain (instance/ECS roles), but it brings a second HTTP
and configuration stack plus XML parsing for an operation that is pure
signing today. If deployment uses IAM roles, the deployment ticket adds a
small credential provider (or revisits this choice) behind the same adapter.

### Email: Resend over Req

`SimpleFit.Email.Resend` posts JSON to `https://api.resend.com/emails` with
bearer auth and an optional `idempotency-key`. Messages are validated in
`SimpleFit.Email.Message` (recipient limit, no CR/LF in headers, text or
HTML body). `SimpleFit.Email.deliver_later/1` enqueues delivery in the Oban
`mailers` queue (ADR 0006); each job uses `email-job-<id>` as idempotency
key, transient failures retry (max 5 attempts), permanent ones cancel.

Considered: `swoosh` (a full mailer framework with templates and previews
that this API-only app does not need yet) and the `resend` package
(pre-1.0). Neither adds value over one HTTP call behind our boundary.

### Configuration and fail-closed behaviour

* Values are read only in `config/runtime.exs`. A value that is set but
  malformed (region, bucket, endpoint, prefix, sender) fails boot.
* Production always configures the real adapters. Missing credentials do not
  block boot (no feature depends on them yet); operations then return
  `:configuration_error` and log the missing key names. Nothing falls back to
  a fake. `AWS_S3_ENDPOINT` must be `https://` in production.
* Development uses the real adapters only when their credentials are
  exported; otherwise Fake/Log, so no account is needed.

## Consequences

* New providers (Stripe, Google/Apple identity, push) follow the same
  pattern: boundary + behaviour + adapter on `SimpleFit.HTTP`, errors from
  `SimpleFit.Provider`, test adapter or `Req.Test` stubs.
* Contexts never import `Req`, AWS or provider modules directly.
* If a production deployment needs storage or email, its secrets must be set;
  `:configuration_error` logs make a missing secret visible on first use.
