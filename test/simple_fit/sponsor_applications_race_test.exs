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
  import SimpleFit.VerificationHelpers, only: [stub_storage: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.Email.JobPayload
  alias SimpleFit.Repo

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationEvent,
    ApplicationNotification,
    Applications,
    ApplicationSubmission,
    ContactVerification,
    Evidence
  }

  # SF-114 rows (evidence, change requests and the fixture operator they name,
  # contact codes, notifications) are committed too. TRUNCATE fires no row triggers.
  @tables ~w(sponsor_application_notifications sponsor_application_contact_codes
             sponsor_application_evidence sponsor_application_events
             sponsor_application_submissions sponsor_application_change_requests
             sponsor_applications platform_operators)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)
    # Emails queued by these tests (SF-114) are committed too.
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      # `review!/2` commits a fixture operator and its user: remove that user too.
      operators = Repo.all(from(o in "platform_operators", select: type(o.user_id, :binary_id)))
      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^operators))
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job and j.queue == "mailers"))
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

  ## SF-114

  defp initiate!(user, application) do
    {:ok, {_view, evidence, _upload}} =
      Evidence.initiate(user, %{
        "expected_revision" => Repo.reload!(application).revision,
        "kind" => "logo",
        "file_name" => "logo.png",
        "content_type" => "image/png",
        "byte_size" => 1000
      })

    evidence
  end

  test "one upload confirmed five times at once: attached once, every answer the same", %{
    users: users
  } do
    user = user!(users)
    app = draft!(user)
    evidence = initiate!(user, app)
    stub_storage(%{evidence.id => {1000, "image/png"}})

    results = concurrently(for _ <- 1..5, do: fn -> Evidence.confirm(user, evidence.id) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.reload!(evidence).status == :uploaded

    assert Repo.aggregate(
             from(e in ApplicationEvent,
               where:
                 e.application_id == ^app.id and
                   e.event == "sponsor_application.evidence_uploaded"
             ),
             :count
           ) == 1
  end

  test "a removal racing the submission: the snapshot and the frozen documents agree", %{
    users: users
  } do
    user = user!(users)
    app = draft!(user)
    evidence = initiate!(user, app)
    stub_storage(%{evidence.id => {1000, "image/png"}})
    {:ok, _} = Evidence.confirm(user, evidence.id)
    current = Repo.reload!(app)

    [remove, submit] =
      concurrently([
        fn -> Evidence.remove(user, evidence.id, %{"expected_revision" => current.revision}) end,
        fn -> Applications.submit(user, submit_params(current)) end
      ])

    assert Enum.count([remove, submit], &match?({:ok, _}, &1)) == 1
    evidence = Repo.reload!(evidence)

    case Repo.one(from(s in ApplicationSubmission, where: s.application_id == ^app.id)) do
      nil ->
        assert evidence.status == :removed and evidence.submission_id == nil

      submission ->
        assert [%{"evidence_id" => id}] = submission.snapshot["uploads"]
        assert id == evidence.id
        assert evidence.status == :uploaded and evidence.submission_id == submission.id
    end
  end

  test "repeated submissions at once queue one notification", %{users: users} do
    user = user!(users)
    params = submit_params(draft!(user))

    app_id =
      Repo.one!(from(a in Application, where: a.applicant_user_id == ^user.id, select: a.id))

    results = concurrently(for _ <- 1..5, do: fn -> Applications.submit(user, params) end)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert Repo.aggregate(
             from(n in ApplicationNotification, where: n.application_id == ^app_id),
             :count
           ) == 1
  end

  test "the right contact code confirmed five times at once: verified once", %{users: users} do
    user = user!(users)
    app = draft!(user)
    {:ok, _} = ContactVerification.request(user)
    job = Repo.one!(from(j in Oban.Job, order_by: [desc: j.id], limit: 1))
    {:ok, message} = JobPayload.open(job.args["payload"])
    [code] = Regex.run(~r/\b\d{6}\b/, message.text)

    results =
      concurrently(
        for _ <- 1..5, do: fn -> ContactVerification.confirm(user, %{"code" => code}) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :code_expired}))
    assert Repo.reload!(app).contact_email_verified_at
  end
end
