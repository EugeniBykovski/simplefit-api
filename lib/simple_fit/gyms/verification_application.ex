defmodule SimpleFit.Gyms.VerificationApplication do
  @moduledoc """
  A gym's business-verification application (SF-103): the business details
  the owner declares, its review status and revision. Internal to
  `SimpleFit.Gyms`; see `SimpleFit.Gyms.Verification`.

  The registration number and address are business data, not a person's,
  but they are never shown outside the owner's own application and the
  operator review (redacted from inspection and logs).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Fighters.CountryCodes
  alias SimpleFit.Gyms.VerificationPolicy

  @type status :: :draft | :submitted | :changes_requested | :approved | :rejected | :revoked

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          revision: pos_integer() | nil,
          policy_version: String.t() | nil,
          legal_name: String.t() | nil,
          registration_country: String.t() | nil,
          registration_number: String.t() | nil,
          address_line: String.t() | nil,
          postal_code: String.t() | nil,
          city: String.t() | nil,
          website: String.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          submitted_at: DateTime.t() | nil,
          submitted_revision: pos_integer() | nil,
          submitted_by_user_id: Ecto.UUID.t() | nil,
          decided_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses [:draft, :submitted, :changes_requested, :approved, :rejected, :revoked]
  @editable [:draft, :changes_requested]
  @control ~r/[\p{Cc}\p{Cf}]/u
  @lengths %{
    legal_name: 200,
    registration_number: 40,
    address_line: 200,
    postal_code: 20,
    city: 80
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_verification_applications" do
    field :gym_id, :binary_id
    field :status, Ecto.Enum, values: @statuses
    field :revision, :integer, default: 1
    field :policy_version, :string
    field :legal_name, :string, redact: true
    field :registration_country, :string
    field :registration_number, :string, redact: true
    field :address_line, :string, redact: true
    field :postal_code, :string, redact: true
    field :city, :string, redact: true
    field :website, :string
    field :created_by_user_id, :binary_id
    field :submitted_at, :utc_datetime_usec
    field :submitted_revision, :integer
    field :submitted_by_user_id, :binary_id
    field :decided_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Every status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Whether the owner may change the application (`draft`, `changes_requested`)."
  @spec editable?(t()) :: boolean()
  def editable?(%__MODULE__{status: status}), do: status in @editable

  @doc """
  The owner's details (`VerificationPolicy.fields/0`; any subset). Text is
  trimmed; blank or `null` clears an optional field; the country is
  upper-cased and must be a known ISO 3166-1 alpha-2 code. Nothing is
  required while drafting (submission checks completeness). Bumps
  `revision` when anything changes.
  """
  @spec details_changeset(t(), map()) :: Ecto.Changeset.t()
  def details_changeset(%__MODULE__{} = application, attrs) do
    fields = VerificationPolicy.fields()

    application
    |> cast(attrs, fields, empty_values: [])
    |> then(&Enum.reduce(fields, &1, fn field, cs -> trim_or_clear(cs, field) end))
    |> update_change(:registration_country, &upcase/1)
    |> validate_country()
    |> then(&Enum.reduce(@lengths, &1, fn {f, max}, cs -> validate_text(cs, f, max) end))
    |> validate_website()
    |> bump_revision()
  end

  defp trim_or_clear(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, value} when is_binary(value) ->
        put_change(
          changeset,
          field,
          if(String.trim(value) == "", do: nil, else: String.trim(value))
        )

      _unchanged_or_nil ->
        changeset
    end
  end

  defp upcase(value) when is_binary(value), do: String.upcase(value)
  defp upcase(value), do: value

  defp validate_country(changeset) do
    validate_change(changeset, :registration_country, fn :registration_country, code ->
      if is_binary(code) and CountryCodes.valid?(code),
        do: [],
        else: [registration_country: {"is invalid", [validation: :inclusion]}]
    end)
  end

  defp validate_text(changeset, field, max) do
    changeset
    |> validate_length(field, min: 1, max: max, count: :codepoints)
    |> validate_change(field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@control, value),
        do: [{field, {"must not contain control characters", [validation: :format]}}],
        else: []
    end)
  end

  # An http(s) link with a host and no credentials (as the gym's website, SF-85).
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

  defp bump_revision(%Ecto.Changeset{valid?: true, changes: changes} = changeset)
       when map_size(changes) > 0,
       do: put_change(changeset, :revision, changeset.data.revision + 1)

  defp bump_revision(changeset), do: changeset
end
