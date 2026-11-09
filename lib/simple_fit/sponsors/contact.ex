defmodule SimpleFit.Sponsors.Contact do
  @moduledoc """
  A business contact of a sponsor organization (SF-112, ADR 0030): someone the
  platform may write to about the organization. **Not an account, not a member:**
  it has no user id, its email proves nothing and matches no account, and it grants
  no access. Linking a contact to an account would need a verified identity and an
  explicit authorized operation; none exists.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_contacts" do
    field :organization_id, :binary_id
    field :kind, Ecto.Enum, values: [:primary, :additional]
    field :full_name, :string
    field :job_title, :string
    field :email, :string
    field :phone, :string

    timestamps()
  end
end
