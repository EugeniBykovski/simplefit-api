defmodule SimpleFitWeb.GymTimetableControllerTest do
  @moduledoc """
  The gym timetable over HTTP (SF-97), with real sessions: every venue,
  template, series and class operation, checked against the OpenAPI
  schemas, `no-store`, and 200 / 201 / 401 / 403 / 404 / 409 / 422. The
  clock is frozen (SF-62).
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers
  import SimpleFit.TimetableHelpers, only: [location_id: 1]

  alias SimpleFit.{Accounts, Clock}
  alias SimpleFitWeb.ApiSpec

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

  defp gym_path(gym_id, suffix), do: "/api/v1/gyms/#{gym_id}#{suffix}"
  defp body(map), do: Jason.encode!(map)

  setup do
    Clock.freeze(@now)
    SimpleFit.Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("tt-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, token: token(owner)}
  end

  test "venues, templates, a one-time class and a weekly series end to end", ctx do
    venue_attrs = %{
      client_request_id: Ecto.UUID.generate(),
      gym_location_id: location_id(ctx.gym.id),
      name: "Main Hall",
      capacity: 20,
      time_zone: "Europe/Warsaw"
    }

    venue =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/venues"), body(venue_attrs))
      |> ok("GymVenueResponse", 201)

    venue_id = venue["venue"]["venue_id"]
    # A retry with the same key: 200, the same venue.
    assert ctx.token
           |> authed()
           |> post(gym_path(ctx.gym.id, "/venues"), body(venue_attrs))
           |> ok("GymVenueResponse", 200) == venue

    ctx.token |> authed() |> get(gym_path(ctx.gym.id, "/venues")) |> ok("GymVenueList")

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/venues/#{venue_id}"))
    |> ok("GymVenueResponse")

    ctx.token
    |> authed()
    |> patch(
      gym_path(ctx.gym.id, "/venues/#{venue_id}"),
      body(%{expected_revision: 1, description: "Upstairs"})
    )
    |> ok("GymVenueResponse")

    ctx.token
    |> authed()
    |> patch(
      gym_path(ctx.gym.id, "/venues/#{venue_id}"),
      body(%{expected_revision: 1, name: "X"})
    )
    |> error(409, "conflict")

    ctx.token
    |> authed()
    |> post(
      gym_path(ctx.gym.id, "/venues"),
      body(%{venue_attrs | client_request_id: Ecto.UUID.generate(), time_zone: "+01:00"})
    )
    |> error(422, "validation_error")

    template =
      ctx.token
      |> authed()
      |> post(
        gym_path(ctx.gym.id, "/class-templates"),
        body(%{
          client_request_id: Ecto.UUID.generate(),
          title: "Boxing Fundamentals",
          default_duration_minutes: 90,
          default_capacity: 16,
          default_venue_id: venue_id
        })
      )
      |> ok("GymClassTemplateResponse", 201)

    template_id = template["template"]["template_id"]

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/class-templates"))
    |> ok("GymClassTemplateList")

    ctx.token
    |> authed()
    |> patch(
      gym_path(ctx.gym.id, "/class-templates/#{template_id}"),
      body(%{expected_revision: 1, description: "Basics"})
    )
    |> ok("GymClassTemplateResponse")

    class =
      ctx.token
      |> authed()
      |> post(
        gym_path(ctx.gym.id, "/class-occurrences"),
        body(%{
          client_request_id: Ecto.UUID.generate(),
          template_id: template_id,
          starts_at: "2026-01-10T10:00:00+01:00"
        })
      )
      |> ok("GymClassOccurrenceResponse", 201)

    assert class["occurrence"]["starts_at"] == "2026-01-10T09:00:00.000000Z"
    assert class["occurrence"]["local_starts_at"] == "2026-01-10T10:00:00"
    assert class["occurrence"]["utc_offset_minutes"] == 60
    assert class["occurrence"]["ends_at"] == "2026-01-10T10:30:00.000000Z"
    refute Map.has_key?(class["occurrence"], "booked")
    class_id = class["occurrence"]["occurrence_id"]

    ctx.token
    |> authed()
    |> post(
      gym_path(ctx.gym.id, "/class-occurrences"),
      body(%{
        client_request_id: Ecto.UUID.generate(),
        template_id: template_id,
        starts_at: "2026-01-10T11:00:00+01:00"
      })
    )
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"schedule" => "venue_unavailable"}))

    moved =
      ctx.token
      |> authed()
      |> patch(
        gym_path(ctx.gym.id, "/class-occurrences/#{class_id}"),
        body(%{expected_revision: 1, starts_at: "2026-01-10T12:00:00+01:00"})
      )
      |> ok("GymClassOccurrenceResponse")

    assert moved["occurrence"]["revision"] == 2

    series =
      ctx.token
      |> authed()
      |> post(
        gym_path(ctx.gym.id, "/class-series"),
        body(%{
          client_request_id: Ecto.UUID.generate(),
          template_id: template_id,
          weekdays: [1, 3, 5],
          local_start_time: "18:00",
          starts_on: "2026-01-05",
          ends_on: "2026-04-30"
        })
      )
      |> ok("GymClassSeriesResponse", 201)

    series_id = series["series"]["series_id"]
    assert series["series"]["skipped_dates"] == []

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/class-series"))
    |> ok("GymClassSeriesList")

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/class-series/#{series_id}"))
    |> ok("GymClassSeriesResponse")

    generated =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/class-series/#{series_id}/generate"))
      |> ok("GymClassSeriesGenerateResponse")

    assert generated["created_count"] == 0

    page =
      ctx.token
      |> authed()
      |> get(
        gym_path(
          ctx.gym.id,
          "/class-occurrences?from=2026-03-23T00:00:00Z&to=2026-04-06T00:00:00Z&limit=100"
        )
      )
      |> ok("GymClassOccurrenceList")

    # 18:00 Warsaw before and after 29 March.
    starts = Map.new(page["occurrences"], &{&1["series_local_date"], &1["starts_at"]})
    assert starts["2026-03-27"] == "2026-03-27T17:00:00.000000Z"
    assert starts["2026-03-30"] == "2026-03-30T16:00:00.000000Z"

    ctx.token
    |> authed()
    |> patch(
      gym_path(ctx.gym.id, "/class-series/#{series_id}"),
      body(%{expected_revision: 1, weekdays: [1, 3]})
    )
    |> ok("GymClassSeriesResponse")

    ctx.token
    |> authed()
    |> post(
      gym_path(ctx.gym.id, "/class-occurrences/#{class_id}/cancel"),
      body(%{expected_revision: 2})
    )
    |> ok("GymClassOccurrenceResponse")
    |> then(&assert(&1["occurrence"]["status"] == "cancelled"))

    ctx.token
    |> authed()
    |> post(
      gym_path(ctx.gym.id, "/class-series/#{series_id}/cancel"),
      body(%{expected_revision: 2})
    )
    |> ok("GymClassSeriesResponse")
    |> then(&assert(&1["series"]["status"] == "cancelled"))

    ctx.token
    |> authed()
    |> post(
      gym_path(ctx.gym.id, "/class-templates/#{template_id}/archive"),
      body(%{expected_revision: 2})
    )
    |> ok("GymClassTemplateResponse")

    ctx.token
    |> authed()
    |> post(gym_path(ctx.gym.id, "/venues/#{venue_id}/deactivate"), body(%{expected_revision: 2}))
    |> ok("GymVenueResponse")
  end

  test "401, 403 for roles that may not write, 404 for strangers and other gyms' ids", ctx do
    {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")
    stranger = registered!("tt-stranger")
    desk_token = token(desk)

    build_conn() |> get(gym_path(ctx.gym.id, "/venues")) |> error(401, "unauthorized")

    desk_token |> authed() |> get(gym_path(ctx.gym.id, "/venues")) |> ok("GymVenueList")

    desk_token
    |> authed()
    |> post(gym_path(ctx.gym.id, "/venues"), body(%{}))
    |> error(403, "forbidden")

    for suffix <- [
          "/venues",
          "/class-templates",
          "/class-series",
          "/class-occurrences?from=2026-01-05T00:00:00Z&to=2026-01-06T00:00:00Z"
        ] do
      token(stranger) |> authed() |> get(gym_path(ctx.gym.id, suffix)) |> error(404, "not_found")
    end

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/venues/#{Ecto.UUID.generate()}"))
    |> error(404, "not_found")

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/class-occurrences/not-a-uuid"))
    |> error(404, "not_found")

    ctx.token
    |> authed()
    |> get(
      gym_path(ctx.gym.id, "/class-occurrences?from=2026-01-01T00:00:00Z&to=2026-03-01T00:00:00Z")
    )
    |> error(422, "validation_error")
  end
end
