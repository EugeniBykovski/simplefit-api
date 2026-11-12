defmodule SimpleFit.SponsorProposalReviewTest do
  @moduledoc """
  SF-130 in the SQL sandbox: operator review of partnership proposals through the
  SF-111 framework - the audited queue and detail, claim, request changes and the
  organization's resubmission, the confirmed accept and decline, conflicts of
  interest, organization suspension, and that no decision creates anything.
  """

  use SimpleFit.DataCase, async: false

  import SimpleFit.OperatorHelpers, only: [untrust_ceremony_keys!: 0]
  import SimpleFit.PartnershipHelpers
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias SimpleFit.Operators
  alias SimpleFit.Operators.AuditEvent

  alias SimpleFit.Sponsors.{
    Membership,
    Organization,
    PartnershipEvent,
    Partnerships,
    Proposal,
    ProposalChangeRequest,
    Provisioning
  }

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    r = founder!(review_permissions() ++ ~w(operators.read operators.manage))
    owner = registered!("owner")
    %{organization: org} = provision!(owner)
    p = submitted_proposal!(owner, org, draft_proposal!(owner, org))
    %{r: r, owner: owner, org: org, p: p}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp audits(command),
    do:
      Repo.all(
        from(e in AuditEvent, where: e.command == ^command, order_by: [e.occurred_at, e.id])
      )

  defp changes(r, p, fields \\ ["summary"]),
    do:
      exec(r, "sponsor_proposal.request_changes", p, %{
        "reason_code" => "unclear_request",
        "fields" => fields,
        "message" => "Please describe which events you have in mind."
      })

  describe "reading" do
    test "the queue lists submitted proposals only, oldest first, and is audited", c do
      draft_proposal!(c.owner, c.org)
      second = submitted_proposal!(c.owner, c.org, draft_proposal!(c.owner, c.org))

      assert {:ok, %{proposals: [one, two], next_cursor: nil}} =
               Operators.list_sponsor_proposals(c.r.user, c.r.session, %{})

      assert {one.proposal.id, two.proposal.id} == {c.p.id, second.id}
      assert one.organization.id == c.org.id and one.submissions == 1
      refute one.change_request_open

      assert {:ok, %{proposals: [_], next_cursor: cursor}} =
               Operators.list_sponsor_proposals(c.r.user, c.r.session, %{"limit" => "1"})

      assert {:ok, %{proposals: [last]}} =
               Operators.list_sponsor_proposals(c.r.user, c.r.session, %{
                 "limit" => "1",
                 "cursor" => cursor
               })

      assert last.proposal.id == second.id

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_sponsor_proposals(c.r.user, c.r.session, %{"status" => "draft"})

      assert length(audits("sponsor_proposals.queue")) == 3
    end

    test "the detail is audited and says whether the reader is a party", c do
      assert {:ok, %{viewer_is_party: false, latest_submission: submission} = view} =
               Operators.get_sponsor_proposal(c.r.user, c.r.session, c.p.id)

      assert submission.snapshot["answers"]["title"] == c.p.title
      assert view.organization.id == c.org.id
      assert [%{target_type: "sponsor_proposal"}] = audits("sponsor_proposals.detail")

      draft = draft_proposal!(c.owner, c.org)

      assert {:error, :not_found} =
               Operators.get_sponsor_proposal(c.r.user, c.r.session, draft.id)

      member!(c.org, c.r.user, :member)

      assert {:ok, %{viewer_is_party: true}} =
               Operators.get_sponsor_proposal(c.r.user, c.r.session, c.p.id)
    end

    test "non-operators get not_found; operators without the permission are refused", c do
      assert {:error, :not_found} =
               Operators.get_sponsor_proposal(c.owner, live_session!(c.owner), c.p.id)

      reader = operator_for!(c.r, registered!("other-op"), ["operators.read"])

      assert {:error, :forbidden} =
               Operators.list_sponsor_proposals(reader.user, reader.session, %{})

      assert {:error, :forbidden} = claim(reader, c.p)
      assert Repo.reload!(c.p).status == :submitted
    end
  end

  describe "review actions" do
    test "claim, request changes, resubmission of only the requested answers", c do
      assert {:ok, %{proposal: %{status: :under_review}}} = claim(c.r, c.p)

      assert {:error, {:revision_conflict, _}} =
               Operators.execute(
                 "sponsor_proposal.request_changes",
                 c.r.user,
                 c.r.session,
                 c.p.id,
                 %{
                   "reason_code" => "unclear_request",
                   "fields" => ["summary"],
                   "message" => "Stale",
                   "expected_revision" => 1,
                   "operation_id" => Ecto.UUID.generate()
                 }
               )

      assert {:error, %Ecto.Changeset{}} =
               exec(c.r, "sponsor_proposal.request_changes", c.p, %{
                 "reason_code" => "unclear_request",
                 "fields" => ["budget_band"],
                 "message" => "Not a proposal field"
               })

      assert {:ok, %{proposal: %{status: :changes_requested}, change_request: request}} =
               changes(c.r, c.p)

      assert request.fields == ["summary"]

      # The organization sees the message and fields, never the reviewer or the reason.
      assert {:ok, view} = Partnerships.get_proposal(c.owner, c.org.id, c.p.id)
      assert view.change_request.message =~ "which events"
      assert view.actions == %{edit: true, submit: true, withdraw: true}
      assert List.last(view.history).actor_kind == :operator
      refute Map.has_key?(List.last(view.history), :actor_user_id)

      p = Repo.reload!(c.p)

      assert {:error, %Ecto.Changeset{errors: [title: {_, [validation: :not_requested]}]}} =
               Partnerships.update_proposal(c.owner, c.org.id, p.id, %{
                 "expected_revision" => p.revision,
                 "title" => "Not requested"
               })

      assert {:ok, _} =
               Partnerships.update_proposal(c.owner, c.org.id, p.id, %{
                 "expected_revision" => p.revision,
                 "summary" => "Amateur events in Warsaw and Berlin in spring."
               })

      assert {:ok, %{proposal: %{status: :submitted}, submissions: [_, _]}} =
               Partnerships.submit_proposal(c.owner, c.org.id, p.id, command(p))

      assert [%{resolved_at: %DateTime{}}] = Repo.all(ProposalChangeRequest)

      assert [%{event: "partnership_proposal.resubmitted"}] =
               Repo.all(
                 from(e in PartnershipEvent, where: e.event == "partnership_proposal.resubmitted")
               )
    end

    test "accept needs a confirmation, is final and creates nothing", c do
      {:ok, _} = claim(c.r, c.p)
      before = {count(Organization), count(Membership)}

      assert {:error, :confirmation_required} =
               exec(c.r, "sponsor_proposal.accept", c.p, %{"reason_code" => "follow_up_planned"})

      assert {:ok, preview} =
               Operators.preview("sponsor_proposal.accept", c.r.user, c.r.session, c.p.id, %{
                 "reason_code" => "follow_up_planned"
               })

      assert "nothing_created" in preview.impact and "nonbinding" in preview.impact
      assert Repo.reload!(c.p).status == :under_review

      assert {:ok, %{proposal: %{status: :accepted, decided_at: %DateTime{}}}} =
               decide(c.r, "sponsor_proposal.accept", c.p, "follow_up_planned")

      assert {count(Organization), count(Membership)} == before

      assert [
               %{outcome: :refused, result_code: "confirmation_required"},
               %{outcome: :allowed} = ok
             ] =
               audits("sponsor_proposal.accept")

      id = ok.target_id
      assert id == c.p.id

      assert {:error, {:conflict, %{proposal: "not_withdrawable", status: "accepted"}}} =
               Partnerships.withdraw_proposal(c.owner, c.org.id, c.p.id, command(c.p))

      assert {:error, {:conflict, %{status: "accepted"}}} =
               decide(c.r, "sponsor_proposal.decline", c.p, "other")
    end

    test "decline is final; its reason stays internal", c do
      {:ok, _} = claim(c.r, c.p)

      assert {:ok, %{proposal: %{status: :declined}}} =
               decide(c.r, "sponsor_proposal.decline", c.p, "not_a_fit_now")

      assert {:ok, view} = Partnerships.get_proposal(c.owner, c.org.id, c.p.id)
      refute inspect(view.history) =~ "not_a_fit_now"
      assert view.actions == %{edit: false, submit: false, withdraw: false}
    end

    test "only an under-review proposal can be decided; a withdrawal wins over a later decision",
         c do
      assert {:error, {:conflict, %{status: "submitted"}}} =
               decide(c.r, "sponsor_proposal.accept", c.p, "follow_up_planned")

      {:ok, _} = claim(c.r, c.p)

      {:ok, preview} =
        Operators.preview("sponsor_proposal.accept", c.r.user, c.r.session, c.p.id, %{
          "reason_code" => "follow_up_planned"
        })

      {:ok, _} = Partnerships.withdraw_proposal(c.owner, c.org.id, c.p.id, command(c.p))

      assert {:error, {:revision_conflict, _}} =
               Operators.execute("sponsor_proposal.accept", c.r.user, c.r.session, c.p.id, %{
                 "reason_code" => "follow_up_planned",
                 "expected_revision" => preview.expected_revision,
                 "operation_id" => Ecto.UUID.generate(),
                 "confirmation_token" => preview.confirmation.token
               })

      assert Repo.reload!(c.p).status == :withdrawn
    end

    test "an operator who belongs to the organization can't act on its proposals", c do
      member!(c.org, c.r.user, :member)
      assert {:error, {:conflict, %{target: "self"}}} = claim(c.r, c.p)
      assert Repo.reload!(c.p).status == :submitted
      assert [%{outcome: :refused, result_code: "self_action"}] = audits("sponsor_proposal.claim")
    end

    test "a suspended organization can't be claimed, asked or accepted, but can be declined", c do
      {:ok, _} = claim(c.r, c.p)
      {:ok, _} = Provisioning.suspend_organization(fixture_authority(), c.org.id, "policy_review")

      assert {:error, {:conflict, %{organization: "suspended"}}} = changes(c.r, c.p)

      assert {:error, {:conflict, %{organization: "suspended"}}} =
               decide(c.r, "sponsor_proposal.accept", c.p, "follow_up_planned")

      assert {:ok, %{proposal: %{status: :declined}}} =
               decide(c.r, "sponsor_proposal.decline", c.p, "other")

      assert Repo.get!(Proposal, c.p.id).status == :declined
    end
  end
end
