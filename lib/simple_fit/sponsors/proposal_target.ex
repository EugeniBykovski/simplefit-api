defmodule SimpleFit.Sponsors.ProposalTarget do
  @moduledoc """
  Partnership proposals as admin action targets (SF-130, the SF-111 framework).
  Drafts don't exist for operators. An operator who created the proposal, or holds a
  non-revoked membership of its organization in any role, is a party and can't act on
  it (conflict of interest, SF-107). Checked from domain relationships, never from
  an email.
  """

  @behaviour SimpleFit.Operators.ActionTarget

  alias SimpleFit.Sponsors.{Proposal, ProposalReview}

  @impl true
  def fetch(id), do: ProposalReview.fetch(id)

  @impl true
  def lock!(id), do: ProposalReview.lock!(id)

  @impl true
  def party?(%Proposal{} = proposal, %{user_id: user_id}),
    do: ProposalReview.party?(proposal, user_id)

  @impl true
  def status(%Proposal{status: status}), do: Atom.to_string(status)

  @impl true
  def project(%Proposal{} = proposal), do: ProposalReview.view(proposal)
end
