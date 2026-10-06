defmodule SimpleFit.Email.Templates.CoachInvite do
  @moduledoc """
  E08 · Coach invited you (`EmailCoachInvite.dc.html`, ADR 0011).

  Sent when a coach invites a fighter. The trigger is deferred: no coach
  profile, coach–fighter relationship, invitation or moderation domain
  exists yet. The renderer only accepts presentation data.

  Variables (all required):

    * `:fighter_name` - 1..80
    * `:coach_name` - the coach's first name ("Yauheni"), 1..80
    * `:coach_initials` - 1..3 uppercase letters for the avatar
    * `:coaching_name` - the coach's business name ("Yauheni Coaching"), 1..80
    * `:coach_tagline` - one line under the name, 1..80
    * `:coach_possessive` - `"his"`, `"her"` or `"their"`, for the
      design's preheader ("Join his team…"); never inferred from a name
    * `:message` - the coach's personal message: user-written text,
      rendered as escaped plain text, one paragraph, 1..500 characters
    * `:join_url` - absolute https URL to join the team

  The consent panel is the design's fixed copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{
    fighter_name: :string,
    coach_name: :string,
    coach_initials: :string,
    coaching_name: :string,
    coach_tagline: :string,
    coach_possessive: :string,
    message: :string,
    join_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "#{data.coach_name} invited you to train with #{data.coaching_name}",
        preheader: "Join #{data.coach_possessive} team on SimpleFit — your log stays yours.",
        tag: "COACH INVITE",
        footer: :invitation
      }

      blocks = [
        {:identity, data.coach_initials, "COACH", data.coaching_name, data.coach_tagline},
        {:heading, "Hi #{data.fighter_name}, train with me on SimpleFit.", 24},
        {:paragraph, ["“#{String.trim(data.message)}” — #{data.coach_name}"]},
        {:panel,
         [
           {:label, "WHAT YOUR COACH CAN SEE · ONLY IF YOU ALLOW"},
           {:bullets,
            [
              "Your trainings, rounds and attendance",
              "RPE, pain flags and weight during a camp",
              "Videos you choose to share"
            ], :check},
           {:caption,
            "Never your messages with others or your location. You can remove access any time.",
            :left}
         ]},
        {:button, "Join #{data.coach_name}’s team", data.join_url, :dark}
      ]

      Layout.render(:coach_invite, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:fighter_name, 80)
    |> Input.validate_line(:coach_name, 80)
    |> validate_format(:coach_initials, ~r/\A\p{Lu}{1,3}\z/u)
    |> Input.validate_line(:coaching_name, 80)
    |> Input.validate_line(:coach_tagline, 80)
    |> validate_inclusion(:coach_possessive, ~w(his her their))
    |> Input.validate_line(:message, 500)
    |> Input.validate_url(:join_url)
  end
end
