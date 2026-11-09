defmodule SimpleFit.Sponsors.Organization do
  @moduledoc """
  An approved sponsor business (SF-112, ADR 0030). Created only by
  `SimpleFit.Sponsors.Provisioning`, never by an applicant or a public endpoint.
  `active`, `suspended` (read-only for its members) or `closed` (gone, terminal);
  transitions and the immutable provisioning are enforced by a trigger, which also
  raises `revision` on every update. No verification, plan or commercial column.
  """

  use Ecto.Schema

  @type status :: :active | :suspended | :closed
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_organizations" do
    field :legal_name, :string
    field :display_name, :string
    field :country_code, :string
    field :website, :string
    field :status, Ecto.Enum, values: [:active, :suspended, :closed]
    field :provisioning_source, Ecto.Enum, values: [:sponsor_application, :local_fixture]
    field :source_application_id, :binary_id
    field :provisioning_key, :binary_id
    field :suspended_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :revision, :integer, default: 1, read_after_writes: true

    timestamps()
  end
end
