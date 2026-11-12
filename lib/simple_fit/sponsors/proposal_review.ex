defmodule SimpleFit.Sponsors.ProposalReview do
  @moduledoc """
  What an operator sees of partnership proposals, and the domain changes of their
  review (SF-130, ADR 0034). Operators reach this only through `SimpleFit.Operators`
  (permission, key check, audit): the projections `sponsors.proposals.read` (queue,
  detail) and the declared actions in `SimpleFit.Sponsors.ProposalReviewActions`.
  Drafts and withdrawn drafts are invisible to operators. Each change runs inside the
  action pipeline's transaction with the proposal locked.

  * **Claim** (`submitted -> under_review`).
  * **Request changes** (`under_review -> changes_requested`): the answers to revisit
    and a message the organization sees; its next submission resolves it.
  * **Accept** (`under_review -> accepted`): SimpleFit will follow up outside the
    product. Final. **Creates nothing**: no payment, campaign, placement, advertising
    entitlement, exposure guarantee, contract or access to athlete or gym data.
  * **Decline** (`under_review -> declined`): final; nothing is created. The reason is
    internal and never shown to the organization.

  Operators never see the organization's contacts or members from here: the
  organization's id, name and status, and what was submitted.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Repo

  alias SimpleFit.Sponsors.{
    Membership,
    Organization,
    PartnershipEvent,
    Partnerships,
    Proposal,
    ProposalChangeRequest,
    ProposalSubmission
  }

  # Proposed defaults (D-SA37), internal codes never shown to the organization.
  @change_reasons ~w(missing_information unclear_request out_of_scope_detail other)
  @accept_reasons ~w(follow_up_planned)
  @decline_reasons ~w(not_a_fit_now outside_supported_categories insufficient_information
                      duplicate_request other)

  @doc "Reason codes of each review action."
  @spec reasons(:claim | :request_changes | :accept | :decline) :: [String.t()]
  def reasons(:claim), do: ~w(review_started)
  def reasons(:request_changes), do: @change_reasons
  def reasons(:accept), do: @accept_reasons
  def reasons(:decline), do: @decline_reasons

  @queue_statuses ~w(submitted under_review changes_requested accepted declined withdrawn)a

  @doc "The statuses a review queue can filter on (never `draft`)."
  @spec queue_statuses() :: [atom()]
  def queue_statuses, do: @queue_statuses

  @doc "A proposal that has been submitted at least once, or `nil`."
  @spec fetch(Ecto.UUID.t()) :: Proposal.t() | nil
  def fetch(id),
    do: Repo.one(from(p in Proposal, where: p.id == ^id and not is_nil(p.submitted_at)))

  @doc false
  @spec lock!(Ecto.UUID.t()) :: Proposal.t() | nil
  def lock!(id),
    do:
      Repo.one(
        from(p in Proposal, where: p.id == ^id and not is_nil(p.submitted_at), lock: "FOR UPDATE")
      )

  @doc """
  Whether `user_id` holds a non-revoked membership (any role) of the proposal's
  organization: a party, who can't review it (conflict of interest, SF-107).
  """
  @spec party?(Proposal.t(), Ecto.UUID.t()) :: boolean()
  def party?(%Proposal{organization_id: org_id, created_by_user_id: creator}, user_id),
    do:
      creator == user_id or
        Repo.exists?(
          from(m in Membership,
            where: m.organization_id == ^org_id and m.user_id == ^user_id and m.status != :revoked
          )
        )

  @doc "The organization of a proposal (id, name, status)."
  @spec organization(Proposal.t()) :: Organization.t()
  def organization(%Proposal{organization_id: id}), do: Repo.get!(Organization, id)

  @doc "The operator's view: the proposal, its organization and every submission."
  @spec view(Proposal.t()) :: map()
  def view(%Proposal{} = proposal) do
    %{
      proposal: proposal,
      organization: organization(proposal),
      latest_submission: latest_submission(proposal.id),
      submissions:
        Repo.all(
          from(s in ProposalSubmission,
            where: s.proposal_id == ^proposal.id,
            order_by: s.sequence,
            select: %{id: s.id, sequence: s.sequence, submitted_at: s.submitted_at}
          )
        ),
      change_request: Partnerships.open_change_request(proposal.id),
      history:
        Repo.all(
          from(e in PartnershipEvent,
            where:
              e.proposal_id == ^proposal.id and e.outcome == :allowed and not is_nil(e.to_status),
            order_by: [asc: e.occurred_at, asc: e.id]
          )
        )
    }
  end

  @doc "The latest submission of a proposal (what a reviewer decides on)."
  @spec latest_submission(Ecto.UUID.t()) :: ProposalSubmission.t() | nil
  def latest_submission(proposal_id),
    do:
      Repo.one(
        from(s in ProposalSubmission,
          where: s.proposal_id == ^proposal_id,
          order_by: [desc: s.sequence],
          limit: 1
        ),
        log: false
      )

  @doc """
  One page of the review queue, oldest submission first (ties by id), after
  `position` (`{submitted_at, id}`). `filters`: `:status` (one of
  `queue_statuses/0`). Each row has the proposal, its organization's name and status,
  the number of submissions and whether a change request is open. Returns
  `{rows, next_position | nil}`.
  """
  @spec queue(map(), pos_integer(), {DateTime.t(), Ecto.UUID.t()} | nil) ::
          {[map()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def queue(filters, limit, position) do
    query =
      from(p in Proposal,
        join: o in Organization,
        on: o.id == p.organization_id,
        where: not is_nil(p.submitted_at),
        order_by: [asc: p.submitted_at, asc: p.id],
        limit: ^(limit + 1),
        select: %{proposal: p, organization: o}
      )
      |> queue_status(filters)
      |> after_position(position)

    {page, more} = Enum.split(Repo.all(query, log: false), limit)

    next =
      case {page, more} do
        {_, []} -> nil
        {page, _} -> {List.last(page).proposal.submitted_at, List.last(page).proposal.id}
      end

    {with_counts(page), next}
  end

  defp queue_status(query, %{status: status}),
    do: from([p, _o] in query, where: p.status == ^status)

  defp queue_status(query, _filters), do: query

  defp after_position(query, nil), do: query

  defp after_position(query, {at, id}),
    do:
      from([p, _o] in query,
        where: p.submitted_at > ^at or (p.submitted_at == ^at and p.id > ^id)
      )

  # Each row's number of submissions and whether a change request is open.
  defp with_counts(page) do
    ids = Enum.map(page, & &1.proposal.id)

    sequences =
      Repo.all(
        from(s in ProposalSubmission,
          where: s.proposal_id in ^ids,
          group_by: s.proposal_id,
          select: {s.proposal_id, max(s.sequence)}
        )
      )
      |> Map.new()

    open =
      Repo.all(
        from(c in ProposalChangeRequest,
          where: c.proposal_id in ^ids and is_nil(c.resolved_at),
          select: c.proposal_id
        )
      )
      |> MapSet.new()

    Enum.map(page, fn row ->
      Map.merge(row, %{
        submissions: Map.get(sequences, row.proposal.id, 0),
        change_request_open: MapSet.member?(open, row.proposal.id)
      })
    end)
  end

  @doc false
  @spec claim!(Proposal.t(), struct(), map()) :: Proposal.t()
  def claim!(proposal, operator, attrs) do
    updated = Repo.update!(change(proposal, status: :under_review))
    event!(updated, "partnership_proposal.claimed", operator, proposal.status, attrs)
    updated
  end

  @doc false
  @spec request_changes!(Proposal.t(), struct(), map(), DateTime.t()) :: Proposal.t()
  def request_changes!(proposal, operator, attrs, now) do
    _request =
      Repo.insert!(
        %ProposalChangeRequest{
          proposal_id: proposal.id,
          requested_by_operator_id: operator.id,
          reason_code: attrs.reason_code,
          fields: attrs.fields,
          message: attrs.message,
          proposal_revision: proposal.revision,
          requested_at: now
        },
        log: false
      )

    updated = Repo.update!(change(proposal, status: :changes_requested))
    event!(updated, "partnership_proposal.changes_requested", operator, proposal.status, attrs)
    updated
  end

  @doc false
  # Accept or decline: final, and nothing else is created.
  @spec decide!(Proposal.t(), struct(), map(), DateTime.t(), :accepted | :declined) ::
          Proposal.t()
  def decide!(proposal, operator, attrs, now, to) do
    updated = Repo.update!(change(proposal, status: to, decided_at: now))
    event!(updated, "partnership_proposal.#{to}", operator, proposal.status, attrs)
    updated
  end

  @doc false
  # The change request's own input.
  @spec validate_change_request(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defdelegate validate_change_request(changeset),
    to: SimpleFit.Sponsors.PartnershipPolicy

  defp event!(proposal, event, operator, from, attrs) do
    Repo.insert!(%PartnershipEvent{
      organization_id: proposal.organization_id,
      proposal_id: proposal.id,
      occurred_at: DateTime.utc_now(),
      event: event,
      outcome: :allowed,
      actor_user_id: operator.user_id,
      actor_kind: :operator,
      from_status: Atom.to_string(from),
      to_status: Atom.to_string(proposal.status),
      revision: proposal.revision,
      reason_code: attrs.reason_code
    })
  end
end
