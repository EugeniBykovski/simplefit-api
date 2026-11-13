defmodule SimpleFit.Sponsors.PartnershipPolicy do
  @moduledoc """
  Partnership preferences and proposals: their answers, vocabularies and
  requiredness (SF-130, ADR 0034). One versioned policy in code, as
  `SimpleFit.Sponsors.ApplicationPolicy`, whose vocabularies it reuses: the same
  interests and market rules, so a sponsor describes itself the same way it did when
  it applied. Each submission records `version/0`.

  | Field | Preferences | Proposal (to submit) | Values |
  | --- | --- | --- | --- |
  | `title` | - | yes | 1-120 chars, trimmed |
  | `interests` | optional | at least one | `ApplicationPolicy.interests/0`, no repeats |
  | `market_scope` | optional | yes | `global`, `countries`, `cities` |
  | `market_countries` | unless `global` | unless `global` | ISO codes, up to 50 |
  | `market_cities` | with `cities` | with `cities` | names, 1-80 chars, up to 20 |
  | `goals` | optional | - | 1-2,000 chars of plain text |
  | `summary` | - | yes | 1-4,000 chars of plain text |

  **Not collected, by decision:** a budget, amount or price (D-SA39), an opportunity
  (none exists, D-SA21), and any athlete, gym, coach or person. A proposal is a
  nonbinding inquiry (D-SA37): nothing about it is a commitment by either side.
  """

  import Ecto.Changeset

  alias SimpleFit.Fighters.CountryCodes
  alias SimpleFit.Sponsors.{ApplicationPolicy, PartnershipPreferences, Proposal}

  @version "sponsor-partnership-2026-11.v1"
  @snapshot_schema "sponsor-partnership-proposal-snapshot.v1"
  @markets [:market_scope, :market_countries, :market_cities]
  @preference_fields [:interests | @markets] ++ [:goals]
  @proposal_fields [:title, :interests | @markets] ++ [:summary]
  @required [:title, :interests, :market_scope, :summary]
  @open_limit 25

  @doc "This policy's version, recorded with every submission."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The submission snapshot's schema tag."
  @spec snapshot_schema() :: String.t()
  def snapshot_schema, do: @snapshot_schema

  @doc "Preference fields."
  @spec preference_fields() :: [atom()]
  def preference_fields, do: @preference_fields

  @doc "Proposal answer fields, in form order."
  @spec proposal_fields() :: [atom()]
  def proposal_fields, do: @proposal_fields

  @doc "Proposal answers a submission needs (plus the market fields its scope needs)."
  @spec required() :: [atom()]
  def required, do: @required

  @doc "Open (undecided, not withdrawn) proposals an organization may have at once."
  @spec open_limit() :: pos_integer()
  def open_limit, do: @open_limit

  @doc "The policy, for forms."
  @spec describe() :: map()
  def describe do
    %{
      version: @version,
      interests: ApplicationPolicy.interests(),
      scopes: ApplicationPolicy.scopes(),
      preference_fields: @preference_fields,
      proposal_fields: @proposal_fields,
      required: @required,
      open_limit: @open_limit,
      statuses: Proposal.statuses()
    }
  end

  @doc "Validates preference answers in `attrs` (string keys) on top of `preferences`."
  @spec preferences_changeset(PartnershipPreferences.t(), map()) :: Ecto.Changeset.t()
  def preferences_changeset(%PartnershipPreferences{} = preferences, attrs) do
    preferences
    |> cast(attrs, @preference_fields, empty_values: [])
    |> update_change(:goals, &trim/1)
    |> validate_length(:goals, min: 1, max: 2000)
    |> markets()
  end

  @doc "Validates proposal answers in `attrs` (string keys) on top of `proposal`."
  @spec proposal_changeset(Proposal.t(), map()) :: Ecto.Changeset.t()
  def proposal_changeset(%Proposal{} = proposal, attrs) do
    proposal
    |> cast(attrs, @proposal_fields, empty_values: [])
    |> update_change(:title, &trim/1)
    |> update_change(:summary, &trim/1)
    |> validate_length(:title, min: 1, max: 120)
    |> validate_length(:summary, min: 1, max: 4000)
    |> markets()
  end

  @doc """
  What a proposal still needs to be submitted, in form order: required answers that
  are empty and the market answers its scope needs.
  """
  @spec missing(Proposal.t()) :: [atom()]
  def missing(%Proposal{} = p) do
    base = Enum.filter(@required, &blank?(Map.fetch!(p, &1)))

    markets =
      case p.market_scope do
        "countries" -> if p.market_countries == [], do: [:market_countries], else: []
        "cities" -> Enum.filter([:market_countries, :market_cities], &(Map.fetch!(p, &1) == []))
        _ -> []
      end

    Enum.filter(@proposal_fields, &(&1 in (base ++ markets)))
  end

  @doc "The submission snapshot: the answers by allowlist, with the schema tag."
  @spec snapshot(Proposal.t()) :: map()
  def snapshot(%Proposal{} = p) do
    %{
      "schema" => @snapshot_schema,
      "policy_version" => @version,
      "kind" => Atom.to_string(p.kind),
      "answers" => Map.new(@proposal_fields, &{Atom.to_string(&1), Map.fetch!(p, &1)}),
      "binding" => false
    }
  end

  @doc "The change request's own input: proposal answers to revisit and a message."
  @spec validate_change_request(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_change_request(changeset) do
    fields = Enum.map(@proposal_fields, &Atom.to_string/1)

    changeset
    |> update_change(:message, &String.trim/1)
    |> validate_length(:message, min: 1, max: 2000)
    |> validate_length(:fields, min: 1, max: length(fields))
    |> validate_subset(:fields, fields)
    |> unique_list(:fields)
  end

  defp markets(changeset) do
    changeset
    |> update_change(:market_countries, fn list -> Enum.map(list, &upcase/1) end)
    |> update_change(:market_cities, fn list -> Enum.map(list, &trim/1) end)
    |> validate_subset(:interests, ApplicationPolicy.interests())
    |> unique_list(:interests)
    |> validate_inclusion(:market_scope, ApplicationPolicy.scopes())
    |> validate_length(:market_countries, max: 50)
    |> validate_change(:market_countries, &countries/2)
    |> unique_list(:market_countries)
    |> validate_length(:market_cities, max: 20)
    |> validate_change(:market_cities, &cities/2)
    |> unique_list(:market_cities)
    |> global_scope()
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(value), do: value

  defp countries(field, codes) do
    if Enum.all?(codes, &(is_binary(&1) and CountryCodes.valid?(&1))),
      do: [],
      else: [{field, {"has invalid entries", validation: :subset}}]
  end

  defp cities(field, names) do
    if Enum.all?(names, &(is_binary(&1) and String.length(&1) in 1..80)),
      do: [],
      else: [{field, {"has invalid entries", validation: :length}}]
  end

  defp unique_list(changeset, field) do
    validate_change(changeset, field, fn ^field, list ->
      if list == Enum.uniq(list),
        do: [],
        else: [{field, {"has duplicates", validation: :unique}}]
    end)
  end

  # A global scope names no countries or cities.
  defp global_scope(changeset) do
    if get_field(changeset, :market_scope) == "global" and
         (get_field(changeset, :market_countries) != [] or
            get_field(changeset, :market_cities) != []) do
      add_error(changeset, :market_scope, "can't name countries or cities when global",
        validation: :scope
      )
    else
      changeset
    end
  end
end
