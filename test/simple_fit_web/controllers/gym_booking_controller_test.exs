defmodule SimpleFitWeb.GymBookingControllerTest do
  @moduledoc """
  Gym class bookings over HTTP (SF-99), with real sessions: the member's
  classes, booking, their bookings and cancellation; the staff roster,
  booking for a member, cancelling and check-in; every response checked
  against the OpenAPI schemas, `no-store`, and 200 / 201 / 401 / 403 / 404 /
  409 / 422. The clock is frozen (SF-62).
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Clock}
  alias SimpleFitWeb.ApiSpec

  # Monday 5 January 2026, 13:00 in Warsaw; the class is today at 19:00.
  @now ~U[2026-01-05 12:00:00Z]

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp ok(conn, schema, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp body(map), do: Jason.encode!(map)

  setup do
    Clock.freeze(@now)
    SimpleFit.Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("bk-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    class = class!(owner, gym.id, "2026-01-05T19:00:00+01:00", 1)
    {marta, member} = member!(owner, gym.id, "Marta Kowalska")
    %{owner: owner, gym: gym, class: class, marta: marta, member: member}
  end

  test "a member lists the classes, books, reads, replays and cancels over HTTP", ctx do
    member_token = token(ctx.marta)
    base = "/api/v1/me/gym-memberships/#{ctx.member.gym_member_id}"

    classes =
      member_token
      |> authed()
      |> get(base <> "/classes?from=2026-01-05T00:00:00Z&to=2026-01-12T00:00:00Z")
      |> ok("GymMemberClassList")

    assert [
             %{
               "remaining_capacity" => 1,
               "booking" => nil,
               "local_starts_at" => "2026-01-05T19:00:00"
             }
           ] =
             classes["classes"]

    request = %{
      occurrence_id: ctx.class.occurrence_id,
      client_request_id: Ecto.UUID.generate()
    }

    booked =
      member_token
      |> authed()
      |> post(base <> "/class-bookings", body(request))
      |> ok("MyGymClassBookingResponse", 201)

    assert %{"status" => "confirmed", "availability" => %{"remaining_capacity" => 0}} =
             booked["booking"]

    booking_id = booked["booking"]["booking_id"]

    # The same key: 200 and the same booking.
    assert member_token
           |> authed()
           |> post(base <> "/class-bookings", body(request))
           |> ok("MyGymClassBookingResponse")
           |> get_in(["booking", "booking_id"]) == booking_id

    member_token |> authed() |> get("/api/v1/me/class-bookings") |> ok("MyGymClassBookingList")

    member_token
    |> authed()
    |> get("/api/v1/me/class-bookings/#{booking_id}")
    |> ok("MyGymClassBookingResponse")

    # Full for someone else.
    {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")

    piotr
    |> token()
    |> authed()
    |> post(
      "/api/v1/me/gym-memberships/#{piotr_member.gym_member_id}/class-bookings",
      body(%{occurrence_id: ctx.class.occurrence_id, client_request_id: Ecto.UUID.generate()})
    )
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"class_occurrence" => "full", "capacity" => 1}))

    # Someone else's booking is not found.
    piotr
    |> token()
    |> authed()
    |> get("/api/v1/me/class-bookings/#{booking_id}")
    |> error(404, "not_found")

    cancelled =
      member_token
      |> authed()
      |> post("/api/v1/me/class-bookings/#{booking_id}/cancel")
      |> ok("MyGymClassBookingResponse")

    assert cancelled["booking"]["cancel_reason"] == "member_cancelled"

    member_token
    |> authed()
    |> post(base <> "/class-bookings", body(%{occurrence_id: ctx.class.occurrence_id}))
    |> error(422, "validation_error")

    build_conn() |> get("/api/v1/me/class-bookings") |> error(401, "unauthorized")
  end

  test "staff read the roster, book for a member, cancel and check in; roles are enforced", ctx do
    {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")
    {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Tomasz Zieliński")
    desk_token = token(desk)
    path = "/api/v1/gyms/#{ctx.gym.id}/class-occurrences/#{ctx.class.occurrence_id}/bookings"

    booked =
      desk_token
      |> authed()
      |> post(
        path,
        body(%{gym_member_id: ctx.member.gym_member_id, client_request_id: Ecto.UUID.generate()})
      )
      |> ok("GymClassBookingResponse", 201)

    assert %{"booked_via" => "staff", "name" => "Marta K."} = booked["booking"]
    booking_id = booked["booking"]["booking_id"]

    roster = desk_token |> authed() |> get(path) |> ok("GymClassRoster")

    assert roster["summary"] == %{
             "capacity" => 1,
             "confirmed_count" => 1,
             "remaining_capacity" => 0,
             "checked_in_count" => 0
           }

    refute Jason.encode!(roster) =~ "@"

    coach |> token() |> authed() |> get(path) |> error(403, "forbidden")

    coach
    |> token()
    |> authed()
    |> post(
      path,
      body(%{gym_member_id: ctx.member.gym_member_id, client_request_id: Ecto.UUID.generate()})
    )
    |> error(403, "forbidden")

    checked =
      coach
      |> token()
      |> authed()
      |> post("/api/v1/gyms/#{ctx.gym.id}/class-bookings/#{booking_id}/check-in")
      |> ok("GymClassCheckInResponse", 201)

    assert checked["check_in"]["method"] == "manual"

    desk_token
    |> authed()
    |> post("/api/v1/gyms/#{ctx.gym.id}/class-bookings/#{booking_id}/check-in")
    |> ok("GymClassCheckInResponse", 200)

    desk_token
    |> authed()
    |> post("/api/v1/gyms/#{ctx.gym.id}/class-bookings/#{booking_id}/cancel")
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"class_booking" => "checked_in"}))

    stranger = registered!("bk-http-stranger")

    stranger |> token() |> authed() |> get(path) |> error(404, "not_found")

    desk_token
    |> authed()
    |> post("/api/v1/gyms/#{ctx.gym.id}/class-bookings/#{Ecto.UUID.generate()}/cancel")
    |> error(404, "not_found")
  end
end
