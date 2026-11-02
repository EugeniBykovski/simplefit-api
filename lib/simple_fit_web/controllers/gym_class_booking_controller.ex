defmodule SimpleFitWeb.GymClassBookingController do
  @moduledoc """
  A gym's class bookings as its staff manage them (SF-99; ADR 0026 D-G15):
  a class's roster, booking and cancelling for a member, recording a
  check-in. Every action acts for the session's own user on the gym named
  in the path; the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}
  alias SimpleFitWeb.Schemas.GymBookingFields

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymBookingJSON

  tags ["Gym bookings"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @occurrence_id %Parameter{
    name: :occurrence_id,
    in: :path,
    required: true,
    description: "A class of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @booking_id %Parameter{
    name: :booking_id,
    in: :path,
    required: true,
    description: "A booking of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a class or booking, also an unknown id or another gym's.
  * `forbidden` - the viewer's role may not do this.
  """

  @staff_booking {"The booking", "application/json", Schemas.GymClassBookingResponse}

  operation :roster,
    operation_id: "getGymClassRoster",
    summary: "A class roster",
    description: """
    The bookings of one class (confirmed by default, or cancelled), oldest confirmation first, with the class's
    counts: a short name and booking facts per member, never an email, profile, other gym or training data.
    Owner, managers and front desk; a coach only for a class they instruct (`view_rosters`).

    #{@access}
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      @gym_id,
      @occurrence_id,
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "`confirmed` (default) or `cancelled` bookings.",
        schema: %Schema{type: :string, enum: ["confirmed", "cancelled"]}
      },
      %Parameter{
        name: :limit,
        in: :query,
        required: false,
        description: "Page size (1–100, default 50).",
        schema: %Schema{type: :integer, minimum: 1, maximum: 100}
      },
      %Parameter{
        name: :cursor,
        in: :query,
        required: false,
        description: "`next_cursor` of the previous page (same filters).",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"The roster", "application/json", Schemas.GymClassRoster},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def roster(conn, %{"gym_id" => gym_id, "occurrence_id" => id} = params) do
    with {:ok, page} <- Gyms.class_roster(conn.assigns.current_user, gym_id, id, params) do
      conn |> no_store() |> render(:roster, page: page)
    end
  end

  operation :create,
    operation_id: "bookGymClassForMember",
    summary: "Book a place for a member",
    description: """
    Books one place for an active member of this gym in one of its classes, with the same rules as the member's
    own booking (scheduled, not started, a place left, one confirmed booking per member). The same
    `client_request_id` again returns that booking (`200`). Owner, managers and front desk (`book_for_member`).

    #{@access}
    #{GymBookingFields.conflicts()}
    * `validation_error` - a missing, invalid or unknown field; `gym_member_id` not a member of this gym.
    * `rate_limited` - 120 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @occurrence_id],
    request_body:
      {"The member", "application/json", Schemas.GymClassBookingForMemberRequest, required: true},
    responses: [
      created: @staff_booking,
      ok:
        {"The booking this `client_request_id` already made", "application/json",
         Schemas.GymClassBookingResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, %{"gym_id" => gym_id, "occurrence_id" => id}) do
    with {:ok, {view, outcome}} <-
           Gyms.book_class_for_member(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:staff_booking, booking: view)
    end
  end

  operation :cancel,
    operation_id: "cancelGymClassBooking",
    summary: "Cancel a member's booking",
    description: """
    Cancels a booking as the gym (`staff_cancelled`) until its class starts; its place is free again. Repeating
    it returns it unchanged. No penalty, refund or notification exists. Owner, managers and front desk
    (`book_for_member`).

    #{@access}
    * `conflict` - `details.class_booking: "checked_in"` or `"cancelled"` (otherwise; `details.cancel_reason`);
      `details.class_occurrence: "started"`.
    * `rate_limited` - 120 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @booking_id],
    responses: [
      ok: @staff_booking,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"gym_id" => gym_id, "booking_id" => id}) do
    with {:ok, view} <-
           Gyms.cancel_class_booking(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id
           ) do
      conn |> no_store() |> render(:staff_booking, booking: view)
    end
  end

  operation :check_in,
    operation_id: "checkInGymClassBooking",
    summary: "Record a check-in",
    description: """
    Records that the member of a confirmed booking came, on the class's own local day (in its venue's zone). One
    per booking: repeating it returns the same check-in (`200`). Nothing is inferred from the clock or the
    booking alone. Any active staff member (`record_check_in`).

    #{@access}
    * `conflict` - `details.class_booking: "cancelled"`; `details.class_occurrence: "cancelled"` or `"not_today"`
      (outside the class's local day).
    * `rate_limited` - 120 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @booking_id],
    responses: [
      created: {"Recorded", "application/json", Schemas.GymClassCheckInResponse},
      ok: {"Already recorded", "application/json", Schemas.GymClassCheckInResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def check_in(conn, %{"gym_id" => gym_id, "booking_id" => id}) do
    with {:ok, {view, outcome}} <-
           Gyms.check_in_class_booking(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:check_in, check_in: view)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
