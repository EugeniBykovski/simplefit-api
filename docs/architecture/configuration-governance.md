# Configuration governance (SF-128)

What the platform's feature switches are, where each value comes from, which code reads it, and the only change
an operator can make. Endpoints: `GET /api/v1/admin/configuration` and `/configuration/flags/{id}`
(`config.read`), `POST /configuration/flags/{id}/{suspend,restore}[/preview]` (`config.flags.write`, SF-111).
Code: `SimpleFit.Configuration`, `SimpleFit.Operators.ConfigurationActions`. Decision:
[D-SA35](sponsor-admin-decision-register.md).

## Inventory (from the code at the SF-128 base, `4e0532d`)

| Key | Source | Consumer | Environments | Control | Risk | Rollback |
| --- | --- | --- | --- | --- | --- | --- |
| `gym.member_invitations` | `GYM_MEMBER_INVITATIONS` (runtime.exs; dev/test config `true`) | `Gyms.MemberInvitations.delivery_enabled?/0`: creating or resending an E07 invitation | all | **suspendable** | medium | restore (new revision) |
| `gym.staff_invitations` | `GYM_STAFF_INVITATIONS` | `Gyms.StaffInvitations.delivery_enabled?/0` (E06) | all | **suspendable** | medium | restore |
| `sponsor.application_emails` | `SPONSOR_APPLICATION_EMAILS` | `Sponsors.ApplicationNotifications.enabled?/0` | all | **suspendable** | medium | restore |
| `sponsor.evidence_uploads` | `SPONSOR_EVIDENCE_UPLOADS` | `Sponsors.Evidence.enabled?/0`: new uploads `503` | all | **suspendable** | medium | restore |
| `coaching.access` | `COACHING_ACCESS_ENABLED` | `Coaching.access_enabled?/0`, `Coaching.LegalPolicy` (legal consent, ADR 0021) | all | read-only | high | — |
| `stripe.billing` | `STRIPE_BILLING_ENABLED` (+ keys) | `Billing.Stripe.Config.status/0` | all | read-only | high | — |
| `stripe.mode` | `STRIPE_MODE` (`test`/`live`; live refused outside prod) | `Billing.Stripe.Config` | all | read-only | high | — |
| `stripe.connect` | `STRIPE_CONNECT_ENABLED` | `Billing.Stripe.Config` | all | read-only | high | — |
| `api.docs` | `API_DOCS_ENABLED` | `SimpleFitWeb.Router` (evaluated at compile time) | prod | build (needs a new build) | medium | — |

Not registered, never shown or changed: database, secret key base, Stripe keys and webhook secrets, WebAuthn
relying party, OAuth client ids, storage and email credentials, CORS origins, proxy hops, operator bootstrap,
Sentry, the dev-only `SIMPLEFIT_LOCAL_DEV_COACHING` and `PHX_BIND_ALL`. Product entitlements are plan data
(SF-101), not flags. No database-backed flag existed before SF-128.

## The one runtime change: suspension

`effective = deployment enabled AND NOT suspended`. A suspension can only turn a feature off; restoring hands the
decision back to the deployment. No runtime change can turn on what the deployment left off, so release gates
(SF-95 recipient page, SF-133 staff page, D-SA09 file scanning, sponsor email copy approval) stay in force.

* **Store.** `runtime_flags`: one row per allowlisted key (a check constraint lists them; rows are never
  deleted), `suspended`, `revision` (raised by a trigger on every change). `runtime_flag_revisions`: append-only
  history (trigger), each change with previous and new state, operator, reason and operation id.
* **Actions.** `config.flag.suspend` / `config.flag.restore` (SF-111): fresh key check, reason code, preview with a
  one-time confirmation bound to operator, session, flag, revision and reason, expected revision, operation id,
  flag row locked, change + history + audit in one transaction. Each is the other's rollback: a new revision,
  never an edit or deletion of history, and not retroactive (sent emails and stored files stay).
* **Environment.** No request names an environment: a change applies to the database of the deployment that
  serves it. `environment` in the inventory is that deployment's `SENTRY_ENVIRONMENT`.
* **Risk.** Registered in code. Every suspendable switch is medium (it stops a user-visible flow but can't send,
  charge or expose anything). High-risk switches are read-only: there is no approval workflow (no second
  approver exists; recorded as blocked).

## Propagation

`Configuration.enabled?/1` reads the committed row on every check: no cache, no PubSub. A committed change is
seen by the next check in every application instance sharing the database; an uncommitted one by none, and a
check never waits on a change in progress (MVCC). If the row can't be read the feature counts as suspended
(fails closed). Overhead: one indexed single-row query per check, and checks happen only when an invitation,
upload or sponsor email is being created. Frontend builds are unaffected (no web flag).

## Not supported

Percentage or targeted rollouts (no deterministic bucketing or targeting identifier is approved), guardrail
metrics and auto-rollback (no telemetry), enabling beyond the deployment, editing any value, two-person approval,
emergency override modes.
