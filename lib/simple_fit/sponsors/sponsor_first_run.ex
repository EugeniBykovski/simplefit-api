defmodule SimpleFit.Sponsors.SponsorFirstRun do
  @moduledoc """
  One member's first run in one sponsor organization's partner portal (SF-119; the
  SF-90 gym pattern, ADR 0018): when they started the tour and how it ended. Nothing
  else is stored: no step, platform or device.

  A row exists only once the member started or ended the introduction. At most one of
  `completed_at` and `dismissed_at` is set, and once set the row is final (a database
  trigger refuses any later change and keeps the keys and the start). Written only by
  `SimpleFit.Sponsors.FirstRun`. It grants nothing.
  """

  use Ecto.Schema

  alias SimpleFit.Sponsors.Organization

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          dismissed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_first_runs" do
    belongs_to :organization, Organization
    field :user_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec

    timestamps()
  end
end
