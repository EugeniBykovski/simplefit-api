defmodule SimpleFitWeb.Schemas.CommerceFields do
  @moduledoc """
  Shared OpenAPI definitions of SimpleFit plans and gym member products
  (SF-101): money is a decimal string plus its ISO 4217 currency and the
  integer minor units it was stored as; never a float.
  """

  alias OpenApiSpex.Schema

  @currencies ~w(PLN EUR USD GBP CHF CZK SEK NOK DKK HUF UAH JPY)

  @doc "The supported ISO 4217 codes."
  def currencies, do: @currencies

  @doc "An ISO 4217 currency."
  def currency do
    %Schema{
      type: :string,
      enum: @currencies,
      description: "ISO 4217 code. No conversion between currencies exists."
    }
  end

  @doc "A decimal amount string."
  def amount(nullable \\ false) do
    %Schema{
      type: :string,
      nullable: nullable,
      pattern: "^[0-9]{1,13}(\\.[0-9]{1,6})?$",
      description:
        "Decimal amount in the currency's major unit (\"149.00\"; \"0\" decimals for JPY). Never a float; no VAT."
    }
  end

  @doc "Integer minor units."
  def amount_minor(nullable \\ false) do
    %Schema{
      type: :integer,
      nullable: nullable,
      minimum: 0,
      description: "The same amount in integer minor units (14900 for 149.00 PLN)."
    }
  end

  @doc "A subscription status."
  def subscription_status do
    %Schema{
      type: :string,
      enum: ["pending_activation", "active", "cancellation_scheduled", "cancelled", "expired"],
      description:
        "`pending_activation` is an intent and grants nothing; only verified provider evidence activates " <>
          "(none exists yet). `cancellation_scheduled` stays in force until `cancellation_effective_at`. " <>
          "`cancelled` and `expired` are final."
    }
  end

  @doc "How a subscription was cancelled."
  def cancel_mode do
    %Schema{
      type: :string,
      nullable: true,
      enum: ["immediate", "period_end", nil],
      description: "`immediate` or at the end of the current period."
    }
  end

  @doc "The lifecycle timestamps of a subscription."
  def lifecycle_properties do
    alias SimpleFitWeb.Schemas.GymTimetableFields, as: F

    %{
      requested_at: F.at("When the intent was recorded."),
      activated_at: F.at_or_null("When verified evidence activated it."),
      current_period_start: F.at_or_null("The paid period's start (verified evidence only)."),
      current_period_end: F.at_or_null("The paid period's end (exclusive)."),
      cancel_mode: cancel_mode(),
      cancellation_requested_at: F.at_or_null("When cancellation was asked for."),
      cancellation_effective_at: F.at_or_null("When it ends (or ended)."),
      ended_at: F.at_or_null("When it became `cancelled` or `expired`.")
    }
  end

  @doc "The lifecycle field names."
  def lifecycle_required,
    do: ~w(requested_at activated_at current_period_start current_period_end cancel_mode
           cancellation_requested_at cancellation_effective_at ended_at)a

  @doc "The cancellation request."
  def cancel_rules do
    """
    `immediate` ends it now; `period_end` schedules the end at the current period's end (an intent is always
    cancelled at once). Repeating the request returns it unchanged. No refund, proration or invoice exists.
    """
  end
end

defmodule SimpleFitWeb.Schemas.SaasPrice do
  @moduledoc "OpenAPI schema: one price of a SimpleFit plan version (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "SaasPrice",
      description:
        "An immutable price for one interval and currency: `fixed` (an amount; `0` means free) or " <>
          "`quote_required` (no amount: priced by a quote, never as zero).",
      type: :object,
      additionalProperties: false,
      required: [:price_version_id, :interval, :currency, :pricing, :amount, :amount_minor],
      properties: %{
        price_version_id: GymTimetableFields.uuid("The price version."),
        interval: %Schema{type: :string, enum: ["month", "year"]},
        currency: CommerceFields.currency(),
        pricing: %Schema{type: :string, enum: ["fixed", "quote_required"]},
        amount: CommerceFields.amount(true),
        amount_minor: CommerceFields.amount_minor(true)
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SaasPlan do
  @moduledoc "OpenAPI schema: a published SimpleFit plan version (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymTimetableFields, SaasPrice}

  OpenApiSpex.schema(
    %{
      title: "SaasPlan",
      description:
        "A plan version SimpleFit published under an approval. Its content and prices never change; a newer " <>
          "version supersedes it for new subscriptions only.",
      type: :object,
      additionalProperties: false,
      required: [
        :plan_key,
        :plan_version_id,
        :version,
        :name,
        :description,
        :price_source,
        :proposed_trial_days,
        :published_at,
        :prices,
        :entitlements
      ],
      properties: %{
        plan_key: %Schema{type: :string, description: "Stable plan key (`starter`)."},
        plan_version_id: GymTimetableFields.uuid("The plan version."),
        version: %Schema{type: :integer, minimum: 1},
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        price_source: %Schema{
          type: :string,
          enum: ["approved_design", "product_decision", "provisional"],
          description: "Where the prices come from."
        },
        proposed_trial_days: %Schema{
          type: :integer,
          nullable: true,
          description: "A proposed trial length. No trial is granted by any endpoint."
        },
        published_at: GymTimetableFields.at("When it was published."),
        prices: %Schema{type: :array, items: SaasPrice},
        entitlements: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:feature_key, :quantity_limit],
            properties: %{
              feature_key: %Schema{type: :string},
              quantity_limit: %Schema{type: :integer, nullable: true, minimum: 1}
            }
          },
          description: "The features this version includes (none is enforced yet)."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SaasPlanList do
  @moduledoc "OpenAPI schema: the published SimpleFit plans (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SaasPlan

  OpenApiSpex.schema(
    %{
      title: "SaasPlanList",
      type: :object,
      additionalProperties: false,
      required: [:plans],
      properties: %{
        plans: %Schema{
          type: :array,
          items: SaasPlan,
          description: "Empty until a version is published."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSaasSubscription do
  @moduledoc "OpenAPI schema: a gym's SimpleFit subscription (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields, SaasPrice}

  OpenApiSpex.schema(
    %{
      title: "GymSaasSubscription",
      description:
        "The gym (not a person) is the subscriber. It keeps the plan and price version it chose. No provider " <>
          "reference, payment or invoice is exposed.",
      type: :object,
      additionalProperties: false,
      required:
        [:subscription_id, :gym_id, :status, :plan, :price, :cancel_reason] ++
          CommerceFields.lifecycle_required(),
      properties:
        Map.merge(CommerceFields.lifecycle_properties(), %{
          subscription_id: GymTimetableFields.uuid("The subscription."),
          gym_id: GymTimetableFields.uuid("The subscribing gym."),
          status: CommerceFields.subscription_status(),
          plan: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:plan_key, :plan_version_id, :version, :name],
            properties: %{
              plan_key: %Schema{type: :string},
              plan_version_id: GymTimetableFields.uuid("The plan version chosen."),
              version: %Schema{type: :integer},
              name: %Schema{type: :string}
            }
          },
          price: SaasPrice,
          cancel_reason: %Schema{
            type: :string,
            nullable: true,
            enum: ["requested_by_gym", "gym_closed", nil]
          }
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSaasSubscriptionResponse do
  @moduledoc "OpenAPI schema: one gym SimpleFit subscription (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymSaasSubscription

  OpenApiSpex.schema(
    %{
      title: "GymSaasSubscriptionResponse",
      type: :object,
      additionalProperties: false,
      required: [:subscription],
      properties: %{subscription: GymSaasSubscription}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSaasSubscriptionList do
  @moduledoc "OpenAPI schema: a gym's SimpleFit subscriptions (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymSaasSubscription

  OpenApiSpex.schema(
    %{
      title: "GymSaasSubscriptionList",
      type: :object,
      additionalProperties: false,
      required: [:subscriptions],
      properties: %{
        subscriptions: %Schema{
          type: :array,
          items: GymSaasSubscription,
          description: "Newest first."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSaasSubscriptionRequest do
  @moduledoc "OpenAPI schema: a gym's SimpleFit subscription intent (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymSaasSubscriptionRequest",
      description:
        "Any other field (a `status`, a receipt, a payment) is a `422`: a client can neither activate nor pay.",
      type: :object,
      additionalProperties: false,
      required: [:plan_version_id, :price_version_id, :client_request_id],
      properties: %{
        plan_version_id: GymTimetableFields.uuid("A published plan version."),
        price_version_id: GymTimetableFields.uuid("One of its `fixed` prices."),
        client_request_id: GymTimetableFields.client_request_id()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SubscriptionCancelRequest do
  @moduledoc "OpenAPI schema: cancel a subscription (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SubscriptionCancelRequest",
      description: "Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:mode],
      properties: %{mode: %Schema{type: :string, enum: ["immediate", "period_end"]}}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymEntitlements do
  @moduledoc "OpenAPI schema: a gym's SimpleFit entitlement projection (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymEntitlements",
      description:
        "What the gym's plan includes, decided by the backend and failing closed. Informational: `enforced` is " <>
          "`false` for every feature, so nothing the gym already uses is gated.",
      type: :object,
      additionalProperties: false,
      required: [:subscription, :features],
      properties: %{
        subscription: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: false,
          required: [:subscription_id, :status, :in_force],
          properties: %{
            subscription_id: GymTimetableFields.uuid("The gym's latest subscription."),
            status: CommerceFields.subscription_status(),
            in_force: %Schema{
              type: :boolean,
              description:
                "Active (or scheduled to cancel) with verified evidence, inside its period."
            }
          },
          description: "`null` when the gym never asked for a plan."
        },
        features: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:key, :description, :enforced, :status, :reason, :quantity_limit],
            properties: %{
              key: %Schema{type: :string},
              description: %Schema{type: :string},
              enforced: %Schema{type: :boolean, description: "Whether any endpoint gates on it."},
              status: %Schema{type: :string, enum: ["entitled", "denied"]},
              reason: %Schema{
                type: :string,
                nullable: true,
                enum: [
                  "no_subscription",
                  "pending_activation",
                  "not_in_force",
                  "not_in_plan",
                  nil
                ]
              },
              quantity_limit: %Schema{type: :integer, nullable: true}
            }
          }
        }
      }
    },
    struct?: false
  )
end
