defmodule SimpleFitWeb.SponsorApplicationControllerTest do
  @moduledoc "SF-113 over HTTP: the applicant's sponsor application API, checked against OpenAPI."

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/sponsor-application"

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    case method do
      :get -> get(conn, path)
      :patch -> patch(conn, path, Jason.encode!(body))
      :post -> post(conn, path, Jason.encode!(body))
    end
  end

  setup do
    user = registered!("applicant")
    %{user: user, token: token!(user)}
  end

  test "no application yet is 404; no session is 401", c do
    assert %{"error" => %{"code" => "not_found"}} =
             call(:get, @path, c.token) |> json_response(404)

    assert build_conn() |> get(@path) |> json_response(401)
  end

  test "save, resume, submit, read the submission", c do
    started =
      call(:patch, @path, c.token, %{
        "client_request_id" => Ecto.UUID.generate(),
        "company_name" => "Acme"
      })
      |> json_response(200)

    assert_schema(started, "SponsorApplicationResponse", ApiSpec.spec())
    a = started["application"]

    assert %{
             "status" => "draft",
             "allowed_actions" => ["edit"],
             "submit_blockers" => ["incomplete"]
           } = a

    assert "goals" in a["missing_fields"]
    assert a["uploads"] == %{"available" => false, "reason" => "file_scanning_unavailable"}
    assert a["sponsor_id"] == nil and a["contact_email_verified"] == false

    stale =
      call(:patch, @path, c.token, %{"expected_revision" => a["revision"] + 5, "goals" => "x"})
      |> json_response(409)

    assert %{"error" => %{"code" => "revision_conflict", "details" => %{"current_revision" => _}}} =
             stale

    invalid =
      call(:patch, @path, c.token, %{
        "expected_revision" => a["revision"],
        "budget_band" => "1000.00"
      })
      |> json_response(422)

    assert %{
             "error" => %{"details" => %{"field_codes" => %{"budget_band" => ["invalid_choice"]}}}
           } =
             invalid

    filled =
      call(
        :patch,
        @path,
        c.token,
        Map.put(complete_answers(), "expected_revision", a["revision"])
      )
      |> json_response(200)

    assert filled["application"]["allowed_actions"] == ["edit", "submit"]

    # Another session of the same account resumes it.
    resumed = call(:get, @path, token!(c.user)) |> json_response(200)
    assert resumed["application"]["revision"] == filled["application"]["revision"]

    request = %{
      "expected_revision" => filled["application"]["revision"],
      "client_request_id" => Ecto.UUID.generate(),
      "declaration_accepted" => true,
      "declaration_version" => "sponsor-application-declaration-test-1",
      "declaration_language" => "en"
    }

    submitted = call(:post, @path <> "/submit", c.token, request) |> json_response(200)
    assert_schema(submitted, "SponsorApplicationResponse", ApiSpec.spec())

    assert %{"status" => "submitted", "allowed_actions" => [], "submissions" => [s]} =
             submitted["application"]

    assert call(:post, @path <> "/submit", c.token, request) |> json_response(200) == submitted

    snapshot =
      call(:get, @path <> "/submissions/#{s["submission_id"]}", c.token) |> json_response(200)

    assert_schema(snapshot, "SponsorApplicationSubmissionResponse", ApiSpec.spec())
    assert snapshot["submission"]["answers"]["company_name"] == "Acme Boxing Gear Sp. z o.o."

    other = token!(registered!("other"))
    assert call(:get, @path <> "/submissions/#{s["submission_id"]}", other) |> json_response(404)
    assert call(:get, @path, other) |> json_response(404)

    assert %{"error" => %{"code" => "conflict", "details" => %{"application" => "not_editable"}}} =
             call(:patch, @path, c.token, %{
               "expected_revision" => submitted["application"]["revision"],
               "goals" => "x"
             })
             |> json_response(409)
  end

  test "missing answers are named on submit", c do
    a = draft!(c.user, %{"company_name" => "Acme"})

    body =
      call(:post, @path <> "/submit", c.token, submit_params(a))
      |> json_response(422)

    codes = body["error"]["details"]["field_codes"]
    assert codes["goals"] == ["required"] and codes["contact_email"] == ["required"]
    refute Map.has_key?(codes, "website")
  end

  test "the policy is what the backend validates", c do
    policy = call(:get, "/api/v1/sponsor-application-policy", c.token) |> json_response(200)
    assert_schema(policy, "SponsorApplicationPolicyResponse", ApiSpec.spec())
    p = policy["policy"]
    assert p["version"] == "sponsor-application-2026-11.v1"
    assert "goals" in p["required"] and "website" not in p["required"]

    assert %{"code" => "eur_5000_20000", "min" => 5000, "max" => 20_000, "currency" => "EUR"} in p[
             "budget_bands"
           ]

    assert p["declaration"]["available"] == true
  end
end
