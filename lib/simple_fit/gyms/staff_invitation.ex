defmodule SimpleFit.Gyms.StaffInvitation do
  @moduledoc """
  A gym's invitation of one email address to a staff role (ADR 0026, D-G12,
  D-G16; SF-93): `pending`, then `accepted`, `declined`, `cancelled` or
  `expired` (all terminal; the database forbids any later change). It grants
  nothing: only the recipient's explicit acceptance creates a staff
  membership (`staff_membership_id`), in the transaction that consumes it.

  The role is `manager`, `coach` or `front_desk`, never `owner` (D-G04). The
  token is stored only as its SHA-256 and the recipient only as an HMAC
  digest plus an encrypted copy (`SimpleFit.Gyms.InvitationSecrets`). A
  pending invitation past `expires_at` (7 days, D-G12) is expired whatever
  its stored status says (`effective_status/2`). Written only by
  `SimpleFit.Gyms`. Not a Coach–Fighter invitation (D-G16).
  """

  use Ecto.Schema

  @type status :: :pending | :accepted | :declined | :cancelled | :expired
  @type role :: :manager | :coach | :front_desk

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          invited_by_staff_membership_id: Ecto.UUID.t() | nil,
          token_hash: binary() | nil,
          recipient_digest: binary() | nil,
          recipient_sealed: String.t() | nil,
          role: role() | nil,
          status: status() | nil,
          expires_at: DateTime.t() | nil,
          send_count: pos_integer() | nil,
          last_sent_at: DateTime.t() | nil,
          responded_at: DateTime.t() | nil,
          staff_membership_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @roles [:manager, :coach, :front_desk]
  @statuses [:pending, :accepted, :declined, :cancelled, :expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Digests and the sealed address are redacted from inspect output (logs,
  # crash reports).
  schema "gym_staff_invitations" do
    field :gym_id, :binary_id
    field :invited_by_staff_membership_id, :binary_id
    field :token_hash, :binary, redact: true
    field :recipient_digest, :binary, redact: true
    field :recipient_sealed, :string, redact: true
    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: @statuses
    field :expires_at, :utc_datetime_usec
    field :send_count, :integer
    field :last_sent_at, :utc_datetime_usec
    field :responded_at, :utc_datetime_usec
    field :staff_membership_id, :binary_id

    timestamps()
  end

  @doc "The roles an invitation can offer (never `owner`)."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Every status, stored or effective."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "The status as of `now`: a pending invitation past its expiry is `:expired`."
  @spec effective_status(t(), DateTime.t()) :: status()
  def effective_status(%__MODULE__{status: :pending, expires_at: at}, now) do
    if DateTime.compare(now, at) == :lt, do: :pending, else: :expired
  end

  def effective_status(%__MODULE__{status: status}, _now), do: status
end
