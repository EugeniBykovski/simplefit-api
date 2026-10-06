defmodule SimpleFitWeb.GoogleAuthControllerTest do
  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.GoogleTokens

  alias SimpleFit.Accounts
  alias SimpleFitWeb.{ApiSpec, SessionTransport}

  @origin "http://localhost:3000"

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp post_google(conn \\ build_conn(), body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/auth/google", Jason.encode!(body))
  end

  defp code(conn, status), do: get_in(json_response(conn, status), ["error", "code"])

  test "body transport (mobile): session in the body, account created then existing" do
    conn = post_google(%{id_token: valid_token("314")})
    body = json_response(conn, 200)

    assert_schema(body, "GoogleAuthResponse", ApiSpec.spec())

    assert %{
             "account" => "created",
             "refresh_token_transport" => "body",
             "refresh_token" => "sfr_" <> _
           } = body

    assert {:ok, _viewer} = Accounts.authenticate_access_token(body["access_token"])
    refute Map.has_key?(body, "email")

    again = post_google(%{id_token: valid_token("314")})
    assert %{"account" => "existing"} = json_response(again, 200)
  end

  test "cookie transport (web): HttpOnly refresh cookie, CSRF proof first" do
    params = %{id_token: valid_token("271"), refresh_token_transport: "cookie"}

    forbidden = post_google(params)
    assert code(forbidden, 403) == "forbidden"

    conn =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put_req_header("x-simplefit-csrf", "1")
      |> post_google(params)

    body = json_response(conn, 200)
    assert %{"refresh_token_transport" => "cookie", "account" => "created"} = body
    refute Map.has_key?(body, "refresh_token")

    assert %{value: "sfr_" <> _, http_only: true} =
             conn.resp_cookies[SessionTransport.cookie_name()]

    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "invalid credentials are one generic 401 with no detail" do
    for token <- [
          "garbage",
          token(claims("1", %{"iss" => "https://evil.example"})),
          token(claims("1", %{"aud" => "9-x.apps.googleusercontent.com"})),
          token(claims("1", %{"exp" => System.os_time(:second) - 600}))
        ] do
      conn = post_google(%{id_token: token})
      assert code(conn, 401) == "unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      refute conn.resp_body =~ "issuer"
      refute conn.resp_body =~ "audience"
    end
  end

  test "validation errors, outage and throttling" do
    assert code(post_google(%{}), 422) == "validation_error"
    assert code(post_google(%{id_token: 42}), 422) == "validation_error"

    bad_transport = post_google(%{id_token: valid_token("1"), refresh_token_transport: "x"})

    assert %{"error" => %{"code" => "validation_error", "details" => %{"fields" => fields}}} =
             json_response(bad_transport, 422)

    assert Map.has_key?(fields, "refresh_token_transport")

    reset()
    stub_jwks(self(), status: 503)
    assert code(post_google(%{id_token: valid_token("1")}), 503) == "service_unavailable"

    for _ <- 1..30, do: post_google(%{id_token: "garbage"})
    limited = post_google(%{id_token: "garbage"})
    assert code(limited, 429) == "rate_limited"
    assert [_seconds] = get_resp_header(limited, "retry-after")
  end

  test "is in the OpenAPI contract under /api/auth, with no real JWT example" do
    spec = ApiSpec.spec()
    assert %{post: %{operationId: "authenticateWithGoogle"}} = spec.paths["/api/auth/google"]
    refute Enum.any?(Map.keys(spec.paths), &String.contains?(&1, "oauth"))
    refute File.read!(ApiSpec.artifact_path()) =~ ~r/eyJ[A-Za-z0-9_-]{10,}\./
  end
end
