defmodule SimpleFit.Standalone.SponsorEntryHttpE2ETest do
  @moduledoc """
  SF-117 standalone HTTP E2E: sponsor entry, context choice and organization access
  against a **separately running** Phoenix server over real HTTP, on a disposable
  database, with production middleware, authentication and authorization (nothing
  injected into a request). Skipped unless `E2E_API_URL` names that server; started
  as for SF-116 (`docs/architecture/adr/0033-sponsor-application-decisions.md`,
  "Standalone HTTP E2E"), on a **fresh** e2e database (one founder per database).

  Organizations come from the real review: an independent founder operator (local
  development ceremony, two software WebAuthn keys and a key check over HTTP)
  approves, suspends and reinstates over HTTP. Adding a second member and revoking
  a membership have no HTTP route in the product (invitations are not built, D-SA12),
  so those two steps use `mix sponsors.fixture` (authority `local_fixture`, dev only),
  as a developer would; everything the user does goes over HTTP.

  With `E2E_SPONSOR_HANDOFF` set, the run writes the accounts' emails and the
  organization ids (never a token or code) for the browser leg
  (simplefit-platform `e2e/real-api/sponsor-portal.spec.ts`).
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

  @decide ~w(sponsors.applications.read sponsors.applications.claim
             sponsors.applications.approve sponsors.restrict)

  @admin "/api/v1/admin/sponsor-applications"

  defp url, do: System.fetch_env!("E2E_API_URL")
  defp database, do: System.fetch_env!("E2E_API_DATABASE_URL")

  setup do
    unless String.contains?(URI.parse(database()).path || "", "e2e"),
      do: raise("E2E_API_DATABASE_URL must name a disposable e2e database")

    unless sql("SELECT count(*) FROM platform_operators") == "0",
      do: raise("E2E_API_DATABASE_URL already has an operator: use a fresh disposable database")

    :ok
  end

  ## HTTP, database and tasks (the disposable database only)

  defp http(method, path, token, body \\ nil) do
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

    {response.status, response.body}
  end

  defp ok!({status, body}, expected \\ 200) do
    assert status == expected, "expected #{expected}, got #{status}: #{inspect(body)}"
    body
  end

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

  ## Accounts, applications and the operator

  defp account!(prefix) do
    sql("DELETE FROM auth_rate_limits")
    email = "sf117-#{prefix}-#{System.unique_integer([:positive])}@example.com"

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

  defp submitted_application!(token, company) do
    answers = Map.merge(complete_answers(), %{"company_name" => company})

    %{"application" => app} =
      http(
        :patch,
        "/api/v1/me/sponsor-application",
        token,
        Map.put(answers, "client_request_id", Ecto.UUID.generate())
      )
      |> ok!()

    %{"application" => submitted} =
      http(:post, "/api/v1/me/sponsor-application/submit", token, %{
        expected_revision: app["revision"],
        client_request_id: Ecto.UUID.generate(),
        declaration_accepted: true,
        declaration_version: app["declaration"]["version"],
        declaration_language: "en"
      })
      |> ok!()

    submitted
  end

  defp operator!(account) do
    out = Path.join(System.tmp_dir!(), "sf117-ceremony-#{account.id}.json")

    mix([
      "operators.dev_ceremony",
      "--user-id",
      account.id,
      "--permissions",
      Enum.join(@decide, ","),
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

    http(:post, path, token, request) |> ok!()
  end

  # The real review: claim, then a confirmed approval. Returns the organization id.
  defp approve!(operator, application_id) do
    detail = http(:get, "#{@admin}/#{application_id}", operator.token) |> ok!()

    http(:post, "#{@admin}/#{application_id}/claim", operator.token, %{
      "reason_code" => "review_started",
      "expected_revision" => detail["application"]["revision"],
      "operation_id" => Ecto.UUID.generate()
    })
    |> ok!()

    %{"application" => approved} =
      confirmed!(operator.token, "#{@admin}/#{application_id}/approve", %{
        "reason_code" => "review_complete"
      })

    approved["organization"]["sponsor_id"]
  end

  defp restrict!(operator, application_id, action, reason) do
    confirmed!(operator.token, "#{@admin}/#{application_id}/#{action}", %{
      "reason_code" => reason
    })
  end

  defp add_member!(org_id, user_id) do
    out =
      mix([
        "sponsors.fixture",
        "add-member",
        "--organization-id",
        org_id,
        "--user-id",
        user_id,
        "--role",
        "member"
      ])

    [_, id] = Regex.run(~r/membership ([0-9a-f-]{36}) is active/, out)
    id
  end

  ## Reading as the user

  defp entry(token, query \\ ""),
    do: (http(:get, "/api/v1/me/entry" <> query, token) |> ok!())["entry"]

  defp organization(token, id), do: http(:get, "/api/v1/sponsor-organizations/#{id}", token)

  defp choose(token, id),
    do:
      http(:put, "/api/v1/me/entry/context", token, %{"context" => "sponsor", "sponsor_id" => id})

  defp workspace_ids(entry), do: Enum.map(entry["sponsor_workspaces"], & &1["sponsor_id"])

  @tag timeout: 300_000
  test "entry, choice and access follow the committed organization and membership state over HTTP" do
    operator = operator!(account!("operator"))

    # Scenario B: an applicant who submitted has a status destination and no workspace.
    a = account!("applicant")
    a_application = submitted_application!(a.token, "Haymaker Drinks")

    assert %{
             "destination" => "sponsor_application_status",
             "capabilities" => [],
             "sponsor_id" => nil
           } =
             entry(a.token, "?intent=sponsor")

    {404, _} = organization(a.token, Ecto.UUID.generate())

    # Scenario C: an independent operator approves; the organization and owner exist; the
    # applicant's entry now opens it, by the membership, nothing else.
    org1 = approve!(operator, a_application["application_id"])

    assert %{"destination" => "sponsor_home", "sponsor_id" => ^org1, "capabilities" => caps} =
             entry(a.token, "?intent=sponsor")

    assert caps == ["SPONSOR_WORKSPACE"]

    assert %{"organization" => %{"status" => "active"}, "membership" => %{"role" => "owner"}} =
             organization(a.token, org1) |> ok!()

    # Scenario D: a second organization (another applicant, approved for real) with A as a
    # member: two choices; a choice selects, never grants.
    b = account!("other")
    b_application = submitted_application!(b.token, "Northside Agency")
    org2 = approve!(operator, b_application["application_id"])
    a_in_org2 = add_member!(org2, a.id)

    assert %{"destination" => "context_selection", "reason" => "sponsor_choice_required"} =
             e = entry(a.token, "?intent=sponsor")

    assert Enum.sort(workspace_ids(e)) == Enum.sort([org1, org2])

    ok!(choose(a.token, org2), 204)

    assert %{"destination" => "sponsor_home", "sponsor_id" => ^org2, "reason" => "last_context"} =
             entry(a.token, "?intent=sponsor")

    assert %{"membership" => %{"role" => "member"}} = organization(a.token, org2) |> ok!()
    {403, _} = http(:get, "/api/v1/sponsor-organizations/#{org2}/contacts", a.token)
    # The organizations stay apart: one's member list never names the other's owner.
    refute Jason.encode!(
             http(:get, "/api/v1/sponsor-organizations/#{org2}/members", a.token)
             |> ok!()
           ) =~ "E2E applicant-owner"

    # Scenario E: suspension through the operator's action. Its details stay readable,
    # as suspended; entry, a new choice and a stale request no longer open it.
    c = account!("third")
    c_application = submitted_application!(c.token, "Ringside Gear")
    org3 = approve!(operator, c_application["application_id"])
    _ = add_member!(org3, a.id)
    restrict!(operator, c_application["application_id"], "suspend-organization", "policy_concern")

    assert %{"organization" => %{"status" => "suspended"}} = organization(a.token, org3) |> ok!()
    {404, _} = choose(a.token, org3)
    refute org3 in workspace_ids(entry(a.token))
    assert %{"context" => nil} = entry(a.token, "?context=sponsor&sponsor_id=#{org3}")

    # Reinstatement makes the same rows valid again; then it is suspended once more for the
    # browser leg.
    restrict!(
      operator,
      c_application["application_id"],
      "reinstate-organization",
      "concern_resolved"
    )

    assert org3 in workspace_ids(entry(a.token))
    restrict!(operator, c_application["application_id"], "suspend-organization", "policy_concern")

    # Revocation: the next request with the same session is denied; the remembered choice
    # (org2) is ignored, and entry falls back to the one workspace left.
    mix([
      "sponsors.fixture",
      "revoke-membership",
      "--membership-id",
      a_in_org2,
      "--reason",
      "e2e"
    ])

    {404, _} = organization(a.token, org2)
    {404, _} = http(:get, "/api/v1/sponsor-organizations/#{org2}/members", a.token)

    assert %{"destination" => "sponsor_home", "sponsor_id" => ^org1, "reason" => reason} =
             entry(a.token, "?intent=sponsor")

    assert reason == "sponsor_workspace_active"

    # Scenario F (API side): another account sees nothing of A's organization.
    {404, _} = organization(b.token, org1)
    {404, _} = choose(b.token, org1)
    refute org1 in workspace_ids(entry(b.token))

    # An operator's own product contexts never include operator authority, and the
    # applicant gets no admin access.
    {404, _} = http(:get, @admin, a.token)
    refute "ADMIN" in entry(operator.token)["capabilities"]

    # Logout ends the session: the old token reads nothing.
    {204, _} = http(:post, "/api/auth/logout", a.token)
    {401, _} = organization(a.token, org1)
    {401, _} = http(:get, "/api/v1/me/entry", a.token)

    if handoff = System.get_env("E2E_SPONSOR_HANDOFF") do
      File.write!(
        handoff,
        Jason.encode!(%{
          applicant: %{email: a.email, user_id: a.id},
          other: %{email: b.email, user_id: b.id},
          owned: org1,
          revoked: org2,
          suspended: org3
        })
      )
    end
  end
end
