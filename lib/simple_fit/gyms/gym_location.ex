defmodule SimpleFit.Gyms.GymLocation do
  @moduledoc """
  An address-only place of a gym (ADR 0026, D-G02): no geocoding, map or
  tracking. A gym has at most one non-archived primary location (partial
  unique index); a completed gym always keeps one (database trigger). SF-85
  writes the primary location during setup; more locations are future
  (WG23).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Fighters.CountryCodes
  alias SimpleFit.Gyms.Gym

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          country_code: String.t() | nil,
          city: String.t() | nil,
          address_line: String.t() | nil,
          entrance_note: String.t() | nil,
          is_primary: boolean() | nil,
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_locations" do
    belongs_to :gym, Gym
    field :name, :string
    field :country_code, :string
    field :city, :string
    field :address_line, :string
    field :entrance_note, :string
    field :is_primary, :boolean
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  @fields [:name, :country_code, :city, :address_line, :entrance_note]
  @control ~r/[\p{Cc}\p{Cf}]/u

  @doc "The fields a primary-location update sets."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The primary location's address (OG2): `country_code` (ISO 3166-1 alpha-2,
  the shared allowlist), `city`, `address_line` (required), optional
  `entrance_note` and `name` (defaults to the city: OG2 has no name field).
  Text is trimmed and never truncated. Replaces every field: an omitted
  optional field is cleared.
  """
  @spec address_changeset(t(), map()) :: Ecto.Changeset.t()
  def address_changeset(%__MODULE__{} = location, attrs) do
    # A full replacement: an omitted optional field is cleared, not kept.
    attrs = Map.merge(%{"entrance_note" => nil, "name" => nil}, attrs)

    location
    |> cast(attrs, @fields, empty_values: [])
    |> update_all_text()
    |> default_name()
    |> update_change(:country_code, &String.upcase/1)
    |> validate_required([:country_code, :city, :address_line, :name])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_length(:city, min: 1, max: 80, count: :codepoints)
    |> validate_length(:address_line, min: 1, max: 200, count: :codepoints)
    |> validate_length(:entrance_note, min: 1, max: 200, count: :codepoints)
    |> validate_change(:country_code, fn :country_code, code ->
      if CountryCodes.valid?(code),
        do: [],
        else: [country_code: {"is invalid", [validation: :inclusion]}]
    end)
    |> validate_printable([:name, :city, :address_line, :entrance_note])
    |> check_constraint(:country_code, name: :country_code_format)
  end

  defp update_all_text(changeset), do: Enum.reduce(@fields, changeset, &trim_or_clear/2)

  defp trim_or_clear(field, changeset) do
    case get_change(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, blank_to_nil(value))
      _other -> changeset
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp default_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :city)} do
      {nil, city} when is_binary(city) -> put_change(changeset, :name, city)
      _named -> changeset
    end
  end

  defp validate_printable(changeset, fields),
    do:
      Enum.reduce(
        fields,
        changeset,
        &validate_change(&2, &1, fn field, value -> printable(field, value) end)
      )

  defp printable(field, value) do
    if is_binary(value) and Regex.match?(@control, value),
      do: [{field, {"must not contain control characters", [validation: :format]}}],
      else: []
  end
end
