defmodule SimpleFitWeb.GymFirstRunControllerTest do
  @moduledoc """
  The gym first run over HTTP (SF-90): `getGymFirstRun`, `startGymFirstRun`,
  `completeGymFirstRun` and `dismissGymFirstRun`. OpenAPI schemas,
  `no-store`, and 200 / 401 / 403 / 404 / 409 / 422.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp first_run(conn, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, "GymFirstRunResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["first_run"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp fr_path(gym_id, suffix \\ ""), do: "/api/v1/gyms/#{gym_id}/first-run#{suffix}"

  defp post_action(conn, gym_id, action, body \\ nil)
  defp post_action(conn, gym_id, action, nil), do: post(conn, fr_path(gym_id, "/#{action}"))

  defp post_action(conn, gym_id, action, body),
    do: post(conn, fr_path(gym_id, "/#{action}"), Jason.encode!(body))

  setup do
    owner = registered!("first-run-http")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, token: token(owner)}
  end

  test "the owner's journey: read, start (twice), complete (twice), then conflicts", ctx do
    initial = ctx.token |> authed() |> get(fr_path(ctx.gym.id)) |> first_run()

    assert initial == %{
             "gym_id" => ctx.gym.id,
             "status" => "not_started",
             "started_at" => nil,
             "completed_at" => nil,
             "dismissed_at" => nil,
             "checklist" => [
               %{"key" => "create_gym", "status" => "completed"},
               %{"key" => "add_class", "status" => "coming_later"},
               %{"key" => "invite_staff", "status" => "coming_later"},
               %{"key" => "invite_members", "status" => "coming_later"},
               %{"key" => "first_check_in", "status" => "coming_later"}
             ]
           }

    started = ctx.token |> authed() |> post_action(ctx.gym.id, "start") |> first_run()
    assert %{"status" => "in_progress", "started_at" => at} = started
    assert is_binary(at)

    # Another device (a new session) resumes the same state.
    other = token(ctx.owner)
    assert ^started = other |> authed() |> post_action(ctx.gym.id, "start", %{}) |> first_run()
    assert ^started = other |> authed() |> get(fr_path(ctx.gym.id)) |> first_run()

    completed = other |> authed() |> post_action(ctx.gym.id, "complete") |> first_run()
    assert %{"status" => "completed", "started_at" => ^at, "dismissed_at" => nil} = completed
    assert completed["checklist"] == initial["checklist"]

    assert ^completed =
             ctx.token |> authed() |> post_action(ctx.gym.id, "complete") |> first_run()

    for action <- ["start", "dismiss"] do
      error = ctx.token |> authed() |> post_action(ctx.gym.id, action) |> error(409, "conflict")
      assert error["details"] == %{"first_run" => "completed"}
    end
  end

  test "skip: dismissed and final, the checklist unchanged", ctx do
    dismissed = ctx.token |> authed() |> post_action(ctx.gym.id, "dismiss") |> first_run()
    assert %{"status" => "dismissed", "started_at" => nil, "completed_at" => nil} = dismissed
    assert Enum.at(dismissed["checklist"], 0) == %{"key" => "create_gym", "status" => "completed"}
    assert dismissed["checklist"] |> Enum.drop(1) |> Enum.all?(&(&1["status"] == "coming_later"))

    assert ^dismissed = ctx.token |> authed() |> post_action(ctx.gym.id, "dismiss") |> first_run()

    error = ctx.token |> authed() |> post_action(ctx.gym.id, "complete") |> error(409, "conflict")
    assert error["details"] == %{"first_run" => "dismissed"}
  end

  test "a draft: unavailable to read, every transition 409 setup_status draft" do
    owner = registered!("first-run-http-draft")
    draft = draft_gym!(owner)
    token = token(owner)

    assert %{"status" => "unavailable", "checklist" => [%{"status" => "available"} | _]} =
             token |> authed() |> get(fr_path(draft.id)) |> first_run()

    for action <- ["start", "complete", "dismiss"] do
      error = token |> authed() |> post_action(draft.id, action) |> error(409, "conflict")
      assert error["details"] == %{"setup_status" => "draft"}
    end
  end

  test "422 for any body field: forged user_id, gym_id, checklist flags", ctx do
    intruder = registered!("first-run-http-intruder")

    for body <- [
          %{"user_id" => intruder.id},
          %{"gym_id" => Ecto.UUID.generate()},
          %{"checklist" => [%{"key" => "invite_staff", "status" => "completed"}]},
          %{"completed_at" => "2026-01-01T00:00:00Z"}
        ] do
      error =
        ctx.token
        |> authed()
        |> post_action(ctx.gym.id, "complete", body)
        |> error(422, "validation_error")

      [key] = Map.keys(body)
      assert error["details"]["fields"] == %{key => ["is not accepted"]}
    end

    assert %{"status" => "not_started"} =
             ctx.token |> authed() |> get(fr_path(ctx.gym.id)) |> first_run()
  end

  test "403 for staff who are not the owner, with nothing recorded", ctx do
    for role <- [:manager, :coach, :front_desk] do
      staff = registered!("first-run-http-#{role}")
      staff!(ctx.gym.id, staff, role)
      token = token(staff)

      token |> authed() |> get(fr_path(ctx.gym.id)) |> error(403, "forbidden")

      for action <- ["start", "complete", "dismiss"] do
        token |> authed() |> post_action(ctx.gym.id, action) |> error(403, "forbidden")
      end
    end

    assert %{"status" => "not_started"} =
             ctx.token |> authed() |> get(fr_path(ctx.gym.id)) |> first_run()
  end

  test "404 for a foreign, unknown or malformed gym, identical bodies", ctx do
    outsider = token(registered!("first-run-http-outsider"))

    bodies =
      for id <- [ctx.gym.id, Ecto.UUID.generate(), "not-a-uuid"] do
        get_body = outsider |> authed() |> get(fr_path(id)) |> error(404, "not_found")
        post_body = outsider |> authed() |> post_action(id, "complete") |> error(404, "not_found")
        assert Map.delete(get_body, "request_id") == Map.delete(post_body, "request_id")
        Map.delete(get_body, "request_id")
      end

    assert bodies |> Enum.uniq() |> length() == 1
  end

  test "401 without, with an invalid, or with a revoked session", ctx do
    build_conn() |> get(fr_path(ctx.gym.id)) |> error(401, "unauthorized")
    build_conn() |> post(fr_path(ctx.gym.id, "/complete")) |> error(401, "unauthorized")
    "not-a-token" |> authed() |> post_action(ctx.gym.id, "start") |> error(401, "unauthorized")

    {:ok, credentials} = Accounts.create_session(ctx.owner)
    :ok = Accounts.revoke_session({:access, credentials.access_token})

    credentials.access_token
    |> authed()
    |> post_action(ctx.gym.id, "complete")
    |> error(401, "unauthorized")

    assert %{"status" => "not_started"} =
             ctx.token |> authed() |> get(fr_path(ctx.gym.id)) |> first_run()
  end

  test "getGym still lists manage_first_run for the owner only", ctx do
    manager = registered!("first-run-http-perm")
    staff!(ctx.gym.id, manager, :manager)

    owner_view = ctx.token |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}") |> json_response(200)

    manager_view =
      token(manager) |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}") |> json_response(200)

    assert "manage_first_run" in owner_view["gym"]["viewer"]["permissions"]
    refute "manage_first_run" in manager_view["gym"]["viewer"]["permissions"]
  end
end
