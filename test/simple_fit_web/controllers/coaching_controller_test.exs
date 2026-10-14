defmodule SimpleFitWeb.CoachingControllerTest do
  @moduledoc """
  Coach–Fighter relationship endpoints over HTTP (ADR 0021): OpenAPI
  schemas, multi-account authorization (IDOR), the sharing gate, the absence
  of any create operation, and privacy: fighter data planted with canaries
  (email, account name, date of birth, body data, goals, next fight) never
  reaches a coach response.
  """

  # Not async: the sharing gate is global configuration.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers

  alias SimpleFit.{Accounts, Coaching, Fighters}
  alias SimpleFitWeb.ApiSpec

  @canary "CANARYsf56rel7Qm2Xv9Kp4Wd8"

  setup do
    configure_sharing()
    :ok
  end

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(user), do: build_conn() |> put_req_header("authorization", "Bearer " <> token(user))

  defp roster(user, query \\ ""),
    do: user |> authed() |> get("/api/v1/me/coach/fighters" <> query)

  defp detail(user, id), do: user |> authed() |> get("/api/v1/me/coach/fighters/#{id}")
  defp coach_end(user, id), do: user |> authed() |> post("/api/v1/me/coach/fighters/#{id}/end")
  defp my_coaches(user, query \\ ""), do: user |> authed() |> get("/api/v1/me/coaches" <> query)
  defp fighter_end(user, id), do: user |> authed() |> post("/api/v1/me/coaches/#{id}/end")

  defp body(conn, status, schema) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp not_found!(conn) do
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  # A fighter whose private data carries canaries everywhere a coach must not look.
  defp planted_fighter! do
    {:ok, user} = Accounts.register_user(:email, "#{String.downcase(@canary)}@example.com")

    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Legal #{@canary} Name",
        "date_of_birth" => "1991-07-23",
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, _} = Accounts.complete_account_registration(user)

    {:ok, _} =
      Fighters.update_profile(user, %{
        "display_name" => "Alex K.",
        "username" => "alex_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "competitive_amateur",
        "amateur_bout_count" => 14,
        "stance" => "southpaw",
        "goals" => ["competition"],
        "next_fight_on" => "2027-03-14",
        "next_fight_name" => "Fight #{@canary} Night",
        "weight_class" => "minus_67",
        "current_weight_kg" => "66.6",
        "height_cm" => 177
      })

    {:ok, _} = Fighters.complete_onboarding(user)
    user
  end

  # Planted private values, compared as decoded JSON values (substring checks
  # of short numbers could match ids or timestamps).
  @private_values [177, 66.6, "66.6", "1991-07-23", "2027-03-14", "minus_67", "competition"]
  @private_keys ~w(goals next_fight_on next_fight_name weight_class current_weight_kg height_cm
                   full_name date_of_birth email user_id fighter_profile_id coach_profile_id
                   consents identities)

  defp refute_private!(raw) do
    refute raw =~ @canary
    refute raw =~ String.downcase(@canary)

    {keys, values} = leaves(Jason.decode!(raw))

    for key <- @private_keys, do: refute(key in keys, "a coach response has the key #{key}")

    for value <- @private_values,
        do: refute(value in values, "a coach response contains #{inspect(value)}")
  end

  defp leaves(map) when is_map(map) do
    Enum.reduce(map, {[], []}, fn {k, v}, {keys, values} ->
      {more_keys, more_values} = leaves(v)
      {[k | keys] ++ more_keys, values ++ more_values}
    end)
  end

  defp leaves(list) when is_list(list) do
    Enum.reduce(list, {[], []}, fn v, {keys, values} ->
      {more_keys, more_values} = leaves(v)
      {keys ++ more_keys, values ++ more_values}
    end)
  end

  defp leaves(value), do: {[], [value]}

  describe "coach roster and detail" do
    setup do
      coach = coach_user!()
      fighter = planted_fighter!()
      %{coach: coach, fighter: fighter, r: activate!(coach, fighter)}
    end

    test "shows only the disclosed C1 + C2 fields, never planted private data", %{
      coach: c,
      r: r
    } do
      conn = roster(c)
      list = body(conn, 200, "CoachFighterRelationshipList")
      assert [entry] = list["relationships"]
      assert list["next_cursor"] == nil
      assert entry["relationship_id"] == r.id
      assert entry["status"] == "active"
      assert entry["disclosure_version"] == version()

      assert entry["fighter"] == %{
               "display_name" => "Alex K.",
               "username" => entry["fighter"]["username"],
               "country_code" => "PL",
               "city" => "Warsaw",
               "experience_level" => "competitive_amateur",
               "stance" => "southpaw",
               "amateur_bout_count" => 14
             }

      refute_private!(conn.resp_body)

      conn = detail(c, r.id)

      assert %{"relationship" => %{"relationship_id" => id}} =
               body(conn, 200, "CoachFighterRelationshipResponse")

      assert id == r.id
      refute_private!(conn.resp_body)
    end

    test "the canaries are really planted: the owner's own profile trips the detector", %{
      fighter: f
    } do
      raw = f |> authed() |> get("/api/v1/me/fighter-profile") |> response(200)
      assert_raise ExUnit.AssertionError, fn -> refute_private!(raw) end
    end

    test "after the end: no detail, and the stub carries only the name snapshot", %{
      coach: c,
      fighter: f,
      r: r
    } do
      assert response(fighter_end(f, r.id), 204) == ""

      not_found!(detail(c, r.id))
      assert %{"relationships" => []} = body(roster(c), 200, "CoachFighterRelationshipList")

      conn = roster(c, "?status=ended")
      assert %{"relationships" => [stub]} = body(conn, 200, "CoachFighterRelationshipList")

      assert stub == %{
               "relationship_id" => r.id,
               "status" => "ended",
               "started_at" => stub["started_at"],
               "ended_at" => stub["ended_at"],
               "ended_by" => "fighter",
               "disclosure_version" => nil,
               "disclosed_fields" => [],
               "fighter" => nil,
               "fighter_display_name_at_end" => "Alex K."
             }

      refute_private!(conn.resp_body)
    end

    test "another coach, a fighter and a user without profiles cannot reach it", %{r: r} do
      other_coach = coach_user!("Other")

      for user <- [other_coach, fighter_user!(), registered_user!()] do
        not_found!(detail(user, r.id))
        not_found!(coach_end(user, r.id))
      end

      # Another coach has a roster of their own, which is empty.
      assert %{"relationships" => []} =
               body(roster(other_coach), 200, "CoachFighterRelationshipList")

      # Users without a completed coach profile have no roster at all.
      not_found!(roster(fighter_user!()))
      not_found!(roster(registered_user!()))
    end

    test "ids are opaque: malformed, unknown and foreign ids answer the same 404", %{coach: c} do
      foreign = activate!(coach_user!("Other"), fighter_user!())
      without_request_id = &update_in(&1, ["error"], fn e -> Map.delete(e, "request_id") end)
      expected = c |> detail(Ecto.UUID.generate()) |> json_response(404) |> without_request_id.()

      for id <- [Ecto.UUID.generate(), "1", "%27%20OR%201%3D1", foreign.id] do
        assert c |> detail(id) |> json_response(404) |> without_request_id.() == expected
        assert c |> coach_end(id) |> json_response(404) |> without_request_id.() == expected
      end
    end
  end

  describe "observability" do
    test "the real flow logs no personal data; telemetry carries outcomes only" do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      parent = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        [
          [:simple_fit, :coaching, :relationship, :activated],
          [:simple_fit, :coaching, :relationship, :ended]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      coach = coach_user!("Coach #{@canary}")
      fighter = planted_fighter!()

      log =
        capture_log([level: :debug], fn ->
          r = activate!(coach, fighter)
          roster(coach)
          detail(coach, r.id)
          my_coaches(fighter)
          coach_end(coach, r.id)
          roster(coach, "?status=ended")
          my_coaches(fighter, "?status=ended")
        end)

      refute log =~ @canary
      refute log =~ String.downcase(@canary)
      refute log =~ "Alex K."

      assert_received {:event, [:simple_fit, :coaching, :relationship, :activated], %{count: 1},
                       %{outcome: :created} = activated}

      assert map_size(activated) == 1

      assert_received {:event, [:simple_fit, :coaching, :relationship, :ended], %{count: 1},
                       %{ended_by: :coach} = ended}

      assert map_size(ended) == 1
    end
  end

  describe "the sharing gate" do
    test "off: coach reads answer 404; ending and the fighter's own list still work" do
      coach = coach_user!()
      fighter = fighter_user!()
      r = activate!(coach, fighter)
      set_sharing(enabled: false)

      not_found!(roster(coach))
      not_found!(roster(coach, "?status=ended"))
      not_found!(detail(coach, r.id))

      assert [_] = body(my_coaches(fighter), 200, "MyCoachRelationshipList")["relationships"]
      assert response(coach_end(coach, r.id), 204) == ""
      assert response(fighter_end(fighter, r.id), 204) == ""

      set_sharing(enabled: true)
      not_found!(detail(coach, r.id))
    end
  end

  describe "fighter side" do
    test "lists own coaches with their public identity; ends one; idempotent" do
      coach = coach_user!("Coach Marek")
      fighter = fighter_user!()
      r = activate!(coach, fighter)

      list = body(my_coaches(fighter), 200, "MyCoachRelationshipList")

      assert [
               %{
                 "relationship_id" => id,
                 "coach" => %{"display_name" => "Coach Marek", "brand_name" => "Marek Boxing"},
                 "coach_display_name_at_end" => nil
               }
             ] = list["relationships"]

      assert id == r.id

      assert response(fighter_end(fighter, r.id), 204) == ""
      assert response(fighter_end(fighter, r.id), 204) == ""

      ended = body(my_coaches(fighter, "?status=ended"), 200, "MyCoachRelationshipList")

      assert [
               %{
                 "coach" => nil,
                 "coach_display_name_at_end" => "Coach Marek",
                 "ended_by" => "fighter"
               }
             ] =
               ended["relationships"]
    end

    test "a fighter cannot see or end another fighter's relationship" do
      coach = coach_user!()
      r = activate!(coach, fighter_user!())
      other = fighter_user!()

      assert %{"relationships" => []} = body(my_coaches(other), 200, "MyCoachRelationshipList")
      not_found!(fighter_end(other, r.id))
      not_found!(fighter_end(coach, r.id))
    end

    test "requires a completed fighter profile" do
      not_found!(my_coaches(coach_user!()))
      not_found!(my_coaches(registered_user!()))
    end
  end

  describe "contract" do
    test "every endpoint requires authentication" do
      id = Ecto.UUID.generate()

      for {method, path} <- [
            {:get, "/api/v1/me/coach/fighters"},
            {:get, "/api/v1/me/coach/fighters/#{id}"},
            {:post, "/api/v1/me/coach/fighters/#{id}/end"},
            {:get, "/api/v1/me/coaches"},
            {:post, "/api/v1/me/coaches/#{id}/end"}
          ] do
        conn = dispatch(build_conn(), @endpoint, method, path, nil)
        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      end
    end

    test "no operation creates, edits or reactivates a relationship" do
      coach = coach_user!()
      fighter = fighter_user!()
      r = activate!(coach, fighter)
      body = %{"coach_profile_id" => "x", "fighter_profile_id" => "y", "status" => "active"}

      for {method, path} <- [
            {:post, "/api/v1/me/coach/fighters"},
            {:post, "/api/v1/me/coaches"},
            {:put, "/api/v1/me/coach/fighters/#{r.id}"},
            {:patch, "/api/v1/me/coach/fighters/#{r.id}"},
            {:patch, "/api/v1/me/coaches/#{r.id}"},
            {:post, "/api/v1/me/coach/fighters/#{r.id}/reactivate"},
            {:post, "/api/v1/coaching/relationships"}
          ] do
        conn =
          coach
          |> authed()
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, path, Jason.encode!(body))

        assert conn.status == 404, "#{method} #{path} answered #{conn.status}"
      end

      ops =
        ApiSpec.spec().paths
        |> Enum.filter(fn {path, _} ->
          path =~ ~r{/me/coach(es)?/} or path =~ "coach/fighters"
        end)
        |> Enum.flat_map(fn {_path, item} ->
          for verb <- [:post, :put, :patch, :delete], op = Map.get(item, verb), do: op.operationId
        end)
        |> Enum.sort()

      assert ops == ["endMyCoachFighterRelationship", "endMyCoachRelationship"]
    end

    test "invalid list parameters are a validation error naming the field" do
      coach = coach_user!()

      for {query, field} <- [
            {"?status=pending", "status"},
            {"?limit=0", "limit"},
            {"?limit=abc", "limit"},
            {"?cursor=#{@canary}", "cursor"}
          ] do
        conn = roster(coach, query)
        body = json_response(conn, 422)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
        assert body["error"]["code"] == "validation_error"
        assert Map.has_key?(body["error"]["details"]["fields"], field)
        refute conn.resp_body =~ @canary
      end
    end
  end
end
