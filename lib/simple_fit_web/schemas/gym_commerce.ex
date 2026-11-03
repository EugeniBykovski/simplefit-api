defmodule SimpleFitWeb.Schemas.GymMemberPrice do
  @moduledoc "OpenAPI schema: one price of a gym member product version (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberPrice",
      description:
        "An immutable price in one currency. A newer one (higher `sequence`) is current for new subscriptions; " <>
          "earlier subscriptions keep theirs. `0` is free. No VAT, discount or conversion.",
      type: :object,
      additionalProperties: false,
      required: [:price_version_id, :currency, :amount, :amount_minor, :sequence, :created_at],
      properties: %{
        price_version_id: GymTimetableFields.uuid("The price version."),
        currency: CommerceFields.currency(),
        amount: CommerceFields.amount(),
        amount_minor: CommerceFields.amount_minor(),
        sequence: %Schema{type: :integer, minimum: 1},
        created_at: GymTimetableFields.at("When it was added.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductVersion do
  @moduledoc "OpenAPI schema: a gym member product version (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberPrice, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductVersion",
      description:
        "`draft` (one at a time), `published` (offered; content immutable), `superseded`, `retired` or " <>
          "`archived` (a discarded draft).",
      type: :object,
      additionalProperties: false,
      required: [
        :version_id,
        :version,
        :status,
        :name,
        :description,
        :class_credits,
        :validity_days,
        :published_at,
        :current_prices,
        :prices
      ],
      properties: %{
        version_id: GymTimetableFields.uuid("The version."),
        version: %Schema{type: :integer, minimum: 1},
        status: %Schema{
          type: :string,
          enum: ["draft", "archived", "published", "superseded", "retired"]
        },
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        class_credits: %Schema{
          type: :integer,
          nullable: true,
          description: "Class admissions (`null`: unlimited within the validity)."
        },
        validity_days: %Schema{
          type: :integer,
          nullable: true,
          description: "Days from activation (`null`: no expiry)."
        },
        published_at: GymTimetableFields.at_or_null("When it was published."),
        current_prices: %Schema{
          type: :array,
          items: GymMemberPrice,
          description: "The current price per currency."
        },
        prices: %Schema{
          type: :array,
          items: GymMemberPrice,
          description: "Every price, by currency then newest first."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProduct do
  @moduledoc "OpenAPI schema: a gym member product as its staff see it (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberProductVersion, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberProduct",
      type: :object,
      additionalProperties: false,
      required: [
        :product_id,
        :gym_id,
        :key,
        :product_type,
        :status,
        :published,
        :draft,
        :versions,
        :created_at,
        :retired_at
      ],
      properties: %{
        product_id: GymTimetableFields.uuid("The product."),
        gym_id: GymTimetableFields.uuid("Its gym."),
        key: %Schema{type: :string, description: "Stable key, unique in the gym."},
        product_type: %Schema{
          type: :string,
          enum: ["single_visit", "class_pack", "unlimited_period"]
        },
        status: %Schema{
          type: :string,
          enum: ["active", "retired"],
          description: "A retired product takes no new subscription."
        },
        published: %Schema{type: :object, allOf: [GymMemberProductVersion], nullable: true},
        draft: %Schema{type: :object, allOf: [GymMemberProductVersion], nullable: true},
        versions: %Schema{
          type: :array,
          items: GymMemberProductVersion,
          description: "Newest first."
        },
        created_at: GymTimetableFields.at("When it was created."),
        retired_at: GymTimetableFields.at_or_null("When it was retired.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductResponse do
  @moduledoc "OpenAPI schema: one gym member product (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberProduct

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductResponse",
      type: :object,
      additionalProperties: false,
      required: [:product],
      properties: %{product: GymMemberProduct}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductList do
  @moduledoc "OpenAPI schema: a gym's member products (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymMemberProduct

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductList",
      type: :object,
      additionalProperties: false,
      required: [:products],
      properties: %{
        products: %Schema{type: :array, items: GymMemberProduct, description: "Oldest first."}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberPriceInput do
  @moduledoc "OpenAPI schema: a price input (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.CommerceFields

  OpenApiSpex.schema(
    %{
      title: "GymMemberPriceInput",
      description:
        "A decimal amount string with at most the currency's decimals (a JSON number, a negative amount or " <>
          "an unknown currency is a `422`).",
      type: :object,
      additionalProperties: false,
      required: [:currency, :amount],
      properties: %{currency: CommerceFields.currency(), amount: CommerceFields.amount()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductContent do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberPriceInput, GymTimetableFields}

  @doc "The content fields of a version."
  def properties do
    %{
      client_request_id: GymTimetableFields.client_request_id(),
      name: %Schema{type: :string, minLength: 1, maxLength: 80},
      description: %Schema{type: :string, nullable: true, maxLength: 500},
      class_credits: %Schema{
        type: :integer,
        nullable: true,
        description:
          "`single_visit`: 1 (or omitted); `class_pack`: 2–500 (required); `unlimited_period`: omitted."
      },
      validity_days: %Schema{
        type: :integer,
        nullable: true,
        minimum: 1,
        maximum: 730,
        description: "Required for `class_pack` and `unlimited_period`."
      },
      price: GymMemberPriceInput
    }
  end
end

defmodule SimpleFitWeb.Schemas.GymMemberProductCreateRequest do
  @moduledoc "OpenAPI schema: create a member product (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymMemberProductContent

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductCreateRequest",
      description:
        "Creates the product, its first version as a draft and that version's first price. Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:client_request_id, :key, :product_type, :name, :price],
      properties:
        Map.merge(GymMemberProductContent.properties(), %{
          key: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,39}$"},
          product_type: %Schema{
            type: :string,
            enum: ["single_visit", "class_pack", "unlimited_period"]
          }
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductVersionRequest do
  @moduledoc "OpenAPI schema: draft a new member product version (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberProductContent

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductVersionRequest",
      description: "The product type never changes. Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:client_request_id, :name, :price],
      properties: GymMemberProductContent.properties()
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberPriceRequest do
  @moduledoc "OpenAPI schema: add a price to a member product version (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{CommerceFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberPriceRequest",
      description: "Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:client_request_id, :currency, :amount],
      properties: %{
        client_request_id: GymTimetableFields.client_request_id(),
        currency: CommerceFields.currency(),
        amount: CommerceFields.amount()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberOffer do
  @moduledoc "OpenAPI schema: a product a member may ask for (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberPrice, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberOffer",
      description: "An active product's published version with its current prices.",
      type: :object,
      additionalProperties: false,
      required: [:product_id, :key, :product_type, :published],
      properties: %{
        product_id: GymTimetableFields.uuid("The product."),
        key: %Schema{type: :string},
        product_type: %Schema{
          type: :string,
          enum: ["single_visit", "class_pack", "unlimited_period"]
        },
        published: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :version_id,
            :version,
            :name,
            :description,
            :class_credits,
            :validity_days,
            :current_prices
          ],
          properties: %{
            version_id: GymTimetableFields.uuid("The published version."),
            version: %Schema{type: :integer},
            name: %Schema{type: :string},
            description: %Schema{type: :string, nullable: true},
            class_credits: %Schema{type: :integer, nullable: true},
            validity_days: %Schema{type: :integer, nullable: true},
            current_prices: %Schema{type: :array, items: GymMemberPrice}
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberOfferList do
  @moduledoc "OpenAPI schema: the products of a member's gym (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymMemberOffer

  OpenApiSpex.schema(
    %{
      title: "GymMemberOfferList",
      type: :object,
      additionalProperties: false,
      required: [:products],
      properties: %{products: %Schema{type: :array, items: GymMemberOffer}}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductSubscription do
  @moduledoc "OpenAPI schema: a member's product subscription (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  alias SimpleFitWeb.Schemas.{
    CommerceFields,
    GymBookingFields,
    GymMemberPrice,
    GymTimetableFields
  }

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductSubscription",
      description:
        "A member's product at the version and price they chose. An intent grants no admission; nothing is " <>
          "charged, refunded or debited. `member_name` is present for staff only.",
      type: :object,
      additionalProperties: false,
      required:
        [:subscription_id, :gym_id, :gym_member_id, :status, :product, :price, :cancel_reason] ++
          CommerceFields.lifecycle_required(),
      properties:
        Map.merge(CommerceFields.lifecycle_properties(), %{
          subscription_id: GymTimetableFields.uuid("The subscription."),
          gym_id: GymTimetableFields.uuid("The gym."),
          gym_member_id: GymTimetableFields.uuid("The membership."),
          member_name: GymBookingFields.name(),
          status: CommerceFields.subscription_status(),
          product: %Schema{
            type: :object,
            additionalProperties: false,
            required: [
              :product_id,
              :key,
              :product_type,
              :version_id,
              :version,
              :name,
              :class_credits,
              :validity_days
            ],
            properties: %{
              product_id: GymTimetableFields.uuid("The product."),
              key: %Schema{type: :string},
              product_type: %Schema{
                type: :string,
                enum: ["single_visit", "class_pack", "unlimited_period"]
              },
              version_id: GymTimetableFields.uuid("The version chosen."),
              version: %Schema{type: :integer},
              name: %Schema{type: :string},
              class_credits: %Schema{type: :integer, nullable: true},
              validity_days: %Schema{type: :integer, nullable: true}
            }
          },
          price: GymMemberPrice,
          cancel_reason: %Schema{
            type: :string,
            nullable: true,
            enum: [
              "requested_by_member",
              "requested_by_staff",
              "membership_ended",
              "gym_closed",
              nil
            ]
          }
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductSubscriptionResponse do
  @moduledoc "OpenAPI schema: one member product subscription (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberProductSubscription

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductSubscriptionResponse",
      type: :object,
      additionalProperties: false,
      required: [:subscription],
      properties: %{subscription: GymMemberProductSubscription}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductSubscriptionList do
  @moduledoc "OpenAPI schema: one page of member product subscriptions (SF-101)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymMemberProductSubscription}

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductSubscriptionList",
      type: :object,
      additionalProperties: false,
      required: [:subscriptions, :next_cursor],
      properties: %{
        subscriptions: %Schema{
          type: :array,
          items: GymMemberProductSubscription,
          description: "Newest first."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberProductSubscriptionRequest do
  @moduledoc "OpenAPI schema: a member's product subscription intent (SF-101)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymMemberProductSubscriptionRequest",
      description: "Any other field (a `status`, a receipt, a payment) is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:product_version_id, :price_version_id, :client_request_id],
      properties: %{
        product_version_id: GymTimetableFields.uuid("The product's published version."),
        price_version_id: GymTimetableFields.uuid("Its current price in the chosen currency."),
        client_request_id: GymTimetableFields.client_request_id()
      }
    },
    struct?: false
  )
end
