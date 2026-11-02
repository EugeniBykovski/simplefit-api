defmodule SimpleFit.Gyms.ClassTemplate do
  @moduledoc """
  A reusable gym class definition (SF-97): a title, an optional
  description and the defaults new series and one-time classes start from
  (duration, capacity, venue, instructor). It is not a scheduled class.
  Editing it changes only those defaults: classes already scheduled keep
  what they were scheduled with. An `:archived` template takes no new
  classes and never becomes active again.
  """

  use Ecto.Schema

  @type status :: :active | :archived

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          default_duration_minutes: pos_integer() | nil,
          default_capacity: pos_integer() | nil,
          default_venue_id: Ecto.UUID.t() | nil,
          default_instructor_staff_membership_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          archived_at: DateTime.t() | nil,
          revision: pos_integer() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_class_templates" do
    field :gym_id, :binary_id
    field :title, :string
    field :description, :string
    field :default_duration_minutes, :integer
    field :default_capacity, :integer
    field :default_venue_id, :binary_id
    field :default_instructor_staff_membership_id, :binary_id
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :archived_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id

    timestamps()
  end
end
