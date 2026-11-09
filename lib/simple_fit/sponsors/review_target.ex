defmodule SimpleFit.Sponsors.ReviewTarget do
  @moduledoc """
  Sponsor applications as admin action targets (SF-114, the SF-111 framework).
  Drafts don't exist for operators. An operator is a party to their own
  application, and (SF-116) to an application whose organization they belong to in
  any role while that membership isn't revoked; a party can't act on it (conflict of
  interest, SF-107). Checked from domain relationships, never from an email.
  """

  @behaviour SimpleFit.Operators.ActionTarget

  alias SimpleFit.Sponsors.{Application, Review}

  @impl true
  def fetch(id), do: Review.fetch(id)

  @impl true
  def lock!(id), do: Review.lock!(id)

  @impl true
  def party?(%Application{applicant_user_id: user_id}, %{user_id: user_id}), do: true

  def party?(%Application{id: id}, %{user_id: user_id}),
    do: Review.member_of_organization?(id, user_id)

  @impl true
  def status(%Application{status: status}), do: Atom.to_string(status)

  @impl true
  def project(%Application{} = application), do: Review.view(application)
end
