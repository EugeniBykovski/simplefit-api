defmodule SimpleFit.GymVerificationRaceTest do
  @moduledoc """
  Gym business verification under true concurrency and real commits
  (SF-103), on separate database connections outside the SQL sandbox:
  concurrent reviewers, approval racing revocation and resubmission,
  duplicate submissions and first saves, an owner edit racing a
  submission, a confirmation racing a removal, and go-live reads racing a
  revocation. Each scenario repeats to catch lock-order defects. Every test
  removes the gyms (with the purge switch), audit events, limiter rows and
  users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Gyms, Repo}

  alias SimpleFit.Gyms.{
    AuditEvent,
    Gym,
    StaffMembership,
    VerificationApplication,
    VerificationEvent,
    VerificationReview
  }

  alias SimpleFit.Gyms.VerificationAuthority.Local

  @rounds 6

  setup do
    Sandbox.mode(Repo, :auto)
    # Committed for real: the jobs an invitation queues go with the rest of the test's rows.
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0
    {:ok, users} = Agent.start(fn -> [] end)
    stub_storage(%{})

    on_exit(fn ->
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      gym_ids =
        Repo.all(
          from(g in Gym,
            left_join: m in StaffMembership,
            on: m.gym_id == g.id,
            where: g.created_by_user_id in ^ids or m.user_id in ^ids,
            distinct: true,
            select: g.id
          )
        )

      purge_gyms!(gym_ids)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("rate_limit_events")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp owned!(ctx) do
    owner = registered!("kyb-race")
    Agent.update(ctx.users, &[owner.id | &1])
    {owner, completed_gym!(owner)}
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp decisions(application_id) do
    Repo.all(
      from(e in VerificationEvent,
        where: e.application_id == ^application_id and e.event != :submitted,
        order_by: [asc: e.seq],
        select: e.event
      )
    )
  end

  defp decide(view, decision, reason \\ nil) do
    fn ->
      VerificationReview.decide(view.application.id, decision,
        revision: view.application.revision,
        reason: reason,
        credential: operator()
      )
    end
  end

  test "concurrent reviewers: exactly one decision wins", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      view = submitted!(owner, gym.id)

      results =
        concurrently([
          decide(view, :approved),
          decide(view, :rejected, "business_not_verifiable"),
          decide(view, :changes_requested, "document_unreadable"),
          decide(view, :approved)
        ])

      assert [{:ok, %{status: winner}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &match?({:error, {:conflict, _}}, &1)) == 3
      assert decisions(view.application.id) == [winner]
      assert Repo.get!(VerificationApplication, view.application.id).status == winner
    end
  end

  test "approval racing revocation never revokes what was not approved", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      view = submitted!(owner, gym.id)

      revoke = fn ->
        VerificationReview.revoke(view.application.id, reason: "other", credential: operator())
      end

      [approve, revoked] = concurrently([decide(view, :approved), revoke])

      assert {:ok, %{status: :approved}} = approve

      case revoked do
        {:ok, %{status: :revoked}} ->
          assert decisions(view.application.id) == [:approved, :revoked]

        {:error, {:conflict, %{verification: "submitted"}}} ->
          assert decisions(view.application.id) == [:approved]
      end
    end
  end

  test "approval racing a resubmission: the operator only approves the revision reviewed", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      first = submitted!(owner, gym.id)
      {:ok, _} = decide(first, :changes_requested, "details_incomplete").()

      {:ok, {edited, :updated}} =
        Gyms.save_business_verification(owner, live_session!(owner), gym.id, %{
          "revision" => first.application.revision,
          "city" => "Kraków"
        })

      resubmit = fn ->
        Gyms.submit_business_verification(owner, live_session!(owner), gym.id, %{
          "revision" => edited.application.revision
        })
      end

      # The operator still holds the first revision.
      [submitted, approval] = concurrently([resubmit, decide(first, :approved)])

      assert {:ok, %{status: :submitted}} = submitted
      assert {:error, {:conflict, _}} = approval
      assert decisions(first.application.id) == [:changes_requested]
    end
  end

  test "duplicate submissions and duplicate first saves", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)

      saves =
        concurrently(
          for _ <- 1..4,
              do: fn ->
                Gyms.save_business_verification(owner, live_session!(owner), gym.id, details())
              end
        )

      assert Enum.count(saves, &match?({:ok, {_, :created}}, &1)) == 1
      assert Enum.count(saves, &match?({:error, {:conflict, %{revision: "stale"}}}, &1)) == 3

      assert Repo.aggregate(
               from(a in VerificationApplication, where: a.gym_id == ^gym.id),
               :count
             ) == 1

      {view, _id, _objects} = upload!(owner, gym.id)

      submits =
        concurrently(
          for _ <- 1..4,
              do: fn ->
                Gyms.submit_business_verification(owner, live_session!(owner), gym.id, %{
                  "revision" => view.application.revision
                })
              end
        )

      assert Enum.all?(submits, &match?({:ok, %{status: :submitted}}, &1))

      assert Repo.aggregate(
               from(e in VerificationEvent,
                 where: e.application_id == ^view.application.id and e.event == :submitted
               ),
               :count
             ) == 1
    end
  end

  test "an owner edit racing the submission never submits other details", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      draft!(owner, gym.id)
      {view, _id, _objects} = upload!(owner, gym.id)
      revision = view.application.revision

      edit = fn ->
        Gyms.save_business_verification(owner, live_session!(owner), gym.id, %{
          "revision" => revision,
          "legal_name" => "Edited in another tab"
        })
      end

      submit = fn ->
        Gyms.submit_business_verification(owner, live_session!(owner), gym.id, %{
          "revision" => revision
        })
      end

      results = concurrently([edit, submit])
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      application = Repo.get!(VerificationApplication, view.application.id)

      case application.status do
        :submitted ->
          assert application.submitted_revision == application.revision
          assert application.legal_name == "Simple Boxing Sp. z o.o."

        :draft ->
          assert application.legal_name == "Edited in another tab"
          assert application.revision == revision + 1
      end
    end
  end

  test "a confirmation racing a removal of the same document has one outcome", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      draft!(owner, gym.id)
      session = live_session!(owner)
      {:ok, current} = Gyms.get_business_verification(owner, gym.id)

      {:ok, {_view, evidence, _upload}} =
        Gyms.add_business_verification_evidence(owner, session, gym.id, %{
          "revision" => current.application.revision,
          "kind" => "other",
          "file_name" => "doc.png",
          "content_type" => "image/png",
          "byte_size" => 512
        })

      stub_storage(%{evidence.id => {512, "image/png"}})
      {:ok, pending} = Gyms.get_business_verification(owner, gym.id)

      confirm = fn ->
        Gyms.confirm_business_verification_evidence(
          owner,
          live_session!(owner),
          gym.id,
          evidence.id
        )
      end

      remove = fn ->
        Gyms.remove_business_verification_evidence(
          owner,
          live_session!(owner),
          gym.id,
          evidence.id,
          %{
            "revision" => pending.application.revision
          }
        )
      end

      [confirmed, removed] = concurrently([confirm, remove])

      {:ok, final} = Gyms.get_business_verification(owner, gym.id)

      case final.evidence do
        # Confirmed first: the removal named a stale revision.
        [%{status: :uploaded}] ->
          assert {:ok, _} = confirmed
          assert {:error, {:conflict, %{revision: "stale"}}} = removed

        # Removed first: the confirmation found it removed.
        [] ->
          assert {:ok, _} = removed
          assert {:error, {:conflict, %{evidence: "removed"}}} = confirmed
      end
    end
  end

  test "go-live reads racing a revocation fail closed once it commits", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      approved = approved!(owner, gym.id)

      read = fn ->
        {:ok, readiness} = Gyms.get_go_live(owner, gym.id)

        {readiness.prerequisites_met,
         Enum.find(readiness.checks, &(&1.key == :business_verification))}
      end

      revoke = fn ->
        VerificationReview.revoke(approved.application.id,
          reason: "suspected_fraud",
          credential: operator()
        )
      end

      [revoked | reads] = concurrently([revoke | List.duplicate(read, 6)])
      assert {:ok, %{status: :revoked}} = revoked

      for {met?, check} <- reads do
        case check.status do
          :passed ->
            assert met?
            assert check.reason_code == :approved

          :failed ->
            refute met?
            assert check.reason_code == :revoked
        end
      end

      assert {false, %{status: :failed, reason_code: :revoked}} = read.()
    end
  end

  describe "the operator boundary under concurrency (SF-136)" do
    test "12 concurrent approvals of one revision: one decision, one history row, one audit row",
         ctx do
      {owner, gym} = owned!(ctx)
      view = submitted!(owner, gym.id)

      results =
        concurrently(
          for _ <- 1..12 do
            fn ->
              VerificationReview.decide(view.application.id, :approved,
                revision: view.application.revision,
                credential: operator()
              )
            end
          end
        )

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, _}}, &1)) == 11

      assert [%{operator_actor_id: actor}] =
               Repo.all(
                 from(e in VerificationEvent,
                   where: e.application_id == ^view.application.id and e.event == :approved
                 )
               )

      assert actor == reviewer_actor_id()

      assert Repo.aggregate(
               from(a in AuditEvent,
                 where:
                   a.verification_application_id == ^view.application.id and
                     a.event_type == :business_verification_approved
               ),
               :count
             ) == 1
    end

    test "a decision racing the operator's revocation: refused, or decided with a whole trail",
         ctx do
      for _ <- 1..6 do
        {owner, gym} = owned!(ctx)
        view = submitted!(owner, gym.id)
        credential = fixture_operator!(%{})

        [decided, :ok] =
          concurrently([
            fn ->
              VerificationReview.decide(view.application.id, :approved,
                revision: view.application.revision,
                credential: credential
              )
            end,
            fn -> revoke_operator(credential) end
          ])

        rows =
          Repo.all(
            from(e in VerificationEvent,
              where: e.application_id == ^view.application.id and e.event == :approved
            )
          )

        status = Repo.get!(VerificationApplication, view.application.id).status

        case decided do
          {:ok, _} ->
            assert status == :approved
            assert [%{operation_id: operation}] = rows
            assert is_binary(operation)

          {:error, {:forbidden, :operator}} ->
            assert status == :submitted
            assert rows == []
        end

        # After a revocation, never again.
        assert {:error, {:forbidden, :operator}} =
                 VerificationReview.show(view.application.id, credential)
      end
    end

    test "a decision racing the operator joining the gym's staff: never both", ctx do
      for _ <- 1..6 do
        {owner, gym} = owned!(ctx)
        view = submitted!(owner, gym.id)
        email = address("kyb-candidate")
        candidate = email_user!(email)
        Agent.update(ctx.users, &[candidate.id | &1])
        credential = fixture_operator!(%{user_id: candidate.id})
        invited = invite!(owner, gym.id, email, :coach)

        [decided, joined] =
          concurrently([
            fn ->
              VerificationReview.decide(view.application.id, :approved,
                revision: view.application.revision,
                credential: credential
              )
            end,
            fn ->
              Gyms.accept_staff_invitation(
                candidate,
                live_session!(candidate),
                {:id, invited.invitation_id},
                client_ip()
              )
            end
          ])

        assert {:ok, _} = joined
        status = Repo.get!(VerificationApplication, view.application.id).status

        case decided do
          {:ok, _} -> assert status == :approved
          {:error, {:conflict, %{operator: "not_independent"}}} -> assert status == :submitted
        end
      end
    end

    test "unauthorized attempts racing a real decision change nothing", ctx do
      {owner, gym} = owned!(ctx)
      view = submitted!(owner, gym.id)

      approve = fn credential ->
        fn ->
          VerificationReview.decide(view.application.id, :approved,
            revision: view.application.revision,
            credential: credential
          )
        end
      end

      results =
        concurrently(
          [approve.(operator())] ++
            for(_ <- 1..8, do: approve.("reviewer@trust.simplefit.test")) ++
            for(_ <- 1..3, do: approve.(%Local.Credential{secret: "guess"}))
        )

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :unauthenticated}, &1)) == 11

      assert [%{operator_actor_id: actor}] =
               Repo.all(
                 from(e in VerificationEvent,
                   where: e.application_id == ^view.application.id and e.event == :approved
                 )
               )

      assert actor == reviewer_actor_id()
    end
  end
end
