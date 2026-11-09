defmodule SimpleFit.Standalone.SponsorReviewHttpE2ETest do
  @moduledoc """
  SF-116 standalone HTTP E2E: the sponsor review flow against a **separately running**
  Phoenix server, over real HTTP, with production middleware, authentication and
  authorization in place (nothing injected into a request). Skipped unless
  `E2E_API_URL` names that server; see `docs/architecture/adr/0033-sponsor-application-decisions.md`
  ("Standalone HTTP E2E") for how it is started.

  The server runs in development configuration on a disposable database (its name must
  contain `e2e`), with the test-only legal fixtures (the published sponsor declaration).
  Accounts are created through the email-code API (the code is read from that database
  with `mix e2e.email_code`); the founder operator is bootstrapped with the local
  development ceremony (`mix operators.dev_ceremony` + `mix operators.ceremony`), as a
  developer would; its two security keys and its key check go over HTTP with the
  repository's **software** WebAuthn authenticator. No hardware key is involved.
  """

  use ExUnit.Case, async: false

  import SimpleFit.OperatorHelpers,
    only: [soft_key: 0, registration_response: 2, assertion_response: 2]

  import SimpleFit.SponsorApplicationHelpers, only: [complete_answers: 0]

  if is_nil(System.get_env("E2E_API_URL")) or is_nil(System.get_env("E2E_API_DATABASE_URL")) do
    @moduletag skip:
                 "standalone E2E: set E2E_API_URL and E2E_API_DATABASE_URL to a running server"
  end

  # Child processes get no provider secret from this environment.
  @cleared [{"RESEND_API_KEY", nil}, {"STRIPE_SECRET_KEY", nil}, {"STRIPE_WEBHOOK_SECRET", nil}]

  defp url, do: System.fetch_env!("E2E_API_URL")
  defp database, do: System.fetch_env!("E2E_API_DATABASE_URL")

  @decide ~w(sponsors.applications.read sponsors.applications.claim
             sponsors.applications.approve sponsors.applications.reject sponsors.restrict)

  setup do
    unless String.contains?(URI.parse(database()).path || "", "e2e"),
      do: raise("E2E_API_DATABASE_URL must name a disposable e2e database")

    # The founder ceremony runs once per database (one founder, SF-110): each run needs
    # a fresh disposable database.
    unless sql("SELECT count(*) FROM platform_operators") == "0",
      do: raise("E2E_API_DATABASE_URL already has an operator: use a fresh disposable database")

    :ok
  end

  ## HTTP

  defp http(method, path, token \\ nil, body \\ nil) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    response =
      Req.request!(
        method: method,
        url: url() <> path,
        headers: headers,
        json: body,
        retry: false,
        decode_body: true
      )

    {response.status, response.body, response}
  end

  defp ok!({status, body, _}, expected \\ 200) do
    assert status == expected, "expected #{expected}, got #{status}: #{inspect(body)}"
    body
  end

  ## Database and tasks (the disposable database only)

  defp sql(query) do
    {out, 0} =
      System.cmd("psql", [database(), "-Atqc", query], stderr_to_stdout: true, env: @cleared)

    String.trim(out)
  end

  defp mix(args) do
    {out, status} =
      System.cmd("mix", args,
        env: [{"MIX_ENV", "dev"}, {"DATABASE_URL", database()} | @cleared],
        stderr_to_stdout: true
      )

    assert status == 0, out
    out
  end

  defp emailed_code(email) do
    mix(["e2e.email_code", email])
    |> String.split("\n")
    |> Enum.find(&Regex.match?(~r/^\d{6}$/, String.trim(&1)))
    |> String.trim()
  end

  ## Journeys

  defp account!(prefix) do
    sql("DELETE FROM auth_rate_limits")
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    %{"registration_token" => registration} =
      http(:post, "/api/auth/email/registrations", nil, %{email: email}) |> ok!(202)

    %{"access_token" => token} =
      http(:post, "/api/auth/email/registrations/verify", nil, %{
        registration_token: registration,
        code: emailed_code(email),
        refresh_token_transport: "body"
      })
      |> ok!()

    http(:patch, "/api/v1/me/account-profile", token, %{
      full_name: "E2E #{prefix}",
      date_of_birth: "1990-05-17",
      accept_terms: true,
      accept_privacy: true
    })
    |> ok!()

    http(:post, "/api/v1/me/account-profile/complete-registration", token, %{}) |> ok!()
    %{"user" => %{"id" => id}} = http(:get, "/api/me", token) |> ok!()
    %{token: token, id: id, email: email}
  end

  defp submitted_application!(token) do
    draft =
      http(
        :patch,
        "/api/v1/me/sponsor-application",
        token,
        Map.put(complete_answers(), "client_request_id", Ecto.UUID.generate())
      )
      |> ok!()

    app = draft["application"]

    submitted =
      http(:post, "/api/v1/me/sponsor-application/submit", token, %{
        expected_revision: app["revision"],
        client_request_id: Ecto.UUID.generate(),
        declaration_accepted: true,
        declaration_version: app["declaration"]["version"],
        declaration_language: "en"
      })
      |> ok!()

    submitted["application"]
  end

  defp operator!(account, permissions) do
    out = Path.join(System.tmp_dir!(), "sf116-ceremony-#{account.id}.json")

    mix([
      "operators.dev_ceremony",
      "--user-id",
      account.id,
      "--permissions",
      Enum.join(permissions, ","),
      "--out",
      out
    ])

    mix(["operators.ceremony", out])
    File.rm!(out)

    [key | _] =
      for _ <- 1..2 do
        key = soft_key()
        options = http(:post, "/api/v1/admin/credentials/options", account.token, %{}) |> ok!()

        http(
          :post,
          "/api/v1/admin/credentials",
          account.token,
          registration_response(key, opts(options))
        )
        |> ok!(201)

        key
      end

    options = http(:post, "/api/v1/admin/step-up/options", account.token, %{}) |> ok!()
    {response, _key} = assertion_response(key, opts(options))
    http(:post, "/api/v1/admin/step-up", account.token, response) |> ok!()
    account
  end

  defp opts(body),
    do: %{
      challenge_id: body["challenge_id"],
      options: %{challenge: body["public_key"]["challenge"]}
    }

  defp confirmed!(token, path, body) do
    %{"preview" => preview} = http(:post, path <> "/preview", token, body) |> ok!()

    request =
      Map.merge(body, %{
        "expected_revision" => preview["expected_revision"],
        "operation_id" => Ecto.UUID.generate(),
        "confirmation_token" => preview["confirmation"]["token"]
      })

    {request, http(:post, path, token, request)}
  end

  defp capabilities(token),
    do: (http(:get, "/api/v1/me/entry?intent=sponsor", token) |> ok!())["entry"]["capabilities"]

  @tag timeout: 180_000
  test "a real operator reviews and approves over HTTP; nothing more is granted than approved" do
    admin = "/api/v1/admin/sponsor-applications"

    # 1-3: an applicant drafts and submits; submission creates no organization or membership.
    applicant = account!("applicant")
    application = submitted_application!(applicant.token)
    id = application["application_id"]
    assert application["status"] == "submitted"

    assert sql(
             "SELECT count(*) FROM sponsor_workspace_memberships WHERE user_id = '#{applicant.id}'"
           ) == "0"

    assert sql("SELECT count(*) FROM sponsor_organizations WHERE source_application_id = '#{id}'") ==
             "0"

    refute "SPONSOR_WORKSPACE" in capabilities(applicant.token)

    # 4-5: an independent founder operator: dev ceremony, two software keys, key check over HTTP.
    # It holds no `read_files` permission, so a document download is forbidden (19).
    operator = operator!(account!("operator"), @decide)

    # 6-7: queue and detail.
    queue = http(:get, admin <> "?status=submitted", operator.token) |> ok!()
    assert Enum.any?(queue["applications"], &(&1["application_id"] == id))
    refute Jason.encode!(queue) =~ "ada@acme.example"
    detail = http(:get, "#{admin}/#{id}", operator.token) |> ok!()

    # 8: claim.
    http(:post, "#{admin}/#{id}/claim", operator.token, %{
      "reason_code" => "review_started",
      "expected_revision" => detail["application"]["revision"],
      "operation_id" => Ecto.UUID.generate()
    })
    |> ok!()

    # Without a confirmation, approval is refused (428).
    {428, %{"error" => %{"code" => "confirmation_required"}}, _} =
      http(:post, "#{admin}/#{id}/approve", operator.token, %{
        "reason_code" => "review_complete",
        "expected_revision" => detail["application"]["revision"] + 1,
        "operation_id" => Ecto.UUID.generate()
      })

    # 9-10: preview, confirmation, approval.
    {approve, response} =
      confirmed!(operator.token, "#{admin}/#{id}/approve", %{"reason_code" => "review_complete"})

    approved = ok!(response)
    assert approved["application"]["status"] == "approved"
    sponsor_id = approved["application"]["organization"]["sponsor_id"]

    # 11-15: the applicant's view, the organization, the only membership, audit, outbox.
    mine = http(:get, "/api/v1/me/sponsor-application", applicant.token) |> ok!()

    assert mine["application"]["status"] == "approved" and
             mine["application"]["sponsor_id"] == sponsor_id

    assert sql("SELECT status FROM sponsor_organizations WHERE id = '#{sponsor_id}'") == "active"

    assert sql(
             "SELECT string_agg(user_id || ':' || role || ':' || status, ',') FROM sponsor_workspace_memberships WHERE organization_id = '#{sponsor_id}'"
           ) ==
             "#{applicant.id}:owner:active"

    assert sql(
             "SELECT count(*) FROM operator_audit_events WHERE command = 'sponsor_application.approve' AND outcome = 'allowed' AND target_id = '#{id}'"
           ) ==
             "1"

    assert sql(
             "SELECT kind || ':' || status FROM sponsor_application_notifications WHERE application_id = '#{id}' AND kind = 'application_approved'"
           ) ==
             "application_approved:queued"

    assert "SPONSOR_WORKSPACE" in capabilities(applicant.token)

    # 16: the same request again changes nothing.
    http(:post, "#{admin}/#{id}/approve", operator.token, approve) |> ok!()

    assert sql("SELECT count(*) FROM sponsor_organizations WHERE source_application_id = '#{id}'") ==
             "1"

    assert sql(
             "SELECT count(*) FROM sponsor_workspace_memberships WHERE organization_id = '#{sponsor_id}'"
           ) == "1"

    assert sql(
             "SELECT count(*) FROM sponsor_application_notifications WHERE application_id = '#{id}' AND kind = 'application_approved'"
           ) ==
             "1"

    # 17: a conflicting decision.
    {409, %{"error" => %{"code" => "conflict", "details" => %{"status" => "approved"}}}, _} =
      http(:post, "#{admin}/#{id}/reject/preview", operator.token, %{"reason_code" => "other"})

    # 18: self-approval: the operator's own application.
    own = submitted_application!(operator.token)

    {409, %{"error" => %{"code" => "conflict", "details" => %{"target" => "self"}}}, _} =
      http(:post, "#{admin}/#{own["application_id"]}/claim/preview", operator.token, %{
        "reason_code" => "review_started"
      })

    # 19: no operator (404), no authentication (401), no permission (403).
    {404, _, _} = http(:get, admin, applicant.token)

    {404, _, _} =
      http(:post, "#{admin}/#{id}/approve/preview", applicant.token, %{
        "reason_code" => "review_complete"
      })

    {401, _, _} = http(:get, admin)

    {403, %{"error" => %{"code" => "forbidden"}}, _} =
      http(
        :post,
        "#{admin}/#{id}/documents/#{Ecto.UUID.generate()}/download",
        operator.token,
        %{}
      )

    # 20: suspension: read-only, no workspace; reinstatement restores it.
    {_, response} =
      confirmed!(operator.token, "#{admin}/#{id}/suspend-organization", %{
        "reason_code" => "approval_mistaken"
      })

    assert ok!(response)["application"]["organization"]["status"] == "suspended"
    refute "SPONSOR_WORKSPACE" in capabilities(applicant.token)
    http(:get, "/api/v1/sponsor-organizations/#{sponsor_id}", applicant.token) |> ok!()

    assert sql(
             "SELECT authority || ':' || actor_user_id FROM sponsor_organization_events WHERE organization_id = '#{sponsor_id}' AND event = 'organization.suspended'"
           ) ==
             "platform_operator:#{operator.id}"

    {_, response} =
      confirmed!(operator.token, "#{admin}/#{id}/reinstate-organization", %{
        "reason_code" => "concern_resolved"
      })

    assert ok!(response)["application"]["organization"]["status"] == "active"
    assert "SPONSOR_WORKSPACE" in capabilities(applicant.token)

    # Denials are audited; no token or contact in any audit row.
    assert sql(
             "SELECT count(*) FROM operator_audit_events WHERE outcome = 'refused' AND result_code = 'self_action'"
           ) != "0"

    assert sql(
             "SELECT count(*) FROM operator_audit_events WHERE CAST(row_to_json(operator_audit_events) AS text) LIKE '%sfc_%' OR CAST(row_to_json(operator_audit_events) AS text) LIKE '%ada@acme.example%'"
           ) ==
             "0"
  end
end
