defmodule SimpleFit.Sponsors.ApplicationPolicy do
  @moduledoc """
  The sponsor application's answers, vocabularies and requiredness (SF-113, ADR
  0031): one versioned policy in code, not a rule engine. The backend alone decides
  what is valid and what a submission needs; each submission records `version/0`,
  so it stays interpretable after the policy changes (a new version, never an edit
  of this one).

  Source: the SF-108 design (SPA1 / SP1-SP7, canvas version 1794214317-c2e0) and
  the SF-107 lifecycle. **Proposed, not approved** (D-SA02, D-SA05, D-SA09):

  | Step | Field | Required to submit | Values |
  | --- | --- | --- | --- |
  | company | `company_name` | yes | 1-200 chars, trimmed |
  | company | `website` | no | `https://`, up to 200 chars |
  | company | `country_code` | yes | ISO 3166-1 alpha-2 |
  | company | `industry` | yes | `industries/0` |
  | contact | `contact_full_name`, `contact_position` | yes | 1-120 chars |
  | contact | `contact_email` | yes | an address, normalized to lower case; **never verified, grants nothing** |
  | contact | `contact_phone` | no | E.164 (`+48123456789`) |
  | interests | `interests` | at least one | `interests/0`, no repeats |
  | markets | `market_scope` | yes | `global`, `countries`, `cities` |
  | markets | `market_countries` | unless `global` | ISO codes, up to 50; none with `global` |
  | markets | `market_cities` | with `cities` | names, 1-80 chars, up to 20; none with `global` |
  | budget | `budget_band` | yes | `budget_bands/0`: an annual estimate in EUR excluding VAT, never an amount, price, commitment or verified figure |
  | goals | `goals` | yes | 1-2,000 chars of plain text |

  Not collected: the SP1 logo and SP7 files (uploads unavailable until a file
  scanner is approved, D-SA09; optional, so they don't block submission), VAT ID,
  company size and "partner before" (AS2 only, D-SA09). A submission also needs
  the applicant's acceptance of the published `sponsor-application-declaration`
  (legal registry); while none is published, submission is unavailable.
  """

  import Ecto.Changeset

  alias SimpleFit.Fighters.CountryCodes
  alias SimpleFit.Sponsors.{Application, Evidence}

  @version "sponsor-application-2026-11.v1"
  @declaration_document "sponsor-application-declaration"

  @industries ~w(boxing_equipment sports_apparel nutrition recovery fitness_technology events other)
  @interests ~w(sponsored_challenges sponsored_events equipment_partnerships gym_partnerships
                coach_partnerships marketplace community_campaigns content other)
  @scopes ~w(global countries cities)

  # SP5, in whole euros per year excluding VAT. Bounds are integers: no floats, and
  # a band is never turned into a single amount.
  @budget_bands [
    %{code: "eur_under_5000", min: nil, max: 5_000},
    %{code: "eur_5000_20000", min: 5_000, max: 20_000},
    %{code: "eur_20000_50000", min: 20_000, max: 50_000},
    %{code: "eur_50000_100000", min: 50_000, max: 100_000},
    %{code: "eur_100000_plus", min: 100_000, max: nil},
    %{code: "to_be_discussed", min: nil, max: nil}
  ]

  @steps [
    company: [:company_name, :website, :country_code, :industry],
    contact: [:contact_full_name, :contact_position, :contact_email, :contact_phone],
    interests: [:interests],
    markets: [:market_scope, :market_countries, :market_cities],
    budget: [:budget_band],
    goals: [:goals]
  ]

  @required [
    :company_name,
    :country_code,
    :industry,
    :contact_full_name,
    :contact_position,
    :contact_email,
    :interests,
    :market_scope,
    :budget_band,
    :goals
  ]

  @answers Enum.flat_map(@steps, fn {_step, fields} -> fields end)

  @doc "This policy's version, recorded with every submission."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The legal registry document a submission's declaration must be."
  @spec declaration_document() :: String.t()
  def declaration_document, do: @declaration_document

  @doc "Every answer field, in step order."
  @spec answers() :: [atom()]
  def answers, do: @answers

  @doc "The steps and their fields, in order."
  @spec steps() :: keyword([atom()])
  def steps, do: @steps

  @doc "Fields every submission needs (plus the market fields its scope needs)."
  @spec required() :: [atom()]
  def required, do: @required

  @spec industries() :: [String.t()]
  def industries, do: @industries

  @spec interests() :: [String.t()]
  def interests, do: @interests

  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @spec budget_bands() :: [map()]
  def budget_bands, do: @budget_bands

  @doc """
  Uploads (SP1 logo, SP7 files; SF-114): the evidence policy and whether uploads
  exist in this environment. Off in production until a file scanner or an
  accepted risk is approved (D-SA09). Documents are optional and never scanned.
  """
  @spec uploads() :: map()
  def uploads do
    policy = Evidence.policy()
    Map.put(policy, :reason, if(policy.available, do: nil, else: "file_scanning_unavailable"))
  end

  @doc """
  Validates the answers in `attrs` (string keys) on top of `application`. Only the
  supplied fields change; each is validated now, and the market fields together.
  Nothing a later step needs is required yet. `nil` clears an answer.
  """
  @spec changeset(Application.t(), map()) :: Ecto.Changeset.t()
  def changeset(%Application{} = application, attrs) do
    application
    |> cast(attrs, @answers, empty_values: [])
    |> update_change(:company_name, &trim/1)
    |> update_change(:website, &trim/1)
    |> update_change(:country_code, &upcase/1)
    |> update_change(:contact_full_name, &trim/1)
    |> update_change(:contact_position, &trim/1)
    |> update_change(:contact_email, &email/1)
    |> update_change(:contact_phone, &trim/1)
    |> update_change(:market_countries, fn list -> Enum.map(list, &upcase/1) end)
    |> update_change(:market_cities, fn list -> Enum.map(list, &trim/1) end)
    |> update_change(:goals, &trim/1)
    |> validate_length(:company_name, min: 1, max: 200)
    |> validate_format(:website, ~r/^https:\/\/\S+$/)
    |> validate_length(:website, max: 200)
    |> validate_country(:country_code)
    |> validate_inclusion(:industry, @industries)
    |> validate_length(:contact_full_name, min: 1, max: 120)
    |> validate_length(:contact_position, min: 1, max: 120)
    |> validate_length(:contact_email, max: 254)
    |> validate_format(:contact_email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
    |> validate_format(:contact_phone, ~r/^\+[1-9][0-9]{6,14}$/)
    |> validate_subset(:interests, @interests)
    |> validate_unique_list(:interests)
    |> validate_inclusion(:market_scope, @scopes)
    |> validate_length(:market_countries, max: 50)
    |> validate_change(:market_countries, &countries/2)
    |> validate_unique_list(:market_countries)
    |> validate_length(:market_cities, max: 20)
    |> validate_change(:market_cities, &cities/2)
    |> validate_unique_list(:market_cities)
    |> validate_inclusion(:budget_band, Enum.map(@budget_bands, & &1.code))
    |> validate_length(:goals, min: 1, max: 2000)
    |> validate_global_scope()
  end

  @doc """
  What a submission still needs, in step order: required answers that are empty,
  and the market answers the chosen scope needs.
  """
  @spec missing(Application.t()) :: [atom()]
  def missing(%Application{} = a) do
    base = Enum.filter(@required, &blank?(Map.fetch!(a, &1)))

    markets =
      case a.market_scope do
        "countries" -> if a.market_countries == [], do: [:market_countries], else: []
        "cities" -> Enum.filter([:market_countries, :market_cities], &(Map.fetch!(a, &1) == []))
        _ -> []
      end

    Enum.filter(@answers, &(&1 in (base ++ markets)))
  end

  @doc """
  The submission snapshot: the answers, by an allowlist, with the schema tag; the
  attached documents' metadata (never keys or names) and whether the contact email
  was verified at submission (SF-114).
  """
  @spec snapshot(Application.t(), map()) :: map()
  def snapshot(%Application{} = a, extras \\ %{}) do
    answers = Map.new(@answers, &{Atom.to_string(&1), Map.fetch!(a, &1)})

    %{
      "schema" => "sponsor-application-snapshot.v1",
      "policy_version" => @version,
      "answers" => answers,
      "budget_basis" => "annual_estimate_eur_excluding_vat",
      "contact_email_verified" => Map.get(extras, :contact_email_verified, false),
      "uploads" => Map.get(extras, :uploads, [])
    }
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(value), do: value

  defp email(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp email(value), do: value

  defp validate_country(changeset, field) do
    validate_change(changeset, field, fn ^field, code ->
      if CountryCodes.valid?(code),
        do: [],
        else: [{field, {"is invalid", validation: :inclusion}}]
    end)
  end

  defp countries(field, codes) do
    if Enum.all?(codes, &CountryCodes.valid?/1),
      do: [],
      else: [{field, {"has invalid entries", validation: :subset}}]
  end

  defp cities(field, names) do
    if Enum.all?(names, &(is_binary(&1) and String.length(&1) in 1..80)),
      do: [],
      else: [{field, {"has invalid entries", validation: :length}}]
  end

  defp validate_unique_list(changeset, field) do
    validate_change(changeset, field, fn ^field, list ->
      if list == Enum.uniq(list),
        do: [],
        else: [{field, {"has duplicates", validation: :unique}}]
    end)
  end

  # A global scope names no countries or cities.
  defp validate_global_scope(changeset) do
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
