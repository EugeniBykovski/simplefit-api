defmodule SimpleFit.EmailAuthHelpers do
  @moduledoc """
  Test helpers for passwordless email authentication (ADR 0012): read the
  emails queued for delivery (opening their encrypted payloads) and reset
  rate-limit windows.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.EmailAuth.Challenge
  alias SimpleFit.Email.{JobPayload, Message}
  alias SimpleFit.Repo

  @doc "Every queued email, oldest first."
  @spec queued_emails() :: [Message.t()]
  def queued_emails do
    from(j in Oban.Job,
      where: j.worker == "SimpleFit.Email.DeliveryWorker",
      order_by: [asc: j.id]
    )
    |> Repo.all()
    |> Enum.map(fn job ->
      {:ok, message} = JobPayload.open(job.args["payload"])
      message
    end)
  end

  @doc "The emails queued to `address`, oldest first."
  @spec emails_to(String.t()) :: [Message.t()]
  def emails_to(address), do: Enum.filter(queued_emails(), &(&1.to == [address]))

  @doc "The latest email queued to `address` (raises if none)."
  @spec last_email_to(String.t()) :: Message.t()
  def last_email_to(address),
    do: address |> emails_to() |> List.last() || raise("no email to #{address}")

  @doc "The 6-digit code of an E01 or E17 message."
  @spec code_from(Message.t()) :: String.t()
  def code_from(%Message{subject: subject}) do
    [_, code] = Regex.run(~r/code: (\d{6})\z/, subject)
    code
  end

  @doc "The link token of an E01 message."
  @spec link_token_from(Message.t()) :: String.t()
  def link_token_from(%Message{text: text}) do
    [_, token] = Regex.run(~r"/verify-email#token=(sfv_[A-Za-z0-9_-]{43})", text)
    token
  end

  @doc "Forgets every rate-limit window (the tests' clock never moves)."
  @spec reset_rate_limits() :: :ok
  def reset_rate_limits do
    Repo.query!("DELETE FROM auth_rate_limits", [])
    :ok
  end

  @doc "Moves every open challenge's expiry into the past."
  @spec expire_challenges() :: :ok
  def expire_challenges do
    past = DateTime.add(DateTime.utc_now(), -1)

    Repo.query!(
      "UPDATE email_auth_challenges SET inserted_at = inserted_at - interval '1 hour', expires_at = $1 WHERE closed_at IS NULL",
      [past]
    )

    :ok
  end

  @doc "All challenges, oldest first."
  @spec challenges() :: [Challenge.t()]
  def challenges, do: Repo.all(from(c in Challenge, order_by: [asc: c.inserted_at]))
end
