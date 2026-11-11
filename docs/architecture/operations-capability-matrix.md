# Operations capability matrix (SF-126)

What the Control Plane can truthfully say about the running system, from the code at `4dee8bd`. Endpoints:
`GET /api/v1/admin/operations/health` (`system.health.read`), `GET /api/v1/admin/operations/jobs[/{id}]`
(`system.jobs.read`). Decision: [D-SA33](sponsor-admin-decision-register.md). Statuses and their rules:
`SimpleFit.Observability.Operations`.

| Subsystem | Source of truth | Collection | Freshness | Retention | Shown | Actions | Missing |
| --- | --- | --- | --- | --- | --- | --- | --- |
| API | The request itself | Answering the health read | Per request | None | `healthy` at `observed_at` | None | External liveness monitoring |
| PostgreSQL | `SELECT 1` from the app | Timed query per read | Per request | None | `healthy` + `query_ms`, or `unavailable` | None | Replication, size, connections (not exposed) |
| Background jobs | `oban_jobs` | Grouped counts per read | Per request | Finished jobs pruned after 1 day | Counts by queue and state; `degraded` on any failure in 24 h or retrying | None (retry BLOCKED) | — |
| Job list / detail | `oban_jobs` | Bounded keyset query | Per request | 1 day for finished jobs | Id, queue, worker, state, attempts, timestamps, exception module only | None | — |
| Email | `Email.DeliveryWorker` jobs | Counts per read | Per request | 1 day | Accepted by the provider / failed / pending; never "delivered" | None | Provider delivery callbacks (no webhook) |
| Stripe webhooks | `stripe_webhook_events` | Counts by status + last receipt | Per request | Kept | `degraded` on failures, else `unknown` | None (no replay) | Outbound webhooks don't exist |
| Storage | — | — | — | — | `no_telemetry` | None | Any storage check |
| Error monitoring | Sentry (not readable by the app) | — | — | — | `no_telemetry` | None | Sentry API integration |
| Migrations | `schema_migrations` | Count and latest version per read | Per request | Kept | Applied count, latest version | None (no run or rollback) | Pending migrations of a release |
| Release | `SENTRY_RELEASE` / `SENTRY_ENVIRONMENT` | Config at boot | Boot | — | Release, environment, `configured` or `default` | None | Build SHA, deploy time |
| Uptime / SLA | — | — | — | — | Not shown | — | History of samples and a method |

## Workers and retry

| Worker | Effect | Retry |
| --- | --- | --- |
| `Email.DeliveryWorker` | Sends real email (codes, invitations, notices) | Unsupported: resending stale codes or notices isn't approved |
| `Billing.Stripe.EventWorker` | Applies a stored Stripe event | Needs policy (billing state) |
| `Billing.Stripe.SweepWorker` | Reconciles subscriptions hourly | Needs policy; the next run reconciles |
| `EmailAuth.CleanupWorker`, `Gyms.VerificationCleanupWorker`, `Sponsors.EvidenceCleanupWorker` | Delete expired or abandoned records and objects | Idempotent, but the scheduler reruns them within an hour; no retry approved |
