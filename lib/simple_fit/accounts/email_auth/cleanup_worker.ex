defmodule SimpleFit.Accounts.EmailAuth.CleanupWorker do
  @moduledoc """
  Hourly cleanup of email authentication state (ADR 0012), scheduled by
  `Oban.Plugins.Cron`:

    * challenges closed or expired more than an hour ago (they hold the
      email of pending registrations, so they are kept no longer than
      needed);
    * rate-limit windows that started more than two days ago (the longest
      window is one day).

  Deletes only what is already unusable, so it is safe to run at any time
  and on several nodes.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 300]

  alias SimpleFit.Accounts.EmailAuth
  alias SimpleFit.RateLimit

  @challenge_retention 60 * 60
  @rate_limit_retention 2 * 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    _challenges = EmailAuth.delete_finished_challenges(DateTime.add(now, -@challenge_retention))
    _windows = RateLimit.delete_stale(DateTime.add(now, -@rate_limit_retention))
    :ok
  end
end
