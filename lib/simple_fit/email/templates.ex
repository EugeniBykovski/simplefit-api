defmodule SimpleFit.Email.Templates do
  @moduledoc """
  SimpleFit transactional email templates (ADR 0011).

  The application owns rendering; the email provider only delivers. Each
  designed email has an explicit function that validates its variables and
  returns a `SimpleFit.Email.Templates.Rendered` (subject, preheader, HTML,
  plain text). There is no generic or user-supplied template execution.

      {:ok, rendered} = Templates.verify_email(code: "407193", verify_url: url, expires_in_minutes: 10)
      {:ok, message} = Templates.to_message(rendered, to: address)
      {:ok, _job} = SimpleFit.Email.deliver_later(message)

  Invalid variables return `{:error, {:invalid_template_data, [{field, reason}]}}`
  before anything is rendered or enqueued. The domain that sends an email
  owns its trigger and idempotency; rendering is deterministic.

  Design traceability: `SimpleFit.Email.Templates.Inventory`.
  """

  alias SimpleFit.Email.Message
  alias SimpleFit.Email.Templates.{AccountDeleted, AccountSuspended, CoachInvite}
  alias SimpleFit.Email.Templates.{DataExportReady, DeletionScheduled, FirstWeekRecap, GymLive}
  alias SimpleFit.Email.Templates.{Input, JoinApproved, MemberInvite, RecoverAccount, Rendered}
  alias SimpleFit.Email.Templates.{StaffInvite, VerifyEmail, WelcomeCoach, WelcomeFighter}

  @type result :: {:ok, Rendered.t()} | {:error, Input.error()}

  @doc "E01 · Verify your email. See `SimpleFit.Email.Templates.VerifyEmail`."
  @spec verify_email(map() | keyword()) :: result()
  defdelegate verify_email(attrs), to: VerifyEmail, as: :render

  @doc "E02 · Welcome, fighter. See `SimpleFit.Email.Templates.WelcomeFighter`."
  @spec welcome_fighter(map() | keyword()) :: result()
  defdelegate welcome_fighter(attrs), to: WelcomeFighter, as: :render

  @doc "E03 · Welcome, coach. See `SimpleFit.Email.Templates.WelcomeCoach`."
  @spec welcome_coach(map() | keyword()) :: result()
  defdelegate welcome_coach(attrs), to: WelcomeCoach, as: :render

  @doc "E05 · Your gym is live. See `SimpleFit.Email.Templates.GymLive`."
  @spec gym_live(map() | keyword()) :: result()
  defdelegate gym_live(attrs), to: GymLive, as: :render

  @doc "E06 · Staff invitation. See `SimpleFit.Email.Templates.StaffInvite`."
  @spec staff_invite(map() | keyword()) :: result()
  defdelegate staff_invite(attrs), to: StaffInvite, as: :render

  @doc "E07 · Member invite from gym. See `SimpleFit.Email.Templates.MemberInvite`."
  @spec member_invite(map() | keyword()) :: result()
  defdelegate member_invite(attrs), to: MemberInvite, as: :render

  @doc "E08 · Coach invited you. See `SimpleFit.Email.Templates.CoachInvite`."
  @spec coach_invite(map() | keyword()) :: result()
  defdelegate coach_invite(attrs), to: CoachInvite, as: :render

  @doc "E09 · Join request approved. See `SimpleFit.Email.Templates.JoinApproved`."
  @spec join_approved(map() | keyword()) :: result()
  defdelegate join_approved(attrs), to: JoinApproved, as: :render

  @doc "E11 · Recover your account. See `SimpleFit.Email.Templates.RecoverAccount`."
  @spec recover_account(map() | keyword()) :: result()
  defdelegate recover_account(attrs), to: RecoverAccount, as: :render

  @doc "E12 · First week recap. See `SimpleFit.Email.Templates.FirstWeekRecap`."
  @spec first_week_recap(map() | keyword()) :: result()
  defdelegate first_week_recap(attrs), to: FirstWeekRecap, as: :render

  @doc "E13 · Account suspended. See `SimpleFit.Email.Templates.AccountSuspended`."
  @spec account_suspended(map() | keyword()) :: result()
  defdelegate account_suspended(attrs), to: AccountSuspended, as: :render

  @doc "E14 · Deletion scheduled. See `SimpleFit.Email.Templates.DeletionScheduled`."
  @spec deletion_scheduled(map() | keyword()) :: result()
  defdelegate deletion_scheduled(attrs), to: DeletionScheduled, as: :render

  @doc "E15 · Account deleted. See `SimpleFit.Email.Templates.AccountDeleted`."
  @spec account_deleted(map() | keyword()) :: result()
  defdelegate account_deleted(attrs), to: AccountDeleted, as: :render

  @doc "E16 · Data export ready. See `SimpleFit.Email.Templates.DataExportReady`."
  @spec data_export_ready(map() | keyword()) :: result()
  defdelegate data_export_ready(attrs), to: DataExportReady, as: :render

  @doc """
  Builds the `SimpleFit.Email.Message` for a rendered template: the HTML and
  plain-text parts together. `opts` are message fields: `:to` (required),
  `:reply_to`, `:from`.
  """
  @spec to_message(Rendered.t(), keyword()) :: {:ok, Message.t()} | {:error, :invalid_request}
  def to_message(%Rendered{} = rendered, opts) do
    opts
    |> Keyword.take([:to, :reply_to, :from])
    |> Keyword.merge(subject: rendered.subject, html: rendered.html, text: rendered.text)
    |> Message.new()
  end
end
