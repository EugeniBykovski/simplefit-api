defmodule SimpleFit.Sponsors.ApplicationEvent do
  @moduledoc """
  Append-only history of a sponsor application (SF-113): created, updated,
  submitted, resubmitted, and refused attempts (stale revision, incomplete,
  declaration unavailable). Ids, statuses and codes only - never answers, emails
  or text. Separate from operator audit: review decisions (a later task) go
  through the SF-111 action framework and are audited there as well.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_application_events" do
    field :application_id, :binary_id
    field :occurred_at, :utc_datetime_usec
    field :event, :string
    field :outcome, Ecto.Enum, values: [:allowed, :refused]
    field :actor_user_id, :binary_id
    field :from_status, :string
    field :to_status, :string
    field :revision, :integer
    field :submission_id, :binary_id
    field :reason_code, :string
    field :request_id, :string
  end
end
