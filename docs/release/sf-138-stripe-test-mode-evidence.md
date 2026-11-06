# SF-138 — Stripe Test Mode evidence and commercial release gate

* Date: 2026-11-06. Base: api `a6d8efc`, platform `a4c4b1b`, mobile `d248076`.
* Nothing here authorizes live payments, a price or a legal term.

## 1. Verdicts

| Release | Verdict |
| --- | --- |
| **Test Mode Technical Readiness** | **NO-GO**: provider verification could not be run |
| **Live Commercial Release** | **NO-GO**: no decision in §7 is approved, and neither is the release |

A later Test Mode GO would not be a Live GO.

**What this does and doesn't mean.** The billing code passes every local check, but
those checks use `SimpleFit.StripeFake`, which was written from the API documentation.
Nothing yet shows that Stripe's real answers match it. The decoders in
`Stripe.Objects` are the main risk: an unexpected real shape fails closed, granting
nothing, but it would also mean a real payment doesn't activate.

## 2. Evidence labels

| Label | Meaning |
| --- | --- |
| REAL STRIPE TEST MODE | Against Stripe's servers. **Nothing in this document has this label** |
| LOCAL INTEGRATION TEST | Real HTTP or real PostgreSQL commits; Stripe is the fake or isn't called |
| MOCKED UNIT TEST | ExUnit with the SQL sandbox and the fake |
| BLOCKED | Needs the prerequisite in §3 |
| NOT VERIFIED | Not executed, for another reason |

## 3. Provider preflight (once)

| Check | Result |
| --- | --- |
| Stripe CLI | 1.25.0 installed |
| CLI test and live keys | Both expired 2026-03-09 |
| Probe: one read-only `GET /v1/balance`, test mode | Refused by Stripe: key expired. Account mode **not proven** |
| CLI profile | Display name `waitme.by`; not obviously a SimpleFit account |
| `STRIPE_*` in the environment, `simplefit-api/.env`, platform env files | None set |
| Webhook endpoint, Products, Prices, portal configuration | None exist for SimpleFit, as far as can be known without access |

**Missing prerequisite.** A Stripe Test Mode key (secret or restricted, with write
access to customers, products, prices, Checkout, subscriptions, invoices, refunds and
the billing portal) for the account SimpleFit will use, its `acct_` id, and a webhook
signing secret. The founder must confirm whether `waitme.by` is that account; it wasn't
used for anything beyond the probe. Keys go in the environment of the local API
process, never in chat, a file in Git or a command-line argument.

## 4. Scenario matrix

Every provider-backed scenario is BLOCKED. The last column is what exists instead, and
none of it stands in for the provider.

| Area | Scenario | Provider | Local evidence |
| --- | --- | --- | --- |
| Preflight | Mode and account proven by Stripe | BLOCKED | MOCKED: `status` fails on another account, a live answer, an expired key |
| Checkout | Hosted session, pay with a test card | BLOCKED | MOCKED, and LOCAL INTEGRATION over HTTP up to the refusal before Stripe |
| Checkout | Retry and lost answer: one session | BLOCKED | MOCKED; LOCAL INTEGRATION: 20 concurrent requests, one session |
| Checkout | Billing UI shows the paid state | BLOCKED | NOT VERIFIED: the browser journey stops at the refusal |
| Webhooks | A delivery signed by Stripe | BLOCKED | Locally signed only |
| Webhooks | Invalid or missing signature, modified body, stale, other mode | Not needed | LOCAL INTEGRATION over HTTP: 400 |
| Webhooks | Repeated delivery | BLOCKED | LOCAL INTEGRATION: 20 concurrent, one inbox row, one job |
| Webhooks | Delayed, out of order, stale | BLOCKED | MOCKED: every decision re-reads the object |
| Webhooks | Unknown customer, unknown subscription, unsupported type | BLOCKED | MOCKED: ignored with an outcome code |
| Lifecycle | Initial payment, active | BLOCKED | MOCKED; LOCAL INTEGRATION: 10 concurrent, one activation |
| Lifecycle | Renewal (would need test clocks) | BLOCKED | LOCAL INTEGRATION: 10 concurrent, one period, one event (new) |
| Lifecycle | Payment failed, past due, recovery | BLOCKED | MOCKED; LOCAL INTEGRATION: failure racing success (new) |
| Lifecycle | Cancel at period end, immediately, reactivation | BLOCKED | MOCKED; LOCAL INTEGRATION: racing a renewal |
| Lifecycle | Expiry after failed payments | BLOCKED | MOCKED |
| Invoices | Created, paid, failed, retried, amounts | BLOCKED | MOCKED |
| Invoices | Voided | BLOCKED | MOCKED (new) |
| Invoices | Credit notes | NOT VERIFIED | Not implemented: no event or model |
| Invoices | Tax fields | NOT VERIFIED | Not read: Stripe Tax is off, no tax is computed or stored |
| Refunds | Full refund, duplicate request, duplicate webhook | BLOCKED | MOCKED; LOCAL INTEGRATION: 10 concurrent, one refund |
| Refunds | Refund failed | BLOCKED | MOCKED (new). Asking again after a failure is NOT VERIFIED: the fake refuses it |
| Refunds | Partial at Stripe | BLOCKED | MOCKED: recorded with its real amount |
| Refunds | Partial from SimpleFit | Not supported | MOCKED: refused, `partial_not_approved` |
| Refunds | After cancellation | BLOCKED | MOCKED (new) |
| Portal | Session and configuration | BLOCKED | MOCKED |
| Disputes | Recorded as disputes | BLOCKED | MOCKED |

## 5. Audit of the existing implementation

### Source of truth

| Concern | Owner |
| --- | --- |
| Subscription lifecycle | `gym_saas_subscriptions` (SF-101), changed from provider state only by `Billing.Reconciliation` |
| Stripe objects | Stripe; every decision re-reads them. An event says only which object to read |
| Customer, subscription, price mapping | `stripe_customers`, `stripe_subscriptions`, `stripe_prices`, each unique per mode |
| Gym ↔ Stripe association | SimpleFit's own checkout row and customer mapping. Metadata never creates identity |
| Invoices, refunds, disputes | `stripe_invoices`, `stripe_refunds`, `stripe_disputes`, never deleted |
| Webhook inbox | `stripe_webhook_events`: ids and type, never the payload; unique per mode and event |
| Exact-once grant | Evidence row unique per `<mode>:<invoice id>` |
| Recovery | Hourly `SweepWorker` (a failed event isn't reprocessed on redelivery; the sweep recovers it) |
| Entitlements | Backend projection, `enforced: false`: no gym is locked out today |

### Lifecycle

Intent → hosted Checkout → payment → signed webhook → inbox row and job → re-read from
Stripe under the subscription lock → paid invoice verified (customer, subscription,
currency, exact amount, current period) → evidence → active → projection → billing page.
A redirect, `checkout.session.completed` or Stripe's `active` status alone grants nothing.

### Money and price versions

| Check | Result |
| --- | --- |
| Integer minor units; no floats in billing | PASS (read) |
| Currency exponents (PLN 2, JPY 0) | PASS (read) |
| No conversion: amounts compared only within one currency | PASS, MOCKED |
| An invoice for another amount or currency grants nothing | PASS, MOCKED |
| Immutable price mapping and versions; subscriptions keep their version | PASS, MOCKED |
| Refund can't exceed the paid amount from SimpleFit | PASS: full only |
| Tax values invented | None: no tax field is stored |

Observation: exact-amount matching means a discount or Stripe Tax would make invoices
fail verification. It fails closed; turning either on needs a code change.

### Authorization (LOCAL INTEGRATION, HTTP with real sessions)

Manager and front desk 403. Stranger, gym member, Coach with a profile and another
gym's owner 404. A subscription id through another gym's path 404. Ended staff 404 on a
live session. An owner who transferred the gym and left 404, and the new owner has
access. No checkout reached the fake in any of these (new). No `User.role`.

### Web state

`queryClient.clear()` runs on every session boundary, so billing data doesn't survive
sign-out or an account switch (read; SF-137's account-switch journey covers the
mechanism, not the billing page specifically).

### Logging

| Check | Result |
| --- | --- |
| `sk_test_`, `whsec_` or the placeholder values in the API log | 0 occurrences |
| Requests to `api.stripe.com` in the placeholder run | 0 logged |
| Client | Key in the `authorization` header only; bodies never logged; billing queries `log: false` |
| Audit rows | Ids only |
| Task output | Ids, modes and statuses |

Inspected with placeholder values only; real card or customer data hasn't passed through.

## 6. Security findings

| Id | Sev | Finding | Status |
| --- | --- | --- | --- |
| F-09 | **P1** | Caller-typed `--operator` and `--approval` authorized refunds, price mappings, connected accounts, portal configuration and catalog publication. Paths: `lib/mix/tasks/billing.stripe.ex`, `lib/mix/tasks/billing.catalog.ex` | **FIXED**. Real `MIX_ENV=prod` build: all seven refused, exit 1, before anything starts |
| F-10 | P2 | `STRIPE_ACCOUNT_ID` was never compared | **FIXED**, MOCKED only |
| O-1 | P3 | `Stripe.Client` documents that every object must carry `livemode`, but one without it passes. Needed if some objects really omit it; only the provider can settle this | OPEN |
| O-2 | P3 | A production build accepts test-mode keys, so a misconfigured deployment could activate plans from test payments. Harmless while `enforced: false` | OPEN: decide before enforcement |
| O-3 | P3 | `STRIPE_LIVE_APPROVAL` accepts any non-blank value. It is a deployment control, not proof of approval | OPEN: record the approval process |
| F-07 | P3 | `cancelGymSaasSubscription` calls Stripe before the rate limit and session hold (from SF-104) | OPEN |

Live gate, confirmed: live mode is refused outside a production build, and without
`STRIPE_LIVE_APPROVAL`; a key of the other mode or a malformed value fails boot; enabled
without a key is `misconfigured`, with no checkout; provisional prices are never mapped
or sold in live mode. Connect stays test-only and creates no payment. No weakness needed
a change here.

**Depends on SF-110:** restoring all seven commands in production, including refunds.

## 7. Commercial decision register

Nothing here is approved by this document. "Who" is a proposal.

| Item | Status | Current state | Who |
| --- | --- | --- | --- |
| Plan prices | PROVISIONAL | Starter 149 / 1490, Growth 349 / 3490, Pro 699 / 6990 PLN; Enterprise by quote; drafts only | Founder |
| Supported currencies | PROVISIONAL | Catalog in PLN; the design shows illustrative EUR tiers | Founder |
| Price changes, grandfathering | BLOCKED | Versions are immutable; no policy | Founder |
| Trials | PROVISIONAL | 14-day proposal, never granted | Founder |
| Tax policy | BLOCKED | Stripe Tax off; none computed | Founder and accountant |
| VAT handling | BLOCKED | Registration, B2B/B2C, reverse charge open | Accountant or legal |
| Invoice issuer | BLOCKED | Stripe's invoices are the history; not confirmed as legal invoices | Legal |
| Refund policy | BLOCKED | Technically full-only; no customer policy | Founder and legal |
| Merchant of record | BLOCKED | SaaS: SimpleFit assumed, entity unconfirmed. Member payments: open | Founder and legal |
| Stripe Connect requirements | BLOCKED | Foundation only; disabled | Founder and legal |
| Payout ownership | BLOCKED | No payouts exist | Founder and legal |
| Member payments | BLOCKED | Disabled | Founder and legal |
| Customer billing terms | BLOCKED | None approved | Legal |
| Cancellation policy | PROVISIONAL | No refund or proration on immediate cancel, as built, not approved | Founder and legal |
| Past-due and access rule | PROVISIONAL | Entitlements lapse at period end; not enforced | Founder |
| Stripe account and verification | BLOCKED | Account unconfirmed (§3) | Founder |
| Production rollout approval | BLOCKED | None | Founder |

## 8. Runbook: the provider run, once credentials exist

Use a non-production build, a disposable database and synthetic gyms. Never `STRIPE_MODE=live`.

1. Put the key, `acct_` id and signing secret in the local API's environment with
   `STRIPE_BILLING_ENABLED=true` and `STRIPE_MODE=test`. Never on a command line.
2. `mix billing.stripe status`. **Stop unless it says `mode test confirmed` and
   `account match`.**
3. `mix billing.stripe webhook-events`, then enable those on a sandbox endpoint or
   forward them with `stripe listen`.
4. `seed-provisional`, `publish` and `map-price` on the disposable database;
   `setup-portal`.
5. As an owner in the browser: choose a plan, pay with Stripe's `4242 4242 4242 4242`,
   confirm active only after the webhook.
6. Run the BLOCKED rows of §4. For renewals, check whether test clocks fit first: the
   checkout flow doesn't attach one today, so this may need a decision, not a retry.

Expect decoder or parameter differences on first contact: that is what this run exists
to find.

## 9. Local results

| Check | Result |
| --- | --- |
| Billing suites, base | 105 passed |
| API `mix test` | 1808 passed (2 doctests, 1806 tests) |
| API `mix quality` (format, warnings, Credo strict, `openapi.check`, Dialyzer), Redocly | Pass, 0 issues |
| `stripe_billing_test` / `billing_test` / other billing | 43 / 21 / 38 passed |
| Race suites, real PostgreSQL commits, fake Stripe | `stripe_billing_race` 9, `billing_race` 13, `gym_bookings_race` 13, `gym_members_race` 10 |
| Platform `pnpm quality` (no platform change) | Pass; 1390 unit tests; generated client up to date |
| Mobile (no contract change) | Not run; OpenAPI identical in all three repositories |
| `gym-billing` real-API spec, placeholder test mode, Chromium | 4 passed; 0 checkouts, 0 customers, 0 invoices |
| Production-build refusal | 7 of 7 refused |
| Disposable database | `simple_fit_sf138_e2e`; `simple_fit_dev` untouched at `20261023090000` |
