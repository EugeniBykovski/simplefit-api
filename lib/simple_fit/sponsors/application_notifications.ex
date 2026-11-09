defmodule SimpleFit.Sponsors.ApplicationNotifications do
  @moduledoc """
  The sponsor application notification outbox (SF-114, ADR 0032). Internal to
  `SimpleFit.Sponsors`.

  `notify!/5` runs **inside the caller's transaction**, which already holds the
  application's row lock: it records one intent per dedupe key
  (`sponsor_application_notifications`) and, when sending is enabled and a
  recipient address exists, enqueues the email as an Oban job in the same
  transaction (`SimpleFit.Email.deliver_later/1`). So a notification exists exactly
  when the change that caused it commits, and a rolled-back change sends nothing.

  Delivery is **at least once** with bounded retries (5 attempts, transient
  failures only) and a provider idempotency key per job; not exactly once. The job
  payload is encrypted (ADR 0011). The outbox row holds ids and codes only.

  Suppressed (recorded, not sent) when emails are disabled
  (`application_emails: false`, production until the copy is designed and
  approved), when there is no address, or when rendering fails. A failed or
  suppressed notification never fails the application change.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Email
  alias SimpleFit.Email.Templates
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.ApplicationNotification

  @unlogged [log: false]

  @doc "Whether sponsor application emails are sent in this environment."
  @spec enabled?() :: boolean()
  def enabled?,
    do: Application.get_env(:simple_fit, SimpleFit.Sponsors, [])[:application_emails] == true

  @doc """
  Records the intent `kind` for `recipient` once per `dedupe_key`, and enqueues it
  when possible. `render` returns `{:ok, rendered}`; `address` may be `nil`.
  Returns the notification row (`nil` when the key was already used).
  """
  @spec notify!(
          Ecto.UUID.t(),
          atom(),
          :applicant | :contact,
          String.t(),
          {String.t() | nil, (-> term())}
        ) ::
          ApplicationNotification.t() | nil
  def notify!(application_id, kind, recipient, dedupe_key, {address, render}) do
    if Repo.exists?(
         from(n in ApplicationNotification, where: n.dedupe_key == ^dedupe_key),
         @unlogged
       ) do
      nil
    else
      {status, reason, job_id} = deliver(kind, address, render)

      row =
        Repo.insert!(
          %ApplicationNotification{
            application_id: application_id,
            kind: kind,
            recipient: recipient,
            status: status,
            suppressed_reason: reason,
            dedupe_key: dedupe_key,
            oban_job_id: job_id
          },
          @unlogged
        )

      :telemetry.execute([:simple_fit, :sponsor_application, :notification], %{count: 1}, %{
        kind: kind,
        status: status
      })

      row
    end
  end

  defp deliver(kind, address, render) do
    cond do
      not enabled?() ->
        {:suppressed, "delivery_disabled", nil}

      not is_binary(address) ->
        {:suppressed, "no_recipient_address", nil}

      true ->
        with {:ok, rendered} <- render.(),
             {:ok, message} <- Templates.to_message(rendered, to: address),
             {:ok, job} <- Email.deliver_later(message) do
          {:queued, nil, job.id}
        else
          _failed ->
            Logger.error("sponsor application notification not queued: #{kind}")
            {:suppressed, "render_failed", nil}
        end
    end
  end
end
