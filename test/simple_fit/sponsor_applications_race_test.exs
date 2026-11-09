defmodule SimpleFit.SponsorApplicationsRaceTest do
  @moduledoc """
  SF-113 under true concurrency and real commits, outside the SQL sandbox: the
  one-current-application index, row locks, revision trigger and append-only
  submissions run for real. Each test empties the application tables with TRUNCATE
  on this disposable test database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Application, Applications, ApplicationSubmission}

  @tables ~w(sponsor_application_events sponsor_application_submissions sponsor_applications)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp user!(users) do
    user = registered!("applicant")
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp count(user, query \\ Application),
    do: Repo.aggregate(from(a in query, where: a.applicant_user_id == ^user.id), :count)

  test "first saves at once with one key: one draft, every answer the same", %{users: users} do
    user = user!(users)
    params = %{"client_request_id" => Ecto.UUID.generate(), "company_name" => "Acme"}
    results = concurrently(for _ <- 1..6, do: fn -> Applications.save(user, params) end)

    ids = for {:ok, %{application: a}} <- results, uniq: true, do: a.id
    assert length(ids) == 1 and Enum.all?(results, &match?({:ok, _}, &1))
    assert count(user) == 1
  end

  test "first saves at once with different keys: one draft, the rest conflict", %{users: users} do
    user = user!(users)

    results =
      concurrently(
        for i <- 1..5,
            do: fn ->
              Applications.save(user, %{
                "client_request_id" => Ecto.UUID.generate(),
                "company_name" => "Acme #{i}"
              })
            end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or match?({:error, {:revision_conflict, _}}, &1) or
                 &1 == {:error, {:conflict, %{application: "exists"}}})
           )

    assert count(user) == 1
  end

  test "saves at the same revision: one applies, the rest are stale", %{users: users} do
    user = user!(users)
    a = draft!(user, %{"company_name" => "Acme"})

    results =
      concurrently(
        for i <- 1..5,
            do: fn ->
              Applications.save(user, %{"expected_revision" => a.revision, "goals" => "Goal #{i}"})
            end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:revision_conflict, _}}, &1)) == 4
    assert Repo.get!(Application, a.id).revision == a.revision + 1
  end

  test "a save racing the submission: never an edit after the snapshot", %{users: users} do
    user = user!(users)
    a = draft!(user)

    [save, submit] =
      concurrently([
        fn ->
          Applications.save(user, %{"expected_revision" => a.revision, "goals" => "Late edit"})
        end,
        fn -> Applications.submit(user, submit_params(a)) end
      ])

    final = Repo.get!(Application, a.id)

    case {save, submit} do
      {{:ok, _}, {:error, {:revision_conflict, _}}} ->
        assert final.status == :draft and final.goals == "Late edit"

      {{:error, _}, {:ok, _}} ->
        [s] = Repo.all(from(x in ApplicationSubmission, where: x.application_id == ^a.id))
        assert final.status == :submitted and final.goals == s.snapshot["answers"]["goals"]
    end
  end

  test "the same submission five times at once (a retried request): one submission", %{
    users: users
  } do
    user = user!(users)
    a = draft!(user)
    request = submit_params(a)
    results = concurrently(for _ <- 1..5, do: fn -> Applications.submit(user, request) end)

    assert Enum.all?(results, &match?({:ok, %{application: %{status: :submitted}}}, &1))

    assert Repo.aggregate(
             from(s in ApplicationSubmission, where: s.application_id == ^a.id),
             :count
           ) == 1
  end

  test "different submissions at once: one, the rest refused", %{users: users} do
    user = user!(users)
    a = draft!(user)

    results =
      concurrently(for _ <- 1..5, do: fn -> Applications.submit(user, submit_params(a)) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or
                 match?({:error, {:conflict, %{application: "not_submittable"}}}, &1) or
                 match?({:error, {:revision_conflict, _}}, &1))
           )

    assert Repo.aggregate(
             from(s in ApplicationSubmission, where: s.application_id == ^a.id),
             :count
           ) == 1
  end

  test "one idempotency key for different requests at once: one submission, the rest refused",
       %{users: users} do
    user = user!(users)
    a = draft!(user)
    key = Ecto.UUID.generate()

    results =
      concurrently([
        fn -> Applications.submit(user, submit_params(a, %{"client_request_id" => key})) end,
        fn ->
          Applications.submit(
            user,
            submit_params(a, %{"client_request_id" => key, "declaration_language" => "pl"})
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) <= 1

    assert Repo.aggregate(
             from(s in ApplicationSubmission, where: s.application_id == ^a.id),
             :count
           ) <= 1
  end

  test "a resubmission racing a stale save after changes were requested", %{users: users} do
    user = user!(users)

    reviewed =
      user |> submitted!(draft!(user)) |> review!(:under_review) |> review!(:changes_requested)

    [save, resubmit] =
      concurrently([
        fn ->
          Applications.save(user, %{"expected_revision" => reviewed.revision, "goals" => "New"})
        end,
        fn -> Applications.submit(user, submit_params(reviewed)) end
      ])

    assert Enum.count([save, resubmit], &match?({:ok, _}, &1)) == 1
    # The loser is stale, or (when the resubmission won) no longer editable.
    assert Enum.any?(
             [save, resubmit],
             &(match?({:error, {:revision_conflict, _}}, &1) or
                 match?({:error, {:conflict, %{application: "not_editable"}}}, &1))
           )

    submissions =
      Repo.all(from(s in ApplicationSubmission, where: s.application_id == ^reviewed.id))

    assert length(submissions) in [1, 2]

    assert hd(Enum.sort_by(submissions, & &1.sequence)).snapshot["answers"]["goals"] ==
             "Support amateur boxing events in Poland."
  end
end
