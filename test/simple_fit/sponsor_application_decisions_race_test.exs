defmodule SimpleFit.SponsorApplicationDecisionsRaceTest do
  @moduledoc """
  SF-116 under true concurrency and real commits, on separate connections outside
  the SQL sandbox (each call runs in its own `Task`, so its own pooled connection and
  transaction): the row locks, the revision trigger, the unique organization per
  application, the one-time confirmations and the operation ids run for real. The
  tables are append-only for the application, so each test empties them with
  TRUNCATE on this disposable test database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1, email_user!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Operators, Repo}
  alias SimpleFit.Operators.AuditEvent

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationChangeRequest,
    ApplicationNotification,
    Membership,
    Organization
  }

  @tables ~w(sponsor_organization_events sponsor_contacts sponsor_workspace_memberships
             sponsor_organizations sponsor_application_notifications
             sponsor_application_contact_codes sponsor_application_evidence
             sponsor_application_events sponsor_application_submissions
             sponsor_application_change_requests sponsor_applications
             operator_action_confirmations operator_audit_events operator_operations
             operator_ceremonies operator_permission_grants operator_step_ups
             operator_webauthn_challenges operator_credentials platform_operators)

  @all ~w(sponsors.applications.read sponsors.applications.claim
          sponsors.applications.request_changes sponsors.applications.approve
          sponsors.applications.reject sponsors.restrict operators.read operators.manage)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.query!("ALTER TABLE operator_audit_events DROP CONSTRAINT IF EXISTS sf116_audit_fails")
      truncate!()
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    founder = founder!(users)

    applicant =
      track(users, email_user!("applicant-#{System.unique_integer([:positive])}@example.com"))

    app = submitted!(applicant, draft!(applicant))
    {:ok, _} = claim(founder, app)
    %{users: users, f: founder, applicant: applicant, app: Repo.reload!(app)}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp founder!(users) do
    user = track(users, registered!("founder"))
    session = live_session!(user)
    op = bootstrap!(user, @all)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp reviewer!(founder, users) do
    user = track(users, registered!("reviewer"))
    session = live_session!(user)

    {:ok, %{operator: op}} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => @all -- ["operators.manage"]})
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: Repo.reload!(op), key: step_up!(user, session, k)}
  end

  defp claim(r, app),
    do:
      Operators.execute("sponsor_application.claim", r.user, r.session, app.id, %{
        "reason_code" => "review_started",
        "expected_revision" => Repo.reload!(app).revision,
        "operation_id" => Ecto.UUID.generate()
      })

  # A confirmed request, prepared before the race (preview first).
  defp prepared(r, action, app, params \\ %{}) do
    {:ok, execute, _preview} = confirmed(r.user, r.session, action, app.id, params)
    fn -> Operators.execute(action, r.user, r.session, app.id, execute) end
  end

  defp allowed(action),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.command == ^action and e.outcome == :allowed),
        :count
      )

  test "A: two operators approve at once: one approval, one organization, one owner", c do
    other = reviewer!(c.f, c.users)

    results =
      concurrently([
        prepared(c.f, "sponsor_application.approve", c.app),
        prepared(other, "sponsor_application.approve", c.app)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.any?(results, &match?({:error, {:revision_conflict, _}}, &1))
    assert Repo.aggregate(Organization, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
    assert allowed("sponsor_application.approve") == 1

    assert Repo.aggregate(
             from(n in ApplicationNotification, where: n.kind == :application_approved),
             :count
           ) == 1
  end

  test "B: approve against reject: exactly one decision commits", c do
    other = reviewer!(c.f, c.users)

    [approve, reject] =
      concurrently([
        prepared(c.f, "sponsor_application.approve", c.app),
        prepared(other, "sponsor_application.reject", c.app)
      ])

    assert Enum.count([approve, reject], &match?({:ok, _}, &1)) == 1
    final = Repo.reload!(c.app)

    case approve do
      {:ok, _} ->
        assert final.status == :approved and Repo.aggregate(Organization, :count) == 1

      _ ->
        assert final.status == :rejected and Repo.aggregate(Organization, :count) == 0
    end
  end

  test "C: approve against request changes from the same revision: one transition", c do
    other = reviewer!(c.f, c.users)

    changes = fn ->
      Operators.execute(
        "sponsor_application.request_changes",
        other.user,
        other.session,
        c.app.id,
        %{
          "reason_code" => "unclear_answers",
          "expected_revision" => c.app.revision,
          "operation_id" => Ecto.UUID.generate(),
          "fields" => ["goals"],
          "message" => "Which events?"
        }
      )
    end

    [approve, request] =
      concurrently([prepared(c.f, "sponsor_application.approve", c.app), changes])

    assert Enum.count([approve, request], &match?({:ok, _}, &1)) == 1
    final = Repo.reload!(c.app)
    requests = Repo.aggregate(ApplicationChangeRequest, :count)

    if match?({:ok, _}, approve),
      do: assert(final.status == :approved and requests == 0),
      else:
        assert(
          final.status == :changes_requested and requests == 1 and
            Repo.aggregate(Organization, :count) == 0
        )
  end

  test "D: suspend against reinstate on an approved organization: one wins, no lost update", c do
    {:ok, _} = prepared(c.f, "sponsor_application.approve", c.app).()
    app = Repo.reload!(c.app)
    other = reviewer!(c.f, c.users)

    # Prepared together from the same state: suspend applies; reinstate is refused
    # at preview (nothing to reinstate) or, if raced, by the plan under the lock.
    suspend = prepared(c.f, "sponsor_application.suspend_organization", app)
    suspend_again = prepared(other, "sponsor_application.suspend_organization", app)

    results = concurrently([suspend, suspend_again])
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.any?(
             results,
             &match?({:error, {:conflict, %{organization: "suspended"}}}, &1)
           )

    assert Repo.one!(Organization).status == :suspended
    assert allowed("sponsor_application.suspend_organization") == 1
  end

  test "E: the same approval request retried five times at once changes things once", c do
    {:ok, execute, _} = confirmed(c.f.user, c.f.session, "sponsor_application.approve", c.app.id)

    results =
      concurrently(
        for _ <- 1..5,
            do: fn ->
              Operators.execute(
                "sponsor_application.approve",
                c.f.user,
                c.f.session,
                c.app.id,
                execute
              )
            end
      )

    assert Enum.all?(results, &match?({:ok, %{application: %{status: :approved}}}, &1))
    assert Repo.aggregate(Organization, :count) == 1 and Repo.aggregate(Membership, :count) == 1
    assert allowed("sponsor_application.approve") == 1
  end

  test "F: when the audit event can't be written, the approval doesn't commit", c do
    # The audit table refuses this action's success row (a constraint added for this test only).
    Repo.query!("""
    ALTER TABLE operator_audit_events ADD CONSTRAINT sf116_audit_fails
      CHECK (action <> 'sponsor_application.approved') NOT VALID
    """)

    assert {:error, :action_failed} = prepared(c.f, "sponsor_application.approve", c.app).()
    assert Repo.reload!(c.app).status == :under_review
    assert Repo.aggregate(Organization, :count) == 0
    assert Repo.aggregate(Membership, :count) == 0

    assert Repo.aggregate(
             from(n in ApplicationNotification, where: n.kind == :application_approved),
             :count
           ) == 0
  end

  test "H: an operator revoked while approving never commits after the revocation", c do
    reviewer = reviewer!(c.f, c.users)
    approve = prepared(reviewer, "sponsor_application.approve", c.app)
    {:ok, revoke, _} = confirmed(c.f.user, c.f.session, "operator.revoke", reviewer.operator.id)

    [approval, revocation] =
      concurrently([
        approve,
        fn -> Operators.revoke(c.f.user, c.f.session, reviewer.operator.id, revoke) end
      ])

    assert {:ok, _} = revocation

    case approval do
      {:ok, _} ->
        # It committed first: its audit row precedes the revocation's.
        [approved_at] =
          Repo.all(
            from(e in AuditEvent,
              where: e.command == "sponsor_application.approve" and e.outcome == :allowed,
              select: e.occurred_at
            )
          )

        [revoked_at] =
          Repo.all(
            from(e in AuditEvent,
              where: e.command == "operator.revoke" and e.outcome == :allowed,
              select: e.occurred_at
            )
          )

        assert DateTime.compare(approved_at, revoked_at) == :lt

      {:error, reason} ->
        assert reason in [:not_found, :forbidden]
        assert Repo.reload!(c.app).status == :under_review
        assert Repo.aggregate(Organization, :count) == 0
    end

    # Afterwards, the revoked operator can't decide anything.
    assert {:error, :not_found} =
             Operators.preview(
               "sponsor_application.reject",
               reviewer.user,
               reviewer.session,
               c.app.id,
               %{
                 "reason_code" => "other"
               }
             )

    assert %Application{} = Repo.reload!(c.app)
  end
end
