defmodule SimpleFitWeb.Schemas.AdminUserContexts do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminUserContexts",
    description:
      "What the account takes part in, as statuses and counts only: never profile content, gym, member or " <>
        "organization data.",
    type: :object,
    required: [
      :fighter_profile,
      :coach_profile,
      :gym_staff,
      :gym_member,
      :sponsor_memberships,
      :platform_operator
    ],
    properties: %{
      fighter_profile: %Schema{type: :string, enum: ~w(not_started in_progress completed)},
      coach_profile: %Schema{type: :string, enum: ~w(not_started in_progress completed)},
      gym_staff: %Schema{type: :integer, minimum: 0, description: "Active staff memberships."},
      gym_member: %Schema{type: :integer, minimum: 0, description: "Active gym memberships."},
      sponsor_memberships: %Schema{type: :integer, minimum: 0},
      platform_operator: %Schema{
        type: :boolean,
        description:
          "A usable platform operator: administered through operator administration only."
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminUserContexts

  OpenApiSpex.schema(%{
    title: "AdminUserSummary",
    description: "An account found by exact search: masked addresses only.",
    type: :object,
    required: [:id, :name, :joined_at, :status, :masked_emails, :contexts],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{
        type: :string,
        nullable: true,
        description: "The account's full name, if registered."
      },
      joined_at: %Schema{type: :string, format: :"date-time"},
      status: %Schema{type: :string, enum: ~w(active suspended)},
      masked_emails: %Schema{type: :array, items: %Schema{type: :string}},
      contexts: AdminUserContexts
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserSearchResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminUserSummary

  OpenApiSpex.schema(%{
    title: "AdminUserSearchResponse",
    description: "At most one account: search is exact, never a list.",
    type: :object,
    required: [:users],
    properties: %{users: %Schema{type: :array, items: AdminUserSummary, maxItems: 1}}
  })
end

defmodule SimpleFitWeb.Schemas.AdminUser do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminUserContexts

  OpenApiSpex.schema(%{
    title: "AdminUser",
    description: """
    One account for operator administration (SF-122). Addresses are masked (`users.reveal_email` shows
    them). Sign-in methods are the identities the person proved control of: an email code, a Google or
    an Apple sign-in. No identity or document verification exists, and none is implied. Sessions carry
    only their start and end: nothing else is recorded.
    """,
    type: :object,
    required: [
      :id,
      :name,
      :joined_at,
      :status,
      :revision,
      :suspension,
      :registration,
      :providers,
      :masked_emails,
      :sessions,
      :last_sign_in_at,
      :contexts
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, nullable: true},
      joined_at: %Schema{type: :string, format: :"date-time"},
      status: %Schema{type: :string, enum: ~w(active suspended)},
      revision: %Schema{type: :integer, minimum: 1, description: "The account state's revision."},
      suspension: %Schema{
        type: :object,
        nullable: true,
        required: [:since, :reason_code],
        properties: %{
          since: %Schema{type: :string, format: :"date-time"},
          reason_code: %Schema{type: :string}
        }
      },
      registration: %Schema{type: :string, enum: ~w(not_started in_progress complete)},
      providers: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: ~w(email google apple)}
      },
      masked_emails: %Schema{type: :array, items: %Schema{type: :string}},
      sessions: %Schema{
        type: :array,
        description: "Active sessions, newest first.",
        items: %Schema{
          type: :object,
          required: [:started_at, :expires_at],
          properties: %{
            started_at: %Schema{type: :string, format: :"date-time"},
            expires_at: %Schema{type: :string, format: :"date-time"}
          }
        }
      },
      last_sign_in_at: %Schema{type: :string, format: :"date-time", nullable: true},
      contexts: AdminUserContexts
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminUser

  OpenApiSpex.schema(%{
    title: "AdminUserResponse",
    type: :object,
    required: [:user],
    properties: %{user: AdminUser}
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserEmailResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminUserEmailResponse",
    type: :object,
    required: [:email_addresses],
    properties: %{email_addresses: %Schema{type: :array, items: %Schema{type: :string}}}
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserReadRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminUserReadRequest",
    description: "Why the operator reads this: recorded with the read.",
    type: :object,
    additionalProperties: false,
    required: [:reason_code],
    properties: %{
      reason_code: %Schema{type: :string, enum: SimpleFit.Operators.user_read_reasons()}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminUserStateResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminUserStateResponse",
    description: "The account's state after an action.",
    type: :object,
    required: [:user],
    properties: %{
      user: %Schema{
        type: :object,
        required: [:id, :status, :revision],
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string, enum: ~w(active suspended)},
          revision: %Schema{type: :integer, minimum: 1}
        }
      }
    }
  })
end

for {module, action, description} <- [
      {SimpleFitWeb.Schemas.SuspendUserRequest, "user.suspend",
       "Suspend an account (SF-122): signed out everywhere, no sign-in until lifted."},
      {SimpleFitWeb.Schemas.LiftUserSuspensionRequest, "user.lift_suspension",
       "Lift an account's suspension (SF-122): sign-in allowed again; sessions stay revoked."},
      {SimpleFitWeb.Schemas.SignOutUserEverywhereRequest, "user.sign_out_everywhere",
       "Revoke every active session of an account (SF-122)."}
    ] do
  defmodule module do
    @moduledoc false
    require OpenApiSpex
    alias SimpleFit.Operators.UserActions
    alias SimpleFitWeb.Schemas.SponsorDecisionRequests

    OpenApiSpex.schema(
      SponsorDecisionRequests.schema(
        module |> Module.split() |> List.last(),
        Map.fetch!(UserActions.reasons(), action),
        description
      ),
      struct?: false
    )
  end
end
