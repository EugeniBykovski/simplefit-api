defmodule SimpleFitWeb.OperatorControllerTest do
  @moduledoc """
  SF-110 operator API: concealment, the full HTTP journey with a software
  authenticator, error codes and OpenAPI conformance.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body || %{}))
      :delete -> delete(conn, path)
    end
  end

  defp options(body),
    do: %{
      challenge_id: body["challenge_id"],
      options: %{challenge: body["public_key"]["challenge"]}
    }

  defp enroll_http!(token, count \\ 2) do
    for _ <- 1..count do
      key = soft_key()
      body = call(:post, "/api/v1/admin/credentials/options", token, %{}) |> json_response(200)
      assert_schema(body, "WebAuthnOptionsResponse", ApiSpec.spec())
      assert body["public_key"]["authenticatorSelection"]["userVerification"] == "required"

      reg =
        call(:post, "/api/v1/admin/credentials", token, registration_response(key, options(body)))

      assert_schema(json_response(reg, 201), "OperatorCredentialRegistered", ApiSpec.spec())
      key
    end
  end

  defp step_up_http!(token, key) do
    body = call(:post, "/api/v1/admin/step-up/options", token, %{}) |> json_response(200)
    {response, key} = assertion_response(key, options(body))
    verified = call(:post, "/api/v1/admin/step-up", token, response) |> json_response(200)
    assert_schema(verified, "OperatorStepUpResponse", ApiSpec.spec())
    key
  end

  @paths [
    {:get, "/api/v1/admin/me"},
    {:get, "/api/v1/admin/credentials"},
    {:post, "/api/v1/admin/credentials/options"},
    {:post, "/api/v1/admin/step-up/options"},
    {:get, "/api/v1/admin/operators"},
    {:post, "/api/v1/admin/operators"},
    {:get, "/api/v1/admin/audit-events"}
  ]

  test "an account without an operator gets the same not_found everywhere" do
    token = token!(registered!("plain"))

    bodies =
      for {method, path} <- @paths do
        conn = call(method, path, token, if(method == :post, do: %{}))
        body = json_response(conn, 404)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
        Map.delete(body["error"], "request_id")
      end

    assert Enum.uniq(bodies) == [
             %{
               "code" => "not_found",
               "message" => "The requested resource was not found",
               "details" => %{}
             }
           ]
  end

  test "no session is 401" do
    assert build_conn() |> get("/api/v1/admin/me") |> json_response(401)
  end

  test "the founder journey over HTTP" do
    founder = registered!("founder")
    token = token!(founder)
    bootstrap!(founder)

    me = call(:get, "/api/v1/admin/me", token) |> json_response(200)
    assert_schema(me, "OperatorSelfResponse", ApiSpec.spec())

    assert %{
             "status" => "pending_enrollment",
             "permissions" => [],
             "security_keys" => %{"required" => 2}
           } = me["operator"]

    assert %{"error" => %{"code" => "enrollment_required"}} =
             call(:get, "/api/v1/admin/operators", token) |> json_response(403)

    [key | _] = enroll_http!(token)

    assert %{"operator" => %{"status" => "active", "step_up" => nil}} =
             call(:get, "/api/v1/admin/me", token) |> json_response(200)

    assert %{"error" => %{"code" => "step_up_required"}} =
             call(:get, "/api/v1/admin/operators", token) |> json_response(403)

    _key = step_up_http!(token, key)
    list = call(:get, "/api/v1/admin/operators", token) |> json_response(200)
    assert_schema(list, "OperatorListResponse", ApiSpec.spec())

    second = registered!("second")
    second_token = token!(second)

    provisioned =
      call(
        :post,
        "/api/v1/admin/operators",
        token,
        Map.merge(op("new_reviewer"), %{
          "user_id" => second.id,
          "permissions" => ["operators.read"]
        })
      )
      |> json_response(200)

    assert_schema(provisioned, "OperatorSummaryResponse", ApiSpec.spec())
    id = provisioned["operator"]["id"]

    [second_key | _] = enroll_http!(second_token)
    _ = step_up_http!(second_token, second_key)
    assert call(:get, "/api/v1/admin/operators", second_token) |> json_response(200)

    assert %{"error" => %{"code" => "forbidden"}} =
             call(
               :post,
               "/api/v1/admin/operators/#{id}/permissions",
               second_token,
               Map.put(op(), "permission", "operators.manage")
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             call(:get, "/api/v1/admin/audit-events", second_token) |> json_response(403)

    revoked =
      call(:post, "/api/v1/admin/operators/#{id}/revoke", token, op("left_company"))
      |> json_response(200)

    assert revoked["operator"]["status"] == "revoked"
    assert call(:get, "/api/v1/admin/operators", second_token) |> json_response(404)

    events = call(:get, "/api/v1/admin/audit-events?limit=100", token) |> json_response(200)
    assert_schema(events, "OperatorAuditEventListResponse", ApiSpec.spec())
    actions = Enum.map(events["events"], & &1["action"])

    assert "operator.revoked" in actions and "operator.provisioned" in actions and
             "operator.bootstrap" in actions
  end

  test "signing out ends operator access with the session" do
    founder = registered!("founder")
    {:ok, credentials} = Accounts.create_session(founder)
    bootstrap!(founder)
    [key | _] = enroll_http!(credentials.access_token)
    _ = step_up_http!(credentials.access_token, key)
    assert call(:get, "/api/v1/admin/operators", credentials.access_token) |> json_response(200)

    :ok = Accounts.revoke_session({:refresh, credentials.refresh_token})
    assert call(:get, "/api/v1/admin/operators", credentials.access_token) |> json_response(401)
  end

  test "malformed requests are validation errors, never a pass" do
    founder = registered!("founder")
    token = token!(founder)
    bootstrap!(founder)
    [key | _] = enroll_http!(token)
    _ = step_up_http!(token, key)

    body =
      call(:post, "/api/v1/admin/operators", token, %{
        "user_id" => "someone@example.com",
        "permissions" => ["*"]
      })
      |> json_response(422)

    assert_schema(body, "ErrorResponse", ApiSpec.spec())

    assert %{"error" => %{"code" => "security_key_rejected"}} =
             call(:post, "/api/v1/admin/step-up", token, %{
               "challenge_id" => Ecto.UUID.generate(),
               "credential_id" => "AA",
               "authenticator_data" => "AA",
               "client_data_json" => "AA",
               "signature" => "AA"
             })
             |> json_response(422)
  end
end
