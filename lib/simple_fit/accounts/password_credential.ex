defmodule SimpleFit.Accounts.PasswordCredential do
  @moduledoc """
  A user's optional password (SF-157, ADR 0012 amendment): an Argon2id hash, at most
  one per user, never the password. Internal to `SimpleFit.Accounts`; never rendered.
  The hash is redacted from `inspect/2`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          password_hash: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "password_credentials" do
    field :user_id, :binary_id
    field :password_hash, :string, redact: true

    timestamps()
  end
end
