defmodule SimpleFit.Operators.AdminActionsTest do
  @moduledoc """
  SF-111: the admin action framework in the SQL sandbox. Declarations, the trusted
  actor, permissions and key checks, reason codes, revisions, previews, confirmations,
  transactions, idempotency, audit, redaction and telemetry. Concurrency on real
  commits is in `SimpleFit.OperatorsRaceTest`; HTTP in `SimpleFitWeb.OperatorControllerTest`.
  """

  use SimpleFit.DataCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias SimpleFit.Operators

  alias SimpleFit.Operators.{
    Actions,
    Audit,
    AuditEvent,
    Confirmation,
    Operation,
    Operator,
    Policy
  }

  alias SimpleFit.Operators.{Grant, Redaction, StepUp}

  @canary "CANARY-7f3c-do-not-store"

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    founder = founder!()
    second = operator!(founder, "second", ["operators.read"])
    %{f: founder, second: second}
  end

  defp founder! do
    user = registered!("founder")
    session = live_session!(user)
    op = bootstrap!(user)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp operator!(founder, prefix, permissions) do
    user = registered!(prefix)
    session = live_session!(user)

    {:ok, %{operator: op}} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: Repo.reload!(op), key: step_up!(user, session, k)}
  end

  defp events(command),
    do:
      Repo.all(
        from(e in AuditEvent, where: e.command == ^command, order_by: [e.occurred_at, e.id])
      )

  defp revision(id), do: Repo.get!(Operator, id).revision

  # Moves this session's key check out of the fresh window (StepUp isn't append-only).
  defp stale_step_up!(%{operator: op, session: s}) do
    old = DateTime.add(DateTime.utc_now(), -(Policy.fresh_window() + 60))

    Repo.update_all(from(x in StepUp, where: x.operator_id == ^op.id and x.session_id == ^s.id),
      set: [verified_at: old]
    )
  end

  describe "declarations" do
    test "only declared actions exist, each with a catalogued permission, reasons and a fresh key check" do
      assert Actions.ids() == [
               "operator.permission.grant",
               "operator.permission.revoke",
               "operator.suspend",
               "operator.reinstate",
               "operator.revoke"
             ]

      for id <- Actions.ids(), action = Actions.fetch!(id) do
        assert Policy.permission?(action.permission)
        assert action.assurance == :fresh_key
        assert action.reasons != []
        assert Enum.all?(action.reasons, &(&1 =~ ~r/^[a-z][a-z0-9_]{1,59}$/))
        assert action.confirmation in [:required, :none]
      end

      assert_raise ArgumentError, fn -> Actions.fetch!("users.delete") end
      refute function_exported?(Operators, :execute_sql, 1)
    end

    test "every action that widens or ends access needs confirmation; narrowing doesn't" do
      required = for id <- Actions.ids(), Actions.fetch!(id).confirmation == :required, do: id
      assert required -- ["operator.permission.revoke"] == required
      assert Actions.fetch!("operator.permission.revoke").confirmation == :none
    end
  end

  describe "the trusted actor" do
    test "a non-operator gets not_found for every action, and leaves no audit row", c do
      plain = registered!("plain")
      session = live_session!(plain)
      before = Repo.aggregate(AuditEvent, :count)

      for id <- Actions.ids() do
        assert {:error, :not_found} =
                 Operators.preview(id, plain, session, c.second.operator.id, %{})

        assert {:error, :not_found} =
                 Operators.execute(id, plain, session, c.second.operator.id, %{})
      end

      assert Repo.aggregate(AuditEvent, :count) == before
    end

    test "actor ids in the body are ignored: the actor is the session's operator", c do
      {:ok, payload, _} =
        confirmed(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      forged =
        Map.merge(payload, %{
          "actor_operator_id" => c.second.operator.id,
          "operator_id" => c.second.operator.id,
          "user_id" => c.second.user.id
        })

      assert {:ok, _} = Operators.suspend(c.f.user, c.f.session, c.second.operator.id, forged)
      [event] = events("operator.suspend")
      assert event.actor_operator_id == c.f.operator.id
      assert event.actor_user_id == c.f.user.id
      assert event.session_id == c.f.session.id
    end

    test "a suspended or revoked actor is concealed, also after its preview", c do
      manager = operator!(c.f, "manager", ["operators.manage", "operators.read"])
      third = operator!(c.f, "third", ["operators.read"])

      {:ok, payload, _} =
        confirmed(manager.user, manager.session, "operator.suspend", third.operator.id)

      {:ok, _} = act(c.f.user, c.f.session, "operator.revoke", manager.operator.id)

      assert {:error, :not_found} =
               Operators.suspend(manager.user, manager.session, third.operator.id, payload)

      assert Repo.get!(Operator, third.operator.id).status == :active
    end
  end

  describe "permissions and key checks" do
    test "a missing capability is refused before validation, and audited", c do
      assert {:error, :forbidden} =
               Operators.preview(
                 "operator.suspend",
                 c.second.user,
                 c.second.session,
                 c.f.operator.id,
                 %{}
               )

      assert {:error, :forbidden} =
               Operators.execute(
                 "operator.suspend",
                 c.second.user,
                 c.second.session,
                 c.f.operator.id,
                 %{}
               )

      assert [
               %{outcome: :refused, result_code: "forbidden"},
               %{outcome: :refused, result_code: "forbidden"}
             ] =
               events("operator.suspend")

      assert Enum.all?(
               events("operator.suspend"),
               &(&1.actor_operator_id == c.second.operator.id)
             )
    end

    test "a key check older than the fresh window is refused for preview and execution", c do
      {:ok, payload, _} =
        confirmed(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      stale_step_up!(c.f)

      assert {:error, :step_up_required} =
               confirmed(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      assert {:error, :step_up_required} =
               Operators.suspend(c.f.user, c.f.session, c.second.operator.id, payload)

      assert Repo.get!(Operator, c.second.operator.id).status == :active

      assert Enum.all?(
               events("operator.suspend"),
               &(&1.outcome == :refused and &1.result_code == "step_up_required")
             )
    end

    test "gym ownership grants nothing here", c do
      owner = registered!("owner")
      session = live_session!(owner)

      {:ok, _gym, _outcome} =
        SimpleFit.Gyms.create_gym(
          owner,
          %{
            "name" => "SF111 Gym",
            "gym_type" => "boxing_gym",
            "client_request_id" => Ecto.UUID.generate()
          },
          "127.0.0.1"
        )

      assert {:error, :not_found} =
               Operators.preview("operator.suspend", owner, session, c.second.operator.id, %{
                 "reason_code" => "security_concern"
               })
    end
  end

  describe "reason codes" do
    test "only the action's own codes are accepted; free text is never stored", c do
      for reason <- ["left_organization", "Because I said so", "", nil] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Operators.preview(
                   "operator.permission.grant",
                   c.f.user,
                   c.f.session,
                   c.second.operator.id,
                   %{
                     "permission" => "audit.read",
                     "reason_code" => reason
                   }
                 )

        assert Keyword.has_key?(cs.errors, :reason_code)
      end

      {:ok, payload, _} =
        confirmed(c.f.user, c.f.session, "operator.permission.grant", c.second.operator.id, %{
          "permission" => "audit.read"
        })

      assert {:error, %Ecto.Changeset{}} =
               Operators.grant(c.f.user, c.f.session, c.second.operator.id, %{
                 payload
                 | "reason_code" => "security_concern"
               })

      assert [%{outcome: :invalid, result_code: "validation_failed"}] =
               events("operator.permission.grant")
    end
  end

  describe "preview" do
    test "shows current and proposed state, impact and needs, and changes nothing", c do
      target = c.second.operator
      before = Repo.get!(Operator, target.id)
      operations = Repo.aggregate(Operation, :count)

      assert {:ok, preview} =
               Operators.preview("operator.revoke", c.f.user, c.f.session, target.id, %{
                 "reason_code" => "left_organization"
               })

      assert %{
               action: "operator.revoke",
               target: %{type: "operator", status: "active"},
               current_state: "active",
               proposed_state: "revoked",
               required_permission: "operators.manage",
               required_assurance: "fresh_key",
               confirmation: %{required: true, token: "sfc_" <> _}
             } = preview

      assert preview.expected_revision == before.revision
      assert "irreversible" in preview.impact
      assert Repo.get!(Operator, target.id) == before
      assert Repo.aggregate(Operation, :count) == operations
    end

    test "an action without confirmation previews without a token", c do
      assert {:ok, %{confirmation: %{required: false, token: nil}, proposed_state: "revoked"}} =
               Operators.preview(
                 "operator.permission.revoke",
                 c.f.user,
                 c.f.session,
                 c.second.operator.id,
                 %{
                   "reason_code" => "role_change",
                   "permission" => "operators.read"
                 }
               )

      assert Repo.aggregate(Confirmation, :count) == 0
    end

    test "unknown, malformed and self targets; impossible changes; stale revisions", c do
      reason = %{"reason_code" => "security_concern"}

      for id <- [Ecto.UUID.generate(), "1; DROP TABLE users", nil] do
        assert {:error, :not_found} =
                 Operators.preview("operator.suspend", c.f.user, c.f.session, id, reason)
      end

      assert {:error, {:conflict, %{target: "self"}}} =
               Operators.preview(
                 "operator.suspend",
                 c.f.user,
                 c.f.session,
                 c.f.operator.id,
                 reason
               )

      {:ok, _} = act(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      assert {:error, {:conflict, %{status: "not_active"}}} =
               Operators.preview(
                 "operator.suspend",
                 c.f.user,
                 c.f.session,
                 c.second.operator.id,
                 reason
               )

      assert {:error, {:revision_conflict, %{current_revision: current}}} =
               Operators.preview(
                 "operator.reinstate",
                 c.f.user,
                 c.f.session,
                 c.second.operator.id,
                 %{"reason_code" => "administrative_correction", "expected_revision" => 1}
               )

      assert current == revision(c.second.operator.id)
      assert Repo.aggregate(Confirmation, :count) == 1
    end
  end

  describe "confirmation" do
    setup c do
      {:ok, payload, preview} =
        confirmed(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      %{payload: payload, preview: preview, target: c.second.operator.id}
    end

    test "a confirmed execution commits once; the token can't be used again", c do
      assert {:ok, %{operator: %{status: :suspended}}} =
               Operators.suspend(c.f.user, c.f.session, c.target, c.payload)

      assert Repo.one!(Confirmation).consumed_at

      replay = %{
        c.payload
        | "operation_id" => Ecto.UUID.generate(),
          "expected_revision" => revision(c.target)
      }

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, c.target, replay)
    end

    test "without a token the action is refused with confirmation_required", c do
      assert {:error, :confirmation_required} =
               Operators.suspend(
                 c.f.user,
                 c.f.session,
                 c.target,
                 Map.delete(c.payload, "confirmation_token")
               )

      assert Repo.get!(Operator, c.target).status == :active
    end

    test "a tampered token, reason, action or target is invalid", c do
      "sfc_" <> rest = c.payload["confirmation_token"]
      flipped = "sfc_" <> String.reverse(rest)

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, c.target, %{
                 c.payload
                 | "confirmation_token" => flipped
               })

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, c.target, %{
                 c.payload
                 | "confirmation_token" => "x"
               })

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, c.target, %{
                 c.payload
                 | "reason_code" => "policy_violation"
               })

      assert {:error, :confirmation_invalid} =
               Operators.revoke(c.f.user, c.f.session, c.target, %{
                 c.payload
                 | "reason_code" => "security_concern"
               })

      other = operator!(c.f, "other", ["operators.read"])

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, other.operator.id, %{
                 c.payload
                 | "expected_revision" => revision(other.operator.id)
               })

      assert Repo.get!(Operator, c.target).status == :active

      assert is_nil(
               Repo.one!(from(x in Confirmation, where: x.target_id == ^c.target)).consumed_at
             )

      assert events("operator.suspend") |> Enum.map(& &1.result_code) |> Enum.uniq() ==
               ["confirmation_invalid"]
    end

    test "a token from another session of the same operator is invalid", c do
      other_session = live_session!(c.f.user)
      _ = step_up!(c.f.user, other_session, c.f.key)

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, other_session, c.target, c.payload)
    end

    test "an expired token is invalid", c do
      real = Repo.one!(Confirmation)
      token = "sfc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      past = DateTime.add(DateTime.utc_now(), -10)

      Repo.insert!(
        Ecto.put_meta(
          %{
            real
            | id: nil,
              token_sha256: :crypto.hash(:sha256, token),
              inserted_at: DateTime.add(past, -Policy.confirmation_ttl()),
              expires_at: past
          },
          state: :built
        )
      )

      assert {:error, :confirmation_invalid} =
               Operators.suspend(c.f.user, c.f.session, c.target, %{
                 c.payload
                 | "confirmation_token" => token
               })
    end

    test "a change after the preview makes it stale: revision_conflict, nothing consumed", c do
      {:ok, _} =
        act(c.f.user, c.f.session, "operator.permission.grant", c.target, %{
          "permission" => "audit.read"
        })

      assert {:error, {:revision_conflict, %{current_revision: current}}} =
               Operators.suspend(c.f.user, c.f.session, c.target, c.payload)

      assert current == revision(c.target)
      refute Repo.one!(from(x in Confirmation, where: x.action == "operator.suspend")).consumed_at

      assert [%{outcome: :conflict, result_code: "revision_stale"}] = events("operator.suspend")
    end

    test "the database lets a confirmation be consumed once and changed in no other way" do
      row = Repo.one!(Confirmation)

      assert_raise Postgrex.Error, ~r/operator_action_confirmations_immutable/, fn ->
        Repo.update_all(from(x in Confirmation, where: x.id == ^row.id),
          set: [expected_revision: 99]
        )
      end

      Repo.update_all(from(x in Confirmation, where: x.id == ^row.id),
        set: [consumed_at: DateTime.utc_now()]
      )

      assert_raise Postgrex.Error, ~r/operator_action_confirmations_immutable/, fn ->
        Repo.update_all(from(x in Confirmation, where: x.id == ^row.id),
          set: [consumed_at: DateTime.utc_now()]
        )
      end
    end
  end

  describe "transactions" do
    test "the change, the revision, the operation, the consumed confirmation and the audit commit together",
         c do
      target = c.second.operator.id
      before = revision(target)
      {:ok, payload, _} = confirmed(c.f.user, c.f.session, "operator.suspend", target)

      assert {:ok, %{operator: op}} = Operators.suspend(c.f.user, c.f.session, target, payload)
      assert op.status == :suspended and op.revision > before

      [event] = events("operator.suspend")

      assert %AuditEvent{
               action: "operator.suspended",
               outcome: :allowed,
               reason_code: "security_concern",
               from_state: "active",
               to_state: "suspended",
               target_type: "operator"
             } = event

      assert event.target_id == target
      assert event.revision == op.revision
      assert event.confirmation_id == Repo.one!(Confirmation).id
      assert event.operation_id == payload["operation_id"]

      assert %Operation{request_sha256: <<_::binary-size(32)>>} =
               Repo.get!(Operation, payload["operation_id"])
    end

    test "if the audit event can't be written, nothing commits", c do
      target = c.second.operator.id
      {:ok, payload, _} = confirmed(c.f.user, c.f.session, "operator.suspend", target)

      Repo.query!("""
      CREATE FUNCTION sf111_fail_audit() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'audit store unavailable'; END; $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER sf111_fail_audit BEFORE INSERT ON operator_audit_events
      FOR EACH ROW WHEN (NEW.outcome = 'allowed' AND NEW.command = 'operator.suspend')
      EXECUTE FUNCTION sf111_fail_audit()
      """)

      log =
        capture_log(fn ->
          assert {:error, :action_failed} =
                   Operators.suspend(c.f.user, c.f.session, target, payload)
        end)

      assert log =~ "admin action failed"
      assert Repo.get!(Operator, target).status == :active
      assert is_nil(Repo.one!(Confirmation).consumed_at)
      refute Repo.get(Operation, payload["operation_id"])
      assert [%{outcome: :failed, result_code: "mutation_failed"}] = events("operator.suspend")
    end

    test "if the domain change fails, nothing commits and no success is audited", c do
      target = c.second.operator.id
      {:ok, payload, _} = confirmed(c.f.user, c.f.session, "operator.revoke", target)

      Repo.query!("""
      CREATE FUNCTION sf111_fail_revoke() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'storage failure'; END; $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER sf111_fail_revoke BEFORE UPDATE ON platform_operators
      FOR EACH ROW WHEN (NEW.status = 'revoked') EXECUTE FUNCTION sf111_fail_revoke()
      """)

      capture_log(fn ->
        assert {:error, :action_failed} = Operators.revoke(c.f.user, c.f.session, target, payload)
      end)

      assert Repo.get!(Operator, target).status == :active

      assert Repo.all(
               from(g in Grant,
                 where: g.operator_id == ^target and is_nil(g.revoked_at)
               )
             ) != []

      assert [%{outcome: :failed}] = events("operator.revoke")
      assert Repo.all(from(e in AuditEvent, where: e.action == "operator.revoked")) == []
    end

    test "an identical retry changes nothing; the same id with other parameters conflicts", c do
      target = c.second.operator.id

      {:ok, payload, _} =
        confirmed(c.f.user, c.f.session, "operator.permission.grant", target, %{
          "permission" => "audit.read"
        })

      assert {:ok, first} = Operators.grant(c.f.user, c.f.session, target, payload)
      assert {:ok, ^first} = Operators.grant(c.f.user, c.f.session, target, payload)
      assert [%{outcome: :allowed}] = events("operator.permission.grant")

      assert Repo.aggregate(from(o in Operation, where: o.id == ^payload["operation_id"]), :count) ==
               1

      assert {:error, {:conflict, %{operation_id: "reused"}}} =
               Operators.revoke_grant(c.f.user, c.f.session, target, "audit.read", %{
                 "reason_code" => "role_change",
                 "operation_id" => payload["operation_id"],
                 "expected_revision" => revision(target)
               })
    end
  end

  describe "audit" do
    test "audit events can't be changed or deleted by the application's role", c do
      {:ok, _} = act(c.f.user, c.f.session, "operator.suspend", c.second.operator.id)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in AuditEvent, where: e.command == "operator.suspend"),
          set: [outcome: :refused]
        )
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(e in AuditEvent, where: e.command == "operator.suspend"))
      end
    end

    test "the log stays readable after its actor is revoked, by another reader", c do
      manager = operator!(c.f, "manager", ["operators.manage", "operators.read"])
      {:ok, _} = act(manager.user, manager.session, "operator.suspend", c.second.operator.id)
      {:ok, _} = act(c.f.user, c.f.session, "operator.revoke", manager.operator.id)

      assert {:ok, %{events: events}} =
               Operators.list_audit_events(c.f.user, c.f.session, %{
                 "actor_operator_id" => manager.operator.id,
                 "command" => "operator.suspend"
               })

      assert [%AuditEvent{outcome: :allowed}] = events
    end

    test "filters, stable order on equal timestamps, and scoped cursors", c do
      at = DateTime.utc_now()

      for _ <- 1..7 do
        Audit.record!(%{
          occurred_at: at,
          action: "sf111.test",
          command: "sf111.test",
          outcome: :refused,
          actor_operator_id: c.second.operator.id
        })
      end

      filters = %{"command" => "sf111.test", "limit" => 3}
      {:ok, p1} = Operators.list_audit_events(c.f.user, c.f.session, filters)

      {:ok, p2} =
        Operators.list_audit_events(
          c.f.user,
          c.f.session,
          Map.put(filters, "cursor", p1.next_cursor)
        )

      {:ok, p3} =
        Operators.list_audit_events(
          c.f.user,
          c.f.session,
          Map.put(filters, "cursor", p2.next_cursor)
        )

      ids = Enum.map(p1.events ++ p2.events ++ p3.events, & &1.id)
      assert length(ids) == 7 and Enum.uniq(ids) == ids
      assert ids == Enum.sort(ids, :desc)
      assert is_nil(p3.next_cursor)

      {head, rest} = String.split_at(p1.next_cursor, div(String.length(p1.next_cursor), 3))
      {char, tail} = String.split_at(rest, 1)
      tampered = head <> if(char == "A", do: "B", else: "A") <> tail

      for bad <- [
            Map.put(filters, "cursor", tampered),
            Map.put(filters, "cursor", "not-a-cursor"),
            %{"command" => "operator.suspend", "cursor" => p1.next_cursor},
            Map.merge(filters, %{"cursor" => p1.next_cursor, "before" => DateTime.to_iso8601(at)}),
            %{"limit" => 101},
            %{"outcome" => "everything"},
            %{"target_type" => "users; --"},
            %{
              "occurred_after" => DateTime.to_iso8601(at),
              "occurred_before" => DateTime.to_iso8601(at)
            }
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Operators.list_audit_events(c.f.user, c.f.session, bad)
      end

      reader = operator!(c.f, "auditor", ["audit.read"])

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_audit_events(
                 reader.user,
                 reader.session,
                 Map.put(filters, "cursor", p1.next_cursor)
               )
    end

    test "each query and detail view is itself audited", c do
      {:ok, %{events: [event | _]}} = Operators.list_audit_events(c.f.user, c.f.session, %{})
      {:ok, _} = Operators.get_audit_event(c.f.user, c.f.session, event.id)
      {:ok, _} = Operators.get_operator(c.f.user, c.f.session, c.second.operator.id)

      assert [_] = Repo.all(from(e in AuditEvent, where: e.action == "audit.events_read"))

      assert [%{target_id: id}] =
               Repo.all(from(e in AuditEvent, where: e.action == "audit.event_viewed"))

      assert id == event.id
      assert [_] = Repo.all(from(e in AuditEvent, where: e.action == "operator.viewed"))

      assert {:error, :not_found} =
               Operators.get_audit_event(c.f.user, c.f.session, Ecto.UUID.generate())
    end

    test "refusal audit is rate limited per operator, so refusals can't fill the table", c do
      call = fn ->
        Operators.execute(
          "operator.suspend",
          c.second.user,
          c.second.session,
          c.f.operator.id,
          %{}
        )
      end

      assert {:error, :forbidden} = call.()
      assert [_] = events("operator.suspend")

      # Exhaust this operator's refusal-audit window (as `SimpleFit.RateLimit` counts it).
      Repo.query!(
        """
        UPDATE auth_rate_limits SET count = $1 WHERE bucket = 'operator_refusal_audit' AND key_digest = $2
        """,
        [Policy.refusal_audit_limit(), :crypto.hash(:sha256, c.second.user.id)]
      )

      assert {:error, :forbidden} = call.()
      assert [_] = events("operator.suspend")
    end
  end

  describe "redaction and telemetry" do
    test "unknown fields, tokens and secrets reach no response, audit row, log or telemetry", c do
      handler = "sf111-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler,
        for(
          e <-
            ~w(started authorized confirmed committed denied conflicted invalid failed audit_persisted previewed replayed)a,
          do: [:simple_fit, :admin_action, e]
        ),
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {results, log} =
        with_log(fn ->
          {:ok, payload, preview} =
            confirmed(c.f.user, c.f.session, "operator.suspend", c.second.operator.id, %{
              "note" => @canary,
              "explanation" => @canary
            })

          {:error, cs} =
            Operators.suspend(c.f.user, c.f.session, c.second.operator.id, %{
              payload
              | "reason_code" => @canary
            })

          ok =
            Operators.suspend(
              c.f.user,
              c.f.session,
              c.second.operator.id,
              Map.put(payload, "secret", @canary)
            )

          {preview, SimpleFitWeb.ChangesetErrors.details(cs), ok, payload["confirmation_token"]}
        end)

      {preview, errors, ok, token} = results
      haystack = inspect({preview, errors, ok}) <> log <> inspect(Repo.all(AuditEvent))
      refute haystack =~ @canary
      refute log =~ token
      refute inspect(Repo.all(AuditEvent)) =~ token

      metadata = collect_telemetry([])
      assert metadata != []

      for {_event, measurements, meta} <- metadata do
        assert Map.keys(meta) |> Enum.sort() == [:action, :phase, :result]
        assert measurements == %{count: 1}
        refute inspect(meta) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/
        refute inspect(meta) =~ @canary
      end

      assert Enum.any?(metadata, fn {e, _, m} ->
               e == [:simple_fit, :admin_action, :committed] and m.action == "operator.suspend"
             end)

      assert Enum.any?(metadata, fn {e, _, m} ->
               e == [:simple_fit, :admin_action, :invalid] and m.result == "validation_failed"
             end)
    end

    test "audit events leave through the allowlist only" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        outcome: :allowed,
        authority: :platform_operator
      }

      assert Map.keys(Redaction.audit_event(event)) |> Enum.sort() ==
               Enum.sort(Redaction.audit_fields())

      refute :token_sha256 in Redaction.audit_fields()
      assert Redaction.details(%{status: "x", secret: @canary, nested: %{a: 1}}) == %{status: "x"}
    end
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        collect_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
