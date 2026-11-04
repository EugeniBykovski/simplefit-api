defmodule SimpleFit.Gyms.VerificationEvent do
  @moduledoc """
  One entry of a verification application's append-only history (SF-103):
  a submission by the owner (`actor_user_id`), or an operator's decision or
  evidence download (`operator`), with the application revision and the
  evidence it covered. Decisions carry a reason code
  (`SimpleFit.Gyms.VerificationPolicy.reasons/1`), never free text. The
  database rejects updates and deletes.
  """

  use Ecto.Schema

  @type event ::
          :submitted
          | :approved
          | :rejected
          | :changes_requested
          | :revoked
          | :evidence_downloaded

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          application_id: Ecto.UUID.t() | nil,
          event: event() | nil,
          reason_code: String.t() | nil,
          application_revision: pos_integer() | nil,
          evidence_ids: [Ecto.UUID.t()],
          actor_user_id: Ecto.UUID.t() | nil,
          operator: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          seq: pos_integer() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gym_verification_events" do
    field :gym_id, :binary_id
    field :application_id, :binary_id

    field :event, Ecto.Enum,
      values: [
        :submitted,
        :approved,
        :rejected,
        :changes_requested,
        :revoked,
        :evidence_downloaded
      ]

    field :reason_code, :string
    field :application_revision, :integer
    field :evidence_ids, {:array, :binary_id}, default: []
    field :actor_user_id, :binary_id
    field :operator, :string
    field :occurred_at, :utc_datetime_usec
    field :seq, :integer, read_after_writes: true
  end
end
