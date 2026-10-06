defmodule SimpleFit.Accounts.Session do
  @moduledoc """
  A SimpleFit application session (ADR 0010).

  Created after an authentication flow has established the user; it does not
  know or store which provider that was. One session resolves exactly one
  user. Sessions end at `expires_at` (absolute) or when revoked.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.{RefreshToken, User}

  @type revoked_reason :: :logout | :refresh_reuse

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          revoked_reason: revoked_reason() | nil,
          refresh_tokens: [RefreshToken.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "sessions" do
    belongs_to :user, User
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revoked_reason, Ecto.Enum, values: [:logout, :refresh_reuse]
    has_many :refresh_tokens, RefreshToken

    timestamps()
  end
end
