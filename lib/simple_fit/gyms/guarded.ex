defmodule SimpleFit.Gyms.Guarded do
  @moduledoc """
  The gym write transaction of the commercial operations (SF-101): member
  products, member product subscriptions and the gym's SaaS subscription
  (`SimpleFit.Billing` calls it through `SimpleFit.Gyms.billing_write/5`).
  Internal to `SimpleFit.Gyms`.

  It holds the caller's session (`FOR SHARE`: a sign-out commits before or
  after, never during), locks the gym row and the actor's active staff
  membership (`Access.authorize_locked/3`, the SF-83 lock order of every
  staff change, so an ownership transfer or a revocation commits entirely
  before or after), checks the permission, requires a completed gym and
  counts the write against the operation's rate limit.
  """

  alias SimpleFit.{Accounts, RateLimit, Repo}
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Gyms.{Access, Gym, Members, MemberSecrets}

  @unlogged [log: false]

  @type limit :: {String.t(), pos_integer(), pos_integer()}

  @doc """
  Runs `fun.(access)` in the transaction above. `limit` is `{bucket, count,
  seconds}`. `fun` returns `{:ok, value}` or `{:error, reason}` (rolled back).
  """
  @spec write(User.t(), Session.t(), term(), atom(), limit(), (Access.t() ->
                                                                 {:ok, term()}
                                                                 | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def write(%User{} = user, %Session{} = session, gym_id, permission, limit, fun) do
    Repo.transaction(
      fn ->
        with :ok <- Members.held(Accounts.hold_active_session(user, session)),
             {:ok, access} <- Access.authorize_locked(user, gym_id, permission),
             :ok <- completed(access.gym),
             :ok <- hit(user, limit),
             {:ok, value} <- fun.(access) do
          value
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  end

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  defp hit(%User{id: user_id}, {bucket, count, seconds}),
    do: RateLimit.hit([{bucket, MemberSecrets.rate_limit_key("user", user_id), count, seconds}])
end
