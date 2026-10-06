defmodule SimpleFitWeb.EmailAuthControllerTest do
  # Not async: some tests switch the trusted-proxy configuration.
  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.Session
  alias SimpleFit.Repo
  alias SimpleFitWeb.{ApiSpec, ClientIP, SessionTransport}

  @origin "http://localhost:3000"

  defp json_post(conn \\ build_conn(), path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp cookie_headers(conn) do
    conn
    |> put_req_header("origin", @origin)
    |> put_req_header("x-simplefit-csrf", "1")
  end

  defp start_registration(email) do
    body = json_post(~p"/api/auth/email/registrations", %{email: email}) |> json_response(202)
    {body["registration_token"], last_email_to(email)}
  end

  defp registered(email) do
    {token, message} = start_registration(email)

    json_post(~p"/api/auth/email/registrations/verify", %{
      registration_token: token,
      code: code_from(message)
    })
    |> json_response(200)

    reset_rate_limits()
  end

  defp error_code(conn, status), do: get_in(json_response(conn, status), ["error", "code"])

  defp with_hops(hops) do
    original = Application.get_env(:simple_fit, ClientIP)
    Application.put_env(:simple_fit, ClientIP, trusted_proxy_hops: hops)
    on_exit(fn -> Application.put_env(:simple_fit, ClientIP, original) end)
  end

  describe "POST /api/auth/email/registrations" do
    test "202 with a registration token; E01 is queued", %{conn: conn} do
      conn = json_post(conn, ~p"/api/auth/email/registrations", %{email: "new@example.com"})
      body = json_response(conn, 202)

      assert_schema(body, "EmailRegistrationAccepted", ApiSpec.spec())
      assert %{"expires_in_seconds" => 600, "resend_after_seconds" => 60} = body
      assert [_e01] = emails_to("new@example.com")
    end

    test "an existing account gets the same response, and nothing is sent" do
      registered("member@example.com")
      sent = length(queued_emails())

      new = json_post(~p"/api/auth/email/registrations", %{email: "new@example.com"})
      existing = json_post(~p"/api/auth/email/registrations", %{email: "member@example.com"})

      assert new.status == existing.status
      assert Map.keys(json_response(new, 202)) == Map.keys(json_response(existing, 202))
      assert length(queued_emails()) == sent + 1
    end

    test "malformed input is a validation error" do
      conn = json_post(~p"/api/auth/email/registrations", %{email: "nope"})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_error"
      assert body["error"]["details"]["fields"] == %{"email" => ["is not a valid email address"]}
      refute conn.resp_body =~ "nope"
    end

    test "a second request within a minute is rate limited with retry-after" do
      json_post(~p"/api/auth/email/registrations", %{email: "new@example.com"})
      conn = json_post(~p"/api/auth/email/registrations", %{email: "new@example.com"})

      assert error_code(conn, 429) == "rate_limited"
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) in 1..60
    end
  end

  describe "POST /api/auth/email/registrations/verify" do
    test "body transport: the registration's session", %{conn: conn} do
      {token, message} = start_registration("fighter@example.com")

      conn =
        json_post(conn, ~p"/api/auth/email/registrations/verify", %{
          registration_token: token,
          code: code_from(message)
        })

      body = json_response(conn, 200)
      assert_schema(body, "SessionTokens", ApiSpec.spec())
      assert %{"refresh_token_transport" => "body", "refresh_token" => "sfr_" <> _} = body
      assert {:ok, _viewer} = Accounts.authenticate_access_token(body["access_token"])
    end

    test "cookie transport sets the refresh cookie and requires the CSRF proof" do
      {token, message} = start_registration("fighter@example.com")

      params = %{
        registration_token: token,
        code: code_from(message),
        refresh_token_transport: "cookie"
      }

      # Without Origin and the CSRF header nothing is verified.
      forbidden = json_post(~p"/api/auth/email/registrations/verify", params)
      assert error_code(forbidden, 403) == "forbidden"
      assert {:ok, :pending} = Accounts.email_registration_status(token, "127.0.0.1")

      conn =
        json_post(cookie_headers(build_conn()), ~p"/api/auth/email/registrations/verify", params)

      body = json_response(conn, 200)

      assert %{"refresh_token_transport" => "cookie"} = body
      refute Map.has_key?(body, "refresh_token")

      assert %{value: "sfr_" <> _, http_only: true} =
               conn.resp_cookies[SessionTransport.cookie_name()]

      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    end

    test "maps every outcome to a catalogued code" do
      {token, message} = start_registration("fighter@example.com")
      code = code_from(message)
      bad = if code == "000000", do: "000001", else: "000000"

      verify = fn params -> json_post(~p"/api/auth/email/registrations/verify", params) end

      assert error_code(verify.(%{registration_token: token, code: bad}), 422) == "code_invalid"

      assert error_code(
               verify.(%{registration_token: token, code: code, refresh_token_transport: "x"}),
               400
             ) ==
               "bad_request"

      assert error_code(verify.(%{registration_token: token, code: "12"}), 422) ==
               "validation_error"

      assert error_code(verify.(%{registration_token: "sfg_unknown", code: code}), 422) ==
               "code_expired"

      # Verified through the link: this client must sign in.
      json_post(~p"/api/auth/email/verification-links/verify", %{token: link_token_from(message)})
      elsewhere = verify.(%{registration_token: token, code: code})
      assert error_code(elsewhere, 409) == "verified_elsewhere"
      assert Repo.aggregate(Session, :count) == 0
    end

    test "conflict when the address was taken during the registration" do
      {token, message} = start_registration("taken@example.com")
      {:ok, _owner} = Accounts.register_user(:email, "taken@example.com")

      conn =
        json_post(~p"/api/auth/email/registrations/verify", %{
          registration_token: token,
          code: code_from(message)
        })

      assert error_code(conn, 409) == "conflict"
    end
  end

  describe "POST /api/auth/email/registrations/status and /verification-links/verify" do
    test "the link verifies without any session; the registration sees verified_elsewhere" do
      {token, message} = start_registration("fighter@example.com")

      pending = json_post(~p"/api/auth/email/registrations/status", %{registration_token: token})
      assert json_response(pending, 200) == %{"status" => "pending"}
      assert_schema(json_response(pending, 200), "EmailRegistrationStatus", ApiSpec.spec())

      link =
        json_post(~p"/api/auth/email/verification-links/verify", %{
          token: link_token_from(message)
        })

      assert json_response(link, 200) == %{"status" => "verified"}
      assert_schema(json_response(link, 200), "EmailVerificationLinkResult", ApiSpec.spec())
      assert get_resp_header(link, "set-cookie") == []
      refute link.resp_body =~ "sfa_"
      assert Repo.aggregate(Session, :count) == 0

      again =
        json_post(~p"/api/auth/email/verification-links/verify", %{
          token: link_token_from(message)
        })

      assert json_response(again, 200) == %{"status" => "already_verified"}

      status = json_post(~p"/api/auth/email/registrations/status", %{registration_token: token})
      assert json_response(status, 200) == %{"status" => "verified_elsewhere"}
    end

    test "an expired link is code_expired" do
      {_token, message} = start_registration("fighter@example.com")
      expire_challenges()

      conn =
        json_post(~p"/api/auth/email/verification-links/verify", %{
          token: link_token_from(message)
        })

      assert error_code(conn, 422) == "code_expired"
    end
  end

  describe "POST /api/auth/email/sign-in and /sign-in/verify" do
    test "identical responses for existing and unknown addresses; E17 only to the account" do
      registered("member@example.com")

      existing = json_post(~p"/api/auth/email/sign-in", %{email: "member@example.com"})
      unknown = json_post(~p"/api/auth/email/sign-in", %{email: "nobody@example.com"})

      assert json_response(existing, 202) == json_response(unknown, 202)
      assert_schema(json_response(existing, 202), "EmailSignInAccepted", ApiSpec.spec())
      assert emails_to("nobody@example.com") == []
      assert last_email_to("member@example.com").subject =~ "sign-in code"
    end

    test "a correct code starts a session (cookie transport)" do
      registered("member@example.com")
      json_post(~p"/api/auth/email/sign-in", %{email: "member@example.com"})
      code = code_from(last_email_to("member@example.com"))

      conn =
        json_post(cookie_headers(build_conn()), ~p"/api/auth/email/sign-in/verify", %{
          email: "member@example.com",
          code: code,
          refresh_token_transport: "cookie"
        })

      assert %{"refresh_token_transport" => "cookie"} = json_response(conn, 200)
      assert conn.resp_cookies[SessionTransport.cookie_name()]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

      replay =
        json_post(~p"/api/auth/email/sign-in/verify", %{email: "member@example.com", code: code})

      assert error_code(replay, 422) == "code_expired"
    end

    test "wrong codes are code_invalid and never echo the input" do
      conn =
        json_post(~p"/api/auth/email/sign-in/verify", %{
          email: "nobody@example.com",
          code: "123456"
        })

      assert error_code(conn, 422) == "code_invalid"
      refute conn.resp_body =~ "123456"
      refute conn.resp_body =~ "nobody@example.com"
    end
  end

  describe "client IP for rate limits" do
    test "TRUSTED_PROXY_HOPS=0 ignores X-Forwarded-For: spoofing never resets the IP limit" do
      for n <- 1..20 do
        conn =
          build_conn()
          |> put_req_header("x-forwarded-for", "10.0.0.#{n}")
          |> json_post(~p"/api/auth/email/sign-in", %{email: "user#{n}@example.com"})

        assert conn.status == 202
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.9.9.9")
        |> json_post(~p"/api/auth/email/sign-in", %{email: "user21@example.com"})

      assert error_code(conn, 429) == "rate_limited"
    end

    test "with one trusted hop, the address the proxy appended is the client" do
      with_hops(1)

      for n <- 1..20 do
        build_conn()
        |> put_req_header("x-forwarded-for", "6.6.6.6, 198.51.100.77")
        |> json_post(~p"/api/auth/email/sign-in", %{email: "user#{n}@example.com"})
      end

      limited =
        build_conn()
        |> put_req_header("x-forwarded-for", "7.7.7.7, 198.51.100.77")
        |> json_post(~p"/api/auth/email/sign-in", %{email: "user21@example.com"})

      assert error_code(limited, 429) == "rate_limited"

      other_client =
        build_conn()
        |> put_req_header("x-forwarded-for", "6.6.6.6, 198.51.100.78")
        |> json_post(~p"/api/auth/email/sign-in", %{email: "user22@example.com"})

      assert other_client.status == 202
    end

    test "ClientIP.get/1 and parse_hops!/1" do
      conn = %{build_conn() | remote_ip: {192, 0, 2, 1}}
      conn = put_req_header(conn, "x-forwarded-for", "203.0.113.9")
      assert ClientIP.get(conn) == "192.0.2.1"

      with_hops(1)
      assert ClientIP.get(conn) == "203.0.113.9"
      assert ClientIP.get(put_req_header(conn, "x-forwarded-for", "garbage")) == "192.0.2.1"

      with_hops(2)
      assert ClientIP.get(put_req_header(conn, "x-forwarded-for", "203.0.113.9")) == "192.0.2.1"

      assert ClientIP.parse_hops!(nil) == 0
      assert ClientIP.parse_hops!(" 1 ") == 1
      assert_raise ArgumentError, fn -> ClientIP.parse_hops!("-1") end
      assert_raise ArgumentError, fn -> ClientIP.parse_hops!("one") end
      assert_raise ArgumentError, fn -> ClientIP.parse_hops!("6") end
    end
  end

  test "every email auth operation is in the OpenAPI contract, unversioned under /api/auth" do
    paths = ApiSpec.spec().paths

    for path <- [
          "/api/auth/email/registrations",
          "/api/auth/email/registrations/verify",
          "/api/auth/email/registrations/status",
          "/api/auth/email/verification-links/verify",
          "/api/auth/email/sign-in",
          "/api/auth/email/sign-in/verify"
        ] do
      assert %{post: %{operationId: _}} = Map.fetch!(paths, path)
    end

    refute Enum.any?(Map.keys(paths), &String.starts_with?(&1, "/api/v1/auth"))
  end
end
