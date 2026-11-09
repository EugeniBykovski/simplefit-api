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
    {:get, "/api/v1/admin/audit-events"},
    {:get, "/api/v1/admin/audit-events/#{Ecto.UUID.generate()}"},
    {:post, "/api/v1/admin/operators/#{Ecto.UUID.generate()}/suspend/preview"},
    {:post, "/api/v1/admin/operators/#{Ecto.UUID.generate()}/suspend"},
    {:post, "/api/v1/admin/operators/#{Ecto.UUID.generate()}/permissions/preview"},
    {:post,
     "/api/v1/admin/operators/#{Ecto.UUID.generate()}/permissions/audit.read/revoke/preview"}
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
               "/api/v1/admin/operators/#{id}/permissions/preview",
               second_token,
               %{"permission" => "operators.manage", "reason_code" => "role_change"}
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             call(
               :post,
               "/api/v1/admin/operators/#{id}/permissions",
               second_token,
               Map.merge(op("role_change"), %{
                 "permission" => "operators.manage",
                 "expected_revision" => 1
               })
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             call(:get, "/api/v1/admin/audit-events", second_token) |> json_response(403)

    preview =
      call(:post, "/api/v1/admin/operators/#{id}/revoke/preview", token, %{
        "reason_code" => "left_organization"
      })
      |> json_response(200)

    assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())

    revoked =
      call(
        :post,
        "/api/v1/admin/operators/#{id}/revoke",
        token,
        Map.merge(op("left_organization"), %{
          "expected_revision" => preview["preview"]["expected_revision"],
          "confirmation_token" => preview["preview"]["confirmation"]["token"]
        })
      )
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

  describe "admin actions over HTTP (SF-111)" do
    setup do
      founder = registered!("founder")
      token = token!(founder)
      bootstrap!(founder)
      [key | _] = enroll_http!(token)
      _ = step_up_http!(token, key)

      second = registered!("second")

      provisioned =
        call(
          :post,
          "/api/v1/admin/operators",
          token,
          Map.merge(op(), %{"user_id" => second.id, "permissions" => ["operators.read"]})
        )
        |> json_response(200)

      %{token: token, id: provisioned["operator"]["id"]}
    end

    test "preview, confirm and execute; the envelopes of every refusal", c do
      # Pending operators can't be suspended: the state conflict shows in the preview.
      assert %{"error" => %{"code" => "conflict", "details" => %{"status" => "not_active"}}} =
               call(:post, "/api/v1/admin/operators/#{c.id}/suspend/preview", c.token, %{
                 "reason_code" => "security_concern"
               })
               |> json_response(409)

      path = "/api/v1/admin/operators/#{c.id}/revoke"

      preview =
        call(:post, path <> "/preview", c.token, %{"reason_code" => "left_organization"})
        |> json_response(200)

      assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())
      p = preview["preview"]
      assert %{"current_state" => "pending_enrollment"} = p

      body =
        Map.merge(op("left_organization"), %{
          "expected_revision" => p["expected_revision"],
          "confirmation_token" => p["confirmation"]["token"]
        })

      missing = call(:post, path, c.token, Map.delete(body, "confirmation_token"))
      assert %{"error" => %{"code" => "confirmation_required"}} = json_response(missing, 428)
      assert_schema(json_response(missing, 428), "ErrorResponse", ApiSpec.spec())

      stale = call(:post, path, c.token, %{body | "expected_revision" => 99})

      assert %{"error" => %{"code" => "revision_conflict", "details" => details}} =
               json_response(stale, 409)

      assert details == %{"current_revision" => p["expected_revision"]}

      wrong = call(:post, path, c.token, %{body | "confirmation_token" => "sfc_nope"})
      assert %{"error" => %{"code" => "confirmation_invalid"}} = json_response(wrong, 422)

      canary = "CANARY-sf111-http"

      invalid =
        call(:post, path, c.token, %{body | "reason_code" => canary}) |> json_response(422)

      assert %{"error" => %{"code" => "validation_error"}} = invalid
      refute Jason.encode!(invalid) =~ canary

      revoked = call(:post, path, c.token, body) |> json_response(200)
      assert_schema(revoked, "OperatorSummaryResponse", ApiSpec.spec())
      assert revoked["operator"]["status"] == "revoked"

      replayed = %{
        body
        | "operation_id" => Ecto.UUID.generate(),
          "expected_revision" => revoked["operator"]["revision"]
      }

      assert %{"error" => %{"code" => "confirmation_invalid"}} =
               call(:post, path, c.token, replayed) |> json_response(422)
    end

    test "grant, then an identical retry: one change, the same answer", c do
      p =
        call(:post, "/api/v1/admin/operators/#{c.id}/permissions/preview", c.token, %{
          "permission" => "audit.read",
          "reason_code" => "access_request_approved"
        })
        |> json_response(200)
        |> Map.fetch!("preview")

      body =
        Map.merge(op("access_request_approved"), %{
          "permission" => "audit.read",
          "expected_revision" => p["expected_revision"],
          "confirmation_token" => p["confirmation"]["token"]
        })

      first =
        call(:post, "/api/v1/admin/operators/#{c.id}/permissions", c.token, body)
        |> json_response(200)

      assert_schema(first, "OperatorSummaryResponse", ApiSpec.spec())
      assert first["operator"]["permissions"] == ["audit.read", "operators.read"]
      assert first["operator"]["revision"] > p["expected_revision"]

      assert call(:post, "/api/v1/admin/operators/#{c.id}/permissions", c.token, body)
             |> json_response(200) == first
    end

    test "audit log: filters, cursor pages, detail, tampering", c do
      list =
        call(:get, "/api/v1/admin/audit-events?limit=2&command=audit.events", c.token)
        |> json_response(200)

      assert_schema(list, "OperatorAuditEventListResponse", ApiSpec.spec())

      page =
        call(:get, "/api/v1/admin/audit-events?limit=1", c.token)
        |> json_response(200)

      assert [event] = page["events"]
      assert is_binary(page["next_cursor"])

      next =
        call(
          :get,
          "/api/v1/admin/audit-events?limit=1&cursor=#{URI.encode_www_form(page["next_cursor"])}",
          c.token
        )
        |> json_response(200)

      refute hd(next["events"])["id"] == event["id"]

      detail =
        call(:get, "/api/v1/admin/audit-events/#{event["id"]}", c.token) |> json_response(200)

      assert_schema(detail, "OperatorAuditEventResponse", ApiSpec.spec())
      assert detail["event"]["id"] == event["id"]

      refused =
        call(
          :get,
          "/api/v1/admin/audit-events?limit=1&outcome=refused&cursor=#{URI.encode_www_form(page["next_cursor"])}",
          c.token
        )
        |> json_response(422)

      assert %{"error" => %{"details" => %{"field_codes" => %{"cursor" => ["invalid_format"]}}}} =
               refused
    end
  end
end
