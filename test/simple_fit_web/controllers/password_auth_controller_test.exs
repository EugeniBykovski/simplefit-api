defmodule SimpleFitWeb.PasswordAuthControllerTest do
  @moduledoc """
  SF-157 over HTTP: password sign-in, set/reset with an emailed code, change, and what
  a password session may do in the Control Plane (authorization stays the operator's).
  """

  use SimpleFitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.EmailAuthHelpers
  import SimpleFit.OperatorHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Operators.{Grant, Operator}
  alias SimpleFit.Repo
  alias SimpleFitWeb.{ApiSpec, SessionTransport}

  @origin "http://localhost:3000"
  @password "correct horse battery staple"

  defp json(method, path, body, token \\ nil),
    do: json_on(build_conn(), method, path, body, token)

  defp json_on(conn, method, path, body, token \\ nil) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer #{token}"), else: &1))

    dispatch(conn, @endpoint, method, path, if(body, do: Jason.encode!(body)))
  end

  defp error_code(conn, status), do: get_in(json_response(conn, status), ["error", "code"])

  defp address, do: "pw-http-#{System.unique_integer([:positive])}@example.com"

  # An email account with completed registration and a password set through the code.
  defp account!(password \\ @password) do
    address = address()
    {:ok, user} = Accounts.register_user(:email, address)
    user = complete_account_registration!(user)
    json(:post, "/api/auth/password/reset", %{email: address}) |> json_response(202)
    code = code_from(last_email_to(address))

    assert json(:post, "/api/auth/password/reset/confirm", %{
             email: address,
             code: code,
             password: password
           }).status == 204

    reset_rate_limits()
    {user, address}
  end

  defp sign_in!(address, password \\ @password) do
    json(:post, "/api/auth/password/sign-in", %{email: address, password: password})
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  describe "POST /api/auth/password/sign-in" do
    test "body transport: session tokens" do
      {_user, address} = account!()

      body =
        json(:post, "/api/auth/password/sign-in", %{email: address, password: @password})
        |> json_response(200)

      assert_schema(body, "SessionTokens", ApiSpec.spec())
      assert %{"access_token" => _, "refresh_token" => "sfr_" <> _} = body
    end

    test "cookie transport needs the CSRF proof, then sets the HttpOnly refresh cookie" do
      {_user, address} = account!()
      params = %{email: address, password: @password, refresh_token_transport: "cookie"}

      assert json(:post, "/api/auth/password/sign-in", params) |> error_code(403) == "forbidden"

      conn =
        build_conn()
        |> put_req_header("origin", @origin)
        |> put_req_header("x-simplefit-csrf", "1")
        |> json_on(:post, "/api/auth/password/sign-in", params)

      body = json_response(conn, 200)
      refute Map.has_key?(body, "refresh_token")

      assert %{value: "sfr_" <> _, http_only: true} =
               conn.resp_cookies[SessionTransport.cookie_name()]

      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    end

    test "every failure is the same invalid_credentials envelope" do
      {_user, address} = account!()

      for params <- [
            %{email: address, password: "not the password"},
            %{email: address(), password: @password}
          ] do
        conn = json(:post, "/api/auth/password/sign-in", params)
        body = json_response(conn, 422)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
        assert %{"error" => %{"code" => "invalid_credentials", "details" => details}} = body
        assert details == %{}
      end

      assert json(:post, "/api/auth/password/sign-in", %{email: address})
             |> error_code(422) == "validation_error"
    end

    test "throttled with retry-after" do
      {_user, address} = account!()

      for _ <- 1..5,
          do: json(:post, "/api/auth/password/sign-in", %{email: address, password: "nope nope"})

      conn = json(:post, "/api/auth/password/sign-in", %{email: address, password: @password})
      assert error_code(conn, 429) == "rate_limited"
      assert [_seconds] = get_resp_header(conn, "retry-after")
    end
  end

  describe "password set and reset" do
    test "202 for any address; 204 with the code; code errors are catalogued" do
      address = address()
      {:ok, _} = Accounts.register_user(:email, address)

      body = json(:post, "/api/auth/password/reset", %{email: address}) |> json_response(202)
      assert_schema(body, "PasswordResetAccepted", ApiSpec.spec())
      unknown = json(:post, "/api/auth/password/reset", %{email: address()}) |> json_response(202)
      assert Map.keys(unknown) == Map.keys(body)

      code = code_from(last_email_to(address))
      bad = if code == "000000", do: "000001", else: "000000"

      assert json(:post, "/api/auth/password/reset/confirm", %{
               email: address,
               code: bad,
               password: @password
             })
             |> error_code(422) == "code_invalid"

      weak =
        json(:post, "/api/auth/password/reset/confirm", %{
          email: address,
          code: code,
          password: "short"
        })
        |> json_response(422)

      assert %{
               "error" => %{
                 "code" => "validation_error",
                 "details" => %{"fields" => %{"password" => _}}
               }
             } =
               weak

      assert json(:post, "/api/auth/password/reset/confirm", %{
               email: address,
               code: code,
               password: @password
             }).status == 204

      assert json(:post, "/api/auth/password/reset/confirm", %{
               email: address,
               code: code,
               password: @password
             })
             |> error_code(422) == "code_expired"
    end
  end

  describe "/api/me/password" do
    test "status and change; the old password stops working" do
      {_user, address} = account!()
      token = sign_in!(address)

      status = json(:get, "/api/me/password", nil, token) |> json_response(200)
      assert_schema(status, "PasswordStatus", ApiSpec.spec())
      assert status == %{"password_set" => true}

      assert json(
               :put,
               "/api/me/password",
               %{current_password: "wrong wrong", password: "a brand new passphrase"},
               token
             )
             |> error_code(422) == "invalid_credentials"

      assert json(
               :put,
               "/api/me/password",
               %{current_password: @password, password: "a brand new passphrase"},
               token
             ).status ==
               204

      # This session stays.
      assert json(:get, "/api/me/password", nil, token) |> json_response(200)
      reset_rate_limits()

      assert json(:post, "/api/auth/password/sign-in", %{email: address, password: @password})
             |> error_code(422) == "invalid_credentials"
    end

    test "401 without a session; password_not_set without a password" do
      assert json(:get, "/api/me/password", nil) |> error_code(401) == "unauthorized"

      {:ok, user} = Accounts.register_user(:email, address())
      {:ok, %{access_token: token}} = Accounts.create_session(user)

      assert json(:get, "/api/me/password", nil, token) |> json_response(200) == %{
               "password_set" => false
             }

      assert json(
               :put,
               "/api/me/password",
               %{current_password: "anything at all", password: "a brand new passphrase"},
               token
             )
             |> error_code(409) == "password_not_set"
    end
  end

  describe "a password session in the Control Plane (authorization stays the operator's)" do
    test "an account that isn't an operator gets the one not_found answer" do
      {_user, address} = account!()
      token = sign_in!(address)
      assert json(:get, "/api/v1/admin/me", nil, token) |> error_code(404) == "not_found"
      assert json(:get, "/api/v1/admin/operators", nil, token) |> error_code(404) == "not_found"
      assert Repo.aggregate(Operator, :count) == 0
    end

    test "an operator reads at session assurance, but acting needs keys, then a key check" do
      {user, address} = account!()
      operator = bootstrap!(user)
      token = sign_in!(address)

      me = json(:get, "/api/v1/admin/me", nil, token) |> json_response(200)

      assert %{"status" => "pending_enrollment", "permissions" => [_ | _], "step_up" => nil} =
               me["operator"]

      assert json(:get, "/api/v1/admin/operators", nil, token) |> json_response(200)

      {other, _} = account!()

      provision =
        Map.merge(op("new_reviewer"), %{"user_id" => other.id, "permissions" => ["audit.read"]})

      assert json(:post, "/api/v1/admin/operators", provision, token) |> error_code(403) ==
               "enrollment_required"

      # Revoking a permission ends what it allowed, in the same session.
      Repo.update_all(
        from(g in Grant,
          where: g.operator_id == ^operator.id and g.permission == "operators.read"
        ),
        set: [revoked_at: DateTime.utc_now(), revoke_reason_code: "test"]
      )

      assert json(:get, "/api/v1/admin/operators", nil, token) |> error_code(403) == "forbidden"
    end

    test "a revoked operator: not_found at once, whatever the sign-in" do
      {user, address} = account!()
      operator = bootstrap!(user)
      token = sign_in!(address)
      assert json(:get, "/api/v1/admin/me", nil, token) |> json_response(200)

      Repo.update_all(from(o in Operator, where: o.id == ^operator.id),
        set: [status: :revoked, revoked_at: DateTime.utc_now()]
      )

      assert json(:get, "/api/v1/admin/me", nil, token) |> error_code(404) == "not_found"

      assert json(:get, "/api/v1/admin/audit-events", nil, token) |> error_code(404) ==
               "not_found"

      # A new password sign-in changes nothing.
      reset_rate_limits()
      token = sign_in!(address)
      assert json(:get, "/api/v1/admin/me", nil, token) |> error_code(404) == "not_found"
    end
  end
end
