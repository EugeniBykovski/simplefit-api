defmodule SimpleFitWeb.CoachInvitationResponseJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.CoachInvitationResponseController`:
  the coach's public identity and the disclosure, nothing else.
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

  def accept(%{result: result}),
    do: %{relationship_id: result.relationship_id, outcome: Atom.to_string(result.outcome)}
end
