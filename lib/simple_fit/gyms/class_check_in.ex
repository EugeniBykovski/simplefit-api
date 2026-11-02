defmodule SimpleFit.Gyms.ClassCheckIn do
  @moduledoc """
  An attendance event (SF-99; SF-82 01 §4.8): a staff member recorded that
  the member of a confirmed booking came to the class. One per booking (a
  repeated check-in is the same event), recorded by hand (`method:
  :manual`; QR passes, NFC and location are FUTURE). It is participation,
  not training data: no result, note, weight or effort. Never changed or
  deleted; nothing infers it from the clock, a booking or a membership.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          occurrence_id: Ecto.UUID.t() | nil,
          booking_id: Ecto.UUID.t() | nil,
          gym_member_id: Ecto.UUID.t() | nil,
          recorded_by_user_id: Ecto.UUID.t() | nil,
          recorded_by_staff_membership_id: Ecto.UUID.t() | nil,
          method: :manual | nil,
          checked_in_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gym_class_check_ins" do
    field :gym_id, :binary_id
    field :occurrence_id, :binary_id
    field :booking_id, :binary_id
    field :gym_member_id, :binary_id
    field :recorded_by_user_id, :binary_id
    field :recorded_by_staff_membership_id, :binary_id
    field :method, Ecto.Enum, values: [:manual], default: :manual
    field :checked_in_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
