defmodule SimpleFit.GymHelpers do
  @moduledoc """
  Test helpers for gyms (SF-83). Gyms are created through the public
  context. Staff other than the owner can be inserted as fixtures
  (`staff!/3`) where a test is about something else; staff invitations
  (SF-93, their production source) have their own helpers below. A
  completed setup is set directly, because setup completion is SF-85's.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{CoachingHelpers, EmailAuthHelpers, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, GymLocation, StaffInvitation, StaffMembership}

  @doc "A user with completed account registration."
  @spec registered!(String.t()) :: User.t()
  def registered!(prefix \\ "gym"), do: CoachingHelpers.registered_user!(prefix)

  @doc "A globally unique client rate-limit key, so tests (and earlier runs) never share a window."
  @spec client_ip() :: String.t()
  def client_ip, do: "client-#{Ecto.UUID.generate()}"

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

  @doc """
  Marks a gym's setup completed directly, after giving it a primary location
  when it has none (the database refuses completion without one, SF-85). A
  fixture for tests that need a completed gym; the real path is
  `SimpleFit.Gyms.complete_setup/2`.
  """
  @spec complete!(Ecto.UUID.t()) :: :ok
  def complete!(gym_id) do
    unless Repo.exists?(
             from(l in GymLocation,
               where: l.gym_id == ^gym_id and l.is_primary and is_nil(l.archived_at)
             )
           ) do
      Repo.insert!(%GymLocation{
        gym_id: gym_id,
        # Not "Warsaw": privacy tests use the coach profile's city as a canary.
        name: "Kazimierz",
        country_code: "PL",
        city: "Kraków",
        address_line: "ul. Józefa 12",
        is_primary: true
      })
    end

    {1, _} =
      Repo.update_all(from(g in Gym, where: g.id == ^gym_id), set: [setup_status: :completed])

    :ok
  end

  @doc "An active staff membership fixture (`role` other than owner)."
  @spec staff!(Ecto.UUID.t(), User.t(), StaffMembership.role()) :: StaffMembership.t()
  def staff!(gym_id, %User{id: user_id}, role) when role != :owner do
    Repo.insert!(%StaffMembership{gym_id: gym_id, user_id: user_id, role: role, status: :active})
  end

  @doc """
  The current setup revision as `user` reads it, or 1 when they cannot read
  it (the write is then refused for its own reason).
  """
  @spec current_revision(User.t(), Ecto.UUID.t()) :: pos_integer()
  def current_revision(%User{} = user, gym_id) do
    case Gyms.get_setup(user, gym_id) do
      {:ok, %{revision: revision}} -> revision
      {:error, _reason} -> 1
    end
  end

  @doc "`Gyms.update_setup/3` with the current revision unless `attrs` names one."
  @spec save_setup(User.t(), Ecto.UUID.t(), map()) :: term()
  def save_setup(%User{} = user, gym_id, attrs),
    do: Gyms.update_setup(user, gym_id, with_revision(user, gym_id, attrs))

  @doc "`Gyms.put_primary_location/3` with the current revision unless `attrs` names one."
  @spec set_location(User.t(), Ecto.UUID.t(), map()) :: term()
  def set_location(%User{} = user, gym_id, attrs),
    do: Gyms.put_primary_location(user, gym_id, with_revision(user, gym_id, attrs))

  defp with_revision(user, gym_id, attrs),
    do: Map.put_new_lazy(attrs, "expected_revision", fn -> current_revision(user, gym_id) end)

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

  ## Staff invitations (SF-93)

  @doc "A unique email address for a test."
  @spec address(String.t()) :: String.t()
  def address(prefix \\ "staff"),
    do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  @doc """
  A user signed up with an email identity for `email` (verified, ADR 0012)
  and completed account registration under `full_name`.
  """
  @spec email_user!(String.t(), String.t()) :: User.t()
  def email_user!(email \\ address(), full_name \\ "Natalia Wiśniewska") do
    {:ok, user} = Accounts.register_user(:email, email)
    registered_as!(user, full_name)
  end

  @doc "Completes account registration of `user` under `full_name`."
  @spec registered_as!(User.t(), String.t()) :: User.t()
  def registered_as!(%User{} = user, full_name) do
    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => full_name,
        "date_of_birth" => Date.to_iso8601(Date.shift(Date.utc_today(), year: -30)),
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
    user
  end

  @doc "Adds a verified email identity to `user` (the end state of SF-77 linking)."
  @spec link_email!(User.t(), String.t()) :: User.t()
  def link_email!(%User{} = user, email) do
    {:ok, _identity} = Accounts.link_identity(user, :email, email)
    user
  end

  @doc "A live session of `user`."
  @spec live_session!(User.t()) :: Session.t()
  def live_session!(%User{} = user) do
    {:ok, %{session: session}} = Accounts.create_session(user)
    session
  end

  @doc "Invites `email` as `role` through `SimpleFit.Gyms` (asserting success)."
  @spec invite!(User.t(), Ecto.UUID.t(), String.t(), atom() | String.t()) :: map()
  def invite!(%User{} = inviter, gym_id, email, role) do
    {:ok, view, _outcome} =
      Gyms.create_staff_invitation(
        inviter,
        gym_id,
        %{"email" => email, "role" => to_string(role)},
        client_ip()
      )

    view
  end

  @doc "Accepts an inbox invitation as `user` on a new session."
  @spec accept!(User.t(), Ecto.UUID.t()) :: map()
  def accept!(%User{} = user, invitation_id) do
    {:ok, result} =
      Gyms.accept_staff_invitation(user, live_session!(user), {:id, invitation_id}, client_ip())

    result
  end

  @doc "A user with an email identity, invited by `inviter` as `role` and accepted."
  @spec joined_staff!(User.t(), Ecto.UUID.t(), atom(), String.t()) :: {User.t(), map()}
  def joined_staff!(%User{} = inviter, gym_id, role, full_name \\ "Ola Kowalska") do
    email = address("joined")
    user = email_user!(email, full_name)
    invitation = invite!(inviter, gym_id, email, role)
    {user, accept!(user, invitation.invitation_id)}
  end

  @doc "The token of the latest E06 email sent to `email`."
  @spec staff_token_for(String.t()) :: String.t()
  def staff_token_for(email) do
    message = EmailAuthHelpers.last_email_to(email)
    [_, token] = Regex.run(~r"/invite/staff#token=(sfs_[A-Za-z0-9_-]{43})", message.text)
    token
  end

  @doc "The stored staff invitation."
  @spec stored_invitation(Ecto.UUID.t()) :: StaffInvitation.t()
  def stored_invitation(id), do: Repo.get!(StaffInvitation, id)

  @doc "Moves an invitation's expiry into the past (the clock never moves in tests)."
  @spec expire_invitation!(Ecto.UUID.t()) :: :ok
  def expire_invitation!(id) do
    past = DateTime.add(DateTime.utc_now(), -1)

    {1, _} =
      Repo.update_all(from(i in StaffInvitation, where: i.id == ^id), set: [expires_at: past])

    :ok
  end

  @doc "The active staff memberships of `user` at `gym_id`."
  @spec active_memberships(Ecto.UUID.t(), User.t()) :: [StaffMembership.t()]
  def active_memberships(gym_id, %User{id: user_id}) do
    Repo.all(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status == :active
      )
    )
  end
end
