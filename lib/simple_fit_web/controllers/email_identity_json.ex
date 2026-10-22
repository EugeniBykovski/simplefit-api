defmodule SimpleFitWeb.EmailIdentityJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.EmailIdentityController`
  (`EmailIdentityList`, `EmailIdentityLinkAccepted`, `EmailIdentityLinkResult`).
  """

  alias SimpleFit.Accounts.Identity

  def index(%{identities: identities}),
    do: %{email_identities: Enum.map(identities, &identity(&1.email, &1.linked_at))}

  def accepted(%{result: result}),
    do: %{
      expires_in_seconds: result.expires_in_seconds,
      resend_after_seconds: result.resend_after_seconds
    }

  def linked(%{result: %{identity: %Identity{} = identity, outcome: outcome}}),
    do: %{
      outcome: Atom.to_string(outcome),
      email_identity: identity(identity.provider_subject, identity.inserted_at)
    }

  defp identity(email, linked_at),
    do: %{email: email, linked_at: DateTime.to_iso8601(linked_at)}
end
