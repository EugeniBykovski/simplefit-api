defmodule SimpleFitWeb.AccountProfileControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/account-profile"
  @complete_path "/api/v1/me/account-profile/complete-registration"

  setup do
    {:ok, user} = Accounts.register_user(:google, "account-#{System.unique_integer([:positive])}")
    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, token: credentials.access_token}
  end

  defp dob(years), do: Date.to_iso8601(Date.shift(Date.utc_today(), year: -years))

  defp complete_body,
    do: %{
      "full_name" => "Alex Kowalski",
      "date_of_birth" => dob(30),
      "accept_terms" => true,
      "accept_privacy" => true
    }

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp get_profile(token), do: token |> authed() |> get(@path)

  defp patch_profile(token, body),
    do:
      token
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> patch(@path, body)

  defp complete(token), do: token |> authed() |> post(@complete_path)

  defp body(conn, status) do
    body = json_response(conn, status)
    assert_schema(body, "AccountProfileResponse", ApiSpec.spec())
    body["account_profile"]
  end

  defp field_codes(conn) do
    body = json_response(conn, 422)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == "validation_error"
    body["error"]["details"]["field_codes"]
  end

  test "GET before registration: not_started, every requirement missing, nothing created", %{
    user: user,
    token: token
  } do
    profile = token |> get_profile() |> body(200)

    assert profile["registration"] == %{
             "status" => "not_started",
             "completed_at" => nil,
             "missing_requirements" => ["full_name", "date_of_birth", "terms", "privacy"]
           }

    assert profile["consents"]["terms"] == %{
             "accepted" => false,
             "accepted_version" => nil,
             "accepted_at" => nil,
             "current_version" => "terms-v1",
             "current" => false
           }

    assert profile["product_news"] == %{"subscribed" => false, "updated_at" => nil}
    assert Accounts.get_account_registration(user).profile == nil
  end

  test "an empty PATCH keeps not_started", %{token: token} do
    assert (token |> patch_profile(%{}) |> body(200))["registration"]["status"] == "not_started"
  end

  test "partial progress, consents and product news round-trip", %{token: token} do
    profile =
      token
      |> patch_profile(%{
        "full_name" => "Alex Kowalski",
        "accept_terms" => true,
        "product_news" => true
      })
      |> body(200)

    assert profile["registration"]["status"] == "in_progress"
    assert profile["registration"]["missing_requirements"] == ["date_of_birth", "privacy"]
    assert profile["full_name"] == "Alex Kowalski"
    assert profile["consents"]["terms"]["current"]
    assert profile["product_news"]["subscribed"]

    profile = token |> patch_profile(%{"product_news" => false}) |> body(200)
    refute profile["product_news"]["subscribed"]
  end

  test "validation errors carry stable field codes and change nothing", %{
    user: user,
    token: token
  } do
    codes =
      token
      |> patch_profile(%{
        "full_name" => "Alex Kowalski",
        "date_of_birth" => Date.to_iso8601(Date.add(Date.utc_today(), 1)),
        "accept_terms" => false
      })
      |> field_codes()

    assert codes == %{"date_of_birth" => ["out_of_range"], "accept_terms" => ["must_be_accepted"]}

    assert token |> patch_profile(%{"date_of_birth" => dob(15)}) |> field_codes() == %{
             "date_of_birth" => ["too_young"]
           }

    assert Accounts.get_account_registration(user).profile == nil
  end

  test "completion: blocked while incomplete, then complete and idempotent", %{token: token} do
    token |> patch_profile(Map.delete(complete_body(), "accept_privacy")) |> body(200)
    assert token |> complete() |> field_codes() == %{"privacy" => ["required"]}

    token |> patch_profile(%{"accept_privacy" => true}) |> body(200)
    first = token |> complete() |> body(200)

    assert first["registration"]["status"] == "complete"
    assert first["registration"]["missing_requirements"] == []
    assert first["date_of_birth"] == dob(30)

    again = token |> complete() |> body(200)
    assert again["registration"]["completed_at"] == first["registration"]["completed_at"]

    assert token |> patch_profile(%{"date_of_birth" => dob(31)}) |> field_codes() ==
             %{"date_of_birth" => ["immutable"]}
  end

  test "a provider-authenticated user registers like any other: sign-in completes nothing" do
    {:ok, apple_user} =
      Accounts.register_user(:apple, "apple-#{System.unique_integer([:positive])}")

    {:ok, credentials} = Accounts.create_session(apple_user)

    assert (credentials.access_token |> get_profile() |> body(200))["registration"]["status"] ==
             "not_started"

    assert credentials.access_token |> complete() |> field_codes() |> Map.keys() |> Enum.sort() ==
             ["date_of_birth", "full_name", "privacy", "terms"]
  end

  test "exposes no ids, user id or internal timestamps", %{user: user, token: token} do
    token |> patch_profile(complete_body()) |> body(200)
    conn = get_profile(token)

    refute conn.resp_body =~ user.id

    for field <-
          ~w(id user_id inserted_at registration_completed_at document_version decision) do
      refute conn.resp_body =~ ~s("#{field}")
    end
  end

  test "/api/me is unchanged by registration", %{user: user, token: token} do
    token |> patch_profile(complete_body()) |> body(200)
    token |> complete() |> body(200)

    me = token |> authed() |> get("/api/me") |> json_response(200)
    assert Map.keys(me) == ["user"]
    assert Map.keys(me["user"]) |> Enum.sort() == ["created_at", "id"]
    assert me["user"]["id"] == user.id
  end

  test "every operation requires authentication", %{conn: conn} do
    assert json_response(get(conn, @path), 401)["error"]["code"] == "unauthorized"

    assert json_response(post(build_conn(), @complete_path), 401)["error"]["code"] ==
             "unauthorized"

    conn = build_conn() |> put_req_header("content-type", "application/json") |> patch(@path, %{})
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "the routes are versioned product resources" do
    paths = Map.keys(ApiSpec.spec().paths)
    assert @path in paths and @complete_path in paths
  end
end
