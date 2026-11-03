defmodule SimpleFitWeb.Schemas.GymBillingSummary do
  @moduledoc "OpenAPI schema: a gym's SimpleFit billing summary (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymSaasSubscription, GymTimetableFields}

  @payment_states ~w(none ended awaiting_checkout checkout_open processing action_required
                     payment_failed past_due cancellation_scheduled active)

  @provider_statuses ~w(incomplete incomplete_expired trialing active past_due canceled unpaid paused)

  OpenApiSpex.schema(
    %{
      title: "GymBillingSummary",
      description:
        "The gym's SimpleFit plan and payment state, from provider state SimpleFit reconciled (never from a " <>
          "browser redirect). No card, bank or payment method detail is exposed.",
      type: :object,
      additionalProperties: false,
      required: [:provider, :subscription, :payment, :checkout],
      properties: %{
        provider: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:status, :mode, :portal_available],
          properties: %{
            status: %Schema{
              type: :string,
              enum: ["ready", "disabled", "unavailable"],
              description:
                "`disabled`: payments are switched off in this environment (no checkout, nothing is charged); " <>
                  "`unavailable`: misconfigured (fails closed)."
            },
            mode: %Schema{
              type: :string,
              nullable: true,
              enum: ["test", "live", nil],
              description: "`test`: Stripe test mode, no real money moves."
            },
            portal_available: %Schema{
              type: :boolean,
              description:
                "Whether `createGymBillingPortalSession` can open the Stripe Customer Portal."
            }
          }
        },
        subscription: %Schema{
          allOf: [GymSaasSubscription],
          type: :object,
          nullable: true,
          description: "The gym's latest subscription, or `null`."
        },
        payment: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:state],
          properties: %{
            state: %Schema{
              type: :string,
              enum: @payment_states,
              description:
                "`awaiting_checkout` (an intent without checkout), `checkout_open`, `processing` (paid or " <>
                  "completed but not yet confirmed by a paid invoice), `action_required` (the bank asks for " <>
                  "authentication), `payment_failed`, `past_due` (a renewal is unpaid; access lasts until the " <>
                  "paid period ends), `cancellation_scheduled`, `active`, `ended`, `none`."
            },
            provider_status: %Schema{
              type: :string,
              nullable: true,
              enum: @provider_statuses ++ [nil]
            },
            next_payment_at:
              GymTimetableFields.at_or_null(
                "The next renewal date, only when the provider confirms an active, renewing subscription."
              ),
            action_url: %Schema{
              type: :string,
              nullable: true,
              description:
                "Stripe's hosted invoice page to authenticate or pay an open invoice (short-lived use)."
            }
          }
        },
        checkout: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: false,
          required: [:status, :expires_at],
          properties: %{
            status: %Schema{type: :string, enum: ["open"]},
            expires_at: GymTimetableFields.at("When the hosted checkout expires.")
          },
          description: "An open hosted checkout of the pending intent, or `null`."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBillingSummaryResponse do
  @moduledoc "OpenAPI schema: a gym's billing summary (SF-102)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymBillingSummary

  OpenApiSpex.schema(
    %{
      title: "GymBillingSummaryResponse",
      type: :object,
      additionalProperties: false,
      required: [:billing],
      properties: %{billing: GymBillingSummary}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBillingInvoice do
  @moduledoc "OpenAPI schema: one Stripe invoice of the gym (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymBillingInvoice",
      description:
        "A Stripe invoice as SimpleFit last reconciled it. Only `paid` is paid; `draft` and `open` never are. " <>
          "SimpleFit renders no invoice document: `hosted_invoice_url` and `invoice_pdf` are Stripe's.",
      type: :object,
      additionalProperties: false,
      required: [
        :invoice_id,
        :number,
        :status,
        :payment_status,
        :currency,
        :total,
        :total_minor,
        :amount_paid,
        :amount_paid_minor,
        :amount_refunded,
        :amount_refunded_minor,
        :disputed,
        :period_start,
        :period_end,
        :issued_at,
        :paid_at,
        :hosted_invoice_url,
        :invoice_pdf,
        :subscription_id,
        :mode
      ],
      properties: %{
        invoice_id: GymTimetableFields.uuid("SimpleFit's id of the invoice record."),
        number: %Schema{
          type: :string,
          nullable: true,
          description: "Stripe's invoice number, once finalized."
        },
        status: %Schema{type: :string, enum: ["draft", "open", "paid", "uncollectible", "void"]},
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
          description: "The last payment attempt's state at the provider."
        },
        currency: %Schema{type: :string, description: "ISO 4217 code."},
        total: CommerceFields.amount(true),
        total_minor: CommerceFields.amount_minor(),
        amount_paid: CommerceFields.amount(true),
        amount_paid_minor: CommerceFields.amount_minor(),
        amount_refunded: CommerceFields.amount(true),
        amount_refunded_minor: CommerceFields.amount_minor(),
        disputed: %Schema{
          type: :boolean,
          description: "A chargeback/dispute exists for its payment (not a refund)."
        },
        period_start: GymTimetableFields.at_or_null("The billed period's start."),
        period_end: GymTimetableFields.at_or_null("The billed period's end."),
        issued_at: GymTimetableFields.at("When Stripe created it."),
        paid_at: GymTimetableFields.at_or_null("When it was paid."),
        hosted_invoice_url: %Schema{type: :string, nullable: true},
        invoice_pdf: %Schema{type: :string, nullable: true},
        subscription_id: GymTimetableFields.uuid_or_null("The SimpleFit subscription it bills."),
        mode: %Schema{type: :string, enum: ["test", "live"]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBillingInvoiceList do
  @moduledoc "OpenAPI schema: the gym's Stripe invoices (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymBillingInvoice

  OpenApiSpex.schema(
    %{
      title: "GymBillingInvoiceList",
      type: :object,
      additionalProperties: false,
      required: [:invoices],
      properties: %{
        invoices: %Schema{
          type: :array,
          items: GymBillingInvoice,
          description: "Newest first, at most 50."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSaasCheckoutResponse do
  @moduledoc "OpenAPI schema: a hosted checkout of a gym's subscription intent (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymSaasCheckoutResponse",
      type: :object,
      additionalProperties: false,
      required: [:checkout],
      properties: %{
        checkout: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:checkout_id, :status, :url, :expires_at],
          properties: %{
            checkout_id: GymTimetableFields.uuid("SimpleFit's checkout record."),
            status: %Schema{type: :string, enum: ["open"]},
            url: %Schema{
              type: :string,
              description:
                "Stripe-hosted checkout page to redirect the browser to. Never shared or stored by clients."
            },
            expires_at: GymTimetableFields.at("When the hosted checkout expires.")
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBillingPortalResponse do
  @moduledoc "OpenAPI schema: a Stripe Customer Portal session (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymBillingPortalResponse",
      type: :object,
      additionalProperties: false,
      required: [:portal],
      properties: %{
        portal: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:url],
          properties: %{
            url: %Schema{
              type: :string,
              description:
                "Short-lived Stripe Customer Portal URL; open it at once, never store it."
            }
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.StripeWebhookAck do
  @moduledoc "OpenAPI schema: a Stripe webhook acknowledgement (SF-102)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "StripeWebhookAck",
      type: :object,
      additionalProperties: false,
      required: [:received, :duplicate],
      properties: %{
        received: %Schema{type: :boolean},
        duplicate: %Schema{
          type: :boolean,
          description: "The event id was already recorded; nothing changed."
        }
      }
    },
    struct?: false
  )
end
