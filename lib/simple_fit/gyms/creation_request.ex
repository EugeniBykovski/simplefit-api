defmodule SimpleFit.Gyms.CreationRequest do
  @moduledoc """
  One `client_request_id` a user sent to gym creation and the gym it
  produced (`:created`) or resumed (`:resumed`). `gym_id` becomes `nil` when
  that gym is discarded: the key stays spent and is never reused to create a
  gym (SF-85). Written only by `SimpleFit.Gyms.Creation`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          outcome: :created | :resumed | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "gym_creation_requests" do
    field :user_id, :binary_id, primary_key: true
    field :client_request_id, :binary_id, primary_key: true
    field :gym_id, :binary_id
    field :outcome, Ecto.Enum, values: [:created, :resumed]

    timestamps()
  end
end
