defmodule SimpleFitWeb.EntryJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.EntryController` (`EntryResponse`)."

  alias SimpleFit.Entry

  @spec show(%{entry: Entry.t()}) :: %{entry: map()}
  def show(%{entry: entry}) do
    %{
      entry: %{
        destination: entry.destination,
        reason: entry.reason,
        mandatory: entry.mandatory,
        intent: entry.intent,
        account_registration: entry.account_registration,
        fighter_profile: entry.fighter_profile,
        capabilities: Enum.map(entry.capabilities, &capability/1)
      }
    }
  end

  # The client route registry's capability vocabulary.
  defp capability(:fighter), do: "FIGHTER"
end
