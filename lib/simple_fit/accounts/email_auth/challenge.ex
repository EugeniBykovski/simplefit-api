defmodule SimpleFit.Accounts.EmailAuth.Challenge do
  @moduledoc """
  One email authentication challenge (ADR 0012). Internal to
  `SimpleFit.Accounts`.

    * `:verification` (E01): proves ownership of an email address before an
      identity exists. Targets the canonical `email`; answered by the 6-digit
      code or the E01 link; the client that started it holds a registration
      token.
    * `:sign_in` (E17): authenticates an existing email identity. Stores only
      the target digest; answered by the 6-digit code only.

  A challenge is open until `closed_at`; expiry is derived from
  `expires_at`. Closed reasons:

    * `code_verified` - the code was entered by the client that requested
      the challenge; the only state in which a session is ever issued
      (`session_created_at`)
    * `link_verified` - the E01 link verified the email (any device); never a
      session
    * `superseded` - a newer challenge for the same purpose and target
    * `exhausted` - too many wrong codes
    * `conflict` - the email identity was taken (verification) or is gone
      (sign-in) when the challenge was answered

  Verifiers, digests and the email are redacted from `inspect/2`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          purpose: :verification | :sign_in | nil,
          target_digest: binary() | nil,
          email: String.t() | nil,
          code_hash: binary() | nil,
          link_token_hash: binary() | nil,
          registration_token_hash: binary() | nil,
          failed_attempts: non_neg_integer(),
          expires_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil,
          closed_reason: closed_reason() | nil,
          session_created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type closed_reason :: :code_verified | :link_verified | :superseded | :exhausted | :conflict

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "email_auth_challenges" do
    field :purpose, Ecto.Enum, values: [:verification, :sign_in]
    field :target_digest, :binary, redact: true
    field :email, :string, redact: true
    field :code_hash, :binary, redact: true
    field :link_token_hash, :binary, redact: true
    field :registration_token_hash, :binary, redact: true
    field :failed_attempts, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    field :closed_reason, Ecto.Enum,
      values: [:code_verified, :link_verified, :superseded, :exhausted, :conflict]

    field :session_created_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Whether the challenge can still be answered at `now`."
  @spec open?(t(), DateTime.t()) :: boolean()
  def open?(%__MODULE__{closed_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def open?(%__MODULE__{}, _now), do: false
end
