defmodule SimpleFitWeb.CoachInvitationResponseJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.CoachInvitationResponseController`:
  the coach's public identity, the coach's note, dates, status and the
  disclosure, nothing else (never a token, digest or address).
  """

  def preview(%{preview: preview}) do
    coach = preview.coach || %{display_name: nil, brand_name: nil}

    %{
      invitation: %{
        coach: %{display_name: coach.display_name, brand_name: coach.brand_name},
        message: preview.message,
        expires_at: DateTime.to_iso8601(preview.expires_at)
      },
      disclosure: %{
        version: preview.disclosure.version,
        fields: Enum.map(preview.disclosure.fields, &Atom.to_string/1),
        never_shared: Enum.map(preview.disclosure.never_shared, &Atom.to_string/1)
      }
    }
  end

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &incoming/1), next_cursor: cursor}

  def accept(%{result: result}),
    do: %{relationship_id: result.relationship_id, outcome: Atom.to_string(result.outcome)}

  defp incoming(entry) do
    %{
      invitation_id: entry.invitation_id,
      status: Atom.to_string(entry.status),
      coach: %{display_name: entry.coach.display_name, brand_name: entry.coach.brand_name},
      message: entry.message,
      created_at: DateTime.to_iso8601(entry.created_at),
      expires_at: DateTime.to_iso8601(entry.expires_at),
      responded_at: entry.responded_at && DateTime.to_iso8601(entry.responded_at)
    }
  end
end
