defmodule SimpleFit.Sponsors.PartnershipEvent do
  @moduledoc """
  Append-only partnership history (SF-130): preference saves and every proposal
  change, allowed or refused, by a sponsor member or an operator. Ids and codes
  only - never answers or messages.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_partnership_events" do
    field :organization_id, :binary_id
    field :proposal_id, :binary_id
    field :occurred_at, :utc_datetime_usec
    field :event, :string
    field :outcome, Ecto.Enum, values: [:allowed, :refused]
    field :actor_user_id, :binary_id
    field :actor_kind, Ecto.Enum, values: [:sponsor_member, :operator]
    field :from_status, :string
    field :to_status, :string
    field :revision, :integer
    field :submission_id, :binary_id
    field :reason_code, :string
    field :request_id, :string
  end
end
