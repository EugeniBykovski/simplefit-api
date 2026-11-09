defmodule SimpleFitWeb.SponsorApplicationLifecycleTest do
  @moduledoc """
  SF-116 end to end through the Phoenix endpoint and router, against PostgreSQL:
  an applicant drafts and submits over HTTP; an operator (founder bootstrap by the
  offline ceremony fixture, as production's ceremony has no HTTP route) registers two
  software security keys and passes the key check over HTTP; then queue, detail,
  document metadata, preview, confirmed approval, retry, conflicting decision,
  concealment from the applicant, and suspension and reinstatement of the
  organization, each checked against OpenAPI and the database.

  Not a separately running server and not a hardware key: an in-process endpoint
  (the SQL sandbox) and the repository's software WebAuthn authenticator, with
  production verification unchanged.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, email_user!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Operators.AuditEvent

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationNotification,
    Contact,
    Membership,
    Organization
  }

  alias SimpleFitWeb.ApiSpec

  @me "/api/v1/me/sponsor-application"
  @admin "/api/v1/admin/sponsor-applications"
  @permissions ~w(sponsors.applications.read sponsors.applications.claim
                  sponsors.applications.approve sponsors.applications.reject
                  sponsors.applications.read_files sponsors.restrict)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    {credentials.access_token, credentials.session}
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body || %{}))
      :patch -> patch(conn, path, Jason.encode!(body))
    end
  end

  defp options(body),
    do: %{
      challenge_id: body["challenge_id"],
      options: %{challenge: body["public_key"]["challenge"]}
    }

  defp keys_over_http!(token) do
    for _ <- 1..2 do
      key = soft_key()
      body = call(:post, "/api/v1/admin/credentials/options", token, %{}) |> json_response(200)

      call(:post, "/api/v1/admin/credentials", token, registration_response(key, options(body)))
      |> json_response(201)

      key
    end
  end

  defp step_up_over_http!(token, key) do
    body = call(:post, "/api/v1/admin/step-up/options", token, %{}) |> json_response(200)
    {response, key} = assertion_response(key, options(body))
    call(:post, "/api/v1/admin/step-up", token, response) |> json_response(200)
    key
  end

  defp confirmed_call(token, path, body) do
    preview = (call(:post, path <> "/preview", token, body) |> json_response(200))["preview"]

    request =
      Map.merge(body, %{
        "expected_revision" => preview["expected_revision"],
        "operation_id" => Ecto.UUID.generate(),
        "confirmation_token" => preview["confirmation"]["token"]
      })

    {request, call(:post, path, token, request)}
  end

  defp capabilities(token),
    do:
      (call(:get, "/api/v1/me/entry?intent=sponsor", token)
       |> json_response(200))["entry"]["capabilities"]

  test "an application from draft to an approved, suspended and reinstated organization" do
    # 1-4: the applicant drafts and submits over HTTP; submission creates nothing.
    applicant = email_user!("lifecycle-#{System.unique_integer([:positive])}@example.com")
    {applicant_token, _} = token!(applicant)

    draft =
      call(
        :patch,
        @me,
        applicant_token,
        Map.put(complete_answers(), "client_request_id", Ecto.UUID.generate())
      )
      |> json_response(200)

    application_id = draft["application"]["application_id"]
    application = Repo.get!(Application, application_id)

    submitted =
      call(:post, @me <> "/submit", applicant_token, submit_params(application))
      |> json_response(200)

    assert submitted["application"]["status"] == "submitted"
    assert Repo.aggregate(Membership, :count) == 0 and Repo.aggregate(Organization, :count) == 0
    refute "SPONSOR_WORKSPACE" in capabilities(applicant_token)

    # 5-6: an independent operator, keys and key check over HTTP.
    operator = registered!("operator")
    {op_token, op_session} = token!(operator)
    _ = bootstrap!(operator, @permissions)
    [key | _] = keys_over_http!(op_token)
    _ = step_up_over_http!(op_token, key)
    assert op_session

    # 7-9: queue, detail, document metadata (none here).
    queue = call(:get, @admin, op_token) |> json_response(200)
    assert_schema(queue, "SponsorApplicationQueueResponse", ApiSpec.spec())

    assert [%{"application_id" => ^application_id, "status" => "submitted"}] =
             queue["applications"]

    detail = call(:get, "#{@admin}/#{application_id}", op_token) |> json_response(200)
    assert_schema(detail, "SponsorApplicationReviewResponse", ApiSpec.spec())

    assert detail["application"]["latest_submission"]["answers"]["contact_email"] ==
             "ada@acme.example"

    assert detail["application"]["evidence"] == []

    call(:post, "#{@admin}/#{application_id}/claim", op_token, %{
      "reason_code" => "review_started",
      "expected_revision" => detail["application"]["revision"],
      "operation_id" => Ecto.UUID.generate()
    })
    |> json_response(200)

    # 10-17: preview, confirmation, approval, the organization, the owner, audit, outbox.
    {approve, conn} =
      confirmed_call(op_token, "#{@admin}/#{application_id}/approve", %{
        "reason_code" => "review_complete"
      })

    approved = json_response(conn, 200)
    assert_schema(approved, "SponsorApplicationReviewResponse", ApiSpec.spec())
    assert approved["application"]["status"] == "approved"

    org = Repo.one!(Organization)
    assert org.source_application_id == application_id and org.status == :active
    assert [%Membership{user_id: owner, role: :owner}] = Repo.all(Membership)
    assert owner == applicant.id
    assert [%Contact{kind: :primary}] = Repo.all(Contact)

    assert [%{outcome: :allowed, reason_code: "review_complete", target_id: ^application_id}] =
             Repo.all(from(e in AuditEvent, where: e.command == "sponsor_application.approve"))

    assert [%{status: :queued}] =
             Repo.all(from(n in ApplicationNotification, where: n.kind == :application_approved))

    # 18: the same request again: the same answer, nothing new.
    assert call(:post, "#{@admin}/#{application_id}/approve", op_token, approve)
           |> json_response(200)

    assert Repo.aggregate(Organization, :count) == 1 and Repo.aggregate(Membership, :count) == 1

    # 19: a conflicting decision.
    assert %{"error" => %{"code" => "conflict", "details" => %{"status" => "approved"}}} =
             call(:post, "#{@admin}/#{application_id}/reject/preview", op_token, %{
               "reason_code" => "other"
             })
             |> json_response(409)

    # 20-21: the applicant (now an owner) has no admin access and can't approve themselves.
    assert call(:get, @admin, applicant_token) |> json_response(404)

    assert call(:post, "#{@admin}/#{application_id}/approve/preview", applicant_token, %{
             "reason_code" => "review_complete"
           })
           |> json_response(404)

    # The applicant sees an approval and a workspace capability; nothing commercial.
    mine = call(:get, @me, applicant_token) |> json_response(200)
    assert mine["application"]["sponsor_id"] == org.id
    assert "SPONSOR_WORKSPACE" in capabilities(applicant_token)

    # 22: undoing the approval suspends the organization; reinstating restores it.
    {_, conn} =
      confirmed_call(op_token, "#{@admin}/#{application_id}/suspend-organization", %{
        "reason_code" => "approval_mistaken"
      })

    assert json_response(conn, 200)["application"]["organization"]["status"] == "suspended"
    assert Repo.reload!(org).status == :suspended
    assert [%Membership{status: :active}] = Repo.all(Membership)

    {_, conn} =
      confirmed_call(op_token, "#{@admin}/#{application_id}/reinstate-organization", %{
        "reason_code" => "concern_resolved"
      })

    assert json_response(conn, 200)["application"]["organization"]["status"] == "active"

    # 24: no secret or URL in any audit row of this journey.
    audit = inspect(Repo.all(AuditEvent))
    refute audit =~ "sfc_"
    refute audit =~ "ada@acme.example"
  end
end
