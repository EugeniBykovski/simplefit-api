# ADR 0006 — Background jobs with Oban

* Status: Accepted
* Date: 2026-10-05
* Ticket: SF-15

## Context

ADR 0004 named Oban as the job system and deferred it until the first
asynchronous workload. SF-15 introduces it: transactional email delivery
needs retries and must not block requests, and upcoming notification fan-out,
media coordination and webhook follow-ups need the same foundation.

## Decision

* **Oban 2.24 (OSS), PostgreSQL-backed** with the `Basic` engine. No Redis.
  PostgreSQL stays the system of record, so jobs can be enqueued in the same
  transaction as the data change that requires them.
* **Schema:** migration `AddObanJobsTable` pinned to Oban schema version 14
  (`up(version: 14)`, `down(version: 1)`). A future Oban release that needs a
  newer schema gets a new migration.
* **Supervision:** `{Oban, config}` starts after `SimpleFit.Repo` and before
  the endpoint.
* **Queues (minimal):** `default` (limit 10) and `mailers` (limit 5). Add a
  queue only when a workload needs its own concurrency limit or isolation,
  never one per domain by default.
* **Plugins:** `Pruner` deletes completed, cancelled and discarded jobs after
  24 hours, which also bounds how long job arguments (such as email
  contents) are retained. `Lifeline` rescues jobs orphaned by a crashed node
  after 30 minutes.
* **Tests:** `testing: :manual`. Jobs never run on their own; tests use
  `Oban.Testing` (`assert_enqueued`, `perform_job`) or drain a queue
  explicitly.
* **Logging:** Oban's structured default logger is attached outside tests
  (job start/stop/exception, JSON). Job metrics are declared in
  `SimpleFitWeb.Telemetry`; reporters and alerting belong to SF-8.

### Worker conventions

* Workers live next to their capability or context
  (`SimpleFit.Email.DeliveryWorker`, future
  `SimpleFit.Accounts.Workers.*`), stay thin and call public functions.
* Arguments are small, JSON-serializable and re-validated in `perform/1`.
  Store IDs rather than whole records; avoid secrets and minimize personal
  data in arguments.
* Side effects use an idempotency key derived from the job id, so retries
  are safe.
* Map provider errors with `SimpleFit.Provider.retryable?/1`: retry
  transient failures with a bounded `max_attempts`, cancel permanent ones.

## Consequences

* One more supervised process tree and tables (`oban_jobs`, `oban_peers`).
* Deployments run the migration like any other.
* Oban Pro / Web are not used; revisit only with a concrete need (workflows,
  dashboards).
