defmodule SimpleFitWeb.AdminConfigurationControllerTest do
  @moduledoc """
  SF-128 over HTTP, checked against OpenAPI: configuration governance. Who may read
  (`config.read`) and change (`config.flags.write`, fresh key check), the registry
  (only registered switches, no secret ever), suspend and restore through the SF-111
  framework (side-effect-free preview, one-time confirmation bound to flag, revision
  and reason, stale revisions, replays, repeats), the real consumers following the
  effective value (a member invitation refused, evidence uploads unavailable), the
  deployment staying the upper bound, append-only history and audit.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers
  import SimpleFit.OperatorHelpers

  alias SimpleFit.{Accounts, Configuration, Gyms, Operators, Repo}
  alias SimpleFit.Configuration.{FlagRevision, RuntimeFlag}
  alias SimpleFit.Gyms.{MemberInvitations, StaffInvitations}
  alias SimpleFit.Operators.AuditEvent
  alias SimpleFit.Sponsors.Evidence
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin/configuration"

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    gyms = Application.get_env(:simple_fit, SimpleFit.Gyms)
    stripe = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

    on_exit(fn ->
      Application.put_env(:simple_fit, SimpleFit.Gyms, gyms)
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, stripe)
    end)

    :ok
  end

  defp operator!(permissions) do
    user = registered!("operator")
    {:ok, credentials} = Accounts.create_session(user)
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

  defp provisioned!(founder, permissions) do
    user = registered!("reader")
    {:ok, credentials} = Accounts.create_session(user)

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

  defp get_json(path, token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  defp post_json(path, token, body),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp flag(key), do: Repo.get_by!(RuntimeFlag, key: key)

  defp preview!(token, flag, action, reason) do
    body = %{"reason_code" => reason, "expected_revision" => flag.revision}
    conn = post_json("#{@admin}/flags/#{flag.id}/#{action}/preview", token, body)
    preview = json_response(conn, 200)
    assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())
    Map.merge(body, %{"confirmation_token" => preview["preview"]["confirmation"]["token"]})
  end

  defp execute(token, flag, action, request, operation \\ Ecto.UUID.generate()),
    do:
      post_json(
        "#{@admin}/flags/#{flag.id}/#{action}",
        token,
        Map.put(request, "operation_id", operation)
      )

  defp suspend!(token, key, reason \\ "incident_response") do
    f = flag(key)
    request = preview!(token, f, "suspend", reason)
    body = execute(token, f, "suspend", request) |> json_response(200)
    assert_schema(body, "AdminConfigurationFlagResponse", ApiSpec.spec())
    body
  end

  describe "who may read and change" do
    test "anonymous 401; product roles 404; read and write need their own permission" do
      owner = registered!("owner")
      _gym = completed_gym!(owner)
      {:ok, owner_session} = Accounts.create_session(owner)
      f = flag("gym.member_invitations")

      paths = [@admin, "#{@admin}/flags/#{f.id}"]

      for path <- paths do
        assert build_conn() |> get(path) |> json_response(401)

        assert %{"error" => %{"code" => "not_found"}} =
                 get_json(path, owner_session.access_token) |> json_response(404)
      end

      founder = operator!(["operators.manage", "billing.read"])

      for path <- paths do
        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, founder.token) |> json_response(403)
      end

      reader = provisioned!(founder, ["config.read"])
      body = get_json(@admin, reader.token) |> json_response(200)
      assert_schema(body, "AdminConfigurationResponse", ApiSpec.spec())

      # Reading doesn't allow changing.
      assert %{"error" => %{"code" => "forbidden"}} =
               post_json("#{@admin}/flags/#{f.id}/suspend/preview", reader.token, %{
                 "reason_code" => "incident_response",
                 "expected_revision" => f.revision
               })
               |> json_response(403)

      assert MemberInvitations.delivery_enabled?()
    end

    test "a revoked write grant stops the next change" do
      founder = operator!(["operators.manage"])
      writer = provisioned!(founder, ["config.read", "config.flags.write"])
      f = flag("sponsor.application_emails")
      request = preview!(writer.token, f, "suspend", "release_issue")

      operator_id =
        Repo.one!(from(o in Operators.Operator, where: o.user_id == ^writer.user.id)).id

      {:ok, _} =
        act(founder.user, founder.session, "operator.permission.revoke", operator_id, %{
          "permission" => "config.flags.write"
        })

      assert %{"error" => %{"code" => "forbidden"}} =
               execute(writer.token, f, "suspend", request) |> json_response(403)

      refute flag("sponsor.application_emails").suspended
    end
  end

  describe "registry" do
    test "only registered switches, with their source, consumer, control and risk; never a secret" do
      Application.put_env(
        :simple_fit,
        SimpleFit.Billing.Stripe,
        Keyword.merge(Application.get_env(:simple_fit, SimpleFit.Billing.Stripe, []),
          secret_key: "sk_test_CANARYSECRETvalue123",
          webhook_secret: "whsec_CANARYwebhook123"
        )
      )

      reader = operator!(["config.read"])
      body = get_json(@admin, reader.token) |> json_response(200)
      assert_schema(body, "AdminConfigurationResponse", ApiSpec.spec())
      config = body["configuration"]
      assert config["environment"] == "test"

      keys = Enum.map(config["flags"], & &1["key"])
      assert Enum.sort(keys) == Enum.sort(Configuration.keys())

      suspendable = for f <- config["flags"], f["control"] == "suspendable", do: f["key"]

      assert Enum.sort(suspendable) ==
               ~w(gym.member_invitations gym.staff_invitations sponsor.application_emails sponsor.evidence_uploads)

      for f <- config["flags"], f["control"] != "suspendable" do
        assert f["flag_id"] == nil
        assert f["revision"] == nil
      end

      for key <- ~w(stripe.billing stripe.mode stripe.connect coaching.access) do
        assert %{"risk" => "high", "control" => "read_only"} =
                 Enum.find(config["flags"], &(&1["key"] == key))
      end

      invitations = Enum.find(config["flags"], &(&1["key"] == "gym.member_invitations"))

      assert %{
               "variable" => "GYM_MEMBER_INVITATIONS",
               "consumer" => "SimpleFit.Gyms.MemberInvitations.delivery_enabled?/0",
               "deployment_value" => true,
               "suspended" => false,
               "effective" => true
             } = invitations

      assert invitations["revision"] == flag("gym.member_invitations").revision

      assert Enum.find(config["flags"], &(&1["key"] == "stripe.mode"))["deployment_value"] ==
               "test"

      json = Jason.encode!(body)
      refute json =~ "CANARY"
      refute json =~ "sk_test"
      refute json =~ "whsec_"
      refute json =~ "DATABASE_URL"
      refute json =~ "postgres"
    end

    test "no key outside the allowlist can exist, even in the database" do
      assert_raise Ecto.ConstraintError, ~r/key_allowlist/, fn ->
        Repo.insert!(%RuntimeFlag{key: "stripe.billing"})
      end

      assert_raise Ecto.ConstraintError, ~r/runtime_flags_no_delete/, fn ->
        Repo.delete!(flag("gym.member_invitations"))
      end
    end

    test "an unknown or read-only switch can't be targeted; no route enables anything", _ctx do
      writer = operator!(["config.read", "config.flags.write"])
      body = %{"reason_code" => "incident_response", "expected_revision" => 1}

      for id <- [Ecto.UUID.generate(), "stripe.billing", "not-a-uuid"] do
        assert %{"error" => %{"code" => "not_found"}} =
                 post_json("#{@admin}/flags/#{id}/suspend/preview", writer.token, body)
                 |> json_response(404)
      end

      for {method, path} <- [
            {:post, "#{@admin}/flags/#{flag("gym.member_invitations").id}/enable"},
            {:put, "#{@admin}/flags/#{flag("gym.member_invitations").id}"},
            {:patch, @admin},
            {:post, "#{@admin}/environment"},
            {:post, "#{@admin}/stripe.billing/enable"}
          ] do
        assert %{"error" => %{"code" => "not_found"}} =
                 build_conn()
                 |> put_req_header("authorization", "Bearer " <> writer.token)
                 |> put_req_header("content-type", "application/json")
                 |> dispatch(@endpoint, method, path, ~s({"value": true}))
                 |> json_response(404)
      end

      assert Repo.aggregate(RuntimeFlag, :count) == 4
    end
  end

  describe "suspend and restore" do
    test "preview changes nothing; suspension turns the real consumer off; restore turns it back" do
      writer = operator!(["config.read", "config.flags.write"])
      owner = registered!("gym-owner")
      gym = completed_gym!(owner)
      f = flag("gym.member_invitations")

      request = preview!(writer.token, f, "suspend", "incident_response")
      # Side-effect free: same revision, same value, the consumer still on.
      assert flag("gym.member_invitations").revision == f.revision
      assert MemberInvitations.delivery_enabled?()

      assert {:ok, _, :created} =
               Gyms.create_member_invitation(
                 owner,
                 gym.id,
                 %{"email" => "a@example.com"},
                 client_ip()
               )

      body = execute(writer.token, f, "suspend", request) |> json_response(200)

      assert %{
               "suspended" => true,
               "effective" => false,
               "deployment_value" => true
             } = body["flag"]

      assert body["flag"]["revision"] == f.revision + 1

      assert [%{"change" => "suspend", "reason_code" => "incident_response"} = first] =
               body["flag"]["history"]

      assert first["revision"] == f.revision + 1

      # The real consumer follows.
      refute MemberInvitations.delivery_enabled?()

      assert {:error, {:conflict, %{member_invitation: "recipient_flow_unavailable"}}} =
               Gyms.create_member_invitation(
                 owner,
                 gym.id,
                 %{"email" => "b@example.com"},
                 client_ip()
               )

      # Restore: the deployment decides again.
      restored = flag("gym.member_invitations")
      request = preview!(writer.token, restored, "restore", "incident_resolved")
      body = execute(writer.token, restored, "restore", request) |> json_response(200)
      assert %{"suspended" => false, "effective" => true} = body["flag"]
      assert body["flag"]["revision"] == f.revision + 2
      assert MemberInvitations.delivery_enabled?()

      assert {:ok, _, :created} =
               Gyms.create_member_invitation(
                 owner,
                 gym.id,
                 %{"email" => "c@example.com"},
                 client_ip()
               )

      assert [f.revision + 2, f.revision + 1] ==
               Enum.map(body["flag"]["history"], & &1["revision"])

      events =
        Repo.all(
          from(e in AuditEvent,
            where: e.target_type == "runtime_flag" and e.outcome == :allowed,
            order_by: e.occurred_at,
            select: e.action
          )
        )

      assert events == ["config.flag_suspended", "config.flag_restored"]
    end

    test "evidence uploads become unavailable while suspended" do
      writer = operator!(["config.read", "config.flags.write"])
      assert Evidence.enabled?()
      suspend!(writer.token, "sponsor.evidence_uploads", "provider_outage")
      refute Evidence.enabled?()
      assert Evidence.policy().available == false
    end

    test "the deployment is the upper bound: restore never enables what it left off" do
      Application.put_env(
        :simple_fit,
        SimpleFit.Gyms,
        Keyword.put(Application.get_env(:simple_fit, SimpleFit.Gyms), :staff_invitations, false)
      )

      writer = operator!(["config.read", "config.flags.write"])
      f = flag("gym.staff_invitations")

      conn =
        post_json("#{@admin}/flags/#{f.id}/suspend/preview", writer.token, %{
          "reason_code" => "release_issue",
          "expected_revision" => f.revision
        })

      assert "deployment_disabled_no_effect" in json_response(conn, 200)["preview"]["impact"]

      body = suspend!(writer.token, "gym.staff_invitations", "release_issue")
      assert %{"deployment_value" => false, "effective" => false} = body["flag"]

      restored = flag("gym.staff_invitations")
      request = preview!(writer.token, restored, "restore", "release_fixed")
      body = execute(writer.token, restored, "restore", request) |> json_response(200)
      assert %{"suspended" => false, "effective" => false} = body["flag"]
      refute StaffInvitations.delivery_enabled?()
    end

    test "stale revision, replayed confirmation, repeated operation, wrong state and unknown reason" do
      a = operator!(["config.read", "config.flags.write", "operators.manage"])
      b = provisioned!(a, ["config.read", "config.flags.write"])
      f = flag("sponsor.application_emails")

      stale = preview!(a.token, f, "suspend", "release_issue")
      fresh = preview!(b.token, f, "suspend", "abuse_or_spam")
      operation = Ecto.UUID.generate()
      assert execute(b.token, f, "suspend", fresh, operation) |> json_response(200)

      # A previewed revision 1; B committed revision 2: A must preview again.
      assert %{"error" => %{"code" => "revision_conflict"}} =
               execute(a.token, f, "suspend", stale) |> json_response(409)

      # The same request again changes nothing and answers the current state.
      repeat = execute(b.token, f, "suspend", fresh, operation) |> json_response(200)
      assert repeat["flag"]["revision"] == f.revision + 1

      # A used confirmation can't be replayed for a new operation.
      assert %{"error" => %{"code" => "confirmation_invalid"}} =
               execute(b.token, flag("sponsor.application_emails"), "suspend", %{
                 fresh
                 | "expected_revision" => f.revision + 1
               })
               |> json_response(422)

      # Already suspended: a suspension preview is a conflict.
      assert %{"error" => %{"code" => "conflict", "details" => %{"status" => "suspended"}}} =
               post_json(
                 "#{@admin}/flags/#{f.id}/suspend/preview",
                 a.token,
                 %{"reason_code" => "release_issue", "expected_revision" => f.revision + 1}
               )
               |> json_response(409)

      # A confirmation is bound to its reason: changing the reason invalidates it.
      g = flag("sponsor.evidence_uploads")
      request = preview!(a.token, g, "suspend", "release_issue")

      assert %{"error" => %{"code" => "confirmation_invalid"}} =
               execute(a.token, g, "suspend", %{request | "reason_code" => "planned_maintenance"})
               |> json_response(422)

      assert %{"error" => %{"code" => "validation_error"}} =
               post_json("#{@admin}/flags/#{g.id}/suspend/preview", a.token, %{
                 "reason_code" => "because_i_said_so",
                 "expected_revision" => g.revision
               })
               |> json_response(422)

      assert Repo.aggregate(FlagRevision, :count) == 1
      refute flag("sponsor.evidence_uploads").suspended
    end

    test "history is append-only" do
      writer = operator!(["config.read", "config.flags.write"])
      suspend!(writer.token, "gym.member_invitations")
      [revision] = Repo.all(FlagRevision)

      assert_raise Ecto.ConstraintError, ~r/append_only/, fn ->
        revision |> Ecto.Changeset.change(reason_code: "other") |> Repo.update!()
      end

      assert_raise Ecto.ConstraintError, ~r/append_only/, fn -> Repo.delete!(revision) end
    end
  end
end
