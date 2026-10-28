defmodule SimpleFit.Gyms.GymFirstRun do
  @moduledoc """
  One owner's first run at one gym (SF-90; ADR 0026 D-G21, ADR 0018
  pattern): when they started the introduction and how it ended. Nothing
  else is stored: no step, platform, device or checklist progress (the
  checklist is derived from the gym's own records).

  A row exists only once the owner started or ended the introduction. At
  most one of `completed_at` and `dismissed_at` is set, and once set the row
  is final (a database trigger refuses any later change, and keeps the keys
  and the start immutable). Written only by `SimpleFit.Gyms.FirstRun`.
  """

  use Ecto.Schema

  alias SimpleFit.Gyms.Gym

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
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

  schema "gym_first_runs" do
    belongs_to :gym, Gym
    field :user_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec

    timestamps()
  end
end
