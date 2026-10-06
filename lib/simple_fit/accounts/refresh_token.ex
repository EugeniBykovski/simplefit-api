defmodule SimpleFit.Accounts.RefreshToken do
  @moduledoc """
  One refresh token issued to a `SimpleFit.Accounts.Session` (ADR 0010).

  Only the SHA-256 of the secret is stored (`token_hash`, redacted from
  `inspect/2`); the secret itself exists only in the response that issued it.
  A token is usable once: refreshing consumes it (`consumed_at`) and issues
  its successor.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.Session

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          session_id: Ecto.UUID.t() | nil,
          session: Session.t() | Ecto.Association.NotLoaded.t() | nil,
          token_hash: binary() | nil,
          expires_at: DateTime.t() | nil,
          consumed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "session_refresh_tokens" do
    belongs_to :session, Session
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps()
  end
end
