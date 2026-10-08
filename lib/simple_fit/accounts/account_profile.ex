defmodule SimpleFit.Accounts.AccountProfile do
  @moduledoc """
  Shared account registration basics of a user (ADR 0016): the person's full
  name and date of birth, and when registration was completed.

  It belongs to the person, whatever roles they hold: fighter, coach, gym and
  sponsor journeys all start from the same completed registration. It holds
  no role, no username and no public display name (those belong to role
  profiles such as `SimpleFit.Fighters.FighterProfile`).

  Consents are not columns here: they are an append-only history
  (`SimpleFit.Accounts.AccountConsent`). The consent fields of
  `update_changeset/3` are virtual: they are validated here and turned into
  history records by the context.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Accounts.User

  @minimum_age 16
  @required_fields [:full_name, :date_of_birth]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          full_name: String.t() | nil,
          date_of_birth: Date.t() | nil,
          registration_completed_at: DateTime.t() | nil,
          accept_terms: boolean() | nil,
          accept_privacy: boolean() | nil,
          product_news: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  # Personal data is redacted from inspect output (logs, crash reports).
  schema "account_profiles" do
    belongs_to :user, User

    field :full_name, :string, redact: true
    field :date_of_birth, :date, redact: true
    field :registration_completed_at, :utc_datetime

    # Consent decisions sent with a save (see the moduledoc).
    field :accept_terms, :boolean, virtual: true
    field :accept_privacy, :boolean, virtual: true
    field :product_news, :boolean, virtual: true

    timestamps()
  end

  @doc "The minimum age, in whole years, to register an account."
  @spec minimum_age() :: pos_integer()
  def minimum_age, do: @minimum_age

  @doc "Profile fields required to complete registration, in form order."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @doc "Keys a client may send."
  @spec editable_fields() :: [atom()]
  def editable_fields,
    do: [:full_name, :date_of_birth, :accept_terms, :accept_privacy, :product_news]

  @doc """
  Saves any subset of the registration basics and consent decisions. Nothing
  is required while registration is in progress. Required consents can only
  be accepted (`true`). Once registration is complete, the full name can be
  changed but not cleared, and the date of birth cannot be changed.
  """
  @spec update_changeset(t(), map(), Date.t()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = profile, attrs, %Date{} = today) when is_map(attrs) do
    profile
    |> cast(attrs, editable_fields(), empty_values: [])
    |> update_change(:full_name, &trim/1)
    |> validate_length(:full_name, min: 1, max: 200)
    |> validate_date_of_birth(today)
    |> validate_sent_true(:accept_terms)
    |> validate_sent_true(:accept_privacy)
    |> validate_not_null(:product_news)
    |> validate_completed(profile)
    |> check_constraint(:date_of_birth,
      name: :account_profiles_completed_immutable,
      message: "can't be changed once registration is complete"
    )
  end

  @doc """
  Marks registration complete. `missing_consents` are the required consents
  not accepted at their current version; each becomes a `required` error.
  An already complete registration keeps its original completion time.
  """
  @spec complete_changeset(t(), [atom()], Date.t(), DateTime.t()) :: Ecto.Changeset.t()
  def complete_changeset(
        %__MODULE__{} = profile,
        missing_consents,
        %Date{} = today,
        %DateTime{} = now
      ) do
    changeset =
      profile
      |> change()
      |> validate_required(@required_fields)
      |> validate_age(today)

    changeset =
      Enum.reduce(missing_consents, changeset, fn kind, acc ->
        add_error(acc, kind, "must be accepted at its current version", validation: :required)
      end)

    changeset
    |> then(fn changeset ->
      if profile.registration_completed_at,
        do: changeset,
        else: put_change(changeset, :registration_completed_at, DateTime.truncate(now, :second))
    end)
    |> check_constraint(:registration_completed_at,
      name: :completed_registration_requirements,
      message: "requires every required field"
    )
  end

  @doc "Profile fields still empty, in form order."
  @spec missing_fields(t() | nil) :: [atom()]
  def missing_fields(nil), do: @required_fields

  def missing_fields(%__MODULE__{} = profile),
    do: Enum.filter(@required_fields, &(Map.fetch!(profile, &1) in [nil, ""]))

  @doc """
  The person's age in whole years on `today`, by calendar date: the year
  difference, minus one until this year's birthday has been reached. A
  29 February birthday is reached on 1 March in common years.
  """
  @spec age(Date.t(), Date.t()) :: integer()
  def age(%Date{year: born_year, month: born_month, day: born_day}, %Date{
        year: year,
        month: month,
        day: day
      })
      when is_integer(born_year) and is_integer(year) do
    years = year - born_year

    if {month, day} < {born_month, born_day},
      do: years - 1,
      else: years
  end

  ## Validation helpers

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value

  defp validate_date_of_birth(changeset, today) do
    validate_change(changeset, :date_of_birth, fn :date_of_birth, date ->
      cond do
        Date.compare(date, today) == :gt ->
          [date_of_birth: {"can't be in the future", [validation: :number]}]

        age(date, today) < @minimum_age ->
          [
            date_of_birth:
              {"must be at least %{age} years ago", [validation: :too_young, age: @minimum_age]}
          ]

        true ->
          []
      end
    end)
  end

  defp validate_age(changeset, today) do
    case get_field(changeset, :date_of_birth) do
      %Date{} = date ->
        if age(date, today) < @minimum_age,
          do:
            add_error(changeset, :date_of_birth, "must be at least %{age} years ago",
              validation: :too_young,
              age: @minimum_age
            ),
          else: changeset

      _missing ->
        changeset
    end
  end

  # A required consent, when sent, can only be accepted: `false` or `null`
  # is `must_be_accepted`. Not sending it leaves it as it is.
  defp validate_sent_true(changeset, field) do
    case Map.fetch(changeset.params || %{}, Atom.to_string(field)) do
      {:ok, true} -> changeset
      {:ok, _other} -> add_error(changeset, field, "must be accepted", validation: :acceptance)
      :error -> changeset
    end
  end

  defp validate_not_null(changeset, field) do
    case Map.fetch(changeset.params || %{}, Atom.to_string(field)) do
      {:ok, nil} -> add_error(changeset, field, "can't be blank", validation: :required)
      _sent_or_absent -> changeset
    end
  end

  # After completion: the full name stays required; the date of birth is fixed.
  defp validate_completed(changeset, %__MODULE__{registration_completed_at: nil}), do: changeset

  defp validate_completed(changeset, %__MODULE__{}) do
    changeset = validate_required(changeset, [:full_name])

    if Map.has_key?(changeset.changes, :date_of_birth),
      do:
        add_error(changeset, :date_of_birth, "can't be changed once registration is complete",
          validation: :immutable
        ),
      else: changeset
  end
end
