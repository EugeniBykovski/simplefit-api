defmodule SimpleFitWeb.MeControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.Sessions
  alias SimpleFitWeb.ApiSpec

  setup do
    {:ok, user} = Accounts.register_user(:google, "109876543210")
    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, credentials: credentials}
  end

  defp me(token) do
    build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(~p"/api/me")
  end

  test "returns exactly the session's user", %{user: user, credentials: c} do
    conn = me(c.access_token)
    body = json_response(conn, 200)

    assert_schema(body, "CurrentUserResponse", ApiSpec.spec())

    assert body == %{
             "user" => %{"id" => user.id, "created_at" => DateTime.to_iso8601(user.inserted_at)}
           }
  end

  test "exposes no identity, credential or invented capability", %{credentials: c} do
    conn = me(c.access_token)

    for secret <- ["109876543210", c.access_token, c.refresh_token, c.session.id] do
      refute conn.resp_body =~ secret
    end

    for field <- ~w(provider provider_subject role type profile workspaces session token) do
      refute conn.resp_body =~ ~s("#{field}")
    end
  end

  test "another user's token resolves the other user", %{credentials: c} do
    {:ok, other} = Accounts.register_user(:email, "someone@example.com")
    {:ok, other_credentials} = Accounts.create_session(other)

    assert json_response(me(other_credentials.access_token), 200)["user"]["id"] == other.id
    refute json_response(me(c.access_token), 200)["user"]["id"] == other.id
  end

  test "unauthenticated requests get the canonical 401", %{conn: conn} do
    conn = get(conn, ~p"/api/me")

    assert %{"error" => %{"code" => "unauthorized", "request_id" => request_id}} =
             json_response(conn, 401)

    assert is_binary(request_id)
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert_schema(json_response(conn, 401), "ErrorResponse", ApiSpec.spec())
  end

  test "rejects malformed, expired, refresh and non-bearer credentials", %{credentials: c} do
    ttl = Sessions.config!().access_token_ttl

    expired =
      Sessions.sign_access_token_at(
        c.session.id,
        DateTime.add(DateTime.utc_now(:second), -(ttl + 1))
      )

    for header <- [
          "Bearer",
          "Bearer ",
          "Bearer garbage",
          "Bearer " <> expired,
          "Bearer " <> c.refresh_token,
          "Basic " <> c.access_token,
          c.access_token
        ] do
      conn = build_conn() |> put_req_header("authorization", header) |> get(~p"/api/me")
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end
  end

  test "accepts the bearer scheme case-insensitively", %{credentials: c} do
    conn =
      build_conn()
      |> put_req_header("authorization", "bearer " <> c.access_token)
      |> get(~p"/api/me")

    assert json_response(conn, 200)
  end

  test "a revoked session is rejected immediately", %{credentials: c} do
    :ok = Accounts.revoke_session({:refresh, c.refresh_token})
    assert json_response(me(c.access_token), 401)
  end
end
