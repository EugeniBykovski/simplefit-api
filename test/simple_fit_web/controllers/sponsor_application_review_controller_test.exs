defmodule SimpleFitWeb.SponsorApplicationReviewControllerTest do
  @moduledoc """
  SF-114 over HTTP, checked against OpenAPI: the applicant's evidence and contact
  verification endpoints, and operator review (read, claim, request changes).
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.VerificationHelpers, only: [stub_storage: 1]
  import SimpleFit.GymHelpers, only: [registered!: 1, email_user!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Email.JobPayload
  alias SimpleFitWeb.ApiSpec

  @me "/api/v1/me/sponsor-application"
  @admin "/api/v1/admin/sponsor-applications"
  @review ~w(sponsors.applications.read sponsors.applications.claim sponsors.applications.request_changes)

  defp session!(user) do
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

  defp revision(token),
    do: (call(:get, @me, token) |> json_response(200))["application"]["revision"]

  defp last_code do
    job = Repo.one!(from(j in Oban.Job, order_by: [desc: j.id], limit: 1))
    {:ok, message} = JobPayload.open(job.args["payload"])
    [code] = Regex.run(~r/\b\d{6}\b/, message.text)
    code
  end

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    user = email_user!("applicant-#{System.unique_integer([:positive])}@example.com")
    {token, _session} = session!(user)
    app = draft!(user)
    %{user: user, token: token, app: app}
  end

  describe "evidence" do
    test "initiate, upload (stubbed), confirm, remove, submit", c do
      created =
        call(:post, @me <> "/evidence", c.token, %{
          "expected_revision" => revision(c.token),
          "kind" => "logo",
          "file_name" => "logo.png",
          "content_type" => "image/png",
          "byte_size" => 1000
        })
        |> json_response(201)

      assert_schema(created, "SponsorApplicationEvidenceResponse", ApiSpec.spec())
      id = created["evidence"]["evidence_id"]

      assert %{"status" => "pending_upload", "scanned" => false, "submitted" => false} =
               created["evidence"]

      assert %{"method" => "PUT", "headers" => %{"content-type" => "image/png"}} =
               created["upload"]

      # The key never leaves the server; only the presigned URL embeds it.
      refute Map.has_key?(created["evidence"], "object_key")

      stub_storage(%{id => {1000, "image/png"}})

      confirmed =
        call(:post, "#{@me}/evidence/#{id}/confirm", c.token, %{}) |> json_response(200)

      assert_schema(confirmed, "SponsorApplicationResponse", ApiSpec.spec())

      assert [%{"evidence_id" => ^id, "status" => "uploaded"}] =
               confirmed["application"]["evidence"]

      # A second document, removed again.
      %{"evidence" => %{"evidence_id" => other}} =
        call(:post, @me <> "/evidence", c.token, %{
          "expected_revision" => revision(c.token),
          "kind" => "other",
          "file_name" => "notes.pdf",
          "content_type" => "application/pdf",
          "byte_size" => 10
        })
        |> json_response(201)

      removed =
        call(:post, "#{@me}/evidence/#{other}/remove", c.token, %{
          "expected_revision" => revision(c.token)
        })
        |> json_response(200)

      assert_schema(removed, "SponsorApplicationResponse", ApiSpec.spec())
      assert [%{"evidence_id" => ^id}] = removed["application"]["evidence"]

      submitted =
        call(:post, @me <> "/submit", c.token, submit_params(Repo.reload!(c.app)))
        |> json_response(200)

      assert [%{"evidence_id" => ^id, "submitted" => true}] =
               submitted["application"]["evidence"]
    end

    test "errors: validation, missing object, storage down, someone else's document", c do
      bad =
        call(:post, @me <> "/evidence", c.token, %{
          "expected_revision" => revision(c.token),
          "kind" => "logo",
          "file_name" => "x.exe",
          "content_type" => "application/x-msdownload",
          "byte_size" => 10
        })
        |> json_response(422)

      assert %{"error" => %{"code" => "validation_error", "details" => %{"field_codes" => codes}}} =
               bad

      assert codes["content_type"] == ["invalid_choice"]

      %{"evidence" => %{"evidence_id" => id}} =
        call(:post, @me <> "/evidence", c.token, %{
          "expected_revision" => revision(c.token),
          "kind" => "logo",
          "file_name" => "logo.png",
          "content_type" => "image/png",
          "byte_size" => 1000
        })
        |> json_response(201)

      stub_storage(%{})

      assert %{"error" => %{"code" => "conflict", "details" => %{"upload" => "not_found"}}} =
               call(:post, "#{@me}/evidence/#{id}/confirm", c.token, %{}) |> json_response(409)

      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 503, ""))

      assert %{"error" => %{"code" => "service_unavailable"}} =
               call(:post, "#{@me}/evidence/#{id}/confirm", c.token, %{}) |> json_response(503)

      {stranger, _} = session!(registered!("stranger"))

      assert %{"error" => %{"code" => "not_found"}} =
               call(:post, "#{@me}/evidence/#{id}/confirm", stranger, %{}) |> json_response(404)

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("#{@me}/evidence/#{id}/confirm", "{}")
             |> json_response(401)
    end
  end

  describe "contact verification" do
    test "request a code, a wrong code, the right code", c do
      sent = call(:post, @me <> "/contact-verification", c.token, %{}) |> json_response(200)
      assert_schema(sent, "SponsorApplicationResponse", ApiSpec.spec())
      assert sent["application"]["contact_email_verified"] == false
      code = last_code()
      wrong = if code == "000000", do: "111111", else: "000000"

      assert %{"error" => %{"code" => "code_invalid"}} =
               call(:post, @me <> "/contact-verification/confirm", c.token, %{"code" => wrong})
               |> json_response(422)

      ok =
        call(:post, @me <> "/contact-verification/confirm", c.token, %{"code" => code})
        |> json_response(200)

      assert ok["application"]["contact_email_verified"] == true

      assert %{"error" => %{"code" => "code_expired"}} =
               call(:post, @me <> "/contact-verification/confirm", c.token, %{"code" => code})
               |> json_response(422)
    end
  end

  describe "operator review" do
    setup c do
      operator = registered!("reviewer")
      {token, session} = session!(operator)
      _ = bootstrap!(operator, @review)
      [key | _] = enroll!(operator, session)
      _ = step_up!(operator, session, key)
      app = submitted!(c.user, c.app)
      %{op_token: token, app: app}
    end

    test "read, preview, claim, request changes; the applicant sees the request", c do
      shown = call(:get, "#{@admin}/#{c.app.id}", c.op_token) |> json_response(200)
      assert_schema(shown, "SponsorApplicationReviewResponse", ApiSpec.spec())
      revision = shown["application"]["revision"]
      body = %{"reason_code" => "review_started", "expected_revision" => revision}

      preview =
        call(:post, "#{@admin}/#{c.app.id}/claim/preview", c.op_token, body)
        |> json_response(200)

      assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())

      claimed =
        call(
          :post,
          "#{@admin}/#{c.app.id}/claim",
          c.op_token,
          Map.put(body, "operation_id", Ecto.UUID.generate())
        )
        |> json_response(200)

      assert_schema(claimed, "SponsorApplicationReviewResponse", ApiSpec.spec())
      assert claimed["application"]["status"] == "under_review"

      changes = %{
        "reason_code" => "unclear_answers",
        "expected_revision" => claimed["application"]["revision"],
        "operation_id" => Ecto.UUID.generate(),
        "fields" => ["goals"],
        "message" => "Which events?"
      }

      requested =
        call(:post, "#{@admin}/#{c.app.id}/request-changes", c.op_token, changes)
        |> json_response(200)

      assert_schema(requested, "SponsorApplicationReviewResponse", ApiSpec.spec())
      assert requested["application"]["status"] == "changes_requested"

      assert %{"fields" => ["goals"], "message" => "Which events?"} =
               requested["application"]["change_request"]

      mine = call(:get, @me, c.token) |> json_response(200)
      assert_schema(mine, "SponsorApplicationResponse", ApiSpec.spec())

      assert %{"fields" => ["goals"], "message" => "Which events?"} =
               mine["application"]["change_request"]

      # Answers outside the request are refused with their own code.
      refused =
        call(:patch, @me, c.token, %{
          "expected_revision" => mine["application"]["revision"],
          "company_name" => "Renamed"
        })
        |> json_response(422)

      assert refused["error"]["details"]["field_codes"] == %{"company_name" => ["not_requested"]}
    end

    test "the applicant can't use admin routes; drafts are not found", c do
      assert %{"error" => %{"code" => "not_found"}} =
               call(:get, "#{@admin}/#{c.app.id}", c.token) |> json_response(404)

      other = registered!("drafter")
      draft = draft!(other)

      assert %{"error" => %{"code" => "not_found"}} =
               call(:get, "#{@admin}/#{draft.id}", c.op_token) |> json_response(404)
    end

    test "no approval or rejection route exists", c do
      for path <- ["approve", "reject", "decide"] do
        assert call(:post, "#{@admin}/#{c.app.id}/#{path}", c.op_token, %{}).status == 404
      end
    end
  end
end
