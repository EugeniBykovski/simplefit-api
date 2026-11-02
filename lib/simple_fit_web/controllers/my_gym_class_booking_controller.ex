defmodule SimpleFitWeb.MyGymClassBookingController do
  @moduledoc """
  A member's own class bookings (SF-99; ADR 0026 D-G07): the classes of the
  gym of one of their own active memberships, booking a place, their
  bookings, cancelling one. Account-scoped: the user is the session's and
  the membership must be theirs; no Fighter or Coach profile is needed. The
  rules live in `SimpleFit.Gyms`.
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

  @gym_member_id %Parameter{
    name: :gym_member_id,
    in: :path,
    required: true,
    description: "One of the viewer's own memberships (it must be active).",
    schema: %Schema{type: :string, format: :uuid}
  }
  @booking_id %Parameter{
    name: :booking_id,
    in: :path,
    required: true,
    description: "One of the viewer's own bookings.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @limit %Parameter{
    name: :limit,
    in: :query,
    required: false,
    description: "Page size (1–100, default 50).",
    schema: %Schema{type: :integer, minimum: 1, maximum: 100}
  }
  @cursor %Parameter{
    name: :cursor,
    in: :query,
    required: false,
    description: "`next_cursor` of the previous page (same filters).",
    schema: %Schema{type: :string}
  }

  @booking {"The booking", "application/json", Schemas.MyGymClassBookingResponse}

  operation :classes,
    operation_id: "listMyGymClasses",
    summary: "The classes of my gym",
    description: """
    The classes of the gym of one of the viewer's own active memberships starting in `[from, to)` (at most 31
    days), by start time, with the places left and the viewer's own booking. Never another participant.

    #{GymBookingFields.member_access()}
    * `validation_error` - an invalid window, `status`, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [
      @gym_member_id,
      %Parameter{
        name: :from,
        in: :query,
        required: true,
        description: "Window start: an RFC 3339 instant with an offset.",
        schema: %Schema{type: :string, format: :"date-time"}
      },
      %Parameter{
        name: :to,
        in: :query,
        required: true,
        description: "Window end (exclusive), at most 31 days after `from`.",
        schema: %Schema{type: :string, format: :"date-time"}
      },
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only `scheduled` or `cancelled` classes (default: both).",
        schema: %Schema{type: :string, enum: ["scheduled", "cancelled"]}
      },
      @limit,
      @cursor
    ],
    responses: [
      ok: {"The classes", "application/json", Schemas.GymMemberClassList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def classes(conn, %{"gym_member_id" => member_id} = params) do
    with {:ok, page} <- Gyms.list_member_classes(conn.assigns.current_user, member_id, params) do
      conn |> no_store() |> render(:classes, page: page)
    end
  end

  operation :create,
    operation_id: "bookMyGymClass",
    summary: "Book a place in a class",
    description: """
    Books one place for the viewer in a class of the gym of their own active membership, while the class is
    scheduled and has not started and a place is left. The same `client_request_id` again returns that booking
    (`200`), even after it was cancelled, and takes no place. No waitlist exists: a full class is a `409`.
    Creates no training session, relationship, payment or entitlement.

    #{GymBookingFields.member_access()}
    #{GymBookingFields.conflicts()}
    * `validation_error` - a missing, invalid or unknown field.
    * `rate_limited` - 60 bookings and cancellations per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_member_id],
    request_body:
      {"The class", "application/json", Schemas.GymClassBookingRequest, required: true},
    responses: [
      created: @booking,
      ok:
        {"The booking this `client_request_id` already made", "application/json",
         Schemas.MyGymClassBookingResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, %{"gym_member_id" => member_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.book_class(
             conn.assigns.current_user,
             conn.assigns.current_session,
             member_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:booking, booking: view)
    end
  end

  operation :index,
    operation_id: "listMyGymClassBookings",
    summary: "My class bookings",
    description: """
    The viewer's class bookings at every gym, newest first.

    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only `confirmed` or `cancelled` bookings (default: both).",
        schema: %Schema{type: :string, enum: ["confirmed", "cancelled"]}
      },
      @limit,
      @cursor
    ],
    responses: [
      ok: {"The bookings", "application/json", Schemas.MyGymClassBookingList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <- Gyms.list_my_class_bookings(conn.assigns.current_user, params) do
      conn |> no_store() |> render(:bookings, page: page)
    end
  end

  operation :show,
    operation_id: "getMyGymClassBooking",
    summary: "One of my class bookings",
    description: """
    One of the viewer's own bookings.

    * `not_found` - unknown, or not the viewer's.
    """,
    security: @security,
    parameters: [@booking_id],
    responses: [
      ok: @booking,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"booking_id" => id}) do
    with {:ok, view} <- Gyms.get_my_class_booking(conn.assigns.current_user, id) do
      conn |> no_store() |> render(:booking, booking: view)
    end
  end

  operation :cancel,
    operation_id: "cancelMyGymClassBooking",
    summary: "Cancel my class booking",
    description: """
    Cancels one of the viewer's own bookings until its class starts (`member_cancelled`); its place is free
    again. Final: booking again is a new booking. Repeating it returns it unchanged. No penalty or refund exists.

    * `not_found` - unknown, or not the viewer's.
    * `conflict` - `details.class_booking: "checked_in"` (attended) or `"cancelled"` (cancelled otherwise;
      `details.cancel_reason`); `details.class_occurrence: "started"`.
    * `rate_limited` - 60 bookings and cancellations per 10 minutes per user.
    """,
    security: @security,
    parameters: [@booking_id],
    responses: [
      ok: @booking,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"booking_id" => id}) do
    with {:ok, view} <-
           Gyms.cancel_my_class_booking(
             conn.assigns.current_user,
             conn.assigns.current_session,
             id
           ) do
      conn |> no_store() |> render(:booking, booking: view)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
