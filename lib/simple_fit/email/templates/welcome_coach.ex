defmodule SimpleFit.Email.Templates.WelcomeCoach do
  @moduledoc """
  E03 · Welcome, coach (`EmailWelcomeCoach.dc.html`, ADR 0011).

  Sent after a coach registers. The trigger is deferred: no coach profile,
  identity check, licence review or payout domain exists yet. The renderer
  only accepts presentation data.

  Variables (all required):

    * `:coaching_name` - the coach's business name ("Yauheni Coaching"), 1..80
    * `:invite_url` - absolute https invite link, shown as text without its
      scheme
    * `:payouts_url` - absolute https URL of the payout setup

  The two remaining steps, the consent note and "Reply to this email" are
  the design's fixed copy; the sender must set a monitored `reply_to`.
  """

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{coaching_name: :string, invite_url: :string, payouts_url: :string}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "Your coaching space is ready",
        preheader: "Invite fighters, finish payouts, get your verified badge.",
        tag: "COACH",
        footer: :activity
      }

      blocks = [
        {:eyebrow, String.upcase(data.coaching_name)},
        {:heading, "Your coaching space is ready."},
        {:paragraph, ["Fighters can now book you and join your team. Two things left:"]},
        {:steps,
         [
           {"Finish the identity check",
            "About 2 minutes. Needed before clients can pay for private sessions."},
           {"Wait for licence review",
            "Our Trust team checks documents in 1–2 days. We’ll email you."}
         ]},
        {:panel,
         [
           {:label, "YOUR INVITE LINK"},
           {:mono, Format.bare_url(data.invite_url)},
           {:caption,
            "Fighters who join keep their own private log. You see training data only with their consent.",
            :left}
         ]},
        {:button, "Finish payouts", data.payouts_url, :dark},
        {:paragraph, ["Questions? Reply to this email — a real person answers."], :note}
      ]

      Layout.render(:welcome_coach, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:coaching_name, 80)
    |> Input.validate_url(:invite_url)
    |> Input.validate_url(:payouts_url)
  end
end
