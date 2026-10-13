defmodule SimpleFit.Coaches.CoachProfile do
  @moduledoc """
  A user's coach profile and the state of its onboarding (ADR 0020; SF-49
  §4.2 field and enum contract).

  The fields are the ones both Coach registrations collect once reconciled
  (Claude Design OC1/OC2 and WCR1/WCR2): the public coach identity (coach
  name, optional brand, country, city, bio, coaching languages) and how the
  coach works (`coaching_formats`, optional `competition_levels`). Formats,
  competition levels, audiences and training types are different concepts and
  never share a vocabulary.

  A profile belongs to exactly one user and a user has at most one. It is
  never created with the user, and it is independent of the account profile
  (`display_name` is never derived from `AccountProfile.full_name`), of the
  fighter profile and of any gym.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Accounts.User
  alias SimpleFit.Fighters.CountryCodes

  @languages [:en, :pl, :ru, :be, :uk]
  @coaching_formats [:personal_training, :group_coaching, :online_coaching, :fight_camps]
  @competition_levels [:amateur, :professional]

  # Required to complete onboarding, in step order (OC1/WCR1, then OC2/WCR2).
  @required_fields [:display_name, :country_code, :city, :coaching_formats]
  @editable_fields [
    :display_name,
    :brand_name,
    :country_code,
    :city,
    :bio,
    :languages,
    :coaching_formats,
    :competition_levels
  ]
  @selection_fields [:languages, :coaching_formats, :competition_levels]

  # Characters are counted as code points, as PostgreSQL's char_length does.
  @lengths [display_name: {1, 60}, brand_name: {1, 80}, city: {1, 80}, bio: {1, 500}]

  # C0/C1 control characters; the bio may also contain line breaks (LF, CR).
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @control_except_newlines ~r/[\x{0000}-\x{0009}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}]/u

  @type language :: :en | :pl | :ru | :be | :uk
  @type coaching_format :: :personal_training | :group_coaching | :online_coaching | :fight_camps
  @type competition_level :: :amateur | :professional

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          display_name: String.t() | nil,
          brand_name: String.t() | nil,
          country_code: String.t() | nil,
          city: String.t() | nil,
          bio: String.t() | nil,
          languages: [language()],
          coaching_formats: [coaching_format()],
          competition_levels: [competition_level()],
          onboarding_completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  # Personal data is redacted from inspect output (logs, crash reports).
  schema "coach_profiles" do
    belongs_to :user, User

    field :display_name, :string, redact: true
    field :brand_name, :string, redact: true
    field :country_code, :string, redact: true
    field :city, :string, redact: true
    field :bio, :string, redact: true
    field :languages, {:array, Ecto.Enum}, values: @languages, default: []
    field :coaching_formats, {:array, Ecto.Enum}, values: @coaching_formats, default: []
    field :competition_levels, {:array, Ecto.Enum}, values: @competition_levels, default: []
    field :onboarding_completed_at, :utc_datetime

    timestamps()
  end

  @doc "Coaching languages a coach can offer (spoken languages, not UI locales)."
  @spec languages() :: [language()]
  def languages, do: @languages

  @doc "How the coach works (OC2/WCR2)."
  @spec coaching_formats() :: [coaching_format()]
  def coaching_formats, do: @coaching_formats

  @doc "Competitive levels of the fighters the coach prepares (OC2/WCR2)."
  @spec competition_levels() :: [competition_level()]
  def competition_levels, do: @competition_levels

  @doc "Fields that must be set before onboarding can be completed, in step order."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @doc "Fields a coach may change."
  @spec editable_fields() :: [atom()]
  def editable_fields, do: @editable_fields

  @doc """
  Saves any subset of the editable fields. Values are validated, but nothing
  is required while onboarding is in progress. Once it is completed, the
  required fields can be changed but not cleared, so a completed profile stays
  complete.

  Text is trimmed; an empty or blank text, like `null`, clears an optional
  field. `null` or `[]` clears a selection. Selections keep the order given
  and reject repeated values.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = profile, attrs) when is_map(attrs) do
    profile
    |> cast(attrs, @editable_fields, empty_values: [])
    |> update_change(:display_name, &trim/1)
    |> update_change(:brand_name, &trim/1)
    |> update_change(:country_code, &canonical_country_code/1)
    |> update_change(:city, &trim/1)
    |> update_change(:bio, &trim/1)
    |> clear_null_selections()
    |> validate_lengths()
    |> validate_printable(:display_name, @control)
    |> validate_printable(:brand_name, @control)
    |> validate_printable(:city, @control)
    |> validate_printable(:bio, @control_except_newlines)
    |> validate_country_code()
    |> validate_unique_selections()
    |> validate_completed_requirements()
    |> check_constraint(:country_code, name: :country_code_format, message: "has invalid format")
    |> check_constraint(:onboarding_completed_at,
      name: :completed_onboarding_requirements,
      message: "requires every required field"
    )
    |> check_constraint(:onboarding_completed_at,
      name: :onboarding_completed_at_immutable,
      message: "can't be changed once onboarding is completed"
    )
  end

  @doc """
  Marks onboarding complete. Invalid while any required field is missing; a
  profile that is already complete keeps its original completion time.
  """
  @spec complete_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def complete_changeset(%__MODULE__{} = profile, %DateTime{} = now) do
    profile
    |> change()
    |> validate_requirements()
    |> then(fn changeset ->
      if profile.onboarding_completed_at,
        do: changeset,
        else: put_change(changeset, :onboarding_completed_at, DateTime.truncate(now, :second))
    end)
    |> check_constraint(:onboarding_completed_at,
      name: :completed_onboarding_requirements,
      message: "requires every required field"
    )
  end

  @doc "Required fields that are still empty, in step order."
  @spec missing_requirements(t() | nil) :: [atom()]
  def missing_requirements(nil), do: @required_fields

  def missing_requirements(%__MODULE__{} = profile),
    do: Enum.filter(@required_fields, &(Map.fetch!(profile, &1) in [nil, "", []]))

  @doc """
  The onboarding state: `:not_started` without a profile, `:completed` once
  completion has been recorded, `:in_progress` otherwise. Having every
  required field is not completion: only `complete_changeset/2` records it.
  """
  @spec onboarding_status(t() | nil) :: :not_started | :in_progress | :completed
  def onboarding_status(nil), do: :not_started
  def onboarding_status(%__MODULE__{onboarding_completed_at: %DateTime{}}), do: :completed
  def onboarding_status(%__MODULE__{}), do: :in_progress

  ## Validation helpers

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value

  defp canonical_country_code(value) when is_binary(value),
    do: value |> trim() |> then(&(&1 && String.upcase(&1)))

  defp canonical_country_code(value), do: value

  # `null` clears a selection, like any other optional field.
  defp clear_null_selections(changeset) do
    Enum.reduce(@selection_fields, changeset, fn field, acc ->
      if Map.has_key?(acc.changes, field) and is_nil(acc.changes[field]),
        do: put_change(acc, field, []),
        else: acc
    end)
  end

  defp validate_lengths(changeset) do
    Enum.reduce(@lengths, changeset, fn {field, {min, max}}, acc ->
      validate_length(acc, field, min: min, max: max, count: :codepoints)
    end)
  end

  defp validate_printable(changeset, field, control) do
    validate_change(changeset, field, fn ^field, value ->
      if Regex.match?(control, value),
        do: [{field, {"must not contain control characters", [validation: :format]}}],
        else: []
    end)
  end

  defp validate_unique_selections(changeset),
    do: Enum.reduce(@selection_fields, changeset, &validate_unique/2)

  defp validate_unique(field, changeset) do
    validate_change(changeset, field, fn ^field, values ->
      if Enum.uniq(values) == values, do: [], else: [{field, {"must not repeat a value", []}}]
    end)
  end

  # A selected ISO 3166-1 alpha-2 country, shared with the fighter profile
  # (SF-25): not any two letters.
  defp validate_country_code(changeset) do
    changeset
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/)
    |> validate_change(:country_code, fn :country_code, code ->
      if CountryCodes.valid?(code) or not Regex.match?(~r/^[A-Z]{2}$/, code),
        do: [],
        else: [country_code: {"is not an ISO 3166-1 alpha-2 country", [validation: :inclusion]}]
    end)
  end

  defp validate_completed_requirements(%Ecto.Changeset{data: profile} = changeset) do
    if profile.onboarding_completed_at, do: validate_requirements(changeset), else: changeset
  end

  # `validate_required/2` does not treat an empty list as missing; at least one
  # coaching format is a requirement.
  defp validate_requirements(changeset) do
    changeset
    |> validate_required(@required_fields -- [:coaching_formats])
    |> then(fn changeset ->
      if get_field(changeset, :coaching_formats) in [nil, []],
        do: add_error(changeset, :coaching_formats, "can't be blank", validation: :required),
        else: changeset
    end)
  end
end
