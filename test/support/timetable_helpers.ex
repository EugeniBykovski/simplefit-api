defmodule SimpleFit.TimetableHelpers do
  @moduledoc "Fixtures for gym timetable tests (SF-97), through `SimpleFit.Gyms`."

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Gyms, Repo}
  alias SimpleFit.Gyms.{ClassOccurrence, GymLocation}

  @zone "Europe/Warsaw"

  @doc "The gym's primary location id."
  @spec location_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def location_id(gym_id),
    do:
      Repo.one!(from(l in GymLocation, where: l.gym_id == ^gym_id and l.is_primary, select: l.id))

  @doc "A venue created by `admin` (asserting success)."
  @spec venue!(User.t(), Ecto.UUID.t(), map()) :: map()
  def venue!(%User{} = admin, gym_id, attrs \\ %{}) do
    {:ok, {view, :created}} =
      Gyms.create_venue(
        admin,
        session(admin),
        gym_id,
        Map.merge(
          %{
            "client_request_id" => Ecto.UUID.generate(),
            "gym_location_id" => location_id(gym_id),
            "name" => "Ring #{System.unique_integer([:positive])}",
            "time_zone" => @zone
          },
          attrs
        )
      )

    view
  end

  @doc "A class template created by `admin` (asserting success)."
  @spec template!(User.t(), Ecto.UUID.t(), map()) :: map()
  def template!(%User{} = admin, gym_id, attrs \\ %{}) do
    {:ok, {view, :created}} =
      Gyms.create_class_template(
        admin,
        session(admin),
        gym_id,
        Map.merge(
          %{
            "client_request_id" => Ecto.UUID.generate(),
            "title" => "Boxing Fundamentals",
            "default_duration_minutes" => 60,
            "default_capacity" => 16
          },
          attrs
        )
      )

    view
  end

  @doc "Schedules a one-time class (the raw result)."
  @spec one_time(User.t(), Ecto.UUID.t(), map()) :: term()
  def one_time(%User{} = admin, gym_id, attrs) do
    Gyms.create_class_occurrence(
      admin,
      session(admin),
      gym_id,
      Map.put_new(attrs, "client_request_id", Ecto.UUID.generate())
    )
  end

  @doc "Schedules a one-time class (asserting success)."
  @spec one_time!(User.t(), Ecto.UUID.t(), map()) :: map()
  def one_time!(%User{} = admin, gym_id, attrs) do
    {:ok, {view, :created}} = one_time(admin, gym_id, attrs)
    view
  end

  @doc "Creates a series (the raw result)."
  @spec series(User.t(), Ecto.UUID.t(), map()) :: term()
  def series(%User{} = admin, gym_id, attrs) do
    Gyms.create_class_series(
      admin,
      session(admin),
      gym_id,
      Map.put_new(attrs, "client_request_id", Ecto.UUID.generate())
    )
  end

  @doc "Creates a series (asserting success)."
  @spec series!(User.t(), Ecto.UUID.t(), map()) :: map()
  def series!(%User{} = admin, gym_id, attrs) do
    {:ok, {view, :created}} = series(admin, gym_id, attrs)
    view
  end

  @doc "A series' occurrences, by date."
  @spec series_rows(Ecto.UUID.t()) :: [ClassOccurrence.t()]
  def series_rows(series_id),
    do:
      Repo.all(
        from(o in ClassOccurrence,
          where: o.series_id == ^series_id,
          order_by: [asc: o.series_local_date]
        )
      )

  @doc "A stored occurrence."
  @spec stored_occurrence(Ecto.UUID.t()) :: ClassOccurrence.t()
  def stored_occurrence(id), do: Repo.get!(ClassOccurrence, id)

  @doc "A live session of `user` (one per call)."
  @spec session(User.t()) :: SimpleFit.Accounts.Session.t()
  def session(%User{} = user), do: SimpleFit.GymHelpers.live_session!(user)
end
