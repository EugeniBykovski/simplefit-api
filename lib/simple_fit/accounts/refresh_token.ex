defmodule SimpleFit.Accounts.RefreshToken do
  @moduledoc """
  One refresh token issued to a `SimpleFit.Accounts.Session` (ADR 0010).

  Only the SHA-256 of the secret is stored (`token_hash`, redacted from
  `inspect/2`); the secret itself exists only in the response that issued it.
  A token is usable once: refreshing consumes it (`consumed_at`) and issues
  its successor, a child (`parent_id`). A child replaced by a lost-response
  recovery before its first use is `superseded_at` (SF-75); `recoveries`
  counts the recoveries made from a token.
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
          parent_id: Ecto.UUID.t() | nil,
          superseded_at: DateTime.t() | nil,
          recoveries: non_neg_integer(),
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
    field :parent_id, :binary_id
    field :superseded_at, :utc_datetime
    field :recoveries, :integer, default: 0

    timestamps()
  end
end
