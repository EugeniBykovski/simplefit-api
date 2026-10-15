defmodule SimpleFit.Coaching.Invitation do
  @moduledoc """
  A coach's invitation to a fighter (ADR 0021 amendment SF-57; SF-49 §6.3,
  §7): `pending`, then `accepted`, `declined`, `cancelled` or `expired`
  (terminal). It is never a relationship: only the fighter's acceptance
  creates one, in the transaction that consumes the invitation.

  The token is stored only as its SHA-256 and the recipient only as an HMAC
  digest plus an encrypted copy (`SimpleFit.Coaching.InvitationSecrets`).
  An invitation past `expires_at` is expired even while its stored status
  is still `pending` (`effective_status/2`). Written only by
  `SimpleFit.Coaching`.
  """

  use Ecto.Schema

  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Coaching.Relationship

  @type status :: :pending | :accepted | :declined | :cancelled | :expired

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          coach_profile_id: Ecto.UUID.t() | nil,
          token_hash: binary() | nil,
          recipient_digest: binary() | nil,
          recipient_sealed: String.t() | nil,
          message: String.t() | nil,
          status: status() | nil,
          expires_at: DateTime.t() | nil,
          send_count: pos_integer() | nil,
          last_sent_at: DateTime.t() | nil,
          responded_at: DateTime.t() | nil,
          accepted_disclosure_version: String.t() | nil,
          relationship_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Digests, the sealed address and the coach's note are redacted from
  # inspect output (logs, crash reports).
  schema "coach_invitations" do
    belongs_to :coach_profile, CoachProfile
    belongs_to :relationship, Relationship

    field :token_hash, :binary, redact: true
    field :recipient_digest, :binary, redact: true
    field :recipient_sealed, :string, redact: true
    field :message, :string, redact: true
    field :status, Ecto.Enum, values: [:pending, :accepted, :declined, :cancelled, :expired]
    field :expires_at, :utc_datetime_usec
    field :send_count, :integer
    field :last_sent_at, :utc_datetime_usec
    field :responded_at, :utc_datetime_usec
    field :accepted_disclosure_version, :string

    timestamps()
  end

  @doc "The status as of `now`: a pending invitation past its expiry is `:expired`."
  @spec effective_status(t(), DateTime.t()) :: status()
  def effective_status(%__MODULE__{status: :pending, expires_at: at}, now) do
    if DateTime.compare(now, at) == :lt, do: :pending, else: :expired
  end

  def effective_status(%__MODULE__{status: status}, _now), do: status
end
