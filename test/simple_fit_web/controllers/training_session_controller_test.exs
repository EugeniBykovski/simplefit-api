defmodule SimpleFitWeb.TrainingSessionControllerTest do
  @moduledoc """
  Training sessions over HTTP (SF-62; ADR 0023): OpenAPI schemas, status
  codes (201 / 200 replay / 404 / 409 / 422), `no-store`, multi-account
  authorization (IDOR), revoked sessions, the relationship end, and privacy:
  canaries planted in a fighter's private data and in rejected input never
  reach a response or a log.
  """

  # Not async: the sharing gate is global configuration.
  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.TrainingHelpers

  alias SimpleFit.{Accounts, Coaching, Fighters}
  alias SimpleFitWeb.ApiSpec

  @canary "CANARYsf62trn3Wd7Qp1Zk5"
  @coach_path "/api/v1/me/coach/training-sessions"
  @fighter_path "/api/v1/me/training-sessions"

  setup do
    configure_sharing()
    coach = coach_user!("Coach Marek")
    fighter = planted_fighter!()
    %{coach: coach, fighter: fighter, rel: activate!(coach, fighter).id}
  end

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(%Accounts.User{} = user), do: authed(token(user))

  defp authed(token) when is_binary(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp create(user, attrs), do: user |> authed() |> post(@coach_path, Jason.encode!(attrs))

  defp body(conn, status, schema) do
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

  describe "coach operations" do
    test "create answers 201, a replay 200 with the same session", ctx do
      attrs = session_attrs(ctx.rel)

      first = create(ctx.coach, attrs) |> body(201, "CoachTrainingSessionResponse")
      again = create(ctx.coach, attrs) |> body(200, "CoachTrainingSessionResponse")

      assert first["training_session"]["id"] == again["training_session"]["id"]
      session = first["training_session"]
      assert session["status"] == "planned" and session["relationship_id"] == ctx.rel

      assert session["fighter"] == %{
               "display_name" => "Alex K.",
               "username" => session["fighter"]["username"]
             }

      assert session["starts_at"] =~ ~r/Z$/
    end

    test "422 carries field codes and never echoes what was sent", ctx do
      attrs =
        session_attrs(ctx.rel, %{
          "title" => String.duplicate("t", 81) <> @canary,
          "time_zone" => "Mars/#{@canary}",
          "status" => "completed"
        })

      log =
        capture_log([level: :debug], fn ->
          conn = create(ctx.coach, attrs)
          error = error(conn, 422, "validation_error")

          assert error["details"]["field_codes"] == %{
                   "status" => ["invalid"],
                   "time_zone" => ["invalid"],
                   "title" => ["too_long"]
                 }

          refute conn.resp_body =~ @canary
        end)

      refute log =~ @canary
    end

    test "update, cancel and their conflicts", ctx do
      %{"training_session" => %{"id" => id}} =
        create(ctx.coach, session_attrs(ctx.rel)) |> body(201, "CoachTrainingSessionResponse")

      changed =
        ctx.coach
        |> authed()
        |> patch(
          "#{@coach_path}/#{id}",
          Jason.encode!(%{"duration_minutes" => 90, "notes" => nil})
        )
        |> body(200, "CoachTrainingSessionResponse")

      assert %{"duration_minutes" => 90, "notes" => nil} = changed["training_session"]

      ctx.coach
      |> authed()
      |> patch("#{@coach_path}/#{id}", Jason.encode!(%{"status" => "cancelled"}))
      |> error(422, "validation_error")

      cancelled =
        ctx.coach
        |> authed()
        |> post("#{@coach_path}/#{id}/cancel")
        |> body(200, "CoachTrainingSessionResponse")

      assert %{"status" => "cancelled", "cancelled_by" => "coach", "cancel_reason" => nil} =
               cancelled["training_session"]

      ctx.coach
      |> authed()
      |> post("#{@coach_path}/#{id}/cancel")
      |> body(200, "CoachTrainingSessionResponse")

      conflict =
        ctx.coach
        |> authed()
        |> patch("#{@coach_path}/#{id}", Jason.encode!(%{"title" => "Later"}))
        |> error(409, "conflict")

      assert conflict["details"] == %{"status" => "cancelled"}
    end

    test "list and show the coach's sessions with filters", ctx do
      assign!(ctx.coach, ctx.rel)
      assign!(ctx.coach, ctx.rel, %{"training_type" => "pads"})

      page =
        ctx.coach
        |> authed()
        |> get(@coach_path <> "?limit=1")
        |> body(200, "CoachTrainingSessionList")

      assert [%{"id" => id}] = page["training_sessions"]
      assert page["next_cursor"]

      next =
        ctx.coach
        |> authed()
        |> get(@coach_path <> "?limit=1&cursor=" <> page["next_cursor"])
        |> body(200, "CoachTrainingSessionList")

      assert [%{"id" => other}] = next["training_sessions"]
      refute other == id

      ctx.coach
      |> authed()
      |> get("#{@coach_path}/#{id}")
      |> body(200, "CoachTrainingSessionResponse")

      ctx.coach
      |> authed()
      |> get(@coach_path <> "?status=finished")
      |> error(422, "validation_error")
    end
  end

  describe "fighter operations" do
    test "the fighter reads their own sessions with the coach's public identity", ctx do
      session = assign!(ctx.coach, ctx.rel)

      list = ctx.fighter |> authed() |> get(@fighter_path) |> body(200, "MyTrainingSessionList")
      assert [%{"id" => id, "coach" => coach}] = list["training_sessions"]

      assert id == session.id and
               coach == %{"display_name" => "Coach Marek", "brand_name" => "Marek Boxing"}

      ctx.fighter
      |> authed()
      |> get("#{@fighter_path}/#{id}")
      |> body(200, "MyTrainingSessionResponse")
    end

    test "after an end the fighter sees the session cancelled, the coach sees nothing", ctx do
      session = assign!(ctx.coach, ctx.rel)

      ctx.fighter |> authed() |> post("/api/v1/me/coaches/#{ctx.rel}/end") |> response(204)

      mine =
        ctx.fighter
        |> authed()
        |> get("#{@fighter_path}/#{session.id}")
        |> body(200, "MyTrainingSessionResponse")

      assert %{
               "status" => "cancelled",
               "cancelled_by" => "system",
               "cancel_reason" => "relationship_ended",
               "coach" => nil,
               "coach_display_name_at_end" => "Coach Marek"
             } = mine["training_session"]

      ctx.coach |> authed() |> get("#{@coach_path}/#{session.id}") |> error(404, "not_found")

      ctx.coach
      |> authed()
      |> post(@coach_path, Jason.encode!(session_attrs(ctx.rel)))
      |> error(404, "not_found")
    end
  end

  describe "completion (SF-63)" do
    defp started!(coach, rel) do
      session = assign!(coach, rel)

      {1, _} =
        SimpleFit.Repo.update_all(
          from(t in SimpleFit.Training.TrainingSession, where: t.id == ^session.id),
          set: [starts_at: DateTime.add(DateTime.utc_now(), -600, :second)]
        )

      session
    end

    defp complete(user_or_token, id, body \\ %{}),
      do:
        user_or_token |> authed() |> post("#{@fighter_path}/#{id}/complete", Jason.encode!(body))

    test "200 with the server's completion time; a repeat is 200 and unchanged", ctx do
      session = started!(ctx.coach, ctx.rel)

      first = complete(ctx.fighter, session.id) |> body(200, "MyTrainingSessionResponse")
      again = complete(ctx.fighter, session.id) |> body(200, "MyTrainingSessionResponse")

      assert %{"status" => "completed", "completed_at" => at, "cancelled_at" => nil} =
               first["training_session"]

      assert again["training_session"]["completed_at"] == at

      coach_view =
        ctx.coach
        |> authed()
        |> get("#{@coach_path}/#{session.id}")
        |> body(200, "CoachTrainingSessionResponse")

      assert coach_view["training_session"]["completed_at"] == at
    end

    test "409 for a cancelled or not yet started session; 422 for any body field", ctx do
      cancelled = started!(ctx.coach, ctx.rel)
      ctx.coach |> authed() |> post("#{@coach_path}/#{cancelled.id}/cancel") |> json_response(200)

      assert complete(ctx.fighter, cancelled.id) |> error(409, "conflict") |> Map.get("details") ==
               %{"status" => "cancelled"}

      future = assign!(ctx.coach, ctx.rel)

      assert complete(ctx.fighter, future.id) |> error(409, "conflict") |> Map.get("details") ==
               %{"starts_at" => "not_started"}

      started = started!(ctx.coach, ctx.rel)

      conn =
        complete(ctx.fighter, started.id, %{"completed_at" => "2020-01-01T00:00:00Z#{@canary}"})

      assert error(conn, 422, "validation_error")["details"]["field_codes"] == %{
               "completed_at" => ["invalid"]
             }

      refute conn.resp_body =~ @canary
    end

    test "404 for the coach, other users, unknown and malformed ids; 401 without a valid session",
         ctx do
      session = started!(ctx.coach, ctx.rel)

      for user <- [ctx.coach, fighter_user!(), coach_user!("Coach Ola")] do
        complete(user, session.id) |> error(404, "not_found")
      end

      complete(ctx.fighter, Ecto.UUID.generate()) |> error(404, "not_found")
      complete(ctx.fighter, "not-a-uuid") |> error(404, "not_found")

      bearer = token(ctx.fighter)
      _ = Accounts.revoke_session({:access, bearer})
      complete(bearer, session.id) |> error(401, "unauthorized")

      build_conn()
      |> post("#{@fighter_path}/#{session.id}/complete")
      |> error(401, "unauthorized")
    end

    test "view=upcoming and view=history on both lists", ctx do
      done = started!(ctx.coach, ctx.rel)
      complete(ctx.fighter, done.id) |> json_response(200)
      upcoming = assign!(ctx.coach, ctx.rel)

      for {path, schema} <- [
            {@fighter_path, "MyTrainingSessionList"},
            {@coach_path, "CoachTrainingSessionList"}
          ],
          user = if(path == @fighter_path, do: ctx.fighter, else: ctx.coach) do
        up = user |> authed() |> get(path <> "?view=upcoming") |> body(200, schema)
        assert Enum.map(up["training_sessions"], & &1["id"]) == [upcoming.id]
        hist = user |> authed() |> get(path <> "?view=history") |> body(200, schema)
        assert Enum.map(hist["training_sessions"], & &1["id"]) == [done.id]
        user |> authed() |> get(path <> "?view=everything") |> error(422, "validation_error")
      end
    end
  end

  describe "authorization" do
    test "foreign coaches and fighters, malformed ids and the dual-role user get 404", ctx do
      session = assign!(ctx.coach, ctx.rel)
      other_coach = coach_user!("Coach Ola")
      other_fighter = fighter_user!()

      for {user, method, path} <- [
            {other_coach, :get, "#{@coach_path}/#{session.id}"},
            {other_coach, :post, "#{@coach_path}/#{session.id}/cancel"},
            {other_coach, :patch, "#{@coach_path}/#{session.id}"},
            {ctx.fighter, :get, "#{@coach_path}/#{session.id}"},
            {ctx.fighter, :post, "#{@coach_path}/#{session.id}/cancel"},
            {other_fighter, :get, "#{@fighter_path}/#{session.id}"},
            {ctx.coach, :get, "#{@fighter_path}/#{session.id}"},
            {ctx.coach, :get, "#{@coach_path}/not-a-uuid"}
          ] do
        user |> authed() |> dispatch(@endpoint, method, path, "{}") |> error(404, "not_found")
      end

      other_coach |> create(session_attrs(ctx.rel)) |> error(404, "not_found")
    end

    test "a revoked or missing session is 401", ctx do
      bearer = token(ctx.coach)
      _ = Accounts.revoke_session({:access, bearer})

      bearer |> authed() |> get(@coach_path) |> error(401, "unauthorized")
      build_conn() |> get(@fighter_path) |> error(401, "unauthorized")
    end

    test "while sharing is off the coach side is 404 and the fighter still reads", ctx do
      session = assign!(ctx.coach, ctx.rel)
      set_sharing(enabled: false)

      ctx.coach |> authed() |> get(@coach_path) |> error(404, "not_found")

      ctx.coach
      |> authed()
      |> post("#{@coach_path}/#{session.id}/cancel")
      |> error(404, "not_found")

      ctx.fighter |> authed() |> get(@fighter_path) |> body(200, "MyTrainingSessionList")
    end
  end

  test "no private fighter data in any coach response or log", ctx do
    log =
      capture_log([level: :debug], fn ->
        %{"training_session" => %{"id" => id}} =
          create(ctx.coach, session_attrs(ctx.rel)) |> body(201, "CoachTrainingSessionResponse")

        for path <- [@coach_path, "#{@coach_path}/#{id}"] do
          conn = ctx.coach |> authed() |> get(path)
          refute conn.resp_body =~ @canary
          refute conn.resp_body =~ String.downcase(@canary)
          refute conn.resp_body =~ "66.6"
        end

        _ = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)
      end)

    refute log =~ @canary
    refute log =~ String.downcase(@canary)
  end
end
