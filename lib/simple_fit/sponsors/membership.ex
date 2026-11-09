defmodule SimpleFit.Sponsors.Membership do
  @moduledoc """
  A user's membership of one sponsor organization (SF-112, ADR 0030): role
  `owner`, `manager` or `member`; status `active`, `suspended` or `revoked`
  (terminal). It is the only thing that gives sponsor rights, and only in its own
  organization. Not created from an email, an invitation link, a contact entry,
  registration intent or any other context. Never deleted.
  """

  use Ecto.Schema

  @type role :: :owner | :manager | :member
  @type status :: :active | :suspended | :revoked
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_workspace_memberships" do
    field :organization_id, :binary_id
    field :user_id, :binary_id
    field :role, Ecto.Enum, values: [:owner, :manager, :member]
    field :status, Ecto.Enum, values: [:active, :suspended, :revoked]
    field :suspended_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string

    timestamps()
  end
end
