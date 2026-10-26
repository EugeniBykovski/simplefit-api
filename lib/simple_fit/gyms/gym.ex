defmodule SimpleFit.Gyms.Gym do
  @moduledoc """
  A gym: the tenant root of everything gym-scoped (ADR 0026, D-G01).

  A gym is created as a `:draft` together with its owner's staff membership
  (`SimpleFit.Gyms.StaffMembership`) and becomes `:completed` only through
  the setup checks of SF-85; completion is final (the database rejects a
  return to draft, and refuses completion without an active primary
  location). Ownership is not stored here: the gym's single active
  `owner` membership is the only source of truth (D-G04). There is no
  publication, plan, payment or verification state (D-G09–D-G11 are
  deferred).

  Rows are written only by `SimpleFit.Gyms`; responses are built from
  explicit projections, never from this struct.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Gyms.{GymLocation, StaffMembership}

  @type gym_type ::
          :boxing_gym
          | :boxing_club
          | :amateur_club
          | :professional_team
          | :combat_sports_gym
          | :fitness_boxing_studio

  @type setup_status :: :draft | :completed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          gym_type: gym_type() | nil,
          setup_status: setup_status() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          phone: String.t() | nil,
          website: String.t() | nil,
          tagline: String.t() | nil,
          accent_color: String.t() | nil,
          revision: pos_integer() | nil,
          locations: [GymLocation.t()] | Ecto.Association.NotLoaded.t(),
          staff_memberships: [StaffMembership.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # OG1's six single-select labels, in design order (D-G13).
  @gym_types [
    :boxing_gym,
    :boxing_club,
    :amateur_club,
    :professional_team,
    :combat_sports_gym,
    :fitness_boxing_studio
  ]

  @control ~r/[\p{Cc}\p{Cf}]/u

  # OG3's six accent swatches (Claude Design 1792675284-1046), contrast-checked
  # against both themes; stored as canonical lowercase hex.
  @accent_colors ~w(#aeb95a #e3a24f #e07a5f #7fa7c9 #edefe7 #8d9840)

  @setup_fields [:name, :gym_type, :phone, :website, :tagline, :accent_color]
  @optional_setup_fields [:phone, :website, :tagline, :accent_color]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gyms" do
    field :name, :string
    field :gym_type, Ecto.Enum, values: @gym_types
    field :setup_status, Ecto.Enum, values: [:draft, :completed]
    field :created_by_user_id, :binary_id
    field :client_request_id, :binary_id
    field :phone, :string, redact: true
    field :website, :string
    field :tagline, :string
    field :accent_color, :string
    field :revision, :integer, default: 1

    has_many :locations, GymLocation
    has_many :staff_memberships, StaffMembership

    timestamps()
  end

  @doc "The gym types (D-G13), in design order."
  @spec gym_types() :: [gym_type()]
  def gym_types, do: @gym_types

  @doc "The approved accent colours (OG3)."
  @spec accent_colors() :: [String.t()]
  def accent_colors, do: @accent_colors

  @doc "The fields a setup update may change (`name`, `gym_type` and the optional ones)."
  @spec setup_fields() :: [atom()]
  def setup_fields, do: @setup_fields

  @doc """
  A setup update (SF-85): any subset of `setup_fields/0`. Text is trimmed; an
  empty or blank optional field, like `null`, clears it; `name` and
  `gym_type` cannot be cleared. Nothing is rounded or truncated: an invalid
  value is an error. Bumps `revision` when anything changes.
  """
  @spec setup_changeset(t(), map()) :: Ecto.Changeset.t()
  def setup_changeset(%__MODULE__{} = gym, attrs) do
    gym
    |> cast(attrs, @setup_fields, empty_values: [])
    |> update_change(:name, &trim_required/1)
    |> clear_blank_optional()
    |> update_change(:accent_color, &String.downcase/1)
    |> validate_required([:name, :gym_type])
    |> validate_name()
    |> validate_format(:phone, ~r/^\+?[0-9][0-9 ()-]{4,30}$/, message: "is not a phone number")
    |> validate_website()
    |> validate_length(:tagline, min: 1, max: 120, count: :codepoints)
    |> validate_printable(:tagline)
    |> validate_inclusion(:accent_color, @accent_colors)
    |> bump_revision()
    |> check_constraint(:phone, name: :phone_format)
    |> check_constraint(:website, name: :website_format)
    |> check_constraint(:tagline, name: :tagline_length)
    |> check_constraint(:accent_color, name: :accent_color_values)
  end

  @doc "Bumps `revision` (a setup change outside the gym row, e.g. its primary location)."
  @spec touch_changeset(t()) :: Ecto.Changeset.t()
  def touch_changeset(%__MODULE__{revision: revision} = gym),
    do: change(gym, revision: revision + 1)

  @doc """
  A new draft gym for `created_by_user_id` from the creation fields (`name`,
  `gym_type`). The name is trimmed and must be 1–80 printable characters.
  """
  @spec create_changeset(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(created_by_user_id, client_request_id, attrs) do
    %__MODULE__{
      created_by_user_id: created_by_user_id,
      client_request_id: client_request_id,
      setup_status: :draft
    }
    |> cast(attrs, [:name, :gym_type])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :gym_type])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_change(:name, fn :name, name ->
      if Regex.match?(@control, name),
        do: [name: {"must not contain control characters", [validation: :format]}],
        else: []
    end)
    |> check_constraint(:name, name: :name_length)
    |> check_constraint(:gym_type, name: :gym_type_values)
  end

  defp trim_required(value) when is_binary(value), do: String.trim(value)
  defp trim_required(value), do: value

  defp clear_blank_optional(changeset),
    do: Enum.reduce(@optional_setup_fields, changeset, &trim_or_clear/2)

  defp trim_or_clear(field, changeset) do
    case fetch_change(changeset, field) do
      {:ok, value} when is_binary(value) -> put_change(changeset, field, blank_to_nil(value))
      _unchanged_or_nil -> changeset
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_name(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_printable(:name)
  end

  defp validate_printable(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@control, value),
        do: [{field, {"must not contain control characters", [validation: :format]}}],
        else: []
    end)
  end

  # An http(s) link with a host and no credentials; never another scheme.
  defp validate_website(changeset) do
    validate_change(changeset, :website, fn :website, value ->
      uri = URI.parse(value)

      cond do
        String.length(value) > 200 ->
          [
            website:
              {"should be at most %{count} character(s)",
               [count: 200, validation: :length, kind: :max, type: :string]}
          ]

        uri.scheme not in ["http", "https"] or uri.host in [nil, ""] or uri.userinfo != nil or
            Regex.match?(~r/\s/, value) ->
          [website: {"is not a web address", [validation: :format]}]

        true ->
          []
      end
    end)
  end

  defp bump_revision(%Ecto.Changeset{changes: changes} = changeset) when map_size(changes) == 0,
    do: changeset

  defp bump_revision(changeset),
    do: put_change(changeset, :revision, (changeset.data.revision || 1) + 1)
end
