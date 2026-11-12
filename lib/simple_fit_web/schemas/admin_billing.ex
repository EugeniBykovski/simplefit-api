defmodule SimpleFitWeb.Schemas.AdminBillingFields do
  @moduledoc """
  Shared OpenAPI definitions of the operator billing views (SF-127): one Stripe mode
  per response, amounts as integer minor units plus a decimal string of their own
  currency, never a float and never converted.
  """

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CommerceFields

  @doc "A Stripe mode."
  def mode(description \\ "The Stripe mode every figure was read from; never both.") do
    %Schema{type: :string, enum: ["test", "live"], description: description}
  end

  @doc "A timestamp."
  def at(description, nullable \\ false),
    do: %Schema{type: :string, format: :"date-time", nullable: nullable, description: description}

  @doc "A count."
  def count, do: %Schema{type: :integer, minimum: 0}

  @doc "Counts keyed by each of `keys` (every key present; zero is a measured zero)."
  def counts(keys, description) do
    %Schema{
      type: :object,
      description: description,
      required: keys,
      properties: Map.new(keys, &{&1, count()})
    }
  end

  @doc "Integer minor units of one recorded amount."
  def minor(description), do: %Schema{type: :integer, minimum: 0, description: description}

  @doc "A decimal amount string, or null for a currency SimpleFit doesn't list."
  def decimal(description) do
    %Schema{
      type: :string,
      nullable: true,
      pattern: "^[0-9]{1,16}(\\.[0-9]{1,6})?$",
      description:
        description <>
          " As a decimal string in the currency's major unit; null when SimpleFit doesn't list the currency " <>
          "(its minor units are still exact)."
    }
  end

  @doc "A sum of minor units, as a string of digits (a total may exceed a JSON number's exact range)."
  def minor_sum(description),
    do: %Schema{type: :string, pattern: "^[0-9]{1,20}$", description: description}

  @doc "A gym, by id and name only."
  def gym do
    %Schema{
      type: :object,
      required: [:id, :name],
      description: "The subscribing gym: its id and name only, never its people.",
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, nullable: true}
      }
    }
  end

  @doc "A reconciliation state."
  def reconciliation do
    %Schema{
      type: :object,
      required: [:state, :discrepancy, :synced_at],
      description: """
      `in_sync`: the Stripe link was read within six hours and had no discrepancy; `stale`: read longer ago
      (the hourly sweep should have re-read it); `mismatch`: the last read recorded a `discrepancy` code and
      granted nothing; `not_linked`: a checkout exists but no Stripe Subscription is linked yet;
      `not_evaluated`: no provider record, so nothing was reconciled. Never "reconciled" without a read.
      """,
      properties: %{
        state: %Schema{
          type: :string,
          enum: ~w(in_sync stale mismatch not_linked not_evaluated)
        },
        discrepancy: %Schema{
          type: :string,
          nullable: true,
          description:
            "A code: `customer_mismatch`, `price_mismatch`, `ended_locally_live_at_provider`, " <>
              "`invoice_subscription_mismatch`, `invoice_currency_mismatch`, `invoice_amount_mismatch`, " <>
              "`invoice_period_over`, `invoice_period_missing`, `invoice_not_paid`, `invalid_evidence`, or " <>
              "another code reconciliation recorded."
        },
        synced_at: at("When Stripe was last read for it.", true)
      }
    }
  end

  @doc "A plan reference on a subscription."
  def plan_ref do
    %Schema{
      type: :object,
      required: [:key, :plan_version_id, :version, :name, :version_status],
      description:
        "The plan version the subscription agreed to, as it was; never a newer version.",
      properties: %{
        key: %Schema{type: :string},
        plan_version_id: %Schema{type: :string, format: :uuid},
        version: %Schema{type: :integer, minimum: 1},
        name: %Schema{type: :string},
        version_status: version_status()
      }
    }
  end

  @doc "A plan version status."
  def version_status,
    do: %Schema{type: :string, enum: ~w(draft archived published superseded retired)}

  @doc "The agreed price."
  def agreed_price do
    %Schema{
      type: :object,
      required: [:interval, :currency, :pricing, :amount, :amount_minor],
      description: "The price version the subscription agreed to (immutable).",
      properties: %{
        interval: %Schema{type: :string, enum: ["month", "year"]},
        currency: CommerceFields.currency(),
        pricing: %Schema{type: :string, enum: ["fixed", "quote_required"]},
        amount: CommerceFields.amount(true),
        amount_minor: CommerceFields.amount_minor(true)
      }
    }
  end

  @doc "A Stripe subscription status."
  def provider_status(nullable \\ true) do
    %Schema{
      type: :string,
      nullable: nullable,
      enum: ~w(incomplete incomplete_expired trialing active past_due canceled unpaid paused),
      description:
        "Stripe's subscription status as last read; null without a link. Not SimpleFit's status: " <>
          "`active` at Stripe is not a collected payment, `past_due` is not a final failure."
    }
  end

  @doc "A subscription row's properties."
  def subscription_properties do
    %{
      id: %Schema{type: :string, format: :uuid},
      gym: gym(),
      status: CommerceFields.subscription_status(),
      environment: %Schema{
        type: :string,
        enum: ["test", "live", "none"],
        description:
          "Its Stripe link's mode, else its latest checkout's; `none`: no provider record (never counted in a mode)."
      },
      plan: plan_ref(),
      price: agreed_price(),
      requested_at: at("When the gym requested it."),
      activated_at: at("When verified evidence first activated it.", true),
      current_period_start: at("The paid period's start.", true),
      current_period_end: at("The paid period's end.", true),
      cancel_reason: %Schema{
        type: :string,
        nullable: true,
        enum: ["requested_by_gym", "gym_closed", "provider_initiated", nil]
      },
      cancellation_effective_at: at("When a scheduled cancellation takes effect.", true),
      ended_at: at("When it was cancelled or expired.", true),
      provider_status: provider_status(),
      cancel_at_period_end: %Schema{
        type: :boolean,
        nullable: true,
        description: "Stripe's flag as last read; null without a link."
      },
      reconciliation: reconciliation()
    }
  end

  @doc "The properties every subscription row has."
  def subscription_required,
    do: [
      :id,
      :gym,
      :status,
      :environment,
      :plan,
      :price,
      :requested_at,
      :activated_at,
      :current_period_start,
      :current_period_end,
      :cancel_reason,
      :cancellation_effective_at,
      :ended_at,
      :provider_status,
      :cancel_at_period_end,
      :reconciliation
    ]

  @doc "An invoice row's properties."
  def invoice_properties do
    %{
      id: %Schema{
        type: :string,
        format: :uuid,
        description: "SimpleFit's id of the invoice record."
      },
      mode: mode("The invoice's Stripe mode."),
      number: %Schema{
        type: :string,
        nullable: true,
        description:
          "Stripe's invoice number, once finalized (the reference to look it up in Stripe)."
      },
      subscription_id: %Schema{type: :string, format: :uuid, nullable: true},
      status: %Schema{type: :string, enum: ~w(draft open paid uncollectible void)},
      payment_status: %Schema{
        type: :string,
        nullable: true,
        enum: [
          "requires_action",
          "requires_payment_method",
          "processing",
          "succeeded",
          "canceled",
          nil
        ],
        description: "The last payment attempt's state at Stripe, as last read."
      },
      issue: %Schema{
        type: :string,
        nullable: true,
        enum: ["payment_failed", "action_required", "uncollectible", nil],
        description:
          "`payment_failed`: open, its last attempt failed (Stripe may retry: `next_payment_attempt_at`); " <>
            "`action_required`: open, the customer must confirm; `uncollectible`: Stripe marked it so. " <>
            "None is a final judgement of the gym; no action is offered here."
      },
      currency: %Schema{type: :string, description: "ISO 4217 code, as Stripe recorded it."},
      total: decimal("The invoice total."),
      total_minor: minor("The invoice total."),
      amount_due: decimal("Amount due."),
      amount_due_minor: minor("Amount due."),
      amount_paid: decimal("Amount paid."),
      amount_paid_minor: minor("Amount paid."),
      amount_remaining: decimal("Amount remaining."),
      amount_remaining_minor: minor("Amount remaining."),
      amount_refunded: decimal("Amount Stripe refunded of it."),
      amount_refunded_minor: minor("Amount Stripe refunded of it."),
      disputed: %Schema{
        type: :boolean,
        description: "A dispute exists for its payment (not a refund)."
      },
      billing_reason: %Schema{type: :string, nullable: true},
      period_start: at("The billed period's start.", true),
      period_end: at("The billed period's end.", true),
      issued_at: at("When Stripe created it."),
      paid_at: at("When it was paid.", true),
      attempt_count: count(),
      next_payment_attempt_at: at("Stripe's next automatic attempt, if any.", true),
      synced_at: at("When SimpleFit last read it from Stripe.")
    }
  end

  @doc "The properties every invoice row has."
  def invoice_required, do: invoice_properties() |> Map.keys() |> Enum.sort()

  @doc "A refund or dispute of an invoice."
  def invoice_event(kind) do
    base = %{
      status: %Schema{type: :string},
      reason: %Schema{type: :string, nullable: true},
      amount: decimal("Its amount."),
      amount_minor: minor("Its amount."),
      currency: %Schema{type: :string},
      created_at: at("When SimpleFit recorded it."),
      synced_at: at("When SimpleFit last read it from Stripe.", true)
    }

    properties =
      if kind == :refund,
        do: Map.put(base, :origin, %Schema{type: :string, enum: ["operator", "provider"]}),
        else: base

    %Schema{
      type: :object,
      required: properties |> Map.keys() |> Enum.sort(),
      properties: properties
    }
  end
end

defmodule SimpleFitWeb.Schemas.AdminBillingOverviewResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminBillingFields, as: F

  @statuses ~w(pending_activation active cancellation_scheduled cancelled expired)a
  @provider ~w(incomplete incomplete_expired trialing active past_due canceled unpaid paused)a

  OpenApiSpex.schema(%{
    title: "AdminBillingOverviewResponse",
    description: """
    The billing overview of one Stripe mode (SF-127). Each figure is its own query (no atomic snapshot).
    Counts are measured zeros when zero. `collected` is the gross `amount_paid` of Stripe invoices paid in the
    window, per currency, never converted or summed across currencies, and not revenue; `amount_refunded` is
    what Stripe refunded of those same invoices so far. `unavailable` names metrics with no approved
    definition (MRR, ARR, recognized or net revenue, churn...): they are not reported.
    """,
    type: :object,
    required: [:overview],
    properties: %{
      overview: %Schema{
        type: :object,
        required: [
          :observed_at,
          :mode,
          :configured_mode,
          :integration,
          :subscriptions,
          :unrecorded_subscriptions,
          :provider_statuses,
          :invoices,
          :payment_issues,
          :refunds,
          :disputes,
          :collected,
          :last_synced_at,
          :last_webhook_at,
          :unavailable
        ],
        properties: %{
          observed_at: F.at("When the figures were read."),
          mode: F.mode(),
          configured_mode: F.mode("The mode this deployment is configured for (the default)."),
          integration: %Schema{
            type: :string,
            enum: ["disabled", "misconfigured", "ready"],
            description:
              "The Stripe integration's state. Disabled: nothing is synced, so figures can't change."
          },
          subscriptions:
            F.counts(@statuses, "SimpleFit subscriptions of this mode by SimpleFit status."),
          unrecorded_subscriptions:
            F.counts(@statuses, "Subscriptions with no provider record, by status; in no mode."),
          provider_statuses:
            F.counts(@provider, "Stripe Subscription links of this mode by Stripe status."),
          invoices:
            F.counts(
              ~w(draft open paid uncollectible void)a,
              "Recorded invoices of this mode by status."
            ),
          payment_issues:
            F.counts(
              ~w(payment_failed action_required uncollectible)a,
              "Open invoices whose last attempt failed or awaits the customer, and uncollectible ones."
            ),
          refunds:
            F.counts(
              ~w(requested pending requires_action succeeded failed canceled)a,
              "Refunds of this mode by status (recorded; none can be requested here)."
            ),
          disputes: %Schema{
            type: :array,
            description: "Disputes of this mode by Stripe status.",
            items: %Schema{
              type: :object,
              required: [:status, :count],
              properties: %{status: %Schema{type: :string}, count: F.count()}
            }
          },
          collected: %Schema{
            type: :object,
            required: [:period_start, :period_end, :currencies],
            properties: %{
              period_start: F.at("Window start (by `paid_at`)."),
              period_end: F.at("Window end."),
              currencies: %Schema{
                type: :array,
                items: %Schema{
                  type: :object,
                  required: [
                    :currency,
                    :invoice_count,
                    :amount_paid,
                    :amount_paid_minor,
                    :amount_refunded,
                    :amount_refunded_minor
                  ],
                  properties: %{
                    currency: %Schema{type: :string},
                    invoice_count: F.count(),
                    amount_paid: F.decimal("Gross amount paid."),
                    amount_paid_minor: F.minor_sum("Gross amount paid, in minor units."),
                    amount_refunded: F.decimal("Refunded so far of those invoices."),
                    amount_refunded_minor: F.minor_sum("Refunded so far, in minor units.")
                  }
                }
              }
            }
          },
          last_synced_at:
            F.at("When any Stripe object of this mode was last read; null if never.", true),
          last_webhook_at: F.at("When a webhook of this mode last arrived; null if never.", true),
          unavailable: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              required: [:metric, :reason],
              properties: %{
                metric: %Schema{type: :string},
                reason: %Schema{type: :string, enum: ["no_approved_definition"]}
              }
            }
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingPlan do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{AdminBillingFields, CommerceFields}

  OpenApiSpex.schema(%{
    title: "AdminBillingPlan",
    description: """
    A SaaS plan and every version as recorded (SF-101), newest first. Published versions are immutable;
    a subscription keeps the price version it agreed to. `entitlements` is null in the catalog list and set
    on one plan. No edit exists here.
    """,
    type: :object,
    required: [:key, :created_at, :current_version_id, :versions],
    properties: %{
      key: %Schema{type: :string},
      created_at: AdminBillingFields.at("When the plan was created."),
      current_version_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The published version, if one is."
      },
      versions: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [
            :id,
            :version,
            :name,
            :description,
            :status,
            :price_source,
            :proposed_trial_days,
            :approval_reference,
            :published_at,
            :superseded_at,
            :retired_at,
            :archived_at,
            :created_at,
            :prices,
            :entitlements
          ],
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            version: %Schema{type: :integer, minimum: 1},
            name: %Schema{type: :string},
            description: %Schema{type: :string, nullable: true},
            status: AdminBillingFields.version_status(),
            price_source: %Schema{
              type: :string,
              enum: ["approved_design", "product_decision", "provisional"],
              description: "Where its prices come from. `provisional` prices are never sold live."
            },
            proposed_trial_days: %Schema{
              type: :integer,
              nullable: true,
              description: "Proposed only: no trial is applied by billing."
            },
            approval_reference: %Schema{type: :string, nullable: true},
            published_at: AdminBillingFields.at("Published.", true),
            superseded_at: AdminBillingFields.at("Superseded by a newer version.", true),
            retired_at: AdminBillingFields.at("Retired.", true),
            archived_at: AdminBillingFields.at("Archived (drafts only).", true),
            created_at: AdminBillingFields.at("Drafted."),
            prices: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                required: [
                  :price_version_id,
                  :interval,
                  :currency,
                  :pricing,
                  :amount,
                  :amount_minor,
                  :stripe_mapped_modes
                ],
                properties: %{
                  price_version_id: %Schema{type: :string, format: :uuid},
                  interval: %Schema{type: :string, enum: ["month", "year"]},
                  currency: CommerceFields.currency(),
                  pricing: %Schema{
                    type: :string,
                    enum: ["fixed", "quote_required"],
                    description: "`quote_required` has no amount: never free."
                  },
                  amount: CommerceFields.amount(true),
                  amount_minor: CommerceFields.amount_minor(true),
                  stripe_mapped_modes: %Schema{
                    type: :array,
                    items: AdminBillingFields.mode("A mode it has a Stripe Price in."),
                    description:
                      "The modes this price is mapped to a Stripe Price in (no Stripe id)."
                  }
                }
              }
            },
            entitlements: %Schema{
              type: :array,
              nullable: true,
              items: %Schema{
                type: :object,
                required: [:feature_key, :quantity_limit],
                properties: %{
                  feature_key: %Schema{type: :string},
                  quantity_limit: %Schema{type: :integer, nullable: true}
                }
              }
            }
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingPlanListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminBillingPlanListResponse",
    type: :object,
    required: [:plans],
    properties: %{
      plans: %Schema{type: :array, items: SimpleFitWeb.Schemas.AdminBillingPlan}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingPlanResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AdminBillingPlanResponse",
    type: :object,
    required: [:plan],
    properties: %{plan: SimpleFitWeb.Schemas.AdminBillingPlan}
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingSubscription do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminBillingFields

  OpenApiSpex.schema(%{
    title: "AdminBillingSubscription",
    description: """
    A gym's SimpleFit SaaS subscription (SF-127): SimpleFit's lifecycle status, Stripe's status as last read,
    the agreed plan version and price, and its reconciliation state. `pending_activation` grants nothing;
    Stripe's `trialing` or `active` is not a collected payment.
    """,
    type: :object,
    required: AdminBillingFields.subscription_required(),
    properties: AdminBillingFields.subscription_properties()
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingSubscriptionListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminBillingSubscriptionListResponse",
    type: :object,
    required: [:mode, :subscriptions, :next_cursor],
    properties: %{
      mode: %Schema{
        type: :string,
        enum: ["test", "live", "none"],
        description: "The environment listed."
      },
      subscriptions: %Schema{type: :array, items: SimpleFitWeb.Schemas.AdminBillingSubscription},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingInvoice do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminBillingFields

  OpenApiSpex.schema(%{
    title: "AdminBillingInvoice",
    description: """
    A Stripe invoice of a gym's SaaS subscription as last read (SF-102): amounts are Stripe's, in its own
    currency. No hosted invoice or PDF link, no Stripe id, no payment method.
    """,
    type: :object,
    required: AdminBillingFields.invoice_required() ++ [:gym],
    properties: Map.put(AdminBillingFields.invoice_properties(), :gym, AdminBillingFields.gym())
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingInvoiceListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminBillingFields

  OpenApiSpex.schema(%{
    title: "AdminBillingInvoiceListResponse",
    type: :object,
    required: [:mode, :invoices, :next_cursor],
    properties: %{
      mode: AdminBillingFields.mode(),
      invoices: %Schema{type: :array, items: SimpleFitWeb.Schemas.AdminBillingInvoice},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingSubscriptionResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminBillingFields, as: F

  OpenApiSpex.schema(%{
    title: "AdminBillingSubscriptionResponse",
    description: """
    One gym SaaS subscription with its billing periods (from verified evidence only), its newest recorded
    invoices with their refunds and disputes, and its hosted checkouts' states (never their URLs).
    """,
    type: :object,
    required: [:subscription],
    properties: %{
      subscription: %Schema{
        type: :object,
        required:
          F.subscription_required() ++
            [
              :revision,
              :cancel_mode,
              :cancellation_requested_at,
              :provider_period_start,
              :provider_period_end,
              :periods,
              :invoices,
              :checkouts
            ],
        properties:
          Map.merge(F.subscription_properties(), %{
            revision: %Schema{type: :integer, minimum: 1},
            cancel_mode: %Schema{
              type: :string,
              nullable: true,
              enum: ["immediate", "period_end", nil]
            },
            cancellation_requested_at: F.at("When cancellation was requested.", true),
            provider_period_start: F.at("Stripe's current period start as last read.", true),
            provider_period_end: F.at("Stripe's current period end as last read.", true),
            periods: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                required: [:period_start, :period_end, :source, :recorded_at],
                properties: %{
                  period_start: F.at("Paid period start."),
                  period_end: F.at("Paid period end."),
                  source: %Schema{type: :string, enum: ["activation", "renewal"]},
                  recorded_at: F.at("When the verified evidence was recorded.")
                }
              }
            },
            invoices: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                required: F.invoice_required() ++ [:refunds, :disputes],
                properties:
                  Map.merge(F.invoice_properties(), %{
                    refunds: %Schema{type: :array, items: F.invoice_event(:refund)},
                    disputes: %Schema{type: :array, items: F.invoice_event(:dispute)}
                  })
              }
            },
            checkouts: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                required: [:mode, :status, :created_at, :expires_at, :completed_at],
                properties: %{
                  mode: F.mode("The checkout's Stripe mode."),
                  status: %Schema{type: :string, enum: ~w(creating open completed expired failed)},
                  created_at: F.at("Created."),
                  expires_at: F.at("Expires."),
                  completed_at: F.at("Completed at Stripe.", true)
                }
              }
            }
          })
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminBillingReconciliationResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminBillingFields, as: F

  OpenApiSpex.schema(%{
    title: "AdminBillingReconciliationResponse",
    description: """
    Reconciliation of one Stripe mode (SF-127). There is no reconciliation run: each subscription's Stripe link
    records when Stripe was last read and a discrepancy code when it could not be applied. `in_sync` + `stale` +
    `mismatch` = `linked`. Webhook figures are the inbox's (ids and payloads are never stored or shown).
    """,
    type: :object,
    required: [:reconciliation],
    properties: %{
      reconciliation: %Schema{
        type: :object,
        required: [
          :observed_at,
          :mode,
          :integration,
          :summary,
          :webhooks,
          :discrepancies,
          :next_cursor
        ],
        properties: %{
          observed_at: F.at("When it was read."),
          mode: F.mode(),
          integration: %Schema{type: :string, enum: ["disabled", "misconfigured", "ready"]},
          summary: %Schema{
            type: :object,
            required: [
              :linked,
              :in_sync,
              :stale,
              :mismatch,
              :not_linked,
              :last_synced_at,
              :oldest_synced_at
            ],
            properties: %{
              linked: F.count(),
              in_sync: F.count(),
              stale: F.count(),
              mismatch: F.count(),
              not_linked: %Schema{
                type: :integer,
                minimum: 0,
                description: "Subscriptions with a checkout of this mode but no Stripe link yet."
              },
              last_synced_at: F.at("Most recent read of a link; null if none.", true),
              oldest_synced_at: F.at("Least recent read of a link; null if none.", true)
            }
          },
          webhooks: %Schema{
            type: :object,
            required: [:window_start, :counts, :backlog, :last_received_at, :failed],
            properties: %{
              window_start: F.at("Counts cover events received since."),
              counts:
                F.counts(~w(received processed ignored failed)a, "Events by processing status."),
              backlog: %Schema{
                type: :integer,
                minimum: 0,
                description: "Events still `received` (not yet processed), any age."
              },
              last_received_at: F.at("When an event last arrived.", true),
              failed: %Schema{
                type: :array,
                description: "The newest failed events: type and outcome code only.",
                items: %Schema{
                  type: :object,
                  required: [
                    :event_type,
                    :outcome,
                    :attempts,
                    :event_created_at,
                    :received_at,
                    :processed_at
                  ],
                  properties: %{
                    event_type: %Schema{type: :string},
                    outcome: %Schema{type: :string, nullable: true},
                    attempts: F.count(),
                    event_created_at: F.at("When Stripe created the event."),
                    received_at: F.at("When it arrived."),
                    processed_at: F.at("When processing last finished.", true)
                  }
                }
              }
            }
          },
          discrepancies: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              required: [
                :subscription_id,
                :gym,
                :subscription_status,
                :provider_status,
                :discrepancy,
                :synced_at
              ],
              properties: %{
                subscription_id: %Schema{type: :string, format: :uuid},
                gym: F.gym(),
                subscription_status: %Schema{
                  type: :string,
                  enum: ~w(pending_activation active cancellation_scheduled cancelled expired)
                },
                provider_status: F.provider_status(false),
                discrepancy: %Schema{type: :string},
                synced_at: F.at("When Stripe was last read for it.")
              }
            }
          },
          next_cursor: %Schema{type: :string, nullable: true}
        }
      }
    }
  })
end
