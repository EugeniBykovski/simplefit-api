# Billing oversight: metric registry (SF-127)

`GET /api/v1/admin/billing/*` (`SimpleFit.Operators.billing_*`, `SimpleFit.Billing.Oversight`) is the Control
Plane's read-only view of SimpleFit's SaaS billing: gyms paying SimpleFit (SF-101), through Stripe (SF-102).
Claude Design AD13 "Billing visibility" names four money flows and says they are never added together; only
this one has a domain. This registry is what each figure means. Changing a definition here changes the API's
meaning: update both together. Decision: [D-SA34](sponsor-admin-decision-register.md).

## Rules for every figure

- **One mode.** Every Stripe row names its mode (`test` or `live`). Each response reads exactly one, given as
  `mode` or, by default, the deployment's `STRIPE_MODE` (`configured_mode`). An unknown mode is a
  `validation_error`, never a fallback. Nothing ever adds the two.
- **Environment of a subscription.** An SF-101 subscription has no mode: it takes its Stripe link's, else its
  latest checkout's, else `none` (no provider record). `none` is reported apart
  (`unrecorded_subscriptions`, `mode=none` on the list) and is in no mode's counts.
- **Money.** Integer minor units of the row's own currency, plus the same amount as a decimal string (`null` for
  a currency SimpleFit doesn't list; the minor units are still exact). Sums are computed in PostgreSQL
  (`numeric`), per mode and per currency, and their minor units are sent as a digit string. No conversion, no
  cross-currency total, no float. The browser formats; it never adds.
- **Zero vs unknown.** Every count key is present; `0` is a measured zero. `null` timestamps mean "never"
  (no row). A metric with no definition is listed in `unavailable`, not shown as 0.
- **Consistency.** Each figure is its own query at READ COMMITTED: there is no atomic snapshot across figures.
  A single figure never sees half of a transaction (activation, its period and its paid invoice commit
  together; `test/simple_fit/billing_oversight_race_test.exs`).
- **Freshness.** Stripe objects are as SimpleFit last read them (`synced_at`); a webhook only triggers a re-read.
  `last_synced_at` and `last_webhook_at` say how current a mode's records are. Nothing is fetched from Stripe on
  a dashboard read.
- **Audit.** Overview and catalog: not audited per load (counts and the catalog, as the AD1 overview).
  Subscription list and detail, invoice list and reconciliation: audited per read, with their target. Refusals
  are audited as for every operator call.

## Metrics

| Id | Meaning | Source | Unit / currency | Includes | Excludes | Time basis | Permission |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `subscriptions.<status>` | SimpleFit subscriptions of the mode in each SF-101 status | `gym_saas_subscriptions` + environment rule | count | Every subscription classified into the mode | `none` subscriptions; other mode | Current status at read | `billing.read` |
| `unrecorded_subscriptions.<status>` | Subscriptions with no Stripe link or checkout | same | count | Environment `none` | Any with a Stripe record | Current | `billing.read` |
| `provider_statuses.<status>` | Stripe Subscription links by Stripe's status | `stripe_subscriptions` | count | Links of the mode | — | As last read (`synced_at`) | `billing.read` |
| `invoices.<status>` | Recorded Stripe invoices by Stripe status | `stripe_invoices` | count | All recorded invoices of the mode | — | As last read | `billing.read` |
| `payment_issues.payment_failed` | Open invoices whose last attempt failed | `stripe_invoices` (`open` + `requires_payment_method`) | count | — | Recovered (now `paid`) | As last read | `billing.read` |
| `payment_issues.action_required` | Open invoices awaiting customer authentication | `open` + `requires_action` | count | — | — | As last read | `billing.read` |
| `payment_issues.uncollectible` | Invoices Stripe marked uncollectible | `uncollectible` | count | — | — | As last read | `billing.read` |
| `refunds.<status>` | Refunds by Stripe status | `stripe_refunds` | count | Operator (shell, SF-102) and provider refunds | — | As last read | `billing.read` |
| `disputes[status]` | Disputes by Stripe status | `stripe_disputes` | count | — | Refunds (a dispute is never a refund) | As last read | `billing.read` |
| `collected.currencies[].amount_paid` | **Gross amount paid through Stripe invoices** | `sum(amount_paid)` of `paid` invoices | minor units, per currency | Invoices with `paid_at` in the last 30 days, ending at the read | Open, void, uncollectible; other mode; other currencies | `paid_at` | `billing.read` |
| `collected.currencies[].amount_refunded` | What Stripe has refunded so far of those same invoices | `sum(amount_refunded)` | minor units, per currency | Same invoices | Refunds of invoices paid outside the window | As last read | `billing.read` |
| `reconciliation.summary.*` | Links `in_sync` (read within 6 h, no discrepancy), `stale` (older, not ended at Stripe), `mismatch` (discrepancy code); `not_linked` (checkout, no link) | `stripe_subscriptions`, `stripe_checkouts` | count | Links of the mode | — | `synced_at` | `billing.reconciliation.read` |
| `reconciliation.webhooks.*` | Inbox counts by status (24 h), unprocessed backlog, newest 20 failures (type + outcome code) | `stripe_webhook_events` | count | Events of the mode | Payloads, event and object ids | `inserted_at` | `billing.reconciliation.read` |

`collected` is **not revenue**. It is gross, before refunds, disputes, Stripe fees and tax (SimpleFit computes no
tax); `amount_refunded` sits beside it, never subtracted.

## Not reported (`unavailable`, reason `no_approved_definition`)

| Metric | Why |
| --- | --- |
| `mrr`, `arr` | No normalized recurring-revenue model: intervals, quantities, discounts, trials and lifecycle rules aren't defined. Plan prices times counts would be a guess |
| `recognized_revenue` | No accounting definition or recognition schedule |
| `net_revenue` | Fees, disputes and tax aren't recorded |
| `churn`, `ltv`, `forecast` | No approved definition and no state history |
| `fx_total` | No approved FX source or policy: currencies are never added |

## Not exposed

Stripe object, customer, price, event and payment ids; hosted invoice, PDF and checkout URLs; webhook payloads;
card or payment method details; billing addresses; the gym's people (only the gym's id and name). Stripe's
invoice `number` is shown: it is the reference an operator uses to find the invoice in the Stripe Dashboard.

## Financial actions

None. Refunds (full, under an approval) and price mapping remain SF-102's shell commands, refused in
production builds (SF-138). No refund, cancellation, price change, entitlement change, payment retry, webhook
replay, forced reconcile or Stripe proxy exists in the API; a future one needs its own permission, step-up,
reason, idempotency key and review (D-SA34).
