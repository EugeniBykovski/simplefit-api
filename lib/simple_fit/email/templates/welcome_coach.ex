defmodule SimpleFit.Email.Templates.WelcomeCoach do
  @moduledoc """
  E03 · Welcome, coach (`project/EmailWelcomeCoach.dc.html`, ADR 0011).

  Sent after a coach registers. The trigger is deferred: no coach profile,
  identity check, licence review or payout domain exists yet. The renderer
  only accepts presentation data.

  Required variables:

    * `:coaching_name` - the coach's business name ("Yauheni Coaching"), 1..80
    * `:invite_url` - absolute https invite link, shown as text without its
      scheme
    * `:identity_check_pending` - boolean: the payouts identity check is
      still to do (shows that step and the "Finish payouts" button)
    * `:licence_review_pending` - boolean: the licence review is still
      running (shows that step)

  Conditionally required:

    * `:payouts_url` - absolute https URL of the payout setup; required
      while the identity check is pending, `:unexpected` otherwise

  Visible remaining actions are numbered in order after "Here’s what’s
  left:"; with none pending there is no list and no primary button. The
  preheader follows the pending actions. "Reply to this email" is fixed
  copy; the sender must set a monitored `reply_to`.
  """

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    coaching_name: :string,
    invite_url: :string,
    identity_check_pending: :boolean,
    licence_review_pending: :boolean,
    payouts_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, [:payouts_url]) do
      identity? = data.identity_check_pending
      licence? = data.licence_review_pending

      steps =
        [
          identity? &&
            {"Finish the identity check",
             "About 2 minutes. Needed before clients can pay for private sessions."},
          licence? &&
            {"Wait for licence review",
             "Our Trust team checks documents in 1–2 days. We’ll email you."}
        ]
        |> Enum.filter(& &1)

      frame = %{
        subject: "Your coaching space is ready",
        preheader: preheader(identity?, licence?),
        tag: "COACH",
        footer: :activity
      }

      blocks = [
        {:eyebrow, String.upcase(data.coaching_name)},
        {:heading, "Your coaching space is ready."},
        {:paragraph,
         [
           "Fighters can now book you and join your team." <>
             if(steps == [], do: "", else: " Here’s what’s left:")
         ]},
        if(steps != [], do: {:steps, steps}),
        {:panel,
         [
           {:label, "YOUR INVITE LINK"},
           {:mono, Format.bare_url(data.invite_url)},
           {:caption,
            "Fighters who join keep their own private log. You see training data only with their consent.",
            :left}
         ]},
        if(identity?, do: {:button, "Finish payouts", data.payouts_url, :dark}),
        {:paragraph, ["Questions? Reply to this email — a real person answers."], :note}
      ]

      Layout.render(:welcome_coach, frame, blocks)
    end
  end

  defp preheader(true, true), do: "Invite fighters, finish payouts, get your verified badge."
  defp preheader(true, false), do: "Invite fighters and finish payouts."
  defp preheader(false, true), do: "Invite fighters and get your verified badge."
  defp preheader(false, false), do: "Invite fighters with your link."

  defp checks(changeset) do
    identity? = Ecto.Changeset.get_field(changeset, :identity_check_pending) == true

    changeset
    |> Input.validate_line(:coaching_name, 80)
    |> Input.validate_url(:invite_url)
    |> then(&if identity?, do: Ecto.Changeset.validate_required(&1, [:payouts_url]), else: &1)
    |> Input.validate_only_if(:payouts_url, identity?)
    |> Input.validate_url(:payouts_url)
  end
end
