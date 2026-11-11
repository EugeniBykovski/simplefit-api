defmodule SimpleFitWeb.AdminOversightController do
  @moduledoc """
  Operator oversight of gyms, coaches and fighters (SF-123): read-only. A filtered,
  paged gym list and one gym; exact lookup and one profile for coaches and fighters.
  Each domain has its own permission. There is no update, intervention, export or
  relationship list, and no private coaching, health or member data. The rules live
  in `SimpleFit.Operators` and the owning contexts.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminOversightJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @reason [
    reason_code: [
      in: :query,
      required: true,
      description: "Why the operator reads this; recorded with the read.",
      schema: %Schema{type: :string, enum: Operators.user_read_reasons()}
    ]
  ]
  @exact [
    query: [
      in: :query,
      required: true,
      description: "An exact email address or user id of the person's account.",
      schema: %Schema{type: :string, minLength: 1, maxLength: 320}
    ]
  ]

  @access """
  * `not_found` - not a usable operator (indistinguishable from an unknown route), or no such record. The
    permission is checked first, so an operator without it can't learn whether a record exists.
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  * `validation_error` - a missing or unknown `reason_code`, or a malformed parameter.
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    unprocessable_entity: ApiSpec.error_response("validation_error"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :gyms,
    operation_id: "listAdminGyms",
    summary: "One page of gyms",
    description:
      """
      Needs `gyms.read` and a key check. Newest first; each gym's own state, the primary location's country
      and city and its active staff count. No member data. Every query is recorded (`gyms.listed`).

      """ <> @access,
    security: @security,
    parameters: [
      query: [
        in: :query,
        description: "The start of the gym's name (case-insensitive).",
        schema: %Schema{type: :string, minLength: 1, maxLength: 80}
      ],
      lifecycle: [in: :query, schema: %Schema{type: :string, enum: Enums.lifecycles()}],
      verification: [
        in: :query,
        schema: %Schema{type: :string, enum: Enums.verification_statuses()}
      ],
      country: [
        in: :query,
        description: "The primary location's country, ISO alpha-2.",
        schema: %Schema{type: :string, pattern: "^[A-Z]{2}$"}
      ],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 50, default: 25}],
      cursor: [
        in: :query,
        description: "`next_cursor` of the previous page, with the same filters.",
        schema: %Schema{type: :string, maxLength: 1024}
      ]
    ],
    responses: [ok: {"A page", "application/json", Schemas.AdminGymListResponse}] ++ @base

  def gyms(conn, params) do
    with {:ok, page} <-
           Operators.list_gyms(
             user(conn),
             session(conn),
             Map.take(params, ~w(query lifecycle verification country limit cursor)),
             ctx()
           ) do
      render(conn, :gyms, page: page)
    end
  end

  operation :gym,
    operation_id: "getAdminGym",
    summary: "One gym",
    description:
      "Needs `gyms.read` and a key check. Counts of people, the owner's short name and the verification " <>
        "status; never member names, contacts, business details or documents. Recorded with its " <>
        "`reason_code` (`gym.viewed`).\n\n" <> @access,
    security: @security,
    parameters:
      [gym_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]] ++
        @reason,
    responses: [ok: {"The gym", "application/json", Schemas.AdminGymResponse}] ++ @base

  def gym(conn, %{"gym_id" => id} = params) do
    with {:ok, gym} <-
           Operators.get_gym(
             user(conn),
             session(conn),
             id,
             Map.take(params, ["reason_code"]),
             ctx()
           ) do
      render(conn, :gym, gym: gym)
    end
  end

  operation :coaches,
    operation_id: "searchAdminCoaches",
    summary: "Find one coach by exact email or user id",
    description:
      """
      Needs `coaches.read` and a key check. Exact only, never a list. Every search is recorded with its
      `reason_code` (`coach.searched`), found or not; 60 profile searches per operator and hour.

      """ <> @access <> "* `rate_limited` - too many searches.",
    security: @security,
    parameters: @exact ++ @reason,
    responses:
      [
        ok: {"At most one coach", "application/json", Schemas.AdminCoachSearchResponse},
        too_many_requests: ApiSpec.error_response("rate_limited")
      ] ++ @base

  def coaches(conn, params) do
    with {:ok, result} <-
           Operators.search_coaches(
             user(conn),
             session(conn),
             Map.take(params, ~w(query reason_code)),
             ctx()
           ) do
      render(conn, :coaches, coaches: result.coaches)
    end
  end

  operation :coach,
    operation_id: "getAdminCoach",
    summary: "One coach",
    description:
      "Needs `coaches.read` and a key check. Profile, account state, relationship counts and gym ids; never " <>
        "the bio, fighters, training, notes or messages. Recorded with its `reason_code` (`coach.viewed`)." <>
        "\n\n" <> @access,
    security: @security,
    parameters:
      [coach_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]] ++
        @reason,
    responses: [ok: {"The coach", "application/json", Schemas.AdminCoachResponse}] ++ @base

  def coach(conn, %{"coach_id" => id} = params) do
    with {:ok, coach} <-
           Operators.get_coach(
             user(conn),
             session(conn),
             id,
             Map.take(params, ["reason_code"]),
             ctx()
           ) do
      render(conn, :coach, coach: coach)
    end
  end

  operation :fighters,
    operation_id: "searchAdminFighters",
    summary: "Find one fighter by exact @username, email or user id",
    description:
      """
      Needs `fighters.read` and a key check. Exact only, never a list: `@username`, or the account's email
      address or user id. Every search is recorded with its `reason_code` (`fighter.searched`), found or
      not; shares the profile search limit.

      """ <> @access <> "* `rate_limited` - too many searches.",
    security: @security,
    parameters: [
      query: [
        in: :query,
        required: true,
        description: "`@username`, or an exact email address or user id.",
        schema: %Schema{type: :string, minLength: 1, maxLength: 320}
      ],
      reason_code: @reason[:reason_code]
    ],
    responses:
      [
        ok: {"At most one fighter", "application/json", Schemas.AdminFighterSearchResponse},
        too_many_requests: ApiSpec.error_response("rate_limited")
      ] ++ @base

  def fighters(conn, params) do
    with {:ok, result} <-
           Operators.search_fighters(
             user(conn),
             session(conn),
             Map.take(params, ~w(query reason_code)),
             ctx()
           ) do
      render(conn, :fighters, fighters: result.fighters)
    end
  end

  operation :fighter,
    operation_id: "getAdminFighter",
    summary: "One fighter",
    description:
      "Needs `fighters.read` and a key check. Shared profile fields, account state and counts; never body, " <>
        "health, age, goals, training, notes or messages. Recorded with its `reason_code` " <>
        "(`fighter.viewed`).\n\n" <> @access,
    security: @security,
    parameters:
      [fighter_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]] ++
        @reason,
    responses: [ok: {"The fighter", "application/json", Schemas.AdminFighterResponse}] ++ @base

  def fighter(conn, %{"fighter_id" => id} = params) do
    with {:ok, fighter} <-
           Operators.get_fighter(
             user(conn),
             session(conn),
             id,
             Map.take(params, ["reason_code"]),
             ctx()
           ) do
      render(conn, :fighter, fighter: fighter)
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
