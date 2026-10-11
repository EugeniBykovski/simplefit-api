defmodule SimpleFitWeb.SessionLifecycleTest do
  @moduledoc """
  The whole session lifecycle over HTTP (SF-28, ADR 0010), on the real
  endpoints and PostgreSQL: a passwordless sign-in creates a session, the
  access token expires, the refresh rotates it, logout revokes only that
  session, its credentials stop working, and signing in again starts a new
  one. Once per refresh transport: body (mobile) and cookie (web).
  """

  # Not async: rate limits and emails are shared by the flow.
  use SimpleFitWeb.ConnCase, async: false

  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts.{Session, Sessions}
  alias SimpleFit.Repo
  alias SimpleFitWeb.SessionTransport

  @origin "http://localhost:3000"
  @email "lifecycle@example.com"

  defp json_post(conn \\ build_conn(), path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp web(conn) do
    conn
    |> put_req_header("origin", @origin)
    |> put_req_header("x-simplefit-csrf", "1")
  end

  defp with_cookie(conn, token),
    do: conn |> web() |> put_req_cookie(SessionTransport.cookie_name(), token)

  defp register!(email) do
    body = json_post(~p"/api/auth/email/registrations", %{email: email}) |> json_response(202)

    json_post(~p"/api/auth/email/registrations/verify", %{
      registration_token: body["registration_token"],
      code: code_from(last_email_to(email))
    })
    |> json_response(200)

    reset_rate_limits()
  end

  # A passwordless sign-in (E17 code), returning the response conn.
  defp sign_in(email, transport) do
    json_post(~p"/api/auth/email/sign-in", %{email: email}) |> json_response(202)
    code = code_from(last_email_to(email))
    reset_rate_limits()

    body = %{email: email, code: code}

    case transport do
      :body ->
        json_post(~p"/api/auth/email/sign-in/verify", body)

      :cookie ->
        json_post(
          web(build_conn()),
          ~p"/api/auth/email/sign-in/verify",
          Map.put(body, :refresh_token_transport, "cookie")
        )
    end
  end

  defp me(access_token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> get(~p"/api/me")
  end

  defp session_id!(access_token) do
    {:ok, id} = Sessions.verify_access_token(access_token)
    id
  end

  defp expired_access_token(access_token) do
    # The same session, signed one hour ago: past its 15 minute lifetime.
    Sessions.sign_access_token_at(
      session_id!(access_token),
      DateTime.add(DateTime.utc_now(), -3600)
    )
  end

  setup do
    register!(@email)
    :ok
  end

  test "mobile (body transport): sign in, expire, refresh, log out, sign in again" do
    # Sign in: the backend creates a session; the protected API works.
    signed_in = sign_in(@email, :body) |> json_response(200)
    %{"access_token" => access, "refresh_token" => refresh} = signed_in
    assert %{"user" => %{"id" => user_id}} = me(access) |> json_response(200)

    # A second device of the same user: an independent session.
    other = sign_in(@email, :body) |> json_response(200)
    refute session_id!(other["access_token"]) == session_id!(access)

    # The access token expires: the API rejects it with the canonical 401.
    expired = me(expired_access_token(access))
    assert json_response(expired, 401)["error"]["code"] == "unauthorized"
    assert get_resp_header(expired, "www-authenticate") == ["Bearer"]

    # The refresh rotates the credential; the protected API works again.
    rotated =
      json_post(~p"/api/auth/session/refresh", %{refresh_token: refresh}) |> json_response(200)

    assert rotated["refresh_token"] != refresh
    assert session_id!(rotated["access_token"]) == session_id!(access)
    assert %{"user" => %{"id" => ^user_id}} = me(rotated["access_token"]) |> json_response(200)

    # Logout on this device revokes this session only.
    logout =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> rotated["access_token"])
      |> json_post(~p"/api/auth/logout", %{refresh_token: rotated["refresh_token"]})

    assert response(logout, 204)
    assert %Session{revoked_reason: :logout} = Repo.get!(Session, session_id!(access))

    # Every credential of the revoked session is rejected; nothing is reused.
    assert json_response(me(rotated["access_token"]), 401)

    assert json_post(~p"/api/auth/session/refresh", %{refresh_token: rotated["refresh_token"]})
           |> json_response(401)

    assert json_post(~p"/api/auth/session/refresh", %{refresh_token: refresh})
           |> json_response(401)

    # Logging out again is still a quiet 204.
    again =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> rotated["access_token"])
      |> post(~p"/api/auth/logout")

    assert response(again, 204)

    # The other device was not touched.
    assert %{"user" => %{"id" => ^user_id}} = me(other["access_token"]) |> json_response(200)

    # Signing in again creates a new, valid session.
    renewed = sign_in(@email, :body) |> json_response(200)
    refute session_id!(renewed["access_token"]) == session_id!(access)
    assert %{"user" => %{"id" => ^user_id}} = me(renewed["access_token"]) |> json_response(200)
  end

  test "web (cookie transport): the refresh cookie rotates, logout clears and revokes it" do
    signed_in = sign_in(@email, :cookie)
    %{"access_token" => access} = json_response(signed_in, 200)
    cookie = signed_in.resp_cookies[SessionTransport.cookie_name()].value
    assert json_response(me(access), 200)

    # Access expired: the cookie refresh rotates the cookie and keeps the token out of the body.
    assert json_response(me(expired_access_token(access)), 401)
    refreshed = with_cookie(build_conn(), cookie) |> post(~p"/api/auth/session/refresh")
    body = json_response(refreshed, 200)
    refute Map.has_key?(body, "refresh_token")
    rotated_cookie = refreshed.resp_cookies[SessionTransport.cookie_name()].value
    refute rotated_cookie == cookie
    assert json_response(me(body["access_token"]), 200)

    # Logout with the cookie (and the bearer token): revoked, cookie deleted.
    logout =
      with_cookie(build_conn(), rotated_cookie)
      |> put_req_header("authorization", "Bearer " <> body["access_token"])
      |> post(~p"/api/auth/logout")

    assert response(logout, 204)
    assert logout.resp_cookies[SessionTransport.cookie_name()].max_age == 0

    # A cookie kept from before the logout cannot bring the session back.
    resurrect = with_cookie(build_conn(), rotated_cookie) |> post(~p"/api/auth/session/refresh")
    assert json_response(resurrect, 401)
    assert json_response(me(body["access_token"]), 401)
  end

  test "a deleted user's credentials stop working and nothing recreates the account" do
    %{"access_token" => access, "refresh_token" => refresh} =
      sign_in(@email, :body) |> json_response(200)

    %{"user" => %{"id" => user_id}} = me(access) |> json_response(200)
    Repo.delete!(Repo.get!(SimpleFit.Accounts.User, user_id))

    assert json_response(me(access), 401)

    assert json_post(~p"/api/auth/session/refresh", %{refresh_token: refresh})
           |> json_response(401)

    assert Repo.get(SimpleFit.Accounts.User, user_id) == nil
  end
end
