defmodule SimpleFit.Email.Templates.WelcomeFighter do
  @moduledoc """
  E02 · Welcome, fighter (`project/EmailWelcomeFighter.dc.html`, ADR 0011).

  A member email after a fighter registers. The trigger is deferred: no
  fighter profile, fight camp, gym or booking domain exists yet. The
  renderer only accepts presentation data; it reads nothing.

  Required variables:

    * `:first_name` - one line, 1..80 characters
    * `:app_url` - absolute https URL that opens SimpleFit
    * `:preferences_url`, `:unsubscribe_url` - absolute https URLs for the
      member footer, supplied by the sender (no preference system exists)

  Optional variables (each group all or none):

    * camp: `:camp_weeks` (1..52) and `:camp_ends_on` (`Date`) - the
      "Your N-week fight camp ends …" sentence
    * first class: `:first_class_time` ("18:00 today", 1..24),
      `:first_class_name` (1..60), `:gym_name` (1..80), `:first_class_room`
      ("Ring 2", 1..40), `:first_class_bring` ("gloves 14 oz, wraps,
      mouthguard", 1..120) - the FIRST CLASS card
    * `:next_class_hint` - "Tue 19:30 pads has 4 spots left.", 1..120,
      under "Book your next class"

  The preheader names whichever of class and camp is present. The round
  timer and training-partner steps and the privacy note are fixed copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @camp [:camp_weeks, :camp_ends_on]
  @first_class [
    :first_class_time,
    :first_class_name,
    :gym_name,
    :first_class_room,
    :first_class_bring
  ]

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

  @optional @camp ++ @first_class ++ [:next_class_hint]

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, @optional) do
      camp? = Map.has_key?(data, :camp_weeks)
      class? = Map.has_key?(data, :first_class_time)

      frame = %{
        subject: "You’re in, #{data.first_name} — here’s your first week",
        preheader: preheader(class?, camp?),
        tag: "WELCOME",
        footer: {:member, data.preferences_url, data.unsubscribe_url}
      }

      blocks = [
        {:eyebrow, "WELCOME TO SIMPLEFIT"},
        {:heading, "You’re in, #{data.first_name}."},
        {:paragraph, camp_sentence(data, camp?) ++ ["Here’s where to start."]},
        if(class?, do: first_class(data)),
        {:steps,
         [
           {"Book your next class", data[:next_class_hint]},
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

  defp preheader(true, true), do: "Your class, your camp and the round timer are set."
  defp preheader(true, false), do: "Your class and the round timer are set."
  defp preheader(false, true), do: "Your camp and the round timer are set."
  defp preheader(false, false), do: "The round timer is set."

  defp camp_sentence(_data, false), do: []

  defp camp_sentence(data, true) do
    [
      "Your #{data.camp_weeks}-week fight camp ends ",
      {:strong, Format.weekday_date(data.camp_ends_on)},
      ". "
    ]
  end

  defp first_class(data) do
    {:panel,
     [
       {:label, "FIRST CLASS"},
       {:display, data.first_class_time},
       {:paragraph, ["#{data.first_class_name} · #{data.gym_name} · #{data.first_class_room}"],
        :lead},
       {:paragraph, ["Bring #{data.first_class_bring}. Front desk confirms your membership."],
        :note}
     ], :highlight}
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:first_name, 80)
    |> Input.validate_together(@camp)
    |> validate_number(:camp_weeks, greater_than_or_equal_to: 1, less_than_or_equal_to: 52)
    |> Input.validate_together(@first_class)
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
