defmodule SimpleFit.SponsorPartnershipsTest do
  @moduledoc """
  SF-130 in the SQL sandbox: partnership preferences, the explicit absence of
  opportunities, and the sponsor half of the nonbinding proposal lifecycle -
  membership authorization, cross-organization isolation, roles, suspension,
  idempotency, revisions, completeness, immutable snapshots and the database's own
  lifecycle guard.
  """

  use SimpleFit.DataCase, async: false

  import SimpleFit.PartnershipHelpers
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Operators

  alias SimpleFit.Sponsors.{
    Membership,
    Organization,
    PartnershipEvent,
    PartnershipPreferences,
    Partnerships,
    Proposal,
    ProposalSubmission,
    Provisioning,
    Review
  }

  setup do
    on_exit(&SimpleFit.OperatorHelpers.untrust_ceremony_keys!/0)
    owner = registered!("owner")
    manager = registered!("manager")
    member = registered!("member")
    outsider = registered!("outsider")
    %{organization: org} = provision!(owner)
    member!(org, manager, :manager)
    m = member!(org, member, :member)
    other_owner = registered!("other")
    %{organization: other} = provision!(other_owner)

    %{
      owner: owner,
      manager: manager,
      member: member,
      member_membership: m,
      outsider: outsider,
      org: org,
      other: other,
      other_owner: other_owner
    }
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  # A write the database itself refuses (a trigger or a check), inside a savepoint so
  # the test's transaction stays usable.
  defp refused_by_db(pattern, fun) do
    error =
      try do
        Repo.transaction(fn -> fun.() end)
        flunk("the database accepted the write")
      rescue
        e in [Postgrex.Error, Ecto.ConstraintError] -> e
      end

    assert Exception.message(error) =~ pattern
  end

  describe "opportunities" do
    test "members get an explicit unavailable answer; nobody else learns anything", c do
      for user <- [c.owner, c.manager, c.member] do
        assert {:ok, %{availability: :unavailable, reason: :no_inventory, sponsor_id: id}} =
                 Partnerships.opportunities(user, c.org.id)

        assert id == c.org.id
      end

      assert {:error, :not_found} = Partnerships.opportunities(c.outsider, c.org.id)
      assert {:error, :not_found} = Partnerships.opportunities(c.other_owner, c.org.id)
      assert {:error, :not_found} = Partnerships.opportunities(c.owner, "not-a-uuid")
    end
  end

  describe "preferences" do
    test "nil until first saved; created with revision 0, then by the current revision", c do
      assert {:ok, %{preferences: nil, application_answers: nil, can_edit: false}} =
               Partnerships.get_preferences(c.member, c.org.id)

      assert {:ok, %{can_edit: true}} = Partnerships.get_preferences(c.manager, c.org.id)

      assert {:error, {:revision_conflict, %{current_revision: 0}}} =
               Partnerships.save_preferences(c.owner, c.org.id, %{"expected_revision" => 1})

      assert {:ok, %{preferences: %PartnershipPreferences{revision: 1} = p}} =
               Partnerships.save_preferences(c.manager, c.org.id, %{
                 "expected_revision" => 0,
                 "interests" => ["sponsored_events"],
                 "market_scope" => "global",
                 "goals" => "  Grow amateur boxing.  "
               })

      assert p.goals == "Grow amateur boxing." and p.updated_by_user_id == c.manager.id

      assert {:error, {:revision_conflict, %{current_revision: 1}}} =
               Partnerships.save_preferences(c.owner, c.org.id, %{"expected_revision" => 0})

      assert {:ok, %{preferences: %{revision: 2, market_scope: "countries"}}} =
               Partnerships.save_preferences(c.owner, c.org.id, %{
                 "expected_revision" => 1,
                 "market_scope" => "countries",
                 "market_countries" => ["pl"]
               })

      assert {:ok, %{preferences: %{market_countries: ["PL"], interests: ["sponsored_events"]}}} =
               Partnerships.get_preferences(c.member, c.org.id)

      assert Repo.aggregate(
               from(e in PartnershipEvent, where: e.event == "partnership_preferences.updated"),
               :count
             ) == 1
    end

    test "an invalid save changes nothing; unknown fields and a budget are refused", c do
      {:ok, _} =
        Partnerships.save_preferences(c.owner, c.org.id, %{
          "expected_revision" => 0,
          "interests" => ["content"]
        })

      for bad <- [
            %{"interests" => ["nope"]},
            %{"interests" => ["content", "content"]},
            %{"market_scope" => "global", "market_countries" => ["PL"]},
            %{"market_countries" => ["XX"]},
            %{"goals" => String.duplicate("a", 2001)},
            %{"budget_band" => "eur_under_5000"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Partnerships.save_preferences(
                   c.owner,
                   c.org.id,
                   Map.put(bad, "expected_revision", 1)
                 )
      end

      assert %{revision: 1, interests: ["content"]} = Repo.one!(PartnershipPreferences)
    end

    test "members can't save; suspended organizations are read-only; outsiders see nothing", c do
      params = %{"expected_revision" => 0, "interests" => ["content"]}
      assert {:error, :forbidden} = Partnerships.save_preferences(c.member, c.org.id, params)
      assert {:error, :not_found} = Partnerships.save_preferences(c.outsider, c.org.id, params)
      assert {:error, :not_found} = Partnerships.save_preferences(c.other_owner, c.org.id, params)
      assert {:error, :not_found} = Partnerships.get_preferences(c.outsider, c.org.id)

      {:ok, _} = Provisioning.suspend_organization(fixture_authority(), c.org.id, "policy_review")

      assert {:error, {:conflict, %{organization: "suspended"}}} =
               Partnerships.save_preferences(c.owner, c.org.id, params)

      assert {:ok, %{can_edit: false}} = Partnerships.get_preferences(c.owner, c.org.id)
      assert count(PartnershipPreferences) == 0
    end
  end

  describe "proposals: creating and reading" do
    test "a draft is created once per key; a different request with the key is refused", c do
      key = Ecto.UUID.generate()
      params = Map.put(proposal_answers(), "client_request_id", key)

      assert {:ok, %{proposal: %Proposal{status: :draft, revision: 1} = p, missing: []} = view} =
               Partnerships.create_proposal(c.manager, c.org.id, params)

      assert p.kind == :general_inquiry and p.organization_id == c.org.id
      assert view.actions == %{edit: true, submit: true, withdraw: true}
      assert view.created_by_viewer

      assert {:ok, %{proposal: %{id: same}}} =
               Partnerships.create_proposal(c.manager, c.org.id, params)

      assert same == p.id

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               Partnerships.create_proposal(
                 c.manager,
                 c.org.id,
                 Map.put(params, "title", "Something else")
               )

      assert count(Proposal) == 1
    end

    test "a draft may start incomplete and says what submitting needs", c do
      assert {:ok, %{missing: missing}} =
               Partnerships.create_proposal(c.owner, c.org.id, %{
                 "client_request_id" => Ecto.UUID.generate(),
                 "market_scope" => "cities"
               })

      assert missing == [:title, :interests, :market_countries, :market_cities, :summary]
    end

    test "invalid answers, unknown fields and money are refused", c do
      for bad <- [
            %{"title" => String.duplicate("a", 121)},
            %{"interests" => ["athlete_endorsement"]},
            %{"summary" => ""},
            %{"budget_band" => "eur_100000_plus"},
            %{"opportunity_id" => Ecto.UUID.generate()},
            %{"athlete_id" => Ecto.UUID.generate()}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Partnerships.create_proposal(
                   c.owner,
                   c.org.id,
                   Map.put(bad, "client_request_id", Ecto.UUID.generate())
                 )
      end

      assert {:error, %Ecto.Changeset{}} = Partnerships.create_proposal(c.owner, c.org.id, %{})
      assert count(Proposal) == 0
    end

    test "roles, suspension, revocation and other organizations", c do
      params = Map.put(proposal_answers(), "client_request_id", Ecto.UUID.generate())
      assert {:error, :forbidden} = Partnerships.create_proposal(c.member, c.org.id, params)
      assert {:error, :not_found} = Partnerships.create_proposal(c.outsider, c.org.id, params)
      p = draft_proposal!(c.owner, c.org)

      # Every member reads; nobody outside does, even with the proposal id.
      assert {:ok, %{actions: %{edit: false, submit: false, withdraw: false}}} =
               Partnerships.get_proposal(c.member, c.org.id, p.id)

      assert {:error, :not_found} = Partnerships.get_proposal(c.outsider, c.org.id, p.id)
      assert {:error, :not_found} = Partnerships.get_proposal(c.other_owner, c.other.id, p.id)
      assert {:error, :not_found} = Partnerships.get_proposal(c.other_owner, c.org.id, p.id)
      assert {:ok, %{entries: []}} = Partnerships.list_proposals(c.other_owner, c.other.id)

      assert {:error, :not_found} =
               Partnerships.submit_proposal(c.other_owner, c.other.id, p.id, command(p))

      # A revoked member loses everything on the next call.
      {:ok, _} =
        Provisioning.revoke_membership(
          fixture_authority(),
          c.member_membership.id,
          "left_company"
        )

      assert {:error, :not_found} = Partnerships.get_proposal(c.member, c.org.id, p.id)
      assert {:error, :not_found} = Partnerships.list_proposals(c.member, c.org.id)

      {:ok, _} = Provisioning.suspend_organization(fixture_authority(), c.org.id, "policy_review")

      assert {:ok, %{actions: %{edit: false, submit: false, withdraw: false}}} =
               Partnerships.get_proposal(c.owner, c.org.id, p.id)

      assert {:error, {:conflict, %{organization: "suspended"}}} =
               Partnerships.submit_proposal(c.owner, c.org.id, p.id, command(p))

      assert {:ok, %{can_create: false}} = Partnerships.list_proposals(c.owner, c.org.id)
    end

    test "lists newest first, filters by status and pages", c do
      [a, b, d] = for _ <- 1..3, do: draft_proposal!(c.owner, c.org)
      submitted_proposal!(c.owner, c.org, b)

      assert {:ok, %{entries: page1, next_cursor: cursor, can_create: false}} =
               Partnerships.list_proposals(c.member, c.org.id, %{"limit" => "2"})

      assert {:ok, %{can_create: true}} = Partnerships.list_proposals(c.owner, c.org.id)

      assert Enum.map(page1, & &1.proposal.id) == [d.id, b.id]

      assert {:ok, %{entries: [last], next_cursor: nil}} =
               Partnerships.list_proposals(c.member, c.org.id, %{
                 "limit" => "2",
                 "cursor" => cursor
               })

      assert last.proposal.id == a.id

      assert {:ok, %{entries: [only]}} =
               Partnerships.list_proposals(c.member, c.org.id, %{"status" => "submitted"})

      assert only.proposal.id == b.id

      assert {:error, %Ecto.Changeset{}} =
               Partnerships.list_proposals(c.member, c.org.id, %{"status" => "approved"})

      assert {:error, %Ecto.Changeset{}} =
               Partnerships.list_proposals(c.member, c.org.id, %{"cursor" => "garbage"})
    end

    test "an organization has at most the open limit of proposals", c do
      for _ <- 1..25, do: draft_proposal!(c.owner, c.org)

      assert {:error, {:conflict, %{proposals: "open_limit"}}} =
               Partnerships.create_proposal(
                 c.owner,
                 c.org.id,
                 Map.put(proposal_answers(), "client_request_id", Ecto.UUID.generate())
               )

      assert {:ok, %{can_create: false}} = Partnerships.list_proposals(c.owner, c.org.id)

      # Another organization isn't affected; withdrawing one frees a place.
      draft_proposal!(c.other_owner, c.other)
      [p | _] = Repo.all(from(p in Proposal, where: p.organization_id == ^c.org.id))
      {:ok, _} = Partnerships.withdraw_proposal(c.owner, c.org.id, p.id, command(p))
      draft_proposal!(c.owner, c.org)
    end
  end

  describe "proposals: editing, submitting, withdrawing" do
    test "saves by revision; stale revisions are refused and recorded", c do
      p = draft_proposal!(c.owner, c.org, %{"title" => "Draft"})

      assert {:ok, %{proposal: %{revision: 2, title: "Better"}}} =
               Partnerships.update_proposal(c.manager, c.org.id, p.id, %{
                 "expected_revision" => 1,
                 "title" => "  Better "
               })

      assert {:error, {:revision_conflict, %{current_revision: 2}}} =
               Partnerships.update_proposal(c.owner, c.org.id, p.id, %{
                 "expected_revision" => 1,
                 "title" => "Lost update"
               })

      assert {:error, :forbidden} =
               Partnerships.update_proposal(c.member, c.org.id, p.id, %{
                 "expected_revision" => 2,
                 "title" => "Member"
               })

      assert Repo.reload!(p).title == "Better"

      assert [%{reason_code: "revision_stale", outcome: :refused}] =
               Repo.all(
                 from(e in PartnershipEvent,
                   where: e.event == "partnership_proposal.update_refused"
                 )
               )
    end

    test "submission needs every required answer, snapshots them and locks them", c do
      p = draft_proposal!(c.owner, c.org, %{"title" => "Incomplete"})

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Partnerships.submit_proposal(c.owner, c.org.id, p.id, command(p))

      assert Keyword.keys(errors) |> Enum.sort() == [:interests, :market_scope, :summary]
      assert count(ProposalSubmission) == 0

      {:ok, _} =
        Partnerships.update_proposal(
          c.owner,
          c.org.id,
          p.id,
          Map.put(Map.delete(proposal_answers(), "title"), "expected_revision", p.revision)
        )

      params = command(p)

      assert {:ok, %{proposal: %{status: :submitted} = s, submissions: [sub], actions: actions}} =
               Partnerships.submit_proposal(c.manager, c.org.id, p.id, params)

      assert actions == %{edit: false, submit: false, withdraw: true}
      assert s.submitted_at

      submission = Repo.get!(ProposalSubmission, sub.id)
      assert submission.snapshot["schema"] == "sponsor-partnership-proposal-snapshot.v1"
      assert submission.snapshot["binding"] == false
      assert submission.snapshot["answers"]["title"] == "Incomplete"
      assert submission.policy_version == "sponsor-partnership-2026-11.v1"

      # The same request again: the same answer, nothing new.
      assert {:ok, %{proposal: %{status: :submitted}}} =
               Partnerships.submit_proposal(c.manager, c.org.id, p.id, params)

      assert count(ProposalSubmission) == 1

      # The key for another request, and a second submission, are refused.
      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               Partnerships.submit_proposal(
                 c.manager,
                 c.org.id,
                 p.id,
                 Map.put(params, "expected_revision", params["expected_revision"] + 1)
               )

      assert {:error, {:conflict, %{proposal: "not_submittable", status: "submitted"}}} =
               Partnerships.submit_proposal(c.manager, c.org.id, p.id, command(p))

      assert {:error, {:conflict, %{proposal: "not_editable"}}} =
               Partnerships.update_proposal(c.owner, c.org.id, p.id, %{
                 "expected_revision" => Repo.reload!(p).revision,
                 "title" => "Changed after submission"
               })

      # The database refuses it too, and refuses snapshot edits and deletes.
      refused_by_db(~r/answers_locked/, fn ->
        Repo.update!(Ecto.Changeset.change(Repo.reload!(p), title: "Sneaky"))
      end)

      refused_by_db(~r/append/, fn ->
        Repo.update!(Ecto.Changeset.change(submission, policy_version: "other"))
      end)

      refused_by_db(~r/no_delete/, fn -> Repo.delete!(Repo.reload!(p)) end)
    end

    test "the database allows only the lifecycle's transitions", c do
      p = draft_proposal!(c.owner, c.org)

      for to <- [:under_review, :changes_requested, :accepted, :declined] do
        refused_by_db(~r/proposals_transition/, fn ->
          Repo.update!(
            Ecto.Changeset.change(p,
              status: to,
              submitted_at: DateTime.utc_now(),
              decided_at: if(to in [:accepted, :declined], do: DateTime.utc_now())
            )
          )
        end)
      end

      refused_by_db(~r/immutable/, fn ->
        Repo.update!(Ecto.Changeset.change(p, organization_id: c.other.id))
      end)
    end

    test "withdrawal is final and idempotent", c do
      p = submitted_proposal!(c.owner, c.org, draft_proposal!(c.owner, c.org))
      params = command(p)

      assert {:error, :forbidden} =
               Partnerships.withdraw_proposal(c.member, c.org.id, p.id, params)

      assert {:ok, %{proposal: %{status: :withdrawn, withdrawn_at: at}} = view} =
               Partnerships.withdraw_proposal(c.manager, c.org.id, p.id, params)

      assert at && view.actions == %{edit: false, submit: false, withdraw: false}

      assert {:ok, %{proposal: %{status: :withdrawn}}} =
               Partnerships.withdraw_proposal(c.manager, c.org.id, p.id, params)

      assert {:error, {:conflict, %{proposal: "not_withdrawable", status: "withdrawn"}}} =
               Partnerships.withdraw_proposal(c.owner, c.org.id, p.id, command(p))

      assert {:ok, %{history: history}} = Partnerships.get_proposal(c.member, c.org.id, p.id)

      assert Enum.map(history, &{&1.from_status, &1.to_status}) == [
               {nil, "draft"},
               {"draft", "submitted"},
               {"submitted", "withdrawn"}
             ]
    end

    test "a draft can be withdrawn; it never reaches anyone else", c do
      p = draft_proposal!(c.owner, c.org)

      assert {:ok, %{proposal: %{status: :withdrawn, submitted_at: nil}}} =
               Partnerships.withdraw_proposal(c.owner, c.org.id, p.id, command(p))
    end
  end

  describe "the application's submitted answers" do
    test "are shown beside the preferences and never changed by them", c do
      %{organization: org, application: app, submission: submission} = approved_organization!()
      owner = Repo.get!(User, app.applicant_user_id)

      assert {:ok, %{preferences: nil, application_answers: answers}} =
               Partnerships.get_preferences(owner, org.id)

      assert answers.interests == submission.snapshot["answers"]["interests"]
      assert answers.goals == submission.snapshot["answers"]["goals"]
      refute Map.has_key?(answers, :budget_band)
      refute Map.has_key?(answers, :contact_email)

      {:ok, _} =
        Partnerships.save_preferences(owner, org.id, %{
          "expected_revision" => 0,
          "interests" => ["content"],
          "goals" => "Different goals now."
        })

      assert Repo.reload!(submission).snapshot == submission.snapshot
      assert Repo.reload!(app).interests == app.interests
      assert {:ok, %{application_answers: ^answers}} = Partnerships.get_preferences(owner, org.id)
      _ = c
    end
  end

  test "nothing commercial, and no other organization or membership, is created", c do
    before = {count(Organization), count(Membership)}
    p = draft_proposal!(c.owner, c.org)
    p = submitted_proposal!(c.owner, c.org, p)
    {:ok, _} = Partnerships.withdraw_proposal(c.owner, c.org.id, p.id, command(p))
    assert {count(Organization), count(Membership)} == before

    tables =
      Repo.query!("""
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name ~ '^sponsor_.*(campaign|placement|invoice|payment|entitlement|contract)'
      """).rows

    assert tables == []
  end

  # An organization made from a real approved application (SF-116), so the
  # application's submission exists.
  defp approved_organization! do
    import SimpleFit.SponsorApplicationHelpers
    import SimpleFit.OperatorHelpers, only: [act: 4]
    import SimpleFit.GymHelpers, only: [email_user!: 1]

    r =
      founder!(~w(sponsors.applications.read sponsors.applications.claim
                  sponsors.applications.approve))

    applicant = email_user!("applicant-#{System.unique_integer([:positive])}@example.com")
    app = submitted!(applicant, draft!(applicant))

    {:ok, _} =
      Operators.execute("sponsor_application.claim", r.user, r.session, app.id, %{
        "reason_code" => "review_started",
        "expected_revision" => Repo.reload!(app).revision,
        "operation_id" => Ecto.UUID.generate()
      })

    {:ok, %{organization: org}} = act(r.user, r.session, "sponsor_application.approve", app.id)
    submission = Review.latest_submission(app.id)
    %{organization: org, application: Repo.reload!(app), submission: submission}
  end
end
