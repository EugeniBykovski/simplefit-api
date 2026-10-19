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
  activated. A configured version also has to be in the legal document
  registry (`SimpleFit.Legal.Registry`, ADR 0022) with the same scope: the
  current one `published`, an older one `published` or `superseded`. A
  version that is configured but not registered so, or `withdrawn`,
  discloses nothing and cannot be accepted (fail-closed). The first configured version is the *current* one: the version
  an invitation preview shows and an acceptance must echo (SF-57). A relationship keeps the version its fighter accepted; what a
  coach sees is that version's fields, intersected with what
  `SimpleFit.Fighters.coach_visible_fields/0` allows today. A version that is
  no longer configured discloses nothing, so withdrawing a version narrows
  access at once and a later version never widens an existing relationship.
  """

  alias SimpleFit.Legal.Registry

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

  @doc """
  The disclosure version a fighter is shown and may accept now (the first
  configured version, SF-57), or `nil` when none is configured. The other
  configured versions stay valid for relationships accepted under them.
  """
  @spec current() :: String.t() | nil
  def current do
    config = Application.get_env(:simple_fit, SimpleFit.Coaching, [])

    case config[:current_disclosure] do
      version when is_binary(version) -> if offered?(version), do: version
      _ -> nil
    end
  end

  # The registry agrees: the version is registered under `statuses` with the
  # configured scope.
  defp registered?(version, scope, statuses) do
    case Registry.get("fighter-coach-disclosure", version) do
      {:ok, %{status: status, scope: ^scope}} -> status in statuses
      _ -> false
    end
  end

  @doc "The fields `current/0` discloses (empty when there is none)."
  @spec current_fields() :: [atom()]
  def current_fields, do: if(version = current(), do: fields(version), else: [])

  @doc """
  The coach data-rules version a coach must acknowledge before inviting
  (identifier of an approved legal text), or `nil` when none is configured.
  """
  @spec data_rules_version() :: String.t() | nil
  def data_rules_version do
    with version when is_binary(version) <-
           Application.get_env(:simple_fit, SimpleFit.Coaching, [])[:data_rules_version],
         {:ok, %{status: "published"}} <- Registry.get("coach-data-rules", version) do
      version
    else
      _ -> nil
    end
  end

  @doc "Whether `version` is the configured disclosure version that is published now (acceptable)."
  @spec offered?(term()) :: boolean()
  def offered?(version) when is_binary(version) do
    case configured() do
      %{^version => scope} -> registered?(version, scope, ["published"])
      _ -> false
    end
  end

  def offered?(_version), do: false

  @doc """
  The fighter profile fields disclosed under `version`: its scope's fields,
  in contract order, limited to the fields coaches may ever see. Empty for a
  version that is not configured.
  """
  @spec fields(String.t()) :: [atom()]
  def fields(version) when is_binary(version) do
    case configured() do
      %{^version => scope} ->
        if registered?(version, scope, ["published", "superseded"]),
          do: Map.get(@scopes, scope, []),
          else: []

      _ ->
        []
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

  @doc """
  The current disclosure version from `COACHING_DISCLOSURES`: its first
  entry, or `nil` when unset. Validated by `parse!/1`.
  """
  @spec parse_current!(String.t() | nil) :: String.t() | nil
  def parse_current!(value) do
    _validated = parse!(value)

    case value && value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [first | _] when first != "" ->
        first |> String.split("=", parts: 2) |> hd() |> String.trim()

      _ ->
        nil
    end
  end

  @doc """
  Parses a single legal version identifier (`COACHING_DATA_RULES_VERSION`):
  `nil` when unset; raises on a malformed value.
  """
  @spec parse_version!(String.t() | nil) :: String.t() | nil
  def parse_version!(nil), do: nil

  def parse_version!(value) when is_binary(value) do
    version = String.trim(value)

    if version =~ ~r/^[A-Za-z0-9._-]{1,64}$/,
      do: version,
      else: raise(ArgumentError, "invalid COACHING_DATA_RULES_VERSION")
  end

  @doc "The scope named `name` (as configured or registered), or `:error`."
  @spec scope(term()) :: {:ok, atom()} | :error
  def scope(name) when is_binary(name) do
    case Enum.find(Map.keys(@scopes), &(Atom.to_string(&1) == name)) do
      nil -> :error
      scope -> {:ok, scope}
    end
  end

  def scope(_name), do: :error
end
