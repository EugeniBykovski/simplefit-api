defmodule SimpleFit.Accounts.Restrictions do
  @moduledoc """
  Account suspension and operator sign-out (SF-122; D-SA29 approved for the MVP as
  reversible suspension only). The Accounts context owns these mutations; the
  operator admin actions (`SimpleFit.Operators.UserActions`) authorize, confirm and
  audit them and call in here inside their transaction.

  * **Suspend** - records an open suspension, marks the account `suspended` and
    revokes every active session (`account_suspended`), in one transaction under the
    user row lock. A suspended account can't sign in with any identity (email code,
    Google, Apple), refresh, or use any session: `Sessions.create/1`,
    `Sessions.refresh/1` and `Sessions.authenticate/1` all check it.
  * **Lift** - closes the open suspension and marks the account `active`. Revoked
    sessions stay revoked: the person signs in again.
  * **Sign out everywhere** - revokes every active session (`operator_revoked`);
    the account stays as it is.

  Memberships, profiles, gyms and organizations are untouched: suspension is not
  deletion, nor any domain's own suspension.

  Linearization: every mutation locks the user row `FOR UPDATE` first; session
  issue locks it `FOR KEY SHARE` (`Sessions.create/1`), so a sign-in either commits
  before a suspension (whose revocation then ends that session too) or reads the
  suspension and is refused.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{AccountState, Restriction, Session, User}
  alias SimpleFit.Repo

  @doc "The account's state: `%AccountState{}` (unsaved, revision 1, when never acted on)."
  @spec state(Ecto.UUID.t()) :: AccountState.t()
  def state(user_id) do
    Repo.get(AccountState, user_id) ||
      %AccountState{user_id: user_id, status: :active, revision: 1}
  end

  @doc "Whether the account is suspended (a read without a lock)."
  @spec suspended?(Ecto.UUID.t()) :: boolean()
  def suspended?(user_id) do
    Repo.exists?(from(s in AccountState, where: s.user_id == ^user_id and s.status == :suspended))
  end

  @doc "The open suspension, if any."
  @spec open(Ecto.UUID.t()) :: Restriction.t() | nil
  def open(user_id),
    do: Repo.one(from(r in Restriction, where: r.user_id == ^user_id and is_nil(r.lifted_at)))

  @doc """
  Inside a transaction: locks the user row `FOR UPDATE` and the account state row
  (created at revision 1 when missing), and returns the state; `nil` for no such user.
  """
  @spec lock!(Ecto.UUID.t()) :: AccountState.t() | nil
  def lock!(user_id) do
    true = Repo.in_transaction?()

    case Repo.one(from(u in User, where: u.id == ^user_id, select: u.id, lock: "FOR UPDATE")) do
      nil ->
        nil

      _id ->
        now = DateTime.utc_now()

        {_, _} =
          Repo.insert_all(
            AccountState,
            [%{user_id: user_id, status: :active, inserted_at: now, updated_at: now}],
            on_conflict: :nothing,
            conflict_target: :user_id
          )

        Repo.one!(from(s in AccountState, where: s.user_id == ^user_id, lock: "FOR UPDATE"))
    end
  end

  @doc "Inside a locked transaction (`lock!/1`): suspends the account and revokes its sessions."
  @spec suspend!(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), DateTime.t()) :: non_neg_integer()
  def suspend!(user_id, operator_id, reason_code, now) do
    Repo.insert!(%Restriction{
      user_id: user_id,
      kind: :suspension,
      reason_code: reason_code,
      started_at: now,
      started_by_operator_id: operator_id
    })

    {1, _} =
      Repo.update_all(from(s in AccountState, where: s.user_id == ^user_id),
        set: [status: :suspended, updated_at: now]
      )

    revoke_all!(user_id, :account_suspended, now)
  end

  @doc "Inside a locked transaction (`lock!/1`): lifts the open suspension. Sessions stay revoked."
  @spec lift!(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), DateTime.t()) :: :ok
  def lift!(user_id, operator_id, reason_code, now) do
    {1, _} =
      Repo.update_all(
        from(r in Restriction, where: r.user_id == ^user_id and is_nil(r.lifted_at)),
        set: [lifted_at: now, lift_reason_code: reason_code, lifted_by_operator_id: operator_id]
      )

    {1, _} =
      Repo.update_all(from(s in AccountState, where: s.user_id == ^user_id),
        set: [status: :active, updated_at: now]
      )

    :ok
  end

  @doc """
  Inside a locked transaction (`lock!/1`): revokes every active session of the user
  (`operator_revoked`) and bumps the account revision. Returns how many were active.
  """
  @spec sign_out_everywhere!(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def sign_out_everywhere!(user_id, now) do
    count = revoke_all!(user_id, :operator_revoked, now)

    {1, _} =
      Repo.update_all(from(s in AccountState, where: s.user_id == ^user_id),
        set: [updated_at: now]
      )

    count
  end

  defp revoke_all!(user_id, reason, now) do
    {count, _} =
      Repo.update_all(
        from(s in Session, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
        set: [
          revoked_at: DateTime.truncate(now, :second),
          revoked_reason: reason,
          updated_at: DateTime.truncate(now, :second)
        ]
      )

    count
  end
end
