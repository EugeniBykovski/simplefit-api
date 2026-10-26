defmodule SimpleFit.GymHelpers do
  @moduledoc """
  Test helpers for gyms (SF-83). Gyms are created through the public
  context. Staff other than the owner are inserted as fixtures, because
  staff invitations (their only production source) are a later ticket, and
  a completed setup is set directly, because setup completion is SF-85's.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{CoachingHelpers, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, StaffMembership}

  @doc "A user with completed account registration."
  @spec registered!(String.t()) :: User.t()
  def registered!(prefix \\ "gym"), do: CoachingHelpers.registered_user!(prefix)

  @doc "A unique client rate-limit key, so tests never share a client window."
  @spec client_ip() :: String.t()
  def client_ip, do: "client-#{System.unique_integer([:positive])}"

  @doc "Creation attributes with a fresh idempotency key."
  @spec gym_attrs(map()) :: map()
  def gym_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "client_request_id" => Ecto.UUID.generate(),
        "name" => "Simple Boxing Gym",
        "gym_type" => "boxing_gym"
      },
      overrides
    )
  end

  @doc "A draft gym created by `owner` through `SimpleFit.Gyms.create_gym/3`."
  @spec draft_gym!(User.t(), map()) :: map()
  def draft_gym!(%User{} = owner, overrides \\ %{}) do
    {:ok, view, :created} = Gyms.create_gym(owner, gym_attrs(overrides), client_ip())
    view
  end

  @doc "A gym created by `owner` and marked completed (frees the owner's draft slot)."
  @spec completed_gym!(User.t(), map()) :: map()
  def completed_gym!(%User{} = owner, overrides \\ %{}) do
    view = draft_gym!(owner, overrides)
    complete!(view.id)
    %{view | setup_status: :completed}
  end

  @doc "Marks a gym's setup completed (fixture for SF-85's completion)."
  @spec complete!(Ecto.UUID.t()) :: :ok
  def complete!(gym_id) do
    {1, _} =
      Repo.update_all(from(g in Gym, where: g.id == ^gym_id), set: [setup_status: :completed])

    :ok
  end

  @doc "An active staff membership fixture (`role` other than owner)."
  @spec staff!(Ecto.UUID.t(), User.t(), StaffMembership.role()) :: StaffMembership.t()
  def staff!(gym_id, %User{id: user_id}, role) when role != :owner do
    Repo.insert!(%StaffMembership{gym_id: gym_id, user_id: user_id, role: role, status: :active})
  end

  @doc "The active owners of a gym."
  @spec active_owners(Ecto.UUID.t()) :: [StaffMembership.t()]
  def active_owners(gym_id) do
    Repo.all(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.role == :owner and m.status == :active
      )
    )
  end

  @doc "The audit events of a gym, oldest first."
  @spec audit_events(Ecto.UUID.t()) :: [AuditEvent.t()]
  def audit_events(gym_id) do
    Repo.all(
      from(e in AuditEvent, where: e.gym_id == ^gym_id, order_by: [asc: e.occurred_at, asc: e.id])
    )
  end

  @doc "The number of gyms created by a user."
  @spec gyms_created_by(User.t()) :: non_neg_integer()
  def gyms_created_by(%User{id: user_id}),
    do: Repo.aggregate(from(g in Gym, where: g.created_by_user_id == ^user_id), :count)
end
