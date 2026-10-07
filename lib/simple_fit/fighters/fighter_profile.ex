defmodule SimpleFit.Fighters.FighterProfile do
  @moduledoc """
  A user's fighter profile and the state of its onboarding (ADR 0015).

  The fields are the ones the approved Fighter onboarding collects (Claude
  Design OF1-OF4, mobile vocabularies canonical): the public fighter identity
  (name, username, country, city) and the boxing profile (experience, stance,
  goals, next fight, weight class and optional body data). Everything is
  saved as the fighter goes; only completing onboarding requires the
  `required_fields/0`.

  A profile belongs to exactly one user and a user has at most one. It is
  never created with the user: a user without a profile has not started
  Fighter onboarding.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Accounts.User

  @experience_levels [
    :new_to_boxing,
    :recreational,
    :amateur,
    :competitive_amateur,
    :professional
  ]
  @stances [:orthodox, :southpaw, :switch]
  @goals [:fitness, :learn_boxing, :improve_technique, :competition, :fight_preparation]
  @weight_classes [
    :minus_63_5,
    :minus_67,
    :minus_71,
    :minus_75,
    :minus_80,
    :minus_86,
    :plus_86,
    :not_sure
  ]

  # OF1 (no skip; only the avatar is optional) and OF2 (no skip).
  @required_fields [:display_name, :username, :country_code, :city, :experience_level, :stance]

  @editable_fields [
    :display_name,
    :username,
    :country_code,
    :city,
    :experience_level,
    :bout_count,
    :stance,
    :goals,
    :next_fight_on,
    :next_fight_name,
    :weight_class,
    :current_weight_kg,
    :height_cm
  ]

  @type experience_level ::
          :new_to_boxing | :recreational | :amateur | :competitive_amateur | :professional
  @type stance :: :orthodox | :southpaw | :switch
  @type goal :: :fitness | :learn_boxing | :improve_technique | :competition | :fight_preparation
  @type weight_class ::
          :minus_63_5
          | :minus_67
          | :minus_71
          | :minus_75
          | :minus_80
          | :minus_86
          | :plus_86
          | :not_sure

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          display_name: String.t() | nil,
          username: String.t() | nil,
          country_code: String.t() | nil,
          city: String.t() | nil,
          experience_level: experience_level() | nil,
          bout_count: non_neg_integer() | nil,
          stance: stance() | nil,
          goals: [goal()],
          next_fight_on: Date.t() | nil,
          next_fight_name: String.t() | nil,
          weight_class: weight_class() | nil,
          current_weight_kg: Decimal.t() | nil,
          height_cm: pos_integer() | nil,
          onboarding_completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  # Personal data is redacted from inspect output (logs, crash reports).
  schema "fighter_profiles" do
    belongs_to :user, User

    field :display_name, :string, redact: true
    field :username, :string, redact: true
    field :country_code, :string, redact: true
    field :city, :string, redact: true
    field :experience_level, Ecto.Enum, values: @experience_levels
    field :bout_count, :integer
    field :stance, Ecto.Enum, values: @stances
    field :goals, {:array, Ecto.Enum}, values: @goals, default: []
    field :next_fight_on, :date
    field :next_fight_name, :string, redact: true
    field :weight_class, Ecto.Enum, values: @weight_classes, redact: true
    field :current_weight_kg, :decimal, redact: true
    field :height_cm, :integer, redact: true
    field :onboarding_completed_at, :utc_datetime

    timestamps()
  end

  @doc "Experience levels (OF2)."
  @spec experience_levels() :: [experience_level()]
  def experience_levels, do: @experience_levels

  @doc "Stances (OF2)."
  @spec stances() :: [stance()]
  def stances, do: @stances

  @doc "Training goals (OF3)."
  @spec goals() :: [goal()]
  def goals, do: @goals

  @doc "Approximate weight classes in kg (OF4), plus `:not_sure`."
  @spec weight_classes() :: [weight_class()]
  def weight_classes, do: @weight_classes

  @doc "Fields that must be set before onboarding can be completed, in step order."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @doc "Fields a fighter may change."
  @spec editable_fields() :: [atom()]
  def editable_fields, do: @editable_fields

  @doc """
  Saves any subset of the editable fields. Values are validated, but nothing
  is required while onboarding is in progress. Once it is completed, the
  required fields can be changed but not cleared, so a completed profile stays
  complete.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = profile, attrs) when is_map(attrs) do
    profile
    |> cast(attrs, @editable_fields, empty_values: [])
    |> update_change(:display_name, &trim/1)
    |> update_change(:username, &canonical_username/1)
    |> update_change(:country_code, &canonical_country_code/1)
    |> update_change(:city, &trim/1)
    # `null` clears the goals, like any other optional field.
    |> update_change(:goals, &(&1 || []))
    |> update_change(:next_fight_name, &trim/1)
    |> validate_text(:display_name, 80)
    |> validate_text(:city, 100)
    |> validate_text(:next_fight_name, 120)
    |> validate_format(:username, ~r/^[a-z][a-z0-9_]{2,29}$/)
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/)
    |> validate_number(:bout_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 500)
    |> validate_number(:current_weight_kg,
      greater_than_or_equal_to: 30,
      less_than_or_equal_to: 200
    )
    |> validate_number(:height_cm, greater_than_or_equal_to: 120, less_than_or_equal_to: 230)
    |> update_change(:current_weight_kg, &round_weight/1)
    |> validate_goals()
    |> validate_bout_count()
    |> validate_next_fight()
    |> validate_completed_requirements()
    |> unique_constraint(:username, name: :fighter_profiles_username_index)
    |> check_constraint(:username, name: :username_format, message: "has invalid format")
    |> check_constraint(:country_code, name: :country_code_format, message: "has invalid format")
  end

  @doc """
  Marks onboarding complete. Invalid while any required field is missing; a
  profile that is already complete keeps its original completion time.
  """
  @spec complete_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def complete_changeset(%__MODULE__{} = profile, %DateTime{} = now) do
    profile
    |> change()
    |> validate_required(@required_fields)
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
    do: Enum.filter(@required_fields, &(Map.fetch!(profile, &1) in [nil, ""]))

  @doc """
  The onboarding state: `:not_started` without a profile, `:completed` once
  completion has been recorded, `:in_progress` otherwise.
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

  defp canonical_username(value) when is_binary(value),
    do: value |> trim() |> then(&(&1 && String.downcase(&1)))

  defp canonical_username(value), do: value

  defp canonical_country_code(value) when is_binary(value),
    do: value |> trim() |> then(&(&1 && String.upcase(&1)))

  defp canonical_country_code(value), do: value

  defp round_weight(%Decimal{} = kg), do: Decimal.round(kg, 1)
  defp round_weight(value), do: value

  defp validate_text(changeset, field, max),
    do: validate_length(changeset, field, min: 1, max: max)

  defp validate_goals(changeset) do
    validate_change(changeset, :goals, fn :goals, goals ->
      if Enum.uniq(goals) == goals, do: [], else: [goals: {"must not repeat a goal", []}]
    end)
  end

  # OF2 records a bout count only for Competitive Amateur. Moving to another
  # level clears it; sending one with another level is invalid.
  defp validate_bout_count(changeset) do
    level = get_field(changeset, :experience_level)

    cond do
      level == :competitive_amateur ->
        changeset

      get_change(changeset, :bout_count) != nil ->
        add_error(changeset, :bout_count, "is only recorded for competitive amateurs",
          validation: :inclusion
        )

      true ->
        put_change(changeset, :bout_count, nil)
    end
  end

  # The next fight is a date with an optional event name.
  defp validate_next_fight(changeset) do
    if get_field(changeset, :next_fight_name) && is_nil(get_field(changeset, :next_fight_on)),
      do: add_error(changeset, :next_fight_on, "can't be blank", validation: :required),
      else: changeset
  end

  defp validate_completed_requirements(%Ecto.Changeset{data: profile} = changeset) do
    if profile.onboarding_completed_at,
      do: validate_required(changeset, @required_fields),
      else: changeset
  end
end
