defmodule SimpleFitWeb.AdminUserControllerTest do
  @moduledoc """
  SF-122 over HTTP, checked against OpenAPI: exact account search, one account, email
  reveal, and the three account actions (suspend, lift, sign out everywhere) with
  their preview, confirmation, revision and audit; and what a suspension and a
  sign-out do to the account's real sessions, refresh tokens and sign-ins.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorHelpers, only: [provision!: 1]
  import SimpleFit.GymHelpers, only: [registered!: 1, email_user!: 1, email_user!: 2]
  import SimpleFit.FighterOnboardingHelpers, only: [complete_fighter_onboarding!: 1]
  import SimpleFit.EmailAuthHelpers, only: [last_email_to: 1, code_from: 1]

  alias SimpleFit.{Accounts, Operators, Repo}
  alias SimpleFit.Accounts.{Restriction, Session}
  alias SimpleFit.Operators.AuditEvent
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin/users"
  @all ~w(users.read users.reveal_email users.restrict users.sessions.revoke operators.manage)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp credentials!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    case method do
      :get ->
        get(conn, path)

      :post ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(body || %{}))
    end
  end

  defp operator!(permissions, prefix \\ "operator") do
    user = registered!(prefix)
    credentials = credentials!(user)
    operator = bootstrap!(user, permissions)
    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)

    %{
      user: user,
      token: credentials.access_token,
      session: credentials.session,
      operator: operator
    }
  end

  # Another operator, provisioned by `founder` (bootstrap makes only the first).
  defp provisioned!(founder, permissions, prefix) do
    user = registered!(prefix)
    credentials = credentials!(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)
    %{user: user, token: credentials.access_token, session: credentials.session}
  end

  defp search(token, query, reason \\ "support_request"),
    do: call(:get, "#{@admin}?query=#{URI.encode_www_form(query)}&reason_code=#{reason}", token)

  defp detail(token, id, reason \\ "support_request"),
    do: call(:get, "#{@admin}/#{id}?reason_code=#{reason}", token)

  # Preview, then execute an action over HTTP.
  defp http_act(token, id, action, reason, overrides \\ %{}) do
    preview =
      call(:post, "#{@admin}/#{id}/#{action}/preview", token, %{"reason_code" => reason})
      |> json_response(200)

    assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())
    preview = preview["preview"]

    body =
      Map.merge(
        %{
          "reason_code" => reason,
          "expected_revision" => preview["expected_revision"],
          "operation_id" => Ecto.UUID.generate(),
          "confirmation_token" => preview["confirmation"]["token"]
        },
        overrides
      )

    {preview, body, call(:post, "#{@admin}/#{id}/#{action}", token, body)}
  end

  defp me(token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get("/api/me")

  defp audit(action), do: Repo.all(from(e in AuditEvent, where: e.action == ^action))

  describe "who may use it" do
    test "anonymous 401; an ordinary user, a sponsor owner and a gym owner get the same 404" do
      assert build_conn()
             |> get("#{@admin}?query=x&reason_code=support_request")
             |> json_response(401)

      sponsor = registered!("sponsor")
      provision!(sponsor)

      for user <- [registered!("plain"), sponsor] do
        token = credentials!(user).access_token

        assert %{"error" => %{"code" => "not_found"}} =
                 search(token, user.id) |> json_response(404)

        assert %{"error" => %{"code" => "not_found"}} =
                 detail(token, user.id) |> json_response(404)
      end
    end

    test "an operator without users.read is forbidden; reading never grants writing" do
      op = operator!(["operators.read", "operators.manage"])
      target = registered!("target")

      assert %{"error" => %{"code" => "forbidden"}} =
               search(op.token, target.id) |> json_response(403)

      reader = provisioned!(op, ["users.read"], "reader")
      assert %{"users" => [_]} = search(reader.token, target.id) |> json_response(200)

      assert %{"error" => %{"code" => "forbidden"}} =
               call(:post, "#{@admin}/#{target.id}/suspend/preview", reader.token, %{
                 "reason_code" => "abuse_report"
               })
               |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               call(:post, "#{@admin}/#{target.id}/reveal-email", reader.token, %{
                 "reason_code" => "support_request"
               })
               |> json_response(403)
    end
  end

  describe "search and detail" do
    test "exact email (any case) or id finds one account, masked; partial never matches" do
      op = operator!(@all)
      target = email_user!("Natalia.Exact@Example.com", "Natalia Wiśniewska")

      for query <- ["natalia.exact@example.com", "NATALIA.EXACT@EXAMPLE.COM", target.id] do
        body = search(op.token, query) |> json_response(200)
        assert_schema(body, "AdminUserSearchResponse", ApiSpec.spec())

        assert [%{"id" => id, "masked_emails" => ["n•••@example.com"], "status" => "active"}] =
                 body["users"]

        assert id == target.id
      end

      for query <- ["natalia", "example.com", "%", "*@example.com", String.slice(target.id, 0, 8)] do
        assert %{"users" => []} = search(op.token, query) |> json_response(200)
      end
    end

    test "a reason is required and recorded with every search and view" do
      op = operator!(@all)
      target = registered!("target")

      assert %{"error" => %{"code" => "validation_error"}} =
               call(:get, "#{@admin}?query=#{target.id}", op.token) |> json_response(422)

      assert %{"error" => %{"code" => "validation_error"}} =
               search(op.token, target.id, "curiosity") |> json_response(422)

      _ = search(op.token, target.id, "abuse_report") |> json_response(200)
      _ = search(op.token, "nobody@example.com", "legal_request") |> json_response(200)
      _ = detail(op.token, target.id, "account_security") |> json_response(200)

      assert [
               %{reason_code: "abuse_report", target_id: id},
               %{reason_code: "legal_request", target_id: nil}
             ] =
               Enum.sort_by(audit("user.searched"), &(&1.target_id == nil))

      assert id == target.id
      assert [%{reason_code: "account_security"}] = audit("user.viewed")
    end

    test "searches are limited per operator and hour" do
      op = operator!(@all)
      for _ <- 1..60, do: assert(search(op.token, "nobody@example.com") |> json_response(200))

      assert %{"error" => %{"code" => "rate_limited"}} =
               search(op.token, "nobody@example.com") |> json_response(429)
    end

    test "detail: state, sign-in methods, registration, sessions and context counts; no secret" do
      op = operator!(@all)
      target = email_user!("canary.detail@example.com", "Canary Person")
      complete_fighter_onboarding!(target)
      creds = credentials!(target)

      body = detail(op.token, target.id) |> json_response(200)
      assert_schema(body, "AdminUserResponse", ApiSpec.spec())
      user = body["user"]

      assert %{
               "status" => "active",
               "revision" => 1,
               "suspension" => nil,
               "registration" => "complete",
               "providers" => ["email"],
               "masked_emails" => ["c•••@example.com"],
               "contexts" => %{"fighter_profile" => "completed", "platform_operator" => false}
             } = user

      assert user["sessions"] != []

      raw = detail(op.token, target.id) |> response(200)

      for secret <- [
            "canary.detail@example.com",
            creds.access_token,
            creds.refresh_token,
            creds.session.id
          ] do
        refute raw =~ secret
      end
    end

    test "an unknown id is the same 404 as a missing route" do
      op = operator!(@all)
      assert detail(op.token, Ecto.UUID.generate()) |> json_response(404)
      assert detail(op.token, "not-a-uuid") |> json_response(404)
    end

    test "reveal: full addresses with users.reveal_email and a fresh key, recorded first" do
      op = operator!(@all)
      target = email_user!("reveal.me@example.com")

      assert %{"email_addresses" => ["reveal.me@example.com"]} =
               body =
               call(:post, "#{@admin}/#{target.id}/reveal-email", op.token, %{
                 "reason_code" => "support_request"
               })
               |> json_response(200)

      assert_schema(body, "AdminUserEmailResponse", ApiSpec.spec())
      assert [%{target_id: id, reason_code: "support_request"}] = audit("user.email_revealed")
      assert id == target.id
    end
  end

  describe "suspension" do
    test "suspend: every session stops, refresh and every sign-in are refused; lift: sign-in only" do
      op = operator!(@all)
      target = email_user!("suspend.me@example.com")
      laptop = credentials!(target)
      phone = credentials!(target)
      assert me(laptop.access_token) |> json_response(200)

      {preview, _body, conn} = http_act(op.token, target.id, "suspend", "abuse_report")

      assert %{"current_state" => "active", "proposed_state" => "suspended"} = preview
      assert "signed_out_everywhere" in preview["impact"]

      assert %{"user" => %{"status" => "suspended", "revision" => 2}} =
               body = json_response(conn, 200)

      assert_schema(body, "AdminUserStateResponse", ApiSpec.spec())

      # Both devices, at the very next request; refresh too.
      for creds <- [laptop, phone] do
        assert me(creds.access_token) |> json_response(401)
        assert {:error, :unauthorized} = Accounts.refresh_session(creds.refresh_token)
      end

      # No new session through any identity of the same user.
      {:ok, _} =
        Accounts.link_identity(
          target,
          :google,
          "google-sub-#{System.unique_integer([:positive])}"
        )

      assert {:error, :account_suspended} = Accounts.create_session(target)

      assert Repo.all(
               from(s in Session, where: s.user_id == ^target.id, select: s.revoked_reason)
             )
             |> Enum.uniq() ==
               [:account_suspended]

      assert %{
               "user" => %{
                 "status" => "suspended",
                 "suspension" => %{"reason_code" => "abuse_report"}
               }
             } =
               detail(op.token, target.id) |> json_response(200)

      assert [%{from_state: "active", to_state: "suspended", reason_code: "abuse_report"}] =
               audit("user.suspended")

      # Lift: sign-in works again; the revoked sessions stay revoked.
      {_preview, _body, lifted} =
        http_act(op.token, target.id, "lift-suspension", "issue_resolved")

      assert %{"user" => %{"status" => "active", "revision" => 3}} = json_response(lifted, 200)
      assert me(laptop.access_token) |> json_response(401)
      assert {:error, :unauthorized} = Accounts.refresh_session(phone.refresh_token)
      fresh = credentials!(target)
      assert me(fresh.access_token) |> json_response(200)

      assert [%{lifted_at: %DateTime{}, lift_reason_code: "issue_resolved"}] =
               Repo.all(Restriction)
    end

    test "conflicts: already suspended, nothing to lift, stale revision, replayed confirmation" do
      op = operator!(@all)
      target = registered!("target")

      assert %{"error" => %{"code" => "conflict", "details" => %{"status" => "active"}}} =
               call(:post, "#{@admin}/#{target.id}/lift-suspension/preview", op.token, %{
                 "reason_code" => "issue_resolved"
               })
               |> json_response(409)

      {_preview, body, conn} = http_act(op.token, target.id, "suspend", "fraud")
      assert json_response(conn, 200)

      # The same request again (same operation id) changes nothing.
      assert %{"user" => %{"status" => "suspended", "revision" => 2}} =
               call(:post, "#{@admin}/#{target.id}/suspend", op.token, body) |> json_response(200)

      assert length(Repo.all(Restriction)) == 1

      # The used confirmation with a new operation id: refused.
      assert %{"error" => %{"code" => "confirmation_invalid"}} =
               call(:post, "#{@admin}/#{target.id}/suspend", op.token, %{
                 body
                 | "operation_id" => Ecto.UUID.generate(),
                   "expected_revision" => 2
               })
               |> json_response(422)

      assert %{"error" => %{"code" => "conflict", "details" => %{"status" => "suspended"}}} =
               call(:post, "#{@admin}/#{target.id}/suspend/preview", op.token, %{
                 "reason_code" => "fraud"
               })
               |> json_response(409)

      # A stale revision.
      {:ok, execute, _} = confirmed(op.user, op.session, "user.lift_suspension", target.id)

      assert %{"error" => %{"code" => "revision_conflict"}} =
               call(:post, "#{@admin}/#{target.id}/lift-suspension", op.token, %{
                 execute
                 | "expected_revision" => 1
               })
               |> json_response(409)

      # Without a confirmation.
      assert %{"error" => %{"code" => "confirmation_required"}} =
               call(
                 :post,
                 "#{@admin}/#{target.id}/lift-suspension",
                 op.token,
                 Map.delete(execute, "confirmation_token")
               )
               |> json_response(428)
    end

    test "never against oneself, never against a platform operator's account" do
      op = operator!(@all)

      assert %{"error" => %{"code" => "conflict", "details" => %{"target" => "self"}}} =
               call(:post, "#{@admin}/#{op.user.id}/suspend/preview", op.token, %{
                 "reason_code" => "fraud"
               })
               |> json_response(409)

      assert %{"error" => %{"code" => "conflict", "details" => %{"target" => "self"}}} =
               call(:post, "#{@admin}/#{op.user.id}/sign-out-everywhere/preview", op.token, %{
                 "reason_code" => "account_compromise"
               })
               |> json_response(409)

      other = registered!("other-operator")

      {:ok, _} =
        Operators.provision(
          op.user,
          op.session,
          Map.merge(op(), %{"user_id" => other.id, "permissions" => ["users.read"]})
        )

      assert %{"error" => %{"code" => "conflict", "details" => %{"target" => "operator"}}} =
               call(:post, "#{@admin}/#{other.id}/suspend/preview", op.token, %{
                 "reason_code" => "fraud"
               })
               |> json_response(409)

      assert Repo.all(Restriction) == []
      assert Repo.exists?(from(e in AuditEvent, where: e.result_code == "self_action"))
    end
  end

  describe "sign out everywhere" do
    test "revokes every session of the account at once; the account stays active" do
      op = operator!(@all)
      target = registered!("target")
      sessions = for _ <- 1..3, do: credentials!(target)

      {_preview, _body, conn} =
        http_act(op.token, target.id, "sign-out-everywhere", "user_request")

      assert %{"user" => %{"status" => "active"}} = json_response(conn, 200)

      for creds <- sessions do
        assert me(creds.access_token) |> json_response(401)
        assert {:error, :unauthorized} = Accounts.refresh_session(creds.refresh_token)
      end

      assert me(credentials!(target).access_token) |> json_response(200)
      assert [%{reason_code: "user_request"}] = audit("user.signed_out_everywhere")
    end

    test "needs users.sessions.revoke, not users.restrict" do
      op = operator!(["users.read", "users.restrict"])
      target = registered!("target")

      assert %{"error" => %{"code" => "forbidden"}} =
               call(:post, "#{@admin}/#{target.id}/sign-out-everywhere/preview", op.token, %{
                 "reason_code" => "user_request"
               })
               |> json_response(403)
    end
  end

  test "over HTTP, a suspended account's emailed code is refused with account_suspended" do
    user = email_user!("suspended.http@example.com")
    op = operator!(@all)
    {_p, _b, conn} = http_act(op.token, user.id, "suspend", "fraud")
    assert json_response(conn, 200)

    post_json = fn path, body ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
    end

    post_json.("/api/auth/email/sign-in", %{email: "suspended.http@example.com"})
    code = code_from(last_email_to("suspended.http@example.com"))

    assert %{"error" => %{"code" => "account_suspended"}} =
             post_json.("/api/auth/email/sign-in/verify", %{
               email: "suspended.http@example.com",
               code: code
             })
             |> json_response(403)

    refute Repo.exists?(from(s in Session, where: s.user_id == ^user.id and is_nil(s.revoked_at)))
  end

  test "a suspended account's sign-in answers account_suspended" do
    user = email_user!("suspended.sign-in@example.com")
    op = operator!(@all)
    {_p, _b, conn} = http_act(op.token, user.id, "suspend", "terms_violation")
    assert json_response(conn, 200)
    assert {:error, :account_suspended} = Accounts.create_session(user)
    assert SimpleFitWeb.APIError.status("account_suspended") == 403
  end
end
