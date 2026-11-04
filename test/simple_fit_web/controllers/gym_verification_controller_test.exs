defmodule SimpleFitWeb.GymVerificationControllerTest do
  @moduledoc """
  Gym business verification and go-live readiness over HTTP (SF-103):
  `getGymBusinessVerification`, `saveGymBusinessVerification`,
  `submitGymBusinessVerification`, `createGymVerificationEvidence`,
  `confirmGymVerificationEvidence`, `removeGymVerificationEvidence` and
  `getGymGoLive`. OpenAPI schemas, `no-store`, and 200 / 201 / 401 / 403 /
  404 / 409 / 422 / 429 / 503. No endpoint decides or publishes.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Gyms.{VerificationApplication, VerificationReview}
  alias SimpleFitWeb.ApiSpec

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp verification(conn, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, "GymBusinessVerificationResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["verification"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp vpath(gym_id, suffix \\ ""), do: "/api/v1/gyms/#{gym_id}/business-verification#{suffix}"

  setup do
    Repo.delete_all("rate_limit_events")
    stub_storage(%{})
    owner = registered!("kyb-http")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, token: token(owner)}
  end

  test "the owner's journey: draft, document, submit; an operator approves outside the API",
       ctx do
    initial = ctx.token |> authed() |> get(vpath(ctx.gym.id)) |> verification()

    assert %{
             "status" => "not_started",
             "application" => nil,
             "evidence" => [],
             "latest_decision" => nil,
             "can_edit" => true,
             "can_submit" => false,
             "missing" => ["legal_name", "registration_country", "evidence"],
             "requirements" => %{"policy_version" => "sf103-generic-1", "min_evidence" => 1}
           } = initial

    draft =
      ctx.token
      |> authed()
      |> put(vpath(ctx.gym.id), Jason.encode!(details()))
      |> verification(201)

    assert %{
             "status" => "draft",
             "application" => %{"revision" => 1, "registration_country" => "PL"}
           } =
             draft

    announced =
      ctx.token
      |> authed()
      |> post(
        vpath(ctx.gym.id, "/evidence"),
        Jason.encode!(%{
          revision: 1,
          kind: "registration_extract",
          file_name: "extract.pdf",
          content_type: "application/pdf",
          byte_size: 2048
        })
      )
      |> json_response(201)

    assert_schema(announced, "GymVerificationEvidenceResponse", ApiSpec.spec())
    assert %{"method" => "PUT", "headers" => %{"content-length" => "2048"}} = announced["upload"]
    assert %{"status" => "pending_upload", "id" => evidence_id} = announced["evidence"]
    refute Map.has_key?(announced["evidence"], "object_key")

    stub_storage(%{evidence_id => {2048, "application/pdf"}})

    confirmed =
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/evidence/#{evidence_id}/confirm"))
      |> verification()

    assert %{"can_submit" => true, "evidence" => [%{"status" => "uploaded"}]} = confirmed
    revision = confirmed["application"]["revision"]

    submitted =
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/submit"), Jason.encode!(%{revision: revision}))
      |> verification()

    assert %{"status" => "submitted", "evidence" => [%{"submitted" => true}]} = submitted

    {:ok, _} =
      VerificationReview.decide(submitted["application"]["id"], :approved,
        revision: revision,
        operator: operator()
      )

    approved = ctx.token |> authed() |> get(vpath(ctx.gym.id)) |> verification()

    assert %{
             "status" => "approved",
             "latest_decision" => %{"decision" => "approved", "reason_code" => nil}
           } = approved

    refute inspect(approved) =~ operator()
  end

  test "an owner cannot approve: status fields are refused and no decision route exists", ctx do
    for body <- [%{status: "approved"}, %{verified: true}, %{decided_at: "2026-01-01T00:00:00Z"}] do
      ctx.token
      |> authed()
      |> put(vpath(ctx.gym.id), Jason.encode!(body))
      |> error(422, "validation_error")
    end

    for suffix <- ["/approve", "/decide", "/review"] do
      ctx.token |> authed() |> post(vpath(ctx.gym.id, suffix), "{}") |> error(404, "not_found")
    end

    assert Repo.aggregate(VerificationApplication, :count) == 0
  end

  test "conflicts: stale revision, frozen application, missing upload", ctx do
    ctx.token |> authed() |> put(vpath(ctx.gym.id), Jason.encode!(details())) |> verification(201)

    stale =
      ctx.token
      |> authed()
      |> put(vpath(ctx.gym.id), Jason.encode!(%{revision: 7, city: "Gdańsk"}))
      |> error(409, "conflict")

    assert stale["details"] == %{"revision" => "stale", "current_revision" => 1}

    announced =
      ctx.token
      |> authed()
      |> post(
        vpath(ctx.gym.id, "/evidence"),
        Jason.encode!(%{
          revision: 1,
          kind: "other",
          file_name: "a.png",
          content_type: "image/png",
          byte_size: 10
        })
      )
      |> json_response(201)

    missing =
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/evidence/#{announced["evidence"]["id"]}/confirm"))
      |> error(409, "conflict")

    assert missing["details"] == %{"upload" => "not_found"}

    pending =
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/submit"), Jason.encode!(%{revision: 2}))
      |> error(409, "conflict")

    assert pending["details"] == %{"evidence" => "upload_pending"}

    Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 500, ""))

    ExUnit.CaptureLog.capture_log(fn ->
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/evidence/#{announced["evidence"]["id"]}/confirm"))
      |> error(503, "service_unavailable")
    end)
  end

  test "validation: incomplete submission and documents outside the policy", ctx do
    ctx.token
    |> authed()
    |> put(vpath(ctx.gym.id), Jason.encode!(%{city: "Warszawa"}))
    |> verification(201)

    incomplete =
      ctx.token
      |> authed()
      |> post(vpath(ctx.gym.id, "/submit"), Jason.encode!(%{revision: 1}))
      |> error(422, "validation_error")

    assert Map.keys(incomplete["details"]["fields"]) |> Enum.sort() ==
             ["evidence", "legal_name", "registration_country"]

    ctx.token
    |> authed()
    |> post(
      vpath(ctx.gym.id, "/evidence"),
      Jason.encode!(%{
        revision: 1,
        kind: "other",
        file_name: "x.svg",
        content_type: "image/svg+xml",
        byte_size: 10
      })
    )
    |> error(422, "validation_error")
  end

  test "authorization: 401, 403 for staff, 404 for outsiders and other gyms", ctx do
    {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
    stranger = registered!("kyb-http-stranger")

    build_conn() |> get(vpath(ctx.gym.id)) |> error(401, "unauthorized")
    token(manager) |> authed() |> get(vpath(ctx.gym.id)) |> error(403, "forbidden")

    token(manager)
    |> authed()
    |> put(vpath(ctx.gym.id), Jason.encode!(details()))
    |> error(403, "forbidden")

    token(stranger) |> authed() |> get(vpath(ctx.gym.id)) |> error(404, "not_found")
    ctx.token |> authed() |> get(vpath(Ecto.UUID.generate())) |> error(404, "not_found")

    ctx.token
    |> authed()
    |> post(vpath(ctx.gym.id, "/evidence/#{Ecto.UUID.generate()}/confirm"))
    |> error(404, "not_found")
  end

  test "writes are rate limited per user", ctx do
    ctx.token |> authed() |> put(vpath(ctx.gym.id), Jason.encode!(details())) |> verification(201)

    for revision <- 1..59 do
      ctx.token
      |> authed()
      |> put(vpath(ctx.gym.id), Jason.encode!(%{revision: revision, city: "City #{revision}"}))
      |> verification()
    end

    conn =
      ctx.token
      |> authed()
      |> put(vpath(ctx.gym.id), Jason.encode!(%{revision: 60, city: "Too many"}))

    error(conn, 429, "rate_limited")
    assert [_] = get_resp_header(conn, "retry-after")
  end

  describe "getGymGoLive" do
    test "the readiness checklist; publication is unavailable", ctx do
      conn = ctx.token |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}/go-live")
      body = json_response(conn, 200)
      assert_schema(body, "GymGoLiveResponse", ApiSpec.spec())
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "prerequisites_met" => false,
               "policy_version" => "sf103-golive-1",
               "publication" => %{"status" => "unavailable"},
               "checks" => [%{"key" => "setup_completed", "status" => "passed"} | _]
             } = body["go_live"]

      verification_check =
        Enum.find(body["go_live"]["checks"], &(&1["key"] == "business_verification"))

      assert verification_check == %{
               "key" => "business_verification",
               "status" => "failed",
               "requiredness" => "required",
               "reason_code" => "not_started",
               "action" => "open_verification",
               "source" => "business_verification"
             }
    end

    test "managers read it; coaches are forbidden; outsiders get 404", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Cody Coach")

      token(manager)
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/go-live")
      |> json_response(200)

      token(coach)
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/go-live")
      |> error(403, "forbidden")

      token(registered!("kyb-out"))
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/go-live")
      |> error(404, "not_found")
    end
  end
end
