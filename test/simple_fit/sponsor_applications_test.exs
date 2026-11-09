defmodule SimpleFit.SponsorApplicationsTest do
  @moduledoc """
  SF-113: the sponsor application domain in the SQL sandbox. Drafts, validation,
  submission, snapshots, review-state boundaries, isolation and entry. Real-commit
  races are in `SimpleFit.SponsorApplicationsRaceTest`.
  """

  use SimpleFit.DataCase, async: false

  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.SponsorHelpers, only: [provision!: 1, member!: 2]
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.{Accounts, Entry}
  alias SimpleFit.Legal.Registry

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationEvent,
    Applications,
    ApplicationSubmission,
    Membership,
    Organization
  }

  setup do
    %{user: registered!("applicant")}
  end

  defp save(user, params), do: Applications.save(user, params)
  defp codes(changeset), do: SimpleFitWeb.ChangesetErrors.details(changeset).field_codes

  defp events(app_id),
    do:
      Repo.all(
        from(e in ApplicationEvent,
          where: e.application_id == ^app_id,
          order_by: [e.occurred_at, e.id]
        )
      )

  # Loads a registry without the declaration, then restores the test registry.
  defp without_published_declaration(fun) do
    config = Elixir.Application.get_env(:simple_fit, SimpleFit.Legal)

    try do
      Elixir.Application.put_env(:simple_fit, SimpleFit.Legal,
        registry_path: Elixir.Application.app_dir(:simple_fit, "priv/legal")
      )

      :ok = Registry.load()
      fun.()
    after
      Elixir.Application.put_env(:simple_fit, SimpleFit.Legal, config)
      :ok = Registry.load()
    end
  end

  describe "starting a draft" do
    test "intent, registration and empty saves create nothing", %{user: user} do
      assert {:ok, %{destination: :sponsor_application}} =
               Entry.resolve(user, %{"intent" => "sponsor"})

      assert {:error, :not_found} = Applications.get(user)

      key = Ecto.UUID.generate()

      for params <- [
            %{"client_request_id" => key},
            %{"client_request_id" => key, "company_name" => nil, "interests" => []},
            %{"client_request_id" => key, "company_name" => ""}
          ] do
        assert {:error, %Ecto.Changeset{}} = save(user, params)
      end

      assert Repo.aggregate(Application, :count) == 0
    end

    test "account registration comes first" do
      {:ok, fresh} =
        Accounts.register_user(:google, "sp-app-#{System.unique_integer([:positive])}")

      assert {:error, {:conflict, %{account_registration: "incomplete"}}} =
               save(fresh, %{
                 "client_request_id" => Ecto.UUID.generate(),
                 "company_name" => "Acme"
               })
    end

    test "the first meaningful save creates one draft; a retry answers the same", %{user: user} do
      key = Ecto.UUID.generate()
      params = %{"client_request_id" => key, "company_name" => "  Acme  "}

      assert {:ok, %{application: %Application{status: :draft, company_name: "Acme"} = a}} =
               save(user, params)

      assert {:ok, %{application: %{id: same_id}}} = save(user, params)
      assert same_id == a.id
      assert Repo.aggregate(Application, :count) == 1

      assert {:error, {:revision_conflict, %{current_revision: 1}}} =
               save(user, %{params | "company_name" => "Other"})

      assert [
               %{event: "sponsor_application.created", outcome: :allowed},
               %{outcome: :refused, reason_code: "revision_stale"}
             ] = events(a.id)
    end

    test "requests can't name owners, statuses or unknown fields", %{user: user} do
      other = registered!("other")

      assert {:error, cs} =
               save(user, %{
                 "client_request_id" => Ecto.UUID.generate(),
                 "company_name" => "Acme",
                 "applicant_user_id" => other.id,
                 "status" => "approved"
               })

      assert Map.keys(codes(cs)) |> Enum.sort() == ["applicant_user_id", "status"]
      assert Repo.aggregate(Application, :count) == 0
    end
  end

  describe "saving" do
    setup %{user: user} do
      {:ok, %{application: a}} =
        save(user, %{"client_request_id" => Ecto.UUID.generate(), "company_name" => "Acme"})

      %{a: a}
    end

    test "partial saves need the current revision and change only what was sent", c do
      assert {:ok, %{application: a2}} =
               save(c.user, %{
                 "expected_revision" => c.a.revision,
                 "contact_email" => " Ada@Acme.Example "
               })

      assert a2.company_name == "Acme" and a2.contact_email == "ada@acme.example"
      assert a2.revision > c.a.revision

      assert {:error, {:revision_conflict, %{current_revision: current}}} =
               save(c.user, %{"expected_revision" => c.a.revision, "goals" => "x"})

      assert current == a2.revision
    end

    test "an invalid save changes nothing, and errors name each field", c do
      assert {:error, cs} =
               save(c.user, %{
                 "expected_revision" => c.a.revision,
                 "company_name" => "Changed",
                 "country_code" => "XX",
                 "industry" => "casino",
                 "contact_email" => "not an email",
                 "contact_phone" => "123",
                 "website" => "http://plain.example",
                 "interests" => ["sponsored_events", "sponsored_events"],
                 "budget_band" => "12500.50",
                 "goals" => String.duplicate("g", 2001)
               })

      assert Enum.sort(Map.keys(codes(cs))) ==
               Enum.sort(
                 ~w(country_code industry contact_email contact_phone website interests budget_band goals)
               )

      assert Repo.get!(Application, c.a.id).company_name == "Acme"
    end

    test "markets: a global scope names nothing; the scope decides what's needed", c do
      assert {:error, cs} =
               save(c.user, %{
                 "expected_revision" => c.a.revision,
                 "market_scope" => "global",
                 "market_countries" => ["PL"]
               })

      assert Map.has_key?(codes(cs), "market_scope")

      {:ok, %{application: a}} =
        save(c.user, %{"expected_revision" => c.a.revision, "market_scope" => "cities"})

      {:ok, %{missing: missing}} = Applications.get(c.user)
      assert :market_countries in missing and :market_cities in missing
      _ = a
    end

    test "drafts survive sessions and devices: they live on the server", c do
      {:ok, _} = Accounts.create_session(c.user)
      assert {:ok, %{application: %{id: id, company_name: "Acme"}}} = Applications.get(c.user)
      assert id == c.a.id
    end
  end

  describe "submitting" do
    setup %{user: user} do
      %{a: draft!(user, complete_answers(%{"goals" => nil}))}
    end

    test "every missing answer is named; nothing changes", c do
      assert {:error, cs} = Applications.submit(c.user, submit_params(c.a))
      assert codes(cs) == %{"goals" => ["required"]}
      assert Repo.get!(Application, c.a.id).status == :draft
      assert Repo.aggregate(ApplicationSubmission, :count) == 0
      assert [_, %{outcome: :refused, reason_code: "submission_incomplete"}] = events(c.a.id)
    end

    test "the declaration: accepted, published, current, in an available language", c do
      {:ok, %{application: a}} =
        save(c.user, %{"expected_revision" => c.a.revision, "goals" => "Events"})

      for {override, expected} <- [
            {%{"declaration_accepted" => false}, :changeset},
            {%{"declaration_language" => "pl"}, :changeset},
            {%{"declaration_version" => "sponsor-application-declaration-2020-01-01"},
             {:conflict, %{declaration: "stale"}}}
          ] do
        result = Applications.submit(c.user, submit_params(a, override))

        if expected == :changeset,
          do: assert({:error, %Ecto.Changeset{}} = result),
          else: assert({:error, ^expected} = result)
      end

      without_published_declaration(fn ->
        assert {:error, {:conflict, %{declaration: "unavailable"}}} =
                 Applications.submit(c.user, submit_params(a))

        assert {:ok, %{declaration: %{available: false}}} = Applications.get(c.user)
      end)

      assert Repo.get!(Application, a.id).status == :draft
    end

    test "a successful submission: immutable snapshot, history, and nothing granted", c do
      {:ok, %{application: a}} =
        save(c.user, %{"expected_revision" => c.a.revision, "goals" => "Events"})

      request = submit_params(a)

      assert {:ok, %{application: %{status: :submitted} = submitted, submissions: [s]}} =
               Applications.submit(c.user, request)

      assert s.sequence == 1 and s.application_revision == a.revision
      assert s.policy_version == "sponsor-application-2026-11.v1"
      assert s.snapshot["answers"]["goals"] == "Events"
      assert s.snapshot["contact_email_verified"] == false
      assert byte_size(s.declaration_content_sha256) == 64

      assert [_, _, %{event: "sponsor_application.submitted", to_status: "submitted"}] =
               events(a.id)

      # A retry answers the same; the same key for something else is refused.
      assert {:ok, %{application: %{revision: rev}, submissions: [_]}} =
               Applications.submit(c.user, request)

      assert rev == submitted.revision

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               Applications.submit(c.user, %{request | "declaration_language" => "pl"})

      # Nothing was granted.
      assert Repo.aggregate(Organization, :count) == 0
      assert Repo.aggregate(Membership, :count) == 0

      assert {:ok, %{destination: :sponsor_application_status, capabilities: []}} =
               Entry.resolve(c.user, %{"intent" => "sponsor"})

      # No edits after submission, through the API or the database; the snapshot is append-only.
      assert {:error, {:conflict, %{application: "not_editable"}}} =
               save(c.user, %{"expected_revision" => submitted.revision, "goals" => "Changed"})

      assert_raise Postgrex.Error, ~r/answers_locked/, fn ->
        Repo.update_all(from(x in Application, where: x.id == ^a.id), set: [goals: "Changed"])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(x in ApplicationSubmission, where: x.id == ^s.id),
          set: [policy_version: "forged"]
        )
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(x in ApplicationSubmission, where: x.id == ^s.id))
      end
    end
  end

  describe "review states (test fixture standing in for the future review)" do
    setup %{user: user} do
      a = submitted!(user, draft!(user))
      %{a: a}
    end

    test "changes requested: edit, resubmit; the first submission is unchanged", c do
      reviewed = c.a |> review!(:under_review) |> review!(:changes_requested)

      assert {:ok,
              %{
                destination: :sponsor_application_status,
                reason: :sponsor_application_changes_requested
              }} =
               Entry.resolve(c.user, %{"intent" => "sponsor"})

      {:ok, %{application: edited}} =
        save(c.user, %{"expected_revision" => reviewed.revision, "goals" => "Clearer goals"})

      assert {:ok, %{application: %{status: :submitted}, submissions: [first, second]}} =
               Applications.submit(c.user, submit_params(edited))

      assert second.sequence == 2 and second.snapshot["answers"]["goals"] == "Clearer goals"
      assert first.snapshot["answers"]["goals"] == "Support amateur boxing events in Poland."
      assert Enum.any?(events(c.a.id), &(&1.event == "sponsor_application.resubmitted"))
    end

    test "applicants can't move an application into a review state", c do
      for status <- ~w(under_review approved rejected changes_requested) do
        assert {:error, %Ecto.Changeset{}} =
                 save(c.user, %{"expected_revision" => c.a.revision, "status" => status})
      end

      assert_raise Postgrex.Error, ~r/cannot become/, fn ->
        Repo.update_all(from(x in Application, where: x.id == ^c.a.id), set: [status: :approved])
      end
    end

    test "a rejected application: status visible, reapplication blocked (D-SA03)", c do
      c.a |> review!(:under_review) |> review!(:rejected)

      assert {:ok,
              %{destination: :sponsor_application_status, reason: :sponsor_application_closed}} =
               Entry.resolve(c.user, %{"intent" => "sponsor"})

      assert {:error, {:conflict, %{application: "reapplication_unavailable"}}} =
               save(c.user, %{
                 "client_request_id" => Ecto.UUID.generate(),
                 "company_name" => "Again"
               })

      assert {:ok, %{application: %{status: :rejected}}} = Applications.get(c.user)
    end
  end

  describe "isolation and entry" do
    test "another user can't read or reach an application or its submissions", %{user: user} do
      a = submitted!(user, draft!(user))
      [s] = Repo.all(from(x in ApplicationSubmission, where: x.application_id == ^a.id))
      other = registered!("other")

      assert {:error, :not_found} = Applications.get(other)
      assert {:error, :not_found} = Applications.get_submission(other, s.id)
      assert {:ok, _} = Applications.get_submission(user, s.id)
      assert {:error, :not_found} = Applications.get_submission(user, "not-a-uuid")

      # The other user's own application never touches the first.
      draft!(other)
      assert {:ok, %{application: %{id: id}}} = Applications.get(user)
      assert id == a.id
    end

    test "a draft resumes; a workspace wins over an application", %{user: user} do
      draft!(user, %{"company_name" => "Acme"})

      assert {:ok, %{destination: :sponsor_application_draft}} =
               Entry.resolve(user, %{"intent" => "sponsor"})

      assert {:ok, %{destination: :sponsor_application_draft}} = Entry.resolve(user)

      %{organization: org} = provision!(registered!("owner"))
      member!(org, user)
      org_id = org.id

      assert {:ok, %{destination: :sponsor_home, sponsor_id: ^org_id}} =
               Entry.resolve(user, %{"intent" => "sponsor"})
    end

    test "history holds ids and codes only", %{user: user} do
      a = submitted!(user, draft!(user))
      dump = inspect(events(a.id))
      refute dump =~ "ada@acme.example"
      refute dump =~ "Acme"
    end
  end
end
