defmodule SimpleFit.Email.Templates.WelcomeFighter do
  @moduledoc """
  E02 · Welcome, fighter (`EmailWelcomeFighter.dc.html`, ADR 0011).

  A member email after a fighter registers. The trigger is deferred: no
  fighter profile, fight camp, gym or booking domain exists yet. The
  renderer only accepts presentation data; it reads nothing.

  Variables (all required):

    * `:first_name` - one line, 1..80 characters
    * `:camp_weeks` - fight camp length in weeks, 1..52
    * `:camp_ends_on` - `Date` the fight camp ends
    * `:first_class_time` - display time of the first class ("18:00 today"), 1..24
    * `:first_class_name` - class name ("Technical boxing"), 1..60
    * `:gym_name` - 1..80
    * `:first_class_room` - room or ring ("Ring 2"), 1..40
    * `:first_class_bring` - what to bring ("gloves 14 oz, wraps, mouthguard"), 1..120
    * `:next_class_hint` - the next bookable class ("Tue 19:30 pads has 4 spots left."), 1..120
    * `:app_url` - absolute https URL that opens SimpleFit
    * `:preferences_url`, `:unsubscribe_url` - absolute https URLs for the
      member footer, supplied by the sender (no preference system exists)

  The round-timer and training-partner steps and the privacy note are the
  design's fixed product copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    first_name: :string,
    camp_weeks: :integer,
    camp_ends_on: :date,
    first_class_time: :string,
    first_class_name: :string,
    gym_name: :string,
    first_class_room: :string,
    first_class_bring: :string,
    next_class_hint: :string,
    app_url: :string,
    preferences_url: :string,
    unsubscribe_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "You’re in, #{data.first_name} — here’s your first week",
        preheader: "Your class, your camp and the round timer are set.",
        tag: "WELCOME",
        footer: {:member, data.preferences_url, data.unsubscribe_url}
      }

      blocks = [
        {:eyebrow, "WELCOME TO SIMPLEFIT"},
        {:heading, "You’re in, #{data.first_name}."},
        {:paragraph,
         [
           "Your #{data.camp_weeks}-week fight camp ends ",
           {:strong, Format.weekday_date(data.camp_ends_on)},
           ". Here’s where to start."
         ]},
        {:panel,
         [
           {:label, "FIRST CLASS"},
           {:display, data.first_class_time},
           {:paragraph,
            ["#{data.first_class_name} · #{data.gym_name} · #{data.first_class_room}"], :lead},
           {:paragraph, ["Bring #{data.first_class_bring}. Front desk confirms your membership."],
            :note}
         ], :highlight},
        {:steps,
         [
           {"Book your next class", data.next_class_hint},
           {"Try the round timer", "Pro 12×3:00 is ready — bells, last-10 clap, rest."},
           {"Add a training partner",
            "Friends see what you share; weight and RPE never leave your phone."}
         ]},
        {:button, "Open SimpleFit", data.app_url, :dark},
        {:paragraph,
         [
           "Your trainings are visible to ",
           {:strong, "friends"},
           " by default. Change it any time in Settings → Privacy."
         ], :note}
      ]

      Layout.render(:welcome_fighter, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:first_name, 80)
    |> validate_number(:camp_weeks, greater_than_or_equal_to: 1, less_than_or_equal_to: 52)
    |> Input.validate_line(:first_class_time, 24)
    |> Input.validate_line(:first_class_name, 60)
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:first_class_room, 40)
    |> Input.validate_line(:first_class_bring, 120)
    |> Input.validate_line(:next_class_hint, 120)
    |> Input.validate_url(:app_url)
    |> Input.validate_url(:preferences_url)
    |> Input.validate_url(:unsubscribe_url)
  end
end
