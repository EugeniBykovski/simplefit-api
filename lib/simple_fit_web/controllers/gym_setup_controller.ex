defmodule SimpleFitWeb.GymSetupController do
  @moduledoc """
  Gym owner registration and setup (SF-85; ADR 0026): read and partially
  update a gym's setup, set its primary location, complete the setup and
  discard a draft. Every action acts for the session's own user on the gym
  named in the path; the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymSetupJSON

  tags ["Gyms"]

  @security [%{"bearerAuth" => []}]

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @setup {"The setup", "application/json", Schemas.GymSetupResponse}

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never revealed).
  """

  operation :show,
    operation_id: "getGymSetup",
    summary: "A gym's setup",
    description: """
    The persisted setup of a gym and what a draft still needs before completion (`missing_requirements`). Any
    active staff member may read it; a draft's owner needs no `GYM_WORKSPACE` capability.

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: @setup,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"gym_id" => gym_id}) do
    with {:ok, setup} <- Gyms.get_setup(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:show, setup: setup)
    end
  end

  operation :update,
    operation_id: "updateGymSetup",
    summary: "Save part of a gym's setup",
    description: """
    Saves any subset of the profile (`name`, `gym_type`, `phone`, `website`) and text branding (`tagline`,
    `accent_color`), in a draft or a completed gym. An omitted field is unchanged; `null` or a blank string clears
    an optional field; nothing is rounded or truncated. An empty body changes nothing (and creates nothing).
    Requires the `edit_gym` permission (owner, manager).

    #{@access}
    * `forbidden` - the viewer's role cannot edit the gym.
    * `conflict` - `expected_revision` is stale (`details.revision: "stale"`); nothing is saved.
    * `validation_error` - a field is invalid or cannot be cleared, or the body names an unknown or read-only
      field.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The fields to save", "application/json", Schemas.GymSetupUpdateRequest, required: true},
    responses: [
      ok: @setup,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update(conn, %{"gym_id" => gym_id}) do
    with {:ok, setup} <- Gyms.update_setup(conn.assigns.current_user, gym_id, conn.body_params) do
      conn |> no_store() |> render(:show, setup: setup)
    end
  end

  operation :put_primary_location,
    operation_id: "setGymPrimaryLocation",
    summary: "Set a gym's primary location",
    description: """
    Sets the gym's primary address (OG2: address only). The first call creates the primary location; later calls
    replace its fields in place, so there is never a second primary location. An identical address changes
    nothing. Requires the `manage_locations` permission (owner, manager).

    #{@access}
    * `forbidden` - the viewer's role cannot manage locations.
    * `conflict` - `expected_revision` is stale (`details.revision: "stale"`); nothing is saved.
    * `validation_error` - a field is missing or invalid (`country_code` must be an ISO 3166-1 alpha-2 code), or
      an unknown field is sent.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The primary address", "application/json", Schemas.GymPrimaryLocationRequest,
       required: true},
    responses: [
      ok: @setup,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def put_primary_location(conn, %{"gym_id" => gym_id}) do
    with {:ok, setup} <-
           Gyms.put_primary_location(conn.assigns.current_user, gym_id, conn.body_params) do
      conn |> no_store() |> render(:show, setup: setup)
    end
  end

  operation :complete,
    operation_id: "completeGymSetup",
    summary: "Complete a gym's setup",
    description: """
    Completes the setup of a draft (owner only), after re-validating the persisted state: a valid name and type,
    an active primary location with a complete address, and exactly one active owner. The gym then becomes an
    operational workspace (`GYM_WORKSPACE`, `gym_home` in `resolveMyEntry`). Completion is final and requires
    nothing commercial (no plan, trial, payment, verification or publication). Completing a completed gym returns
    it unchanged.

    #{@access}
    * `forbidden` - only the owner completes setup.
    * `validation_error` - requirements are missing; each is named under `details.fields` with `required`.
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: @setup,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def complete(conn, %{"gym_id" => gym_id}) do
    with {:ok, setup, _outcome} <- Gyms.complete_setup(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:show, setup: setup)
    end
  end

  operation :discard,
    operation_id: "discardGymDraft",
    summary: "Discard a draft gym",
    description: """
    Deletes a draft gym (owner only) with its owner membership, locations and any remembered entry choice naming
    it; a minimal audit event is kept. A completed gym is never deleted here. Discarding frees the owner's draft
    slot but does not refund the creation rate limit.

    #{@access}
    * `forbidden` - only the owner discards the draft.
    * `conflict` - the gym's setup is completed (`details.setup_status: "completed"`).
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      no_content: "Discarded",
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def discard(conn, %{"gym_id" => gym_id}) do
    with :ok <- Gyms.discard_draft(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> send_resp(:no_content, "")
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
