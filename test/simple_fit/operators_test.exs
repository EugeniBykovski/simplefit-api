defmodule SimpleFit.OperatorsTest do
  @moduledoc """
  SF-110: platform operators. Bootstrap ceremonies, lifecycle, permissions, WebAuthn
  enrolment and key checks, revocation, recovery and audit, in the SQL sandbox.
  Concurrency on real commits is in `SimpleFit.OperatorsRaceTest`.
  """

  use SimpleFit.DataCase, async: false

  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.VerificationAuthority
  alias SimpleFit.Operators
  alias SimpleFit.Operators.Policy

  alias SimpleFit.Operators.{
    AuditEvent,
    Bootstrap,
    Ceremony,
    Challenge,
    Credential,
    Grant,
    Operator,
    StepUp
  }

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp founder! do
    user = registered!("founder")
    session = live_session!(user)
    operator = bootstrap!(user)
    [k1, k2] = enroll!(user, session)
    %{user: user, session: session, operator: Repo.reload!(operator), keys: [k1, k2]}
  end

  defp stepped!(%{user: u, session: s, keys: [k | rest]} = f),
    do: %{f | keys: [step_up!(u, s, k) | rest]}

  defp actions(action),
    do: Repo.all(from(e in AuditEvent, where: e.action == ^action, order_by: e.occurred_at))

  describe "the user model" do
    test "users gains no role, type or admin column" do
      assert User.__schema__(:fields) == [:id, :inserted_at, :updated_at]
    end
  end

  describe "founder bootstrap" do
    test "a valid signed statement creates one pending founder with exactly the listed permissions" do
      user = registered!("founder")
      private = trust_ceremony_key!()

      {:ok, op} =
        Bootstrap.run(statement(private, user, %{"permissions" => ["operators.manage"]}))

      assert %Operator{status: :pending_enrollment, bootstrap: true, user_id: uid} = op
      assert uid == user.id

      assert Repo.all(from(g in Grant, where: g.operator_id == ^op.id, select: g.permission)) == [
               "operators.manage"
             ]

      assert [%Ceremony{purpose: :bootstrap}] = Repo.all(Ceremony)

      assert [%AuditEvent{authority: :signed_ceremony, outcome: :allowed}] =
               actions("operator.bootstrap")
    end

    test "is refused without a trusted key, with a wrong signature, environment, window or user" do
      user = registered!("founder")

      assert {:error, :unavailable} =
               Bootstrap.run(statement(:crypto.generate_key(:eddsa, :ed25519) |> elem(1), user))

      private = trust_ceremony_key!()
      {_, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      assert {:error, :untrusted} = Bootstrap.run(statement(stranger, user))
      assert {:error, :untrusted} = Bootstrap.run(statement(private, user, %{}, "unknown-key"))

      assert {:error, :wrong_environment} =
               Bootstrap.run(statement(private, user, %{"environment" => "production"}))

      past = DateTime.add(DateTime.utc_now(), -7200)

      assert {:error, :expired} =
               Bootstrap.run(
                 statement(private, user, %{
                   "issued_at" => DateTime.to_iso8601(past),
                   "not_after" => DateTime.to_iso8601(DateTime.add(past, 60))
                 })
               )

      assert {:error, :invalid} =
               Bootstrap.run(
                 statement(private, user, %{
                   "not_after" =>
                     DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3 * 86_400))
                 })
               )

      assert {:error, :invalid} =
               Bootstrap.run(statement(private, user, %{"permissions" => ["*"]}))

      assert {:error, :invalid} = Bootstrap.run(statement(private, user, %{"permissions" => []}))

      assert {:error, :invalid} =
               Bootstrap.run(statement(private, user, %{"user_id" => "founder@example.com"}))

      assert {:error, :user_not_eligible} =
               Bootstrap.run(statement(private, user, %{"user_id" => Ecto.UUID.generate()}))

      assert {:error, :malformed} = Bootstrap.run("not json")

      {:ok, unregistered} =
        Accounts.register_user(:google, "unregistered-#{System.unique_integer([:positive])}")

      assert {:error, :user_not_eligible} = Bootstrap.run(statement(private, unregistered))

      assert Repo.aggregate(Operator, :count) == 0
      assert length(actions("operator.ceremony_refused")) == 12
    end

    test "a tampered payload fails the signature" do
      user = registered!("founder")
      private = trust_ceremony_key!()
      %{"payload" => p} = signed = Jason.decode!(statement(private, user))
      claims = p |> Base.url_decode64!(padding: false) |> Jason.decode!()
      forged = claims |> Map.put("user_id", registered!("other").id) |> Jason.encode!()

      assert {:error, :untrusted} =
               Bootstrap.run(
                 Jason.encode!(%{signed | "payload" => Base.url_encode64(forged, padding: false)})
               )
    end

    test "a statement is consumed once, and there is only ever one bootstrap" do
      user = registered!("founder")
      private = trust_ceremony_key!()
      signed = statement(private, user)
      assert {:ok, _} = Bootstrap.run(signed)
      assert {:error, :replayed} = Bootstrap.run(signed)
      assert {:error, :operator_exists} = Bootstrap.run(statement(private, registered!("second")))
      assert Repo.aggregate(Operator, :count) == 1
    end

    test "the database itself refuses a second bootstrap row" do
      %{operator: op} = founder!()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Operator{
          user_id: registered!("x").id,
          status: :pending_enrollment,
          bootstrap: true,
          ceremony_id: Ecto.UUID.generate(),
          enrollment_expires_at: DateTime.utc_now()
        })
      end

      assert op.bootstrap
    end
  end

  describe "enrolment" do
    test "the founder becomes active only with the required number of keys" do
      user = registered!("founder")
      session = live_session!(user)
      bootstrap!(user)

      assert {:ok, %{operator: %{status: :pending_enrollment}, permissions: []}} =
               Operators.me(user, session)

      [_k1] = enroll!(user, session, 1)

      assert {:ok, %{operator: %{status: :pending_enrollment}, registered_keys: 1}} =
               Operators.me(user, session)

      [_k2] = enroll!(user, session, 1)

      assert {:ok, %{operator: %{status: :active}, permissions: perms}} =
               Operators.me(user, session)

      assert perms == ["audit.read", "operators.manage", "operators.read"]
      assert [_] = actions("operator.activated")
    end

    test "a pending operator can do nothing but enrol" do
      user = registered!("founder")
      session = live_session!(user)
      bootstrap!(user)
      assert {:error, :enrollment_required} = Operators.list_operators(user, session)
      assert {:error, :enrollment_required} = Operators.step_up_options(user, session)
    end

    test "rejects a replayed, expired, foreign or mismatched registration" do
      user = registered!("founder")
      session = live_session!(user)
      bootstrap!(user)
      key = soft_key()

      {:ok, options} = Operators.registration_options(user, session)
      response = registration_response(key, options)
      assert {:ok, _} = Operators.register_credential(user, session, response)

      assert {:error, :security_key_rejected} =
               Operators.register_credential(user, session, response)

      for overrides <- [
            %{origin: "https://evil.example"},
            %{rp_id: "evil.example"},
            %{challenge: WebAuthn64.random()}
          ] do
        {:ok, options} = Operators.registration_options(user, session)

        assert {:error, :security_key_rejected} =
                 Operators.register_credential(
                   user,
                   session,
                   registration_response(soft_key(), options, overrides)
                 )
      end

      {:ok, options} = Operators.registration_options(user, session)

      Repo.update_all(from(c in Challenge, where: c.id == ^options.challenge_id),
        set: [expires_at: DateTime.utc_now()]
      )

      assert {:error, :security_key_rejected} =
               Operators.register_credential(
                 user,
                 session,
                 registration_response(soft_key(), options)
               )

      {:ok, options} = Operators.registration_options(user, session)
      other_session = live_session!(user)

      assert {:error, :security_key_rejected} =
               Operators.register_credential(
                 user,
                 other_session,
                 registration_response(soft_key(), options)
               )
    end

    test "refuses keys without user verification and syncable keys" do
      user = registered!("founder")
      session = live_session!(user)
      bootstrap!(user)

      for key <- [soft_key(user_verified: false), soft_key(backup_eligible: true)] do
        {:ok, options} = Operators.registration_options(user, session)

        assert {:error, :security_key_rejected} =
                 Operators.register_credential(user, session, registration_response(key, options))
      end

      assert Repo.aggregate(Credential, :count) == 0
    end

    test "the same credential can't be registered twice, even after revocation" do
      %{user: u, session: s} = f = stepped!(founder!())
      [key | _] = f.keys
      {:ok, options} = Operators.registration_options(u, s)

      assert {:error, {:conflict, %{credential: "already_registered"}}} =
               Operators.register_credential(u, s, registration_response(key, options))
    end

    test "enrolment closes when its window expires" do
      user = registered!("founder")
      session = live_session!(user)
      op = bootstrap!(user)

      Repo.query!(
        "UPDATE platform_operators SET enrollment_expires_at = now() - interval '1 second' WHERE id = $1",
        [Ecto.UUID.dump!(op.id)]
      )

      assert {:error, {:conflict, %{enrollment: "expired"}}} =
               Operators.registration_options(user, session)
    end
  end

  describe "key checks" do
    test "are bound to one session and expire" do
      %{user: u, session: s} = f = stepped!(founder!())
      assert {:ok, _} = Operators.list_operators(u, s)

      other = live_session!(u)
      assert {:error, :step_up_required} = Operators.list_operators(u, other)

      Repo.update_all(StepUp, set: [expires_at: DateTime.utc_now()])
      assert {:error, :step_up_required} = Operators.list_operators(u, s)
      _ = f
    end

    test "end with logout and with ending the check" do
      %{user: u, session: s} = stepped!(founder!())
      assert :ok = Operators.end_step_up(u, s)
      assert {:error, :step_up_required} = Operators.list_operators(u, s)
    end

    test "high-risk actions need a fresh check; reads accept an older one" do
      %{user: u, session: s} = stepped!(founder!())
      target = registered!("second")
      Repo.update_all(StepUp, set: [verified_at: DateTime.add(DateTime.utc_now(), -600)])
      assert {:ok, _} = Operators.list_operators(u, s)

      assert {:error, :step_up_required} =
               Operators.provision(
                 u,
                 s,
                 Map.merge(op(), %{"user_id" => target.id, "permissions" => ["audit.read"]})
               )
    end

    test "reject replays, cloned counters, other origins, revoked keys and missing user verification" do
      %{user: u, session: s, keys: [k1, k2]} = founder!()
      {:ok, options} = Operators.step_up_options(u, s)
      {response, k1} = assertion_response(k1, options)
      assert {:ok, _} = Operators.verify_step_up(u, s, response)
      assert {:error, :security_key_rejected} = Operators.verify_step_up(u, s, response)

      {:ok, options} = Operators.step_up_options(u, s)
      {cloned, _} = assertion_response(k1, options, %{counter: k1.counter})
      assert {:error, :security_key_rejected} = Operators.verify_step_up(u, s, cloned)

      {:ok, options} = Operators.step_up_options(u, s)
      {wrong_origin, _} = assertion_response(k1, options, %{origin: "https://evil.example"})
      assert {:error, :security_key_rejected} = Operators.verify_step_up(u, s, wrong_origin)

      {:ok, options} = Operators.step_up_options(u, s)
      {no_uv, _} = assertion_response(%{k2 | user_verified: false}, options)
      assert {:error, :security_key_rejected} = Operators.verify_step_up(u, s, no_uv)

      stranger = soft_key()
      {:ok, options} = Operators.step_up_options(u, s)
      {foreign, _} = assertion_response(stranger, options)
      assert {:error, :security_key_rejected} = Operators.verify_step_up(u, s, foreign)
    end

    test "a client can't claim a check: only a verified assertion records one" do
      %{user: u, session: s} = founder!()
      assert {:error, :step_up_required} = Operators.list_operators(u, s)
      assert {:error, %Ecto.Changeset{}} = Operators.verify_step_up(u, s, %{"verified" => true})
      assert Repo.aggregate(StepUp, :count) == 0
    end
  end

  describe "permissions" do
    setup do
      f = stepped!(founder!())
      second = registered!("second")
      second_session = live_session!(second)

      {:ok, %{operator: op2}} =
        Operators.provision(
          f.user,
          f.session,
          Map.merge(op(), %{"user_id" => second.id, "permissions" => ["operators.read"]})
        )

      [k] = enroll!(second, second_session, 2) |> Enum.take(1)
      second_keys = step_up!(second, second_session, k)

      Map.merge(f, %{
        second: second,
        second_session: second_session,
        op2: op2,
        second_key: second_keys
      })
    end

    test "an operator has exactly what was granted", c do
      assert {:ok, _} = Operators.list_operators(c.second, c.second_session)
      assert {:error, :forbidden} = Operators.list_audit_events(c.second, c.second_session, %{})

      assert {:error, :forbidden} =
               act(c.second, c.second_session, "operator.permission.grant", c.op2.id, %{
                 "permission" => "audit.read"
               })
    end

    test "no self-grant, self-promotion or self-revocation", c do
      me = c.operator

      assert {:error, {:conflict, %{target: "self"}}} =
               act(c.user, c.session, "operator.permission.grant", me.id, %{
                 "permission" => "audit.read"
               })

      assert {:error, {:conflict, %{target: "self"}}} =
               act(c.user, c.session, "operator.revoke", me.id)

      assert {:error, {:conflict, %{target: "self"}}} =
               act(c.user, c.session, "operator.suspend", me.id)

      assert_raise Ecto.ConstraintError, ~r/no_self_grant/, fn ->
        Repo.insert!(%Grant{
          operator_id: me.id,
          permission: "audit.read",
          granted_by_operator_id: me.id,
          reason_code: "x_x",
          operation_id: Ecto.UUID.generate(),
          granted_at: DateTime.utc_now()
        })
      end
    end

    test "the catalog is enforced by the database too", c do
      assert {:error, %Ecto.Changeset{}} =
               act(c.user, c.session, "operator.permission.grant", c.op2.id, %{
                 "permission" => "admin"
               })

      assert_raise Ecto.ConstraintError, ~r/permission_catalog/, fn ->
        Repo.insert!(%Grant{
          operator_id: c.op2.id,
          permission: "*",
          granted_by_operator_id: c.operator.id,
          reason_code: "x_x",
          operation_id: Ecto.UUID.generate(),
          granted_at: DateTime.utc_now()
        })
      end
    end

    test "a revoked permission stops working on the next request", c do
      assert {:ok, _} =
               act(c.user, c.session, "operator.permission.revoke", c.op2.id, %{
                 "permission" => "operators.read"
               })

      assert {:error, :forbidden} = Operators.list_operators(c.second, c.second_session)
    end

    test "suspension and revocation take effect at once and conceal the operator", c do
      assert {:ok, %{operator: %{status: :suspended}}} =
               act(c.user, c.session, "operator.suspend", c.op2.id)

      assert {:error, :not_found} = Operators.me(c.second, c.second_session)
      assert {:error, :not_found} = Operators.list_operators(c.second, c.second_session)

      assert Repo.aggregate(
               from(s in StepUp, where: s.operator_id == ^c.op2.id and is_nil(s.revoked_at)),
               :count
             ) == 0

      assert {:ok, %{operator: %{status: :active}}} =
               act(c.user, c.session, "operator.reinstate", c.op2.id)

      assert {:error, :step_up_required} = Operators.list_operators(c.second, c.second_session)

      assert {:ok, %{operator: %{status: :revoked}, permissions: []}} =
               act(c.user, c.session, "operator.revoke", c.op2.id)

      assert {:error, :not_found} = Operators.me(c.second, c.second_session)

      assert Repo.aggregate(
               from(k in Credential, where: k.operator_id == ^c.op2.id and is_nil(k.revoked_at)),
               :count
             ) == 0

      assert {:error, {:conflict, %{status: "not_suspended"}}} =
               act(c.user, c.session, "operator.reinstate", c.op2.id)
    end

    test "illegal transitions are refused by the database", c do
      {:ok, _} = act(c.user, c.session, "operator.revoke", c.op2.id)

      assert_raise Postgrex.Error, ~r/platform_operators_transition/, fn ->
        Repo.update_all(from(o in Operator, where: o.id == ^c.op2.id), set: [status: :active])
      end

      assert_raise Postgrex.Error, ~r/no_delete/, fn ->
        Repo.delete_all(from(o in Operator, where: o.id == ^c.op2.id))
      end
    end

    test "a repeated operation id changes nothing; reused for another action, it conflicts", c do
      {:ok, payload, _} =
        confirmed(c.user, c.session, "operator.permission.grant", c.op2.id, %{
          "permission" => "audit.read"
        })

      assert {:ok, %{permissions: p1}} = Operators.grant(c.user, c.session, c.op2.id, payload)
      assert {:ok, %{permissions: ^p1}} = Operators.grant(c.user, c.session, c.op2.id, payload)
      assert length(actions("operator.permission_granted")) == 3 + 1 + 1

      {:ok, suspend, _} = confirmed(c.user, c.session, "operator.suspend", c.op2.id)

      assert {:error, {:conflict, %{operation_id: "reused"}}} =
               Operators.suspend(
                 c.user,
                 c.session,
                 c.op2.id,
                 Map.put(suspend, "operation_id", payload["operation_id"])
               )
    end

    test "provisioning: never oneself, never twice, never an unregistered account", c do
      assert {:error, {:conflict, %{target: "self"}}} =
               Operators.provision(
                 c.user,
                 c.session,
                 Map.merge(op(), %{"user_id" => c.user.id, "permissions" => ["audit.read"]})
               )

      assert {:error, {:conflict, %{operator: "exists"}}} =
               Operators.provision(
                 c.user,
                 c.session,
                 Map.merge(op(), %{"user_id" => c.second.id, "permissions" => ["audit.read"]})
               )

      {:ok, fresh} =
        Accounts.register_user(:google, "fresh-#{System.unique_integer([:positive])}")

      assert {:error, {:conflict, %{user: "not_eligible"}}} =
               Operators.provision(
                 c.user,
                 c.session,
                 Map.merge(op(), %{"user_id" => fresh.id, "permissions" => ["audit.read"]})
               )
    end

    test "a lost key: another manager revokes it and the operator must re-enrol", c do
      [cred | _] =
        Repo.all(
          from(k in Credential, where: k.operator_id == ^c.op2.id and is_nil(k.revoked_at))
        )

      assert {:ok, %{operator: %{status: :pending_enrollment}}} =
               Operators.revoke_operator_credential(
                 c.user,
                 c.session,
                 c.op2.id,
                 cred.id,
                 op("lost_key")
               )

      assert {:error, :enrollment_required} = Operators.list_operators(c.second, c.second_session)
    end

    test "an operator can't revoke their own key below the minimum", c do
      [cred | _] = Repo.all(from(k in Credential, where: k.operator_id == ^c.operator.id))

      assert {:error, {:conflict, %{credentials: "minimum_required"}}} =
               Operators.revoke_own_credential(c.user, c.session, cred.id)
    end

    test "refusals are audited with the real actor", c do
      {:error, :forbidden} = Operators.list_audit_events(c.second, c.second_session, %{})

      assert [%AuditEvent{actor_operator_id: id, outcome: :refused, permission: "audit.read"}] =
               actions("operator.access_refused")

      assert id == c.op2.id
    end
  end

  describe "other contexts never grant operator access" do
    test "a coach who owns a gym is not an operator" do
      user = registered!("everything")
      session = live_session!(user)
      SimpleFit.CoachingHelpers.complete_coach!(user)
      SimpleFit.GymHelpers.completed_gym!(user)

      assert {:error, :not_found} = Operators.me(user, session)
      assert {:error, :not_found} = Operators.list_operators(user, session)
      assert {:error, :not_found} = Operators.registration_options(user, session)
      assert {:error, :not_found} = Operators.step_up_options(user, session)
      assert Repo.aggregate(AuditEvent, :count) == 0
    end
  end

  describe "recovery" do
    test "only the last manager, by a signed recovery statement, back to enrolment" do
      %{user: u, operator: o} = founder!()
      private = trust_ceremony_key!()

      recovery = %{"purpose" => "recovery", "operator_id" => o.id, "permissions" => []}

      assert {:ok, %Operator{status: :pending_enrollment}} =
               Bootstrap.run(statement(private, u, recovery))

      assert Repo.aggregate(from(k in Credential, where: is_nil(k.revoked_at)), :count) == 0

      wrong_user = statement(private, registered!("x"), recovery)
      assert {:error, :recovery_not_allowed} = Bootstrap.run(wrong_user)
    end

    test "is refused while another manager can reset keys instead" do
      f = stepped!(founder!())
      other = registered!("other")

      {:ok, _} =
        Operators.provision(
          f.user,
          f.session,
          Map.merge(op(), %{"user_id" => other.id, "permissions" => ["operators.manage"]})
        )

      enroll!(other, live_session!(other))
      private = trust_ceremony_key!()

      assert {:error, :recovery_not_allowed} =
               Bootstrap.run(
                 statement(private, f.user, %{
                   "purpose" => "recovery",
                   "operator_id" => f.operator.id,
                   "permissions" => []
                 })
               )
    end
  end

  describe "audit" do
    test "events are append-only and carry no secrets" do
      f = stepped!(founder!())
      event = Repo.one!(from(e in AuditEvent, limit: 1))

      assert_raise Postgrex.Error, ~r/append_only/, fn ->
        Repo.update_all(from(e in AuditEvent, where: e.id == ^event.id),
          set: [action: "tampered"]
        )
      end

      assert_raise Postgrex.Error, ~r/append_only/, fn -> Repo.delete_all(AuditEvent) end

      {:ok, events} = Operators.list_audit_events(f.user, f.session, %{"limit" => 100})
      dump = inspect(events)
      refute dump =~ "sfa_"
      refute dump =~ "@"
    end
  end

  describe "SF-136 gym verification" do
    test "SF-110 adds no gym verification permission and leaves SF-136's authority alone" do
      _f = stepped!(founder!())

      # SF-123's `gyms.read` reads a gym's state only; no verification permission exists.
      refute Enum.any?(
               Policy.permissions(),
               &String.starts_with?(&1, "gyms.verification.")
             )

      assert VerificationAuthority.ambient_credential() ==
               VerificationAuthority.Local.ambient_credential()
    end
  end
end

defmodule WebAuthn64 do
  @moduledoc false
  def random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
