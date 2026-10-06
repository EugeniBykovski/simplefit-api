defmodule SimpleFit.Accounts.Identity do
  @moduledoc """
  A way to sign in as a `SimpleFit.Accounts.User` (ADR 0009).

  The identity key is `{provider, provider_subject}`, unique across SimpleFit:

    * `:email` - the subject is the canonical address
      (`SimpleFit.Accounts.EmailAddress`).
    * `:google`, `:apple` - the subject is the provider's stable account id
      (the `sub` claim), stored exactly as the provider issues it. An email the
      provider reports is metadata, never the subject.

  An identity belongs to exactly one user. It holds no credential: no
  password, token or provider assertion. `provider_subject` is redacted from
  `inspect/2`, so it does not leak into logs or error reports.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Accounts.{EmailAddress, User}

  @providers [:email, :google, :apple]

  @type provider :: :email | :google | :apple

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          provider: provider() | nil,
          provider_subject: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "identities" do
    belongs_to :user, User

    # Stored as text; the supported set lives here, not in the database.
    field :provider, Ecto.Enum, values: @providers
    field :provider_subject, :string, redact: true

    timestamps()
  end

  @doc "The providers SimpleFit accepts."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc false
  # Validates and canonicalizes {provider, provider_subject}. Internal to
  # SimpleFit.Accounts.
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_subject])
    |> validate_required([:provider, :provider_subject])
    |> canonical_subject()
    |> unique_constraint([:provider, :provider_subject],
      name: :identities_provider_provider_subject_index,
      error_key: :provider_subject
    )
    |> foreign_key_constraint(:user_id)
  end

  defp canonical_subject(%{valid?: false} = changeset), do: changeset

  defp canonical_subject(changeset) do
    subject = get_field(changeset, :provider_subject)

    case get_field(changeset, :provider) do
      :email ->
        case EmailAddress.normalize(subject) do
          {:ok, address} ->
            put_change(changeset, :provider_subject, address)

          :error ->
            add_error(changeset, :provider_subject, "is not a valid email address",
              validation: :format
            )
        end

      _provider_account_id ->
        changeset
        |> validate_length(:provider_subject, max: 255)
        |> validate_format(:provider_subject, ~r/\A[\x21-\x7e]+\z/,
          message: "must be the provider's account id"
        )
    end
  end
end
