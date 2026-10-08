defmodule SimpleFitWeb.EntryControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.AccountRegistrationHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Fighters
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/entry"

  setup do
    {:ok, user} =
      Accounts.register_user(:google, "entry-api-#{System.unique_integer([:positive])}")

    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, token: credentials.access_token}
  end

  defp entry(token, query \\ "") do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(@path <> query)
  end

  defp body(conn) do
    body = json_response(conn, 200)
    assert_schema(body, "EntryResponse", ApiSpec.spec())
    body["entry"]
  end

  test "requires authentication", %{conn: conn} do
    assert json_response(get(conn, @path), 401)["error"]["code"] == "unauthorized"

    assert json_response(get(build_conn(), @path <> "?intent=fighter"), 401)["error"]["code"] ==
             "unauthorized"
  end

  test "a new provider user: account registration first, whatever the intent", %{token: token} do
    for query <- ["", "?intent=fighter", "?intent=coach", "?intent=gym", "?intent=sponsor"] do
      assert %{
               "destination" => "account_registration",
               "reason" => "account_registration_incomplete",
               "mandatory" => true,
               "account_registration" => "not_started",
               "fighter_profile" => "not_started",
               "capabilities" => []
             } = token |> entry(query) |> body()
    end
  end

  test "echoes the validated intent and never stores it", %{user: user, token: token} do
    complete_account_registration!(user)

    assert %{"intent" => "fighter", "destination" => "fighter_onboarding"} =
             token |> entry("?intent=fighter") |> body()

    assert %{"intent" => nil, "destination" => "role_selection"} = token |> entry() |> body()
  end

  test "every destination for a registered user", %{user: user, token: token} do
    complete_account_registration!(user)

    for {query, destination} <- [
          {"", "role_selection"},
          {"?intent=fighter", "fighter_onboarding"},
          {"?intent=coach", "coach_onboarding"},
          {"?intent=gym", "gym_onboarding"},
          {"?intent=sponsor", "sponsor_application"}
        ] do
      assert %{"destination" => ^destination, "capabilities" => []} =
               token |> entry(query) |> body()
    end
  end

  test "a completed fighter signing in again goes home with the FIGHTER capability", %{
    user: user,
    token: token
  } do
    complete_account_registration!(user)

    {:ok, _} =
      Fighters.update_profile(user, %{
        "display_name" => "Alex K.",
        "username" => "entry_api_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "amateur",
        "stance" => "orthodox"
      })

    assert %{"destination" => "fighter_onboarding", "mandatory" => true} =
             token |> entry() |> body()

    {:ok, _} = Fighters.complete_onboarding(user)

    {:ok, again} = Accounts.create_session(user)

    for t <- [token, again.access_token], query <- ["", "?intent=fighter"] do
      assert %{
               "destination" => "fighter_home",
               "reason" => "fighter_onboarding_completed",
               "mandatory" => false,
               "fighter_profile" => "completed",
               "capabilities" => ["FIGHTER"]
             } = t |> entry(query) |> body()
    end
  end

  test "an unknown intent is invalid_choice", %{token: token} do
    for bad <- ["admin", "Fighter", "gym_workspace"] do
      body = token |> entry("?intent=" <> bad) |> json_response(422)
      assert_schema(body, "ErrorResponse", ApiSpec.spec())
      assert body["error"]["code"] == "validation_error"
      assert body["error"]["details"]["field_codes"] == %{"intent" => ["invalid_choice"]}
    end
  end

  test "an empty intent means none; unrelated query parameters are ignored", %{token: token} do
    assert %{"intent" => nil} = token |> entry("?intent=") |> body()
    assert %{"intent" => nil} = token |> entry("?role=fighter&returnTo=%2Fapp") |> body()
  end

  test "responses are not cacheable", %{token: token} do
    assert token |> entry() |> get_resp_header("cache-control") == ["no-store"]
  end

  test "is a versioned product resource with a documented intent parameter" do
    operation = ApiSpec.spec().paths[@path].get
    assert operation.operationId == "resolveMyEntry"
    [param] = operation.parameters
    assert {param.name, param.in, param.required} == {:intent, :query, false}
    assert param.schema.enum == ~w(fighter coach gym sponsor)
  end
end
