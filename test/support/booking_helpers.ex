defmodule SimpleFit.BookingHelpers do
  @moduledoc "Fixtures for gym class booking tests (SF-99), through `SimpleFit.Gyms`."

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{GymHelpers, Gyms, Repo, TimetableHelpers}
  alias SimpleFit.Gyms.{ClassBooking, ClassCheckIn}

  @doc """
  A class of `gym_id` scheduled by `owner` at `starts_at` (RFC 3339 with the
  Warsaw offset) with `capacity` places (asserting success).
  """
  @spec class!(User.t(), Ecto.UUID.t(), String.t(), pos_integer(), map()) :: map()
  def class!(%User{} = owner, gym_id, starts_at, capacity, extra \\ %{}) do
    venue = TimetableHelpers.venue!(owner, gym_id, %{"capacity" => 100})
    template = TimetableHelpers.template!(owner, gym_id, %{"default_venue_id" => venue.venue_id})

    TimetableHelpers.one_time!(
      owner,
      gym_id,
      Map.merge(
        %{
          "template_id" => template.template_id,
          "starts_at" => starts_at,
          "capacity" => capacity
        },
        extra
      )
    )
  end

  @doc "An active member of the gym (a new user who joined by code and was approved)."
  @spec member!(User.t(), Ecto.UUID.t(), String.t()) :: {User.t(), map()}
  def member!(%User{} = owner, gym_id, name \\ "Marta Kowalska") do
    code = GymHelpers.join_code!(owner, gym_id)
    GymHelpers.active_member!(owner, gym_id, code, name)
  end

  @doc "Books `occurrence_id` as `user` with their membership `member_id` (the raw result)."
  @spec book(User.t(), String.t(), String.t(), String.t()) :: term()
  def book(%User{} = user, member_id, occurrence_id, key \\ Ecto.UUID.generate()) do
    Gyms.book_class(user, GymHelpers.live_session!(user), member_id, %{
      "occurrence_id" => occurrence_id,
      "client_request_id" => key
    })
  end

  @doc "Books as `book/4`, asserting a new booking."
  @spec book!(User.t(), String.t(), String.t()) :: map()
  def book!(%User{} = user, member_id, occurrence_id) do
    {:ok, {view, :created}} = book(user, member_id, occurrence_id)
    view
  end

  @doc "Records a check-in as `staff` (the raw result)."
  @spec check_in(User.t(), Ecto.UUID.t(), String.t()) :: term()
  def check_in(%User{} = staff, gym_id, booking_id),
    do: Gyms.check_in_class_booking(staff, GymHelpers.live_session!(staff), gym_id, booking_id)

  @doc "The confirmed bookings of a class in the database."
  @spec confirmed(Ecto.UUID.t()) :: non_neg_integer()
  def confirmed(occurrence_id),
    do:
      Repo.aggregate(
        from(b in ClassBooking,
          where: b.occurrence_id == ^occurrence_id and b.status == :confirmed
        ),
        :count
      )

  @doc "Every booking row of a class, oldest first."
  @spec booking_rows(Ecto.UUID.t()) :: [ClassBooking.t()]
  def booking_rows(occurrence_id),
    do:
      Repo.all(
        from(b in ClassBooking,
          where: b.occurrence_id == ^occurrence_id,
          order_by: [asc: b.inserted_at]
        )
      )

  @doc "The check-ins of a class."
  @spec check_ins(Ecto.UUID.t()) :: non_neg_integer()
  def check_ins(occurrence_id),
    do: Repo.aggregate(from(c in ClassCheckIn, where: c.occurrence_id == ^occurrence_id), :count)
end
