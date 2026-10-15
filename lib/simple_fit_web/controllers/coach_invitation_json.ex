defmodule SimpleFitWeb.CoachInvitationJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.CoachInvitationController`. Fields are
  picked explicitly: never a token, digest, sealed address or account data.
  """

  alias SimpleFit.Coaching
  alias SimpleFit.Coaching.Invitation

  def data_rules(%{rules: rules}) do
    %{
      data_rules: %{
        document_version: rules.document_version,
        acknowledged_at: rules.acknowledged_at && DateTime.to_iso8601(rules.acknowledged_at)
      }
    }
  end

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &view/1), next_cursor: cursor}

  def show(%{invitation: %Invitation{} = invitation}) do
    %{invitation: invitation |> Coaching.invitation_view() |> view()}
  end

  defp view(entry) do
    %{
      invitation_id: entry.invitation_id,
      status: Atom.to_string(entry.status),
      recipient_email: entry.recipient_email,
      message: entry.message,
      created_at: DateTime.to_iso8601(entry.created_at),
      expires_at: DateTime.to_iso8601(entry.expires_at),
      last_sent_at: DateTime.to_iso8601(entry.last_sent_at),
      resends_remaining: entry.resends_remaining,
      responded_at: entry.responded_at && DateTime.to_iso8601(entry.responded_at)
    }
  end
end
