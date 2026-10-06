defmodule SimpleFitWeb.SessionControllerTest do
  # Not async: one test switches the cookie configuration in the app env.
  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.Session
  alias SimpleFit.Repo
  alias SimpleFitWeb.{ApiSpec, SessionTransport}

  @origin "http://localhost:3000"

  setup do
    {:ok, user} = Accounts.register_user(:email, "http-session@example.com")
    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, credentials: credentials}
  end

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp cookie_conn(conn, token) do
    conn
    |> put_req_cookie(SessionTransport.cookie_name(), token)
    |> put_req_header("origin", @origin)
    |> put_req_header("x-simplefit-csrf", "1")
  end

  defp revoked?(session_id), do: Repo.get!(Session, session_id).revoked_at != nil

  describe "POST /api/auth/session/refresh (body transport)" do
    test "rotates and returns new credentials in the body", %{conn: conn, credentials: c} do
      conn = json_post(conn, ~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      body = json_response(conn, 200)
      assert_schema(body, "SessionTokens", ApiSpec.spec())

      assert %{"token_type" => "Bearer", "refresh_token_transport" => "body"} = body
      assert "sfr_" <> _ = body["refresh_token"]
      refute body["refresh_token"] == c.refresh_token
      assert get_resp_header(conn, "set-cookie") == []
      assert {:ok, _viewer} = Accounts.authenticate_access_token(body["access_token"])
    end

    test "the old refresh token is rejected afterwards", %{conn: conn, credentials: c} do
      json_post(conn, ~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      conn =
        json_post(build_conn(), ~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "every invalid credential is the same 401 without echoing it", %{
      conn: conn,
      credentials: c
    } do
      random = "sfr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      for token <- [random, "sfr_short", c.access_token, 12, nil] do
        conn = json_post(build_conn(), ~p"/api/auth/session/refresh", %{refresh_token: token})
        body = json_response(conn, 401)

        assert %{"error" => %{"code" => "unauthorized", "details" => %{}}} = body
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
        if is_binary(token), do: refute(conn.resp_body =~ token)
      end

      assert json_response(post(conn, ~p"/api/auth/session/refresh"), 401)
    end

    test "a revoked session cannot refresh", %{conn: conn, credentials: c} do
      :ok = Accounts.revoke_session({:access, c.access_token})
      conn = json_post(conn, ~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/auth/session/refresh (cookie transport)" do
    test "rotates the cookie and keeps the refresh token out of the body", %{
      conn: conn,
      credentials: c
    } do
      conn = conn |> cookie_conn(c.refresh_token) |> post(~p"/api/auth/session/refresh")

      body = json_response(conn, 200)
      assert_schema(body, "SessionTokens", ApiSpec.spec())
      assert body["refresh_token_transport"] == "cookie"
      refute Map.has_key?(body, "refresh_token")

      cookie = conn.resp_cookies[SessionTransport.cookie_name()]
      assert "sfr_" <> _ = cookie.value
      refute cookie.value == c.refresh_token
      refute conn.resp_body =~ cookie.value
    end

    test "sets a Secure, HttpOnly, SameSite=Strict cookie scoped to /api/auth", %{
      conn: conn,
      credentials: c
    } do
      conn = conn |> cookie_conn(c.refresh_token) |> post(~p"/api/auth/session/refresh")
      [set_cookie] = get_resp_header(conn, "set-cookie")

      assert set_cookie =~ ~r/\A__Secure-sf_refresh=sfr_/
      assert set_cookie =~ "path=/api/auth"
      assert set_cookie =~ "secure"
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "SameSite=Strict"
      assert set_cookie =~ ~r/max-age=\d+/
      refute set_cookie =~ "domain="
    end

    test "requires an allow-listed Origin and the CSRF header", %{credentials: c} do
      attempts = [
        fn conn -> conn |> put_req_cookie(SessionTransport.cookie_name(), c.refresh_token) end,
        fn conn ->
          conn |> cookie_conn(c.refresh_token) |> delete_req_header("x-simplefit-csrf")
        end,
        fn conn ->
          conn |> cookie_conn(c.refresh_token) |> put_req_header("x-simplefit-csrf", "0")
        end,
        fn conn -> conn |> cookie_conn(c.refresh_token) |> delete_req_header("origin") end,
        fn conn ->
          conn |> cookie_conn(c.refresh_token) |> put_req_header("origin", "https://evil.example")
        end
      ]

      for attempt <- attempts do
        conn = build_conn() |> attempt.() |> post(~p"/api/auth/session/refresh")
        assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
      end

      # The rejected requests did not consume the token.
      conn = build_conn() |> cookie_conn(c.refresh_token) |> post(~p"/api/auth/session/refresh")
      assert json_response(conn, 200)
    end

    test "an invalid cookie is a 401 that clears the cookie", %{conn: conn} do
      random = "sfr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conn = conn |> cookie_conn(random) |> post(~p"/api/auth/session/refresh")

      assert json_response(conn, 401)
      [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "__Secure-sf_refresh=;"
      assert set_cookie =~ "max-age=0"
    end

    test "sending the token both ways is ambiguous", %{conn: conn, credentials: c} do
      conn =
        conn
        |> cookie_conn(c.refresh_token)
        |> json_post(~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)
      refute revoked?(c.session.id)
    end

    test "development serves a non-Secure cookie without the __Secure- prefix", %{credentials: c} do
      original = Application.get_env(:simple_fit, SessionTransport)
      Application.put_env(:simple_fit, SessionTransport, secure_cookie: false)
      on_exit(fn -> Application.put_env(:simple_fit, SessionTransport, original) end)

      conn =
        build_conn()
        |> put_req_cookie("sf_refresh", c.refresh_token)
        |> put_req_header("origin", @origin)
        |> put_req_header("x-simplefit-csrf", "1")
        |> post(~p"/api/auth/session/refresh")

      assert json_response(conn, 200)
      [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ ~r/\Asf_refresh=sfr_/
      refute set_cookie =~ "secure"
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "SameSite=Strict"
    end
  end

  describe "POST /api/auth/logout" do
    test "with the bearer token revokes the current session", %{conn: conn, credentials: c} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> c.access_token)
        |> post(~p"/api/auth/logout")

      assert response(conn, 204) == ""
      assert revoked?(c.session.id)
      [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "max-age=0"
    end

    test "with the body refresh token revokes the session", %{conn: conn, credentials: c} do
      conn = json_post(conn, ~p"/api/auth/logout", %{refresh_token: c.refresh_token})
      assert response(conn, 204)
      assert revoked?(c.session.id)
    end

    test "with the cookie revokes the session and needs the CSRF proof", %{credentials: c} do
      conn =
        build_conn()
        |> put_req_cookie(SessionTransport.cookie_name(), c.refresh_token)
        |> post(~p"/api/auth/logout")

      assert json_response(conn, 403)
      refute revoked?(c.session.id)

      conn = build_conn() |> cookie_conn(c.refresh_token) |> post(~p"/api/auth/logout")
      assert response(conn, 204)
      assert revoked?(c.session.id)
    end

    test "is idempotent and reveals nothing", %{credentials: c} do
      bearer = fn ->
        build_conn() |> put_req_header("authorization", "Bearer " <> c.access_token)
      end

      assert response(post(bearer.(), ~p"/api/auth/logout"), 204)
      assert response(post(bearer.(), ~p"/api/auth/logout"), 204)
      assert response(post(build_conn(), ~p"/api/auth/logout"), 204)

      unknown = "sfr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert response(
               json_post(build_conn(), ~p"/api/auth/logout", %{refresh_token: unknown}),
               204
             )

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer sfa_forged")
        |> post(~p"/api/auth/logout")

      assert response(conn, 204)
    end

    test "a logged-out session can neither refresh nor read /api/me", %{credentials: c} do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> c.access_token)
      |> post(~p"/api/auth/logout")

      refresh =
        json_post(build_conn(), ~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      assert json_response(refresh, 401)

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> c.access_token)
        |> get(~p"/api/me")

      assert json_response(me, 401)
    end

    test "logging out one session leaves the user's other sessions alone", %{
      user: user,
      credentials: c
    } do
      {:ok, other} = Accounts.create_session(user)

      build_conn()
      |> put_req_header("authorization", "Bearer " <> c.access_token)
      |> post(~p"/api/auth/logout")

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> other.access_token)
        |> get(~p"/api/me")

      assert json_response(me, 200)
      refute revoked?(other.session.id)
    end
  end

  describe "CORS for the cookie endpoints" do
    test "credentials are allowed only on the refresh and logout endpoints" do
      for path <- [~p"/api/auth/session/refresh", ~p"/api/auth/logout"] do
        conn =
          build_conn()
          |> put_req_header("origin", @origin)
          |> put_req_header("access-control-request-method", "POST")
          |> put_req_header("access-control-request-headers", "content-type, x-simplefit-csrf")
          |> options(path)

        assert conn.status == 204
        assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
        assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      end

      me = build_conn() |> put_req_header("origin", @origin) |> get(~p"/api/me")
      assert get_resp_header(me, "access-control-allow-credentials") == []
    end

    test "unknown origins get no credentials", %{credentials: c} do
      conn =
        build_conn()
        |> put_req_header("origin", "https://evil.example")
        |> json_post(~p"/api/auth/session/refresh", %{refresh_token: c.refresh_token})

      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end
end
