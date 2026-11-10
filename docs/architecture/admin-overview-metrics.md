# Control Plane overview: metric catalog (SF-121)

`GET /api/v1/admin/overview` (`getAdminOverview`, `SimpleFit.Operators.overview/4`) is the
Control Plane overview (Claude Design AD1 `AdminOverview`, MVP, canvas `1794299393-d9d6`). This is
the catalog of what it counts. Each number is a database aggregate computed by the context that
owns the table; no row, name, address or identifier leaves the database, and nothing is computed in
the browser. Changing a definition here changes the API's meaning: update both together.

## Rules for every metric

- **States.** `available` means `value` is a count (0 is a real zero). `restricted` means the
  operator lacks the permission: no value, never 0, and the query isn't run. `unavailable` means
  SimpleFit can't produce the number yet: no value, never 0. A failed read fails the whole request
  (500): every number comes from one snapshot, so there is no partial result to show.
- **As of.** Headline values and breakdowns are current totals at `as_of`. `as_of` is the request
  time rounded **up** to the whole second, so every record stored before it is included at every
  column precision.
- **Snapshot.** All counts are read in one `REPEATABLE READ, READ ONLY` transaction and describe
  the same instant. Tests in the SQL sandbox turn this off (`snapshot: false`). The real-commit test
  `test/simple_fit/overview_race_test.exs` shows that a concurrent commit is invisible inside it.
- **Periods.** `period` is `24h`, `7d` (default) or `30d`, ending at `as_of`: `[as_of − length,
  as_of)`, start inclusive and end exclusive, in UTC. A period only drives `period_counts`, each
  with its own date field below. Lifetime totals are never filtered by it. Anything else is a
  `validation_error`, including an empty value.
- **No history, no trends.** There are no time series, deltas or percentages: none of these
  entities keeps the state history a past total would need.
- **Not audited per load.** The overview is a counts-only read (SF-107: "view not logged per
  load"). Refusals are audited (`operator.access_refused`), as for every operator call.

## Access

| Section | Needs (plus an active operator and a current key check) |
| --- | --- |
| Platform counts (`accounts`, `fighter_profiles`, `coach_profiles`, `gyms`, `sponsor_organizations`) | `platform.dashboard.read` |
| `operators` | `platform.dashboard.read` and `operators.read` |
| `sponsor_applications_waiting` | `sponsors.applications.read` |
| `gym_verifications_waiting` | always `unavailable`: no operator permission or review exists |
| Health checks | `system.health.read` |

At least one of `platform.dashboard.read`, `sponsors.applications.read` or `system.health.read` is
needed for the overview at all (`forbidden` otherwise). A non-operator, or a suspended or revoked
operator, gets `not_found`.

## Metrics

| id | Owner | Value (as of) | Breakdown | Period counts | Source and rules | Limits |
| --- | --- | --- | --- | --- | --- | --- |
| `accounts` | Accounts | Users whose account registration is complete (`account_profiles.registration_completed_at` set) | `in_progress` (profile row, not completed), `not_started` (user with no profile row) | `registration_completed`: `registration_completed_at` in the period | One `users` row per person, however many identities (Google, Apple, email) or contexts they have. `not_started = users − profiles`. | No deletion, suspension or restriction state exists, so none is excluded. |
| `fighter_profiles` | Fighters | Fighter profiles with onboarding completed (`onboarding_completed_at` set) | `in_progress` | `onboarding_completed` | One profile per user. A profile isn't competitive activity. | No archive state. |
| `coach_profiles` | Coaches | Coach profiles with onboarding completed | `in_progress` | `onboarding_completed` | One profile per user; gym affiliations aren't counted. | Coaches have no verification or certification state, so none is shown. |
| `gyms` | Gyms | Gyms with `setup_status = completed` | `draft` | `setup_completed`: distinct gyms with a `setup_completed` audit event (`gym_audit_events.occurred_at`) in the period | Staff memberships and members aren't gyms. A completed setup isn't a verified or published business. | Gyms have no verification, publication or suspension state in this count. |
| `sponsor_organizations` | Sponsors | Organizations with `status = active` and `provisioning_source = sponsor_application` | `suspended`, `closed` | `approved`: `inserted_at` in the period (an organization is created in its application's approval transaction) | Local development fixtures (`local_fixture`) aren't counted. Memberships aren't organizations. | — |
| `operators` | Operators | Operators with `status = active` | — | — | — | Pending, suspended and revoked operators aren't counted. |
| `sponsor_applications_waiting` | Sponsors | Applications `submitted` or `under_review` (waiting for an operator) | Every non-draft status: `submitted`, `under_review`, `changes_requested`, `approved`, `rejected`, `withdrawn` | `first_submitted`: the first submission (`sponsor_application_submissions.sequence = 1`) in the period, never a resubmission; `approved` and `rejected`: `decided_at` in the period | Drafts are the applicant's and never counted, as operators never see them. An approved application stays an application: its organization counts under `sponsor_organizations`. | `changes_requested` waits for the applicant, not an operator. |
| `gym_verifications_waiting` | — | none (`unavailable`) | — | — | — | There's no operator permission, endpoint or review for gym verification yet (SF-103 uses a local fixture authority). |

## Health checks (`system.health.read`)

Nothing is called healthy without a check, and nothing here is an uptime figure.

| id | Status | Signal |
| --- | --- | --- |
| `database` | `healthy` | The overview's own queries answered (a failure fails the request). |
| `background_jobs` | `healthy`, or `degraded` when any job was discarded (retries exhausted) in the last 24 hours | Oban's `oban_jobs`: `waiting` (available, scheduled or retrying) and `discarded_24h`. Discarded jobs are pruned after a day. |
| `payments_webhooks` | always `unknown` | `last_event_at`: when the last Stripe webhook arrived. A receipt time isn't health. |
| `email_provider` | always `no_telemetry` | The email provider reports nothing to SimpleFit. |

The overview has no other notices. The web shows a provider banner only when a check here is
`degraded` or `unavailable`.

## Performance

Each metric is one aggregate over its table, using `count(*) FILTER (WHERE …)` to compute several
counts in one pass. There's no row loading, join or N+1. Tables at MVP scale are read in full, and
no index was added for these reads. If a table grows past that, add the index (or the counter) for
its `WHERE` clause then, with a measured plan. Telemetry: `simple_fit.admin_overview.read.duration`,
tagged with the outcome only.
