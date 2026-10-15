defmodule SimpleFit.Email.Templates.CoachInvite do
  @moduledoc """
  E08 · Coach invited you (`project/EmailCoachInvite.dc.html`, ADR 0011 as
  amended by SF-57).

  Sent when a coach invites someone by email (`SimpleFit.Coaching`). The
  copy is the interim truthful version approved for SF-57 until design CR-12
  and the legal texts land: it names the coach, says nothing is shared
  until the recipient reviews and accepts, lists exactly the fields the
  current disclosure version shares and what is never shared, and gives
  the expiry. It promises no team, sessions or other features. The
  recipient's name is not collected, so the greeting has none.

  Required variables:

    * `:coach_name` - the coach's display name, 1..80
    * `:coach_initials` - 1..3 uppercase letters for the avatar
    * `:coaching_name` - the coach's brand name, or the display name, 1..80
    * `:shared_fields` - labels of the fields the coach would see, 1..10
      lines of at most 60 characters (from the current disclosure version)
    * `:expires_on` - the `Date` the invitation expires
    * `:review_url` - absolute https URL of the invitation review page; the
      one-time token travels in its fragment (`#token=…`)

  Optional variables:

    * `:message` - the coach's personal note: user-written text, rendered
      as escaped plain text (never HTML), one paragraph, 1..500 characters
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    coach_name: :string,
    coach_initials: :string,
    coaching_name: :string,
    shared_fields: {:array, :string},
    expires_on: :date,
    message: :string,
    review_url: :string
  }

  @never_shared [
    "Your weight, height, goals and next fight",
    "Your account name, date of birth and email address",
    "Anything you share with other coaches"
  ]

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, [:message]) do
      frame = %{
        subject: "#{data.coach_name} invited you to connect on SimpleFit",
        preheader: "Nothing is shared unless you review and accept the invitation.",
        tag: "COACH INVITE",
        footer: :invitation
      }

      blocks = [
        {:identity, data.coach_initials, "COACH", data.coaching_name, nil},
        {:heading, "#{data.coach_name} invited you to connect as your coach on SimpleFit.", 24},
        if(data[:message],
          do: {:paragraph, ["“#{String.trim(data.message)}” — #{data.coach_name}"]}
        ),
        {:panel,
         [
           {:label, "IF YOU ACCEPT, YOUR COACH WILL SEE"},
           {:bullets, data.shared_fields, :check},
           {:label, "NEVER SHARED"},
           {:bullets, @never_shared, :dash},
           {:caption,
            "Nothing is shared unless you review and accept. You can remove access at any time.",
            :left}
         ]},
        {:paragraph,
         [
           "This invitation expires on #{Format.long_date(data.expires_on)}. Sign in with this email address to accept."
         ]},
        {:button, "Review invitation", data.review_url, :dark}
      ]

      Layout.render(:coach_invite, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:coach_name, 80)
    |> validate_format(:coach_initials, ~r/\A\p{Lu}{1,3}\z/u)
    |> Input.validate_line(:coaching_name, 80)
    |> Input.validate_lines(:shared_fields, 10, 60)
    |> Input.validate_line(:message, 500)
    |> Input.validate_url(:review_url)
  end
end
