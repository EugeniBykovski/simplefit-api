defmodule SimpleFit.Gyms.ClassBooking do
  @moduledoc """
  A gym member's place in one class occurrence (SF-99; SF-82 01 §4.7).

  Statuses: `:confirmed` (it holds a seat) and `:cancelled` (history; it
  holds none). A booking is made by the member themselves (`booked_via:
  :member`) or by staff for them (`:staff`); its `client_request_id` names
  that one logical request for ever. Cancellation is final: booking the
  same class again is a new row. Reasons: `:member_cancelled`,
  `:staff_cancelled`, `:occurrence_cancelled` (the class was cancelled) and
  `:membership_ended` (the member left or was removed).

  It belongs to the gym's member, never directly to a user, a Fighter or
  Coach profile, a staff membership or a Coach–Fighter relationship, and it
  carries no money. The database keeps the occurrence and the member in the
  booking's gym, allows one confirmed booking per member and class, and
  never lets the confirmed bookings of a class exceed its capacity. Rows are
  never deleted.
  """

  use Ecto.Schema

  @type status :: :confirmed | :cancelled
  @type cancel_reason ::
          :member_cancelled | :staff_cancelled | :occurrence_cancelled | :membership_ended

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          occurrence_id: Ecto.UUID.t() | nil,
          gym_member_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          booked_via: :member | :staff | nil,
          booked_by_user_id: Ecto.UUID.t() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          confirmed_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          cancel_reason: cancel_reason() | nil,
          cancelled_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @cancel_reasons [:member_cancelled, :staff_cancelled, :occurrence_cancelled, :membership_ended]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_class_bookings" do
    field :gym_id, :binary_id
    field :occurrence_id, :binary_id
    field :gym_member_id, :binary_id
    field :status, Ecto.Enum, values: [:confirmed, :cancelled], default: :confirmed
    field :booked_via, Ecto.Enum, values: [:member, :staff]
    field :booked_by_user_id, :binary_id
    field :client_request_id, :binary_id
    field :confirmed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :cancel_reason, Ecto.Enum, values: @cancel_reasons
    field :cancelled_by_user_id, :binary_id

    timestamps()
  end

  @doc "Every cancellation reason."
  @spec cancel_reasons() :: [cancel_reason()]
  def cancel_reasons, do: @cancel_reasons
end
