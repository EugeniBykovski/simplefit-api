defmodule SimpleFit.Coaching.Disclosure do
  @moduledoc """
  The versioned contract of what a fighter discloses to a coach by accepting
  a relationship (ADR 0021; SF-49 §6.4.2).

  A disclosure version is the identifier of an approved, versioned legal
  text, configured per environment; it is never invented here and never
  taken from a client. Each configured version names a field *scope* defined
  in code:

    * `basic_profile` - C1 identity (`display_name`, `username`,
      `country_code`, `city`) and C2 basic boxing information
      (`experience_level`, `stance`, `amateur_bout_count`).

  With no version configured (the default), no relationship can be
  activated. A relationship keeps the version its fighter accepted; what a
  coach sees is that version's fields, intersected with what
  `SimpleFit.Fighters.coach_visible_fields/0` allows today. A version that is
  no longer configured discloses nothing, so withdrawing a version narrows
  access at once and a later version never widens an existing relationship.
  """

  @scopes %{
    basic_profile: [
      :display_name,
      :username,
      :country_code,
      :city,
      :experience_level,
      :stance,
      :amateur_bout_count
    ]
  }

  @doc "The configured disclosure versions and their scopes."
  @spec configured() :: %{String.t() => atom()}
  def configured,
    do: Application.get_env(:simple_fit, SimpleFit.Coaching, [])[:disclosures] || %{}

  @doc "Whether `version` is a configured disclosure version a fighter may accept now."
  @spec offered?(term()) :: boolean()
  def offered?(version) when is_binary(version), do: Map.has_key?(configured(), version)
  def offered?(_version), do: false

  @doc """
  The fighter profile fields disclosed under `version`: its scope's fields,
  in contract order, limited to the fields coaches may ever see. Empty for a
  version that is not configured.
  """
  @spec fields(String.t()) :: [atom()]
  def fields(version) when is_binary(version) do
    case configured() do
      %{^version => scope} -> Map.get(@scopes, scope, [])
      _ -> []
    end
    |> Enum.filter(&(&1 in SimpleFit.Fighters.coach_visible_fields()))
  end

  @doc """
  Parses `COACHING_DISCLOSURES` (config/runtime.exs): comma-separated
  `version=scope` pairs, e.g. `fighter-disclosure-2026-11=basic_profile`.
  Raises on an unknown scope or a malformed or duplicate entry, so a wrong
  configuration fails at boot instead of disclosing anything.
  """
  @spec parse!(String.t() | nil) :: %{String.t() => atom()}
  def parse!(nil), do: %{}

  def parse!(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, acc ->
      with [version, scope] <- String.split(entry, "=", parts: 2),
           version = String.trim(version),
           true <- version =~ ~r/^[A-Za-z0-9._-]{1,64}$/,
           false <- Map.has_key?(acc, version),
           {:ok, scope} <- scope(String.trim(scope)) do
        Map.put(acc, version, scope)
      else
        _ -> raise ArgumentError, "invalid COACHING_DISCLOSURES entry"
      end
    end)
  end

  defp scope(name) do
    case Enum.find(Map.keys(@scopes), &(Atom.to_string(&1) == name)) do
      nil -> :error
      scope -> {:ok, scope}
    end
  end
end
