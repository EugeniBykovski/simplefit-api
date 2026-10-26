defmodule SimpleFitWeb.EntryCoachControllerTest do
  @moduledoc "SF-51 over HTTP: Coach entry, capabilities and the explicit context choice."

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Coaches
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Repo
  alias SimpleFitWeb.ApiSpec

  @entry "/api/v1/me/entry"
  @choice "/api/v1/me/entry/context"

  @coach %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  defp user!(prefix \\ "entry-coach-http") do
    {:ok, user} =
      Accounts.register_user(:google, "#{prefix}-#{System.unique_integer([:positive])}")

    user
  end

  defp session!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp coach!(user, complete? \\ true) do
    {:ok, _} = Coaches.update_profile(user, @coach)
    if complete?, do: {:ok, _} = Coaches.complete_onboarding(user)
    user
  end

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp entry(token, query \\ "") do
    body = token |> authed() |> get(@entry <> query) |> json_response(200)
    assert_schema(body, "EntryResponse", ApiSpec.spec())
    body["entry"]
  end

  defp choose(token, body) do
    token
    |> authed()
    |> put_req_header("content-type", "application/json")
    |> put(@choice, Jason.encode!(body))
  end

  defp error(conn, status) do
    body = json_response(conn, status)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    body["error"]
  end

  describe "GET /api/v1/me/entry" do
    test "the Coach journey end to end, with the documented shape" do
      user = user!()
      token = session!(user)

      assert %{"destination" => "account_registration", "intent" => "coach", "mandatory" => true} =
               entry(token, "?intent=coach")

      complete_account_registration!(user)

      assert %{
               "destination" => "coach_onboarding",
               "reason" => "coach_onboarding_not_started",
               "mandatory" => true,
               "coach_profile" => "not_started",
               "capabilities" => []
             } = entry(token, "?intent=coach")

      coach!(user, false)

      assert %{"destination" => "coach_onboarding", "coach_profile" => "in_progress"} =
               entry(token)

      {:ok, _} = Coaches.complete_onboarding(user)

      assert %{
               "destination" => "coach_home",
               "reason" => "coach_onboarding_completed",
               "mandatory" => false,
               "coach_profile" => "completed",
               "fighter_profile" => "not_started",
               "capabilities" => ["COACH"],
               "context" => nil
             } = entry(token)
    end

    test "a completed Fighter choosing Coach goes to Coach onboarding, then keeps Fighter home by default" do
      user = user!()
      complete_fighter_onboarding!(user)
      token = session!(user)

      assert %{"destination" => "coach_onboarding", "capabilities" => ["FIGHTER"]} =
               entry(token, "?intent=coach")

      coach!(user, false)
      assert %{"destination" => "fighter_home", "coach_profile" => "in_progress"} = entry(token)

      {:ok, _} = Coaches.complete_onboarding(user)

      assert %{"destination" => "context_selection", "capabilities" => ["FIGHTER", "COACH"]} =
               entry(token)

      assert %{"destination" => "fighter_home", "context" => "fighter"} =
               entry(token, "?context=fighter")

      assert %{"destination" => "coach_home", "context" => "coach"} =
               entry(token, "?context=coach")
    end

    test "a requested context that is not completed is ignored and echoed as null" do
      user = user!()
      complete_fighter_onboarding!(user)
      token = session!(user)

      assert %{"destination" => "fighter_home", "context" => nil, "capabilities" => ["FIGHTER"]} =
               entry(token, "?context=coach")
    end

    test "forged capabilities and roles in the query are ignored" do
      user = user!()
      complete_account_registration!(user)
      token = session!(user)

      assert %{"destination" => "role_selection", "capabilities" => []} =
               entry(token, "?capabilities=COACH&role=coach&coach_profile=completed")
    end

    test "an unknown context is invalid_choice" do
      token = user!() |> session!()
      conn = token |> authed() |> get(@entry <> "?context=sponsor")

      assert %{
               "code" => "validation_error",
               "details" => %{"field_codes" => %{"context" => ["invalid_choice"]}}
             } =
               error(conn, 422)
    end

    test "returnTo is never read by the API: no value changes the answer or is echoed" do
      user = user!()
      complete_fighter_onboarding!(user)
      token = session!(user)

      for return_to <- [
            "https://evil.example/app/coach",
            "//evil.example",
            "/%2F%2Fevil.example",
            "/app/coach",
            "javascript:alert(1)",
            "%E0%A4%A"
          ] do
        conn = token |> authed() |> get(@entry <> "?returnTo=" <> URI.encode_www_form(return_to))
        body = json_response(conn, 200)
        assert body["entry"]["destination"] == "fighter_home"
        refute conn.resp_body =~ "evil"
      end
    end
  end

  describe "PUT /api/v1/me/entry/context" do
    setup do
      user = user!()
      complete_fighter_onboarding!(user)
      coach!(user)
      %{user: user, token: session!(user)}
    end

    test "records the choice (204, not cacheable) and the entry follows it", %{token: token} do
      conn = choose(token, %{"context" => "coach"})
      assert response(conn, 204) == ""
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert %{"destination" => "coach_home", "reason" => "last_context"} = entry(token)

      assert response(choose(token, %{"context" => "fighter"}), 204)
      assert %{"destination" => "fighter_home", "reason" => "last_context"} = entry(token)
    end

    test "a choice made on one device applies to the user's other sessions", %{
      user: user,
      token: token
    } do
      other_device = session!(user)
      assert response(choose(token, %{"context" => "coach"}), 204)
      assert %{"destination" => "coach_home"} = entry(other_device)
    end

    test "a context that is not completed is a conflict and records nothing" do
      user = user!()
      complete_fighter_onboarding!(user)
      coach!(user, false)
      token = session!(user)

      assert %{"code" => "conflict"} = error(choose(token, %{"context" => "coach"}), 409)
      assert Repo.get(ContextChoice, user.id) == nil
    end

    test "invalid bodies are validation errors and record nothing", %{user: user, token: token} do
      for {body, codes} <- [
            {%{"context" => "sponsor"}, %{"context" => ["invalid_choice"]}},
            {%{"context" => "gym"}, %{"gym_id" => ["required"]}},
            {%{}, %{"context" => ["required"]}},
            {%{"context" => "coach", "user_id" => Ecto.UUID.generate()},
             %{"user_id" => ["invalid"]}},
            {%{"context" => "coach", "capabilities" => ["COACH"]},
             %{"capabilities" => ["invalid"]}}
          ] do
        assert %{"code" => "validation_error", "details" => %{"field_codes" => ^codes}} =
                 error(choose(token, body), 422)
      end

      assert Repo.get(ContextChoice, user.id) == nil
    end

    test "a choice never touches another user's", %{user: user, token: token} do
      other = user!("entry-coach-http-other")
      complete_fighter_onboarding!(other)
      coach!(other)
      other_token = session!(other)

      assert response(choose(token, %{"context" => "coach"}), 204)
      assert response(choose(other_token, %{"context" => "fighter"}), 204)

      assert Repo.get(ContextChoice, user.id).context == :coach
      assert Repo.get(ContextChoice, other.id).context == :fighter
    end

    test "requires a live session", %{token: token} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put(@choice, ~s({"context":"coach"}))

      assert error(conn, 401)["code"] == "unauthorized"

      :ok = Accounts.revoke_session({:access, token})
      assert error(choose(token, %{"context" => "coach"}), 401)["code"] == "unauthorized"
      assert error(token |> authed() |> get(@entry), 401)["code"] == "unauthorized"
    end

    test "is documented with its request schema and errors" do
      operation = ApiSpec.spec().paths[@choice].put
      assert operation.operationId == "chooseMyEntryContext"
      assert Map.keys(operation.responses) |> Enum.sort() == [204, 401, 404, 409, 422, 500]
    end
  end
end
