defmodule SimpleFitWeb.FirstRunControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/first-run"
  @tour @path <> "/fighter_web_tour"

  setup do
    {:ok, user} =
      Accounts.register_user(:google, "first-run-api-#{System.unique_integer([:positive])}")

    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, token: credentials.access_token}
  end

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp list(token) do
    conn = token |> authed() |> get(@path)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body = json_response(conn, 200)
    assert_schema(body, "FirstRunResponse", ApiSpec.spec())
    [tour, mobile] = body["experiences"]
    assert mobile["experience"] == "fighter_mobile_first_run"
    tour
  end

  defp record(token, body, path \\ @tour) do
    token |> authed() |> put_req_header("content-type", "application/json") |> put(path, body)
  end

  test "requires authentication", %{conn: conn} do
    assert json_response(get(conn, @path), 401)["error"]["code"] == "unauthorized"

    assert json_response(put(build_conn(), @tour, %{outcome: "completed"}), 401)["error"]["code"] ==
             "unauthorized"
  end

  test "a user without a completed Fighter onboarding: unavailable, and nothing is recorded", %{
    token: token
  } do
    assert %{"experience" => "fighter_web_tour", "status" => "unavailable", "recorded_at" => nil} =
             list(token)

    assert json_response(record(token, %{outcome: "completed"}), 409)["error"]["code"] ==
             "conflict"

    assert %{"status" => "unavailable"} = list(token)
  end

  test "a completed Fighter: pending, then the first outcome is kept", %{
    user: user,
    token: token
  } do
    complete_fighter_onboarding!(user)
    assert %{"status" => "pending", "recorded_at" => nil} = list(token)

    first = json_response(record(token, %{outcome: "dismissed"}), 200)
    assert_schema(first, "FirstRunExperienceResponse", ApiSpec.spec())

    assert %{"experience" => %{"status" => "dismissed", "recorded_at" => at}} = first
    assert is_binary(at)

    for outcome <- ["completed", "dismissed"] do
      assert json_response(record(token, %{outcome: outcome}), 200) == first
    end

    assert %{"status" => "dismissed", "recorded_at" => ^at} = list(token)
  end

  test "a new session of the same user sees the kept outcome", %{user: user, token: token} do
    complete_fighter_onboarding!(user)
    json_response(record(token, %{outcome: "completed"}), 200)

    {:ok, other} = Accounts.create_session(user)
    assert %{"status" => "completed"} = list(other.access_token)
  end

  test "the mobile first run keeps its own outcome; the web tour stays pending (SF-41)", %{
    user: user,
    token: token
  } do
    complete_fighter_onboarding!(user)
    mobile_path = @path <> "/fighter_mobile_first_run"

    recorded = json_response(record(token, %{outcome: "completed"}, mobile_path), 200)
    assert_schema(recorded, "FirstRunExperienceResponse", ApiSpec.spec())

    assert %{"experience" => "fighter_mobile_first_run", "status" => "completed"} =
             recorded["experience"]

    assert %{"experience" => "fighter_web_tour", "status" => "pending"} = list(token)
  end

  test "errors", %{user: user, token: token} do
    complete_fighter_onboarding!(user)

    assert json_response(record(token, %{outcome: "completed"}, @path <> "/coach_web_tour"), 404)[
             "error"
           ]["code"] == "not_found"

    for {body, code} <- [{%{}, "required"}, {%{outcome: "skipped"}, "invalid_choice"}] do
      error = json_response(record(token, body), 422)["error"]
      assert error["code"] == "validation_error"
      assert error["details"]["field_codes"] == %{"outcome" => [code]}
    end

    assert %{"status" => "pending"} = list(token)
  end
end
