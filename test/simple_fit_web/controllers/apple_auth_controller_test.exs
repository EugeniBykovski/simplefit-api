defmodule SimpleFitWeb.AppleAuthControllerTest do
  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.AppleTokens

  alias SimpleFit.Accounts
  alias SimpleFitWeb.{ApiSpec, SessionTransport}

  @origin "http://localhost:3000"

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp post_apple(conn \\ build_conn(), body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/auth/apple", Jason.encode!(body))
  end

  defp code(conn, status), do: get_in(json_response(conn, status), ["error", "code"])

  test "body transport (iOS): session in the body, account created then existing" do
    conn = post_apple(credential("000123.ios"))
    body = json_response(conn, 200)

    assert_schema(body, "AppleAuthResponse", ApiSpec.spec())

    assert %{
             "account" => "created",
             "refresh_token_transport" => "body",
             "refresh_token" => "sfr_" <> _
           } = body

    assert {:ok, _viewer} = Accounts.authenticate_access_token(body["access_token"])
    refute Map.has_key?(body, "email")

    again = post_apple(credential("000123.ios"))
    assert %{"account" => "existing"} = json_response(again, 200)
  end

  test "cookie transport (web): HttpOnly refresh cookie, CSRF proof first" do
    params =
      "000456.web"
      |> credential(%{"aud" => web_client()})
      |> Map.put(:refresh_token_transport, "cookie")

    forbidden = post_apple(params)
    assert code(forbidden, 403) == "forbidden"

    conn =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put_req_header("x-simplefit-csrf", "1")
      |> post_apple(params)

    body = json_response(conn, 200)
    assert_schema(body, "AppleAuthResponse", ApiSpec.spec())
    assert %{"refresh_token_transport" => "cookie", "account" => "created"} = body
    refute Map.has_key?(body, "refresh_token")

    assert %{value: "sfr_" <> _, http_only: true} =
             conn.resp_cookies[SessionTransport.cookie_name()]

    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "invalid credentials are one generic 401 with no detail" do
    raw = raw_nonce()

    for {token, nonce} <- [
          {"garbage", raw},
          {token(claims("1", raw, %{"iss" => "https://evil.example"})), raw},
          {token(claims("1", raw, %{"aud" => "com.other.app"})), raw},
          {token(claims("1", raw, %{"exp" => System.os_time(:second) - 600})), raw},
          {token(claims("1", raw)), raw_nonce()}
        ] do
      conn = post_apple(%{id_token: token, nonce: nonce})
      assert code(conn, 401) == "unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

      for detail <- ["issuer", "audience", "nonce", "expired", "apple"] do
        refute String.downcase(conn.resp_body) =~ detail
      end
    end
  end

  test "validation errors, outage and throttling" do
    assert code(post_apple(%{}), 422) == "validation_error"
    assert code(post_apple(%{id_token: 42, nonce: raw_nonce()}), 422) == "validation_error"

    missing_nonce = post_apple(%{id_token: credential("1").id_token})

    assert %{"error" => %{"code" => "validation_error", "details" => %{"fields" => fields}}} =
             json_response(missing_nonce, 422)

    assert Map.has_key?(fields, "nonce")

    assert code(post_apple(%{id_token: "x", nonce: "short"}), 422) == "validation_error"

    bad_transport = post_apple(Map.put(credential("1"), :refresh_token_transport, "x"))

    assert %{"error" => %{"details" => %{"fields" => %{"refresh_token_transport" => _}}}} =
             json_response(bad_transport, 422)

    reset()
    stub_jwks(self(), status: 503)
    assert code(post_apple(credential("1")), 503) == "service_unavailable"

    raw = raw_nonce()
    for _ <- 1..30, do: post_apple(%{id_token: "garbage", nonce: raw})
    limited = post_apple(%{id_token: "garbage", nonce: raw})
    assert code(limited, 429) == "rate_limited"
    assert [_seconds] = get_resp_header(limited, "retry-after")
  end

  test "is in the OpenAPI contract under /api/auth, with no callback and no real JWT example" do
    spec = ApiSpec.spec()
    assert %{post: %{operationId: "authenticateWithApple"}} = spec.paths["/api/auth/apple"]
    refute Enum.any?(Map.keys(spec.paths), &(&1 =~ ~r/callback|oauth/))
    refute File.read!(ApiSpec.artifact_path()) =~ ~r/eyJ[A-Za-z0-9_-]{10,}\./
  end
end
